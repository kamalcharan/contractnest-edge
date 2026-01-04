// supabase/functions/cat-blocks/index.ts
// Catalog Studio - Blocks Edge Function
// Supports both GLOBAL blocks and TENANT-SPECIFIC blocks

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-internal-signature, x-timestamp, x-is-admin',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS'
};

console.log('Cat-Blocks Edge Function - Starting up');

serve(async (req: Request) => {
  const startTime = Date.now();
  const operationId = `cat_blocks_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Environment variables
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');

    if (!supabaseUrl || !supabaseServiceKey) {
      return createErrorResponse('Missing required environment variables', 'CONFIGURATION_ERROR', 500, operationId);
    }

    // Extract headers
    const authHeader = req.headers.get('Authorization');
    const tenantIdHeader = req.headers.get('x-tenant-id');
    const internalSignature = req.headers.get('x-internal-signature');
    const timestamp = req.headers.get('x-timestamp');
    const isAdminHeader = req.headers.get('x-is-admin');

    // Validate required headers
    if (!authHeader) {
      return createErrorResponse('Authorization header is required', 'MISSING_AUTH', 401, operationId);
    }

    if (!tenantIdHeader) {
      return createErrorResponse('x-tenant-id header is required', 'MISSING_TENANT', 400, operationId);
    }

    // Validate internal signature (API must sign requests)
    if (!internalSignature || !timestamp) {
      return new Response(
        JSON.stringify({
          success: false,
          error: {
            code: 'FORBIDDEN',
            message: 'Direct access to edge functions is not allowed. Requests must come through the API layer.'
          },
          metadata: { request_id: operationId, timestamp: new Date().toISOString() }
        }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Read request body for signature verification (for non-GET requests)
    const requestBody = req.method !== 'GET' ? await req.text() : '';

    // Verify HMAC signature
    const isValidSignature = await verifyInternalSignature(
      requestBody,
      internalSignature,
      timestamp,
      internalSecret || ''
    );

    if (!isValidSignature) {
      return new Response(
        JSON.stringify({
          success: false,
          error: { code: 'INVALID_SIGNATURE', message: 'Invalid internal signature.' },
          metadata: { request_id: operationId, timestamp: new Date().toISOString() }
        }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Parse isAdmin from header (for visibility filtering, NOT for blocking CRUD)
    const isAdmin = isAdminHeader === 'true';

    // Create Supabase client
    const supabase = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });

    // Parse URL
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const lastSegment = pathSegments[pathSegments.length - 1];

    console.log(`[cat-blocks] ${req.method} ${url.pathname}`, {
      operationId,
      tenantId: tenantIdHeader,
      isAdmin,
      queryParams: Object.fromEntries(url.searchParams.entries())
    });

    // Route handlers
    switch (req.method) {
      case 'GET':
        // GET /cat-blocks/health - Health check
        if (lastSegment === 'health') {
          return createSuccessResponse({
            status: 'ok',
            message: 'Cat-Blocks edge function is healthy',
            timestamp: new Date().toISOString()
          }, operationId, startTime);
        }

        // GET /cat-blocks/admin - Admin view (all blocks including invisible)
        if (lastSegment === 'admin') {
          if (!isAdmin) {
            return createErrorResponse('Admin access required', 'FORBIDDEN', 403, operationId);
          }
          return await handleGetBlocksAdmin(supabase, url.searchParams, tenantIdHeader, operationId, startTime);
        }

        // GET /cat-blocks?id={id} - Get single block
        const blockId = url.searchParams.get('id');
        if (blockId) {
          return await handleGetBlockById(supabase, blockId, tenantIdHeader, isAdmin, operationId, startTime);
        }

        // GET /cat-blocks - List blocks (filtered for non-admin)
        return await handleGetBlocks(supabase, url.searchParams, tenantIdHeader, isAdmin, operationId, startTime);

      case 'POST':
        // POST /cat-blocks - Create block
        // REMOVED: isAdmin check - anyone can create blocks for their tenant
        const createBody = requestBody ? JSON.parse(requestBody) : {};
        return await handleCreateBlock(supabase, createBody, tenantIdHeader, isAdmin, operationId, startTime);

      case 'PATCH':
        // PATCH /cat-blocks?id={id} - Update block
        // REMOVED: isAdmin check - anyone can update their tenant's blocks
        const updateId = url.searchParams.get('id');
        if (!updateId) {
          return createErrorResponse('Block ID is required for update', 'MISSING_ID', 400, operationId);
        }
        const updateBody = requestBody ? JSON.parse(requestBody) : {};
        return await handleUpdateBlock(supabase, updateId, updateBody, tenantIdHeader, isAdmin, operationId, startTime);

      case 'DELETE':
        // DELETE /cat-blocks?id={id} - Soft delete block
        // REMOVED: isAdmin check - anyone can delete their tenant's blocks
        const deleteId = url.searchParams.get('id');
        if (!deleteId) {
          return createErrorResponse('Block ID is required for delete', 'MISSING_ID', 400, operationId);
        }
        return await handleDeleteBlock(supabase, deleteId, tenantIdHeader, isAdmin, operationId, startTime);

      default:
        return createErrorResponse(`Method ${req.method} not allowed`, 'METHOD_NOT_ALLOWED', 405, operationId);
    }

  } catch (error: any) {
    console.error('[cat-blocks] Unhandled error:', error);
    return new Response(
      JSON.stringify({
        success: false,
        error: { code: 'INTERNAL_ERROR', message: error.message },
        metadata: { request_id: operationId, timestamp: new Date().toISOString() }
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

// ============================================================================
// HANDLER FUNCTIONS
// ============================================================================

/**
 * GET /cat-blocks - List blocks
 * Returns:
 * - Global blocks (tenant_id IS NULL) that are active + visible
 * - Seed blocks (is_seed = true) that are active
 * - Tenant's own blocks
 * - Admin sees all
 */
async function handleGetBlocks(
  supabase: any,
  params: URLSearchParams,
  tenantId: string,
  isAdmin: boolean,
  operationId: string,
  startTime: number
) {
  let query = supabase.from('cat_blocks').select('*');

  // Build visibility filter based on role
  if (!isAdmin) {
    // Non-admin: See global blocks (active+visible) OR seed blocks (active) OR own tenant's blocks
    query = query.or(
      `and(tenant_id.is.null,is_active.eq.true,visible.eq.true),` +
      `and(is_seed.eq.true,is_active.eq.true),` +
      `tenant_id.eq.${tenantId}`
    );
  }
  // Admin sees all blocks

  // Filter by block_type_id
  const blockTypeId = params.get('block_type_id');
  if (blockTypeId) {
    query = query.eq('block_type_id', blockTypeId);
  }

  // Filter by category
  const category = params.get('category');
  if (category) {
    query = query.eq('category', category);
  }

  // Filter by pricing_mode_id
  const pricingModeId = params.get('pricing_mode_id');
  if (pricingModeId) {
    query = query.eq('pricing_mode_id', pricingModeId);
  }

  // Filter by tenant_id (optional explicit filter)
  const filterTenantId = params.get('tenant_id');
  if (filterTenantId) {
    if (filterTenantId === 'null' || filterTenantId === 'global') {
      query = query.is('tenant_id', null);
    } else {
      query = query.eq('tenant_id', filterTenantId);
    }
  }

  // Search by name
  const search = params.get('search');
  if (search) {
    query = query.ilike('name', `%${search}%`);
  }

  // Order by sequence_no, then name
  query = query.order('sequence_no', { ascending: true }).order('name', { ascending: true });

  const { data, error } = await query;

  if (error) {
    console.error('[cat-blocks] Query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, operationId);
  }

  return createSuccessResponse({
    blocks: data || [],
    count: data?.length || 0,
    filters: {
      block_type_id: blockTypeId,
      category,
      pricing_mode_id: pricingModeId,
      tenant_id: filterTenantId,
      search,
      is_admin_view: isAdmin
    }
  }, operationId, startTime);
}

/**
 * GET /cat-blocks/admin - Admin view (all blocks including invisible)
 */
async function handleGetBlocksAdmin(
  supabase: any,
  params: URLSearchParams,
  tenantId: string,
  operationId: string,
  startTime: number
) {
  let query = supabase.from('cat_blocks').select('*');

  // Filter by is_active (optional for admin)
  const isActive = params.get('is_active');
  if (isActive !== null) {
    query = query.eq('is_active', isActive === 'true');
  }

  // Filter by visible (optional for admin)
  const visible = params.get('visible');
  if (visible !== null) {
    query = query.eq('visible', visible === 'true');
  }

  // Filter by is_admin blocks only
  const isAdminBlocks = params.get('is_admin');
  if (isAdminBlocks !== null) {
    query = query.eq('is_admin', isAdminBlocks === 'true');
  }

  // Filter by is_seed
  const isSeed = params.get('is_seed');
  if (isSeed !== null) {
    query = query.eq('is_seed', isSeed === 'true');
  }

  // Filter by tenant_id
  const filterTenantId = params.get('tenant_id');
  if (filterTenantId) {
    if (filterTenantId === 'null' || filterTenantId === 'global') {
      query = query.is('tenant_id', null);
    } else {
      query = query.eq('tenant_id', filterTenantId);
    }
  }

  // Filter by block_type_id
  const blockTypeId = params.get('block_type_id');
  if (blockTypeId) {
    query = query.eq('block_type_id', blockTypeId);
  }

  // Search by name
  const search = params.get('search');
  if (search) {
    query = query.ilike('name', `%${search}%`);
  }

  // Order
  query = query.order('sequence_no', { ascending: true }).order('name', { ascending: true });

  const { data, error } = await query;

  if (error) {
    console.error('[cat-blocks] Admin query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, operationId);
  }

  return createSuccessResponse({
    blocks: data || [],
    count: data?.length || 0,
    admin_view: true
  }, operationId, startTime);
}

/**
 * GET /cat-blocks?id={id} - Get single block
 */
async function handleGetBlockById(
  supabase: any,
  blockId: string,
  tenantId: string,
  isAdmin: boolean,
  operationId: string,
  startTime: number
) {
  // Validate UUID format
  if (!isValidUUID(blockId)) {
    return createErrorResponse('Invalid block ID format', 'INVALID_ID', 400, operationId);
  }

  let query = supabase.from('cat_blocks').select('*').eq('id', blockId);

  const { data, error } = await query.single();

  if (error) {
    if (error.code === 'PGRST116') {
      return createErrorResponse('Block not found', 'NOT_FOUND', 404, operationId);
    }
    console.error('[cat-blocks] Get by ID error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, operationId);
  }

  // Check visibility for non-admin
  if (!isAdmin) {
    const block = data;
    const isGlobalVisible = block.tenant_id === null && block.is_active && block.visible;
    const isSeedVisible = block.is_seed && block.is_active;
    const isOwnTenant = block.tenant_id === tenantId;

    if (!isGlobalVisible && !isSeedVisible && !isOwnTenant) {
      return createErrorResponse('Block not found', 'NOT_FOUND', 404, operationId);
    }
  }

  return createSuccessResponse({ block: data }, operationId, startTime);
}

/**
 * POST /cat-blocks - Create block
 * Anyone can create blocks for their tenant
 * Only admin can create global (tenant_id = null) or seed blocks
 */
async function handleCreateBlock(
  supabase: any,
  body: any,
  tenantId: string,
  isAdmin: boolean,
  operationId: string,
  startTime: number
) {
  // Validate required fields
  if (!body.name) {
    return createErrorResponse('Block name is required', 'VALIDATION_ERROR', 400, operationId);
  }
  if (!body.block_type_id) {
    return createErrorResponse('Block type is required', 'VALIDATION_ERROR', 400, operationId);
  }

  // Determine tenant_id for the block
  let blockTenantId = tenantId; // Default: use request tenant

  // Only admin can create global blocks (tenant_id = null) or seed blocks
  if (body.tenant_id === null || body.is_seed === true) {
    if (!isAdmin) {
      return createErrorResponse('Only admins can create global or seed blocks', 'FORBIDDEN', 403, operationId);
    }
    blockTenantId = body.tenant_id; // Allow null for global blocks
  } else if (body.tenant_id) {
    // If explicit tenant_id provided, validate it matches request or user is admin
    if (body.tenant_id !== tenantId && !isAdmin) {
      return createErrorResponse('Cannot create blocks for other tenants', 'FORBIDDEN', 403, operationId);
    }
    blockTenantId = body.tenant_id;
  }

  // Prepare insert data
  const insertData = {
    name: body.name,
    display_name: body.display_name || body.name,
    block_type_id: body.block_type_id,
    icon: body.icon || '📦',
    description: body.description || null,
    category: body.category || null,
    tags: body.tags || [],
    config: body.config || {},
    pricing_mode_id: body.pricing_mode_id || null,
    base_price: body.base_price || null,
    currency: body.currency || 'INR',
    price_type_id: body.price_type_id || null,
    tax_rate: body.tax_rate ?? 18.00,
    hsn_sac_code: body.hsn_sac_code || null,
    resource_pricing: body.resource_pricing || null,
    variant_pricing: body.variant_pricing || null,
    is_admin: body.is_admin ?? false,
    visible: body.visible ?? true,
    status_id: body.status_id || null,
    is_active: body.is_active ?? true,
    sequence_no: body.sequence_no || 0,
    is_deletable: body.is_deletable ?? true,
    created_by: body.created_by || null,
    updated_by: body.created_by || null,
    // NEW FIELDS
    tenant_id: blockTenantId,
    is_seed: body.is_seed ?? false
  };

  const { data, error } = await supabase
    .from('cat_blocks')
    .insert(insertData)
    .select()
    .single();

  if (error) {
    console.error('[cat-blocks] Create error:', error);
    return createErrorResponse(error.message, error.code || 'CREATE_ERROR', 500, operationId);
  }

  console.log(`[cat-blocks] Created block: ${data.id} for tenant: ${blockTenantId || 'GLOBAL'}`);

  return new Response(
    JSON.stringify({
      success: true,
      data: { block: data },
      metadata: {
        request_id: operationId,
        duration_ms: Date.now() - startTime,
        timestamp: new Date().toISOString()
      }
    }),
    { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}

/**
 * PATCH /cat-blocks?id={id} - Update block
 * Users can update their tenant's blocks
 * Only admin can update global or seed blocks
 */
async function handleUpdateBlock(
  supabase: any,
  blockId: string,
  body: any,
  tenantId: string,
  isAdmin: boolean,
  operationId: string,
  startTime: number
) {
  // Validate UUID format
  if (!isValidUUID(blockId)) {
    return createErrorResponse('Invalid block ID format', 'INVALID_ID', 400, operationId);
  }

  // Check if block exists and user has permission
  const { data: existing, error: checkError } = await supabase
    .from('cat_blocks')
    .select('id, version, tenant_id, is_seed')
    .eq('id', blockId)
    .single();

  if (checkError || !existing) {
    return createErrorResponse('Block not found', 'NOT_FOUND', 404, operationId);
  }

  // Permission check: Can only update own tenant's blocks unless admin
  if (!isAdmin) {
    if (existing.tenant_id === null || existing.is_seed || existing.tenant_id !== tenantId) {
      return createErrorResponse('Cannot update this block', 'FORBIDDEN', 403, operationId);
    }
  }

  // Prepare update data (only include provided fields)
  const updateData: any = {
    updated_at: new Date().toISOString(),
    version: existing.version + 1
  };

  // Map allowed update fields
  const allowedFields = [
    'name', 'display_name', 'block_type_id', 'icon', 'description', 'category',
    'tags', 'config', 'pricing_mode_id', 'base_price', 'currency', 'price_type_id',
    'tax_rate', 'hsn_sac_code', 'resource_pricing', 'variant_pricing',
    'is_admin', 'visible', 'status_id', 'is_active', 'sequence_no', 'is_deletable', 'updated_by'
  ];

  // Admin-only fields
  const adminOnlyFields = ['tenant_id', 'is_seed'];

  for (const field of allowedFields) {
    if (body[field] !== undefined) {
      updateData[field] = body[field];
    }
  }

  // Handle admin-only fields
  if (isAdmin) {
    for (const field of adminOnlyFields) {
      if (body[field] !== undefined) {
        updateData[field] = body[field];
      }
    }
  }

  const { data, error } = await supabase
    .from('cat_blocks')
    .update(updateData)
    .eq('id', blockId)
    .select()
    .single();

  if (error) {
    console.error('[cat-blocks] Update error:', error);
    return createErrorResponse(error.message, error.code || 'UPDATE_ERROR', 500, operationId);
  }

  console.log(`[cat-blocks] Updated block: ${blockId}`);

  return createSuccessResponse({ block: data }, operationId, startTime);
}

/**
 * DELETE /cat-blocks?id={id} - Soft delete block
 * Users can delete their tenant's blocks
 * Only admin can delete global or seed blocks
 */
async function handleDeleteBlock(
  supabase: any,
  blockId: string,
  tenantId: string,
  isAdmin: boolean,
  operationId: string,
  startTime: number
) {
  // Validate UUID format
  if (!isValidUUID(blockId)) {
    return createErrorResponse('Invalid block ID format', 'INVALID_ID', 400, operationId);
  }

  // Check if block exists and is deletable
  const { data: existing, error: checkError } = await supabase
    .from('cat_blocks')
    .select('id, is_deletable, name, tenant_id, is_seed')
    .eq('id', blockId)
    .single();

  if (checkError || !existing) {
    return createErrorResponse('Block not found', 'NOT_FOUND', 404, operationId);
  }

  // Permission check: Can only delete own tenant's blocks unless admin
  if (!isAdmin) {
    if (existing.tenant_id === null || existing.is_seed || existing.tenant_id !== tenantId) {
      return createErrorResponse('Cannot delete this block', 'FORBIDDEN', 403, operationId);
    }
  }

  if (!existing.is_deletable) {
    return createErrorResponse(`Block "${existing.name}" cannot be deleted`, 'NOT_DELETABLE', 400, operationId);
  }

  // Soft delete (set is_active = false)
  const { error } = await supabase
    .from('cat_blocks')
    .update({
      is_active: false,
      updated_at: new Date().toISOString()
    })
    .eq('id', blockId);

  if (error) {
    console.error('[cat-blocks] Delete error:', error);
    return createErrorResponse(error.message, error.code || 'DELETE_ERROR', 500, operationId);
  }

  console.log(`[cat-blocks] Soft deleted block: ${blockId}`);

  return createSuccessResponse({
    message: 'Block deleted successfully',
    block_id: blockId
  }, operationId, startTime);
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/**
 * Verify HMAC signature from API
 */
async function verifyInternalSignature(
  body: string,
  signature: string,
  timestamp: string,
  secret: string
): Promise<boolean> {
  try {
    // Check timestamp is within 5 minutes
    const requestTime = parseInt(timestamp);
    const now = Date.now();
    if (Math.abs(now - requestTime) > 5 * 60 * 1000) {
      console.warn('[cat-blocks] Signature timestamp expired');
      return false;
    }

    // Generate expected signature
    const payload = `${timestamp}.${body}`;
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      'raw',
      encoder.encode(secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );
    const signatureBuffer = await crypto.subtle.sign('HMAC', key, encoder.encode(payload));
    const expectedSignature = btoa(String.fromCharCode(...new Uint8Array(signatureBuffer)));

    return signature === expectedSignature;
  } catch (error) {
    console.error('[cat-blocks] Signature verification error:', error);
    return false;
  }
}

/**
 * Validate UUID format
 */
function isValidUUID(str: string): boolean {
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  return uuidRegex.test(str);
}

/**
 * Create success response
 */
function createSuccessResponse(data: any, operationId: string, startTime: number) {
  return new Response(
    JSON.stringify({
      success: true,
      data,
      metadata: {
        request_id: operationId,
        duration_ms: Date.now() - startTime,
        timestamp: new Date().toISOString()
      }
    }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}

/**
 * Create error response
 */
function createErrorResponse(message: string, code: string, status: number, operationId: string) {
  return new Response(
    JSON.stringify({
      success: false,
      error: { code, message },
      metadata: {
        request_id: operationId,
        timestamp: new Date().toISOString()
      }
    }),
    { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}
