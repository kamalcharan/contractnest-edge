// supabase/functions/cat-blocks/index.ts
// Catalog Studio - Blocks Edge Function
// Version: 2.0 - With optimistic locking, pagination, idempotency, and replay protection

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import {
  corsHeaders,
  verifySignature,
  validateRequestSignature,
  parsePaginationParams,
  applyPagination,
  checkIdempotency,
  storeIdempotency,
  checkVersionConflict,
  createSuccessResponse,
  createErrorResponse,
  isValidUUID,
  generateOperationId,
  extractRequestContext,
  MAX_PAGE_SIZE,
  EdgeContext,
  PaginationParams
} from "../_shared/edgeUtils.ts";

console.log('Cat-Blocks Edge Function v2.0 - Starting up');

serve(async (req: Request) => {
  const startTime = Date.now();
  const operationId = generateOperationId('cat_blocks');

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // ========================================================================
    // STEP 1: Environment validation
    // ========================================================================
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSecret = Deno.env.get('INTERNAL_SIGNING_SECRET') || '';

    if (!supabaseUrl || !supabaseServiceKey) {
      return createErrorResponse('Missing required environment variables', 'CONFIGURATION_ERROR', 500, operationId);
    }

    // ========================================================================
    // STEP 2: Header validation
    // ========================================================================
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return createErrorResponse('Authorization header is required', 'MISSING_AUTH', 401, operationId);
    }

    const tenantIdHeader = req.headers.get('x-tenant-id');
    if (!tenantIdHeader) {
      return createErrorResponse('x-tenant-id header is required', 'MISSING_TENANT', 400, operationId);
    }

    // ========================================================================
    // STEP 3: Read body and validate signature
    // ========================================================================
    const requestBody = req.method !== 'GET' ? await req.text() : '';

    const signatureError = await validateRequestSignature(req, requestBody, internalSecret, operationId);
    if (signatureError) {
      return signatureError;
    }

    // ========================================================================
    // STEP 4: Extract context
    // ========================================================================
    const context = extractRequestContext(req, operationId, startTime);
    if (!context) {
      return createErrorResponse('Invalid request context', 'BAD_REQUEST', 400, operationId);
    }

    // ========================================================================
    // STEP 5: Create Supabase client
    // ========================================================================
    const supabase = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });

    // ========================================================================
    // STEP 6: Parse URL and route
    // ========================================================================
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const lastSegment = pathSegments[pathSegments.length - 1];

    console.log(`[cat-blocks] ${req.method} ${url.pathname}`, {
      operationId,
      tenantId: context.tenantId,
      isAdmin: context.isAdmin,
      hasIdempotencyKey: !!context.idempotencyKey,
      queryParams: Object.fromEntries(url.searchParams.entries())
    });

    // ========================================================================
    // STEP 7: Route to handlers
    // ========================================================================
    switch (req.method) {
      case 'GET':
        if (lastSegment === 'health') {
          return createSuccessResponse({
            status: 'ok',
            version: '2.0',
            message: 'Cat-Blocks edge function is healthy',
            features: ['optimistic_locking', 'pagination', 'idempotency', 'replay_protection']
          }, operationId, startTime);
        }

        if (lastSegment === 'admin') {
          if (!context.isAdmin) {
            return createErrorResponse('Admin access required', 'FORBIDDEN', 403, operationId);
          }
          return await handleGetBlocksAdmin(supabase, url.searchParams, context);
        }

        const blockId = url.searchParams.get('id');
        if (blockId) {
          return await handleGetBlockById(supabase, blockId, context);
        }

        return await handleGetBlocks(supabase, url.searchParams, context);

      case 'POST':
        // Check idempotency first
        const createIdempotency = await checkIdempotency(
          supabase, context.idempotencyKey, context.tenantId, operationId, startTime
        );
        if (createIdempotency.found && createIdempotency.response) {
          return createIdempotency.response;
        }

        const createBody = requestBody ? JSON.parse(requestBody) : {};
        return await handleCreateBlock(supabase, createBody, context);

      case 'PATCH':
        const updateId = url.searchParams.get('id');
        if (!updateId) {
          return createErrorResponse('Block ID is required for update', 'MISSING_ID', 400, operationId);
        }

        // Check idempotency
        const updateIdempotency = await checkIdempotency(
          supabase, context.idempotencyKey, context.tenantId, operationId, startTime
        );
        if (updateIdempotency.found && updateIdempotency.response) {
          return updateIdempotency.response;
        }

        const updateBody = requestBody ? JSON.parse(requestBody) : {};
        return await handleUpdateBlock(supabase, updateId, updateBody, context);

      case 'DELETE':
        const deleteId = url.searchParams.get('id');
        if (!deleteId) {
          return createErrorResponse('Block ID is required for delete', 'MISSING_ID', 400, operationId);
        }
        return await handleDeleteBlock(supabase, deleteId, context);

      default:
        return createErrorResponse(`Method ${req.method} not allowed`, 'METHOD_NOT_ALLOWED', 405, operationId);
    }

  } catch (error: any) {
    console.error('[cat-blocks] Unhandled error:', error);
    return createErrorResponse(error.message, 'INTERNAL_ERROR', 500, operationId);
  }
});

// ============================================================================
// HANDLER: GET /cat-blocks - List blocks with pagination
// ============================================================================
async function handleGetBlocks(
  supabase: any,
  params: URLSearchParams,
  ctx: EdgeContext
) {
  // Parse pagination (backward compatible)
  const pagination = parsePaginationParams(params);

  // Build base query
  let query = supabase.from('cat_blocks').select('*', { count: 'exact' });

  // Visibility filter
  if (!ctx.isAdmin) {
    query = query.or(
      `and(tenant_id.is.null,is_active.eq.true,visible.eq.true),` +
      `and(is_seed.eq.true,is_active.eq.true),` +
      `tenant_id.eq.${ctx.tenantId}`
    );
  }

  // Apply filters
  const blockTypeId = params.get('block_type_id');
  if (blockTypeId) query = query.eq('block_type_id', blockTypeId);

  const category = params.get('category');
  if (category) query = query.eq('category', category);

  const pricingModeId = params.get('pricing_mode_id');
  if (pricingModeId) query = query.eq('pricing_mode_id', pricingModeId);

  const filterTenantId = params.get('tenant_id');
  if (filterTenantId) {
    if (filterTenantId === 'null' || filterTenantId === 'global') {
      query = query.is('tenant_id', null);
    } else {
      query = query.eq('tenant_id', filterTenantId);
    }
  }

  const search = params.get('search');
  if (search) {
    query = query.ilike('name', `%${search}%`);
  }

  // Order
  query = query.order('sequence_no', { ascending: true }).order('name', { ascending: true });

  // Apply pagination
  query = applyPagination(query, pagination, MAX_PAGE_SIZE);

  const { data, error, count } = await query;

  if (error) {
    console.error('[cat-blocks] Query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  // Build response (backward compatible)
  const responseData: any = {
    blocks: data || [],
    count: data?.length || 0,
    filters: {
      block_type_id: blockTypeId,
      category,
      pricing_mode_id: pricingModeId,
      tenant_id: filterTenantId,
      search,
      is_admin_view: ctx.isAdmin
    }
  };

  // Add pagination if requested
  if (pagination) {
    responseData.pagination = {
      page: pagination.page,
      limit: pagination.limit,
      total: count || 0,
      has_more: pagination.offset + pagination.limit < (count || 0)
    };
  }

  return createSuccessResponse(responseData, ctx.operationId, ctx.startTime);
}

// ============================================================================
// HANDLER: GET /cat-blocks/admin - Admin view with pagination
// ============================================================================
async function handleGetBlocksAdmin(
  supabase: any,
  params: URLSearchParams,
  ctx: EdgeContext
) {
  const pagination = parsePaginationParams(params);

  let query = supabase.from('cat_blocks').select('*', { count: 'exact' });

  // Admin filters
  const isActive = params.get('is_active');
  if (isActive !== null) query = query.eq('is_active', isActive === 'true');

  const visible = params.get('visible');
  if (visible !== null) query = query.eq('visible', visible === 'true');

  const isAdminBlocks = params.get('is_admin');
  if (isAdminBlocks !== null) query = query.eq('is_admin', isAdminBlocks === 'true');

  const isSeed = params.get('is_seed');
  if (isSeed !== null) query = query.eq('is_seed', isSeed === 'true');

  const filterTenantId = params.get('tenant_id');
  if (filterTenantId) {
    if (filterTenantId === 'null' || filterTenantId === 'global') {
      query = query.is('tenant_id', null);
    } else {
      query = query.eq('tenant_id', filterTenantId);
    }
  }

  const blockTypeId = params.get('block_type_id');
  if (blockTypeId) query = query.eq('block_type_id', blockTypeId);

  const search = params.get('search');
  if (search) query = query.ilike('name', `%${search}%`);

  query = query.order('sequence_no', { ascending: true }).order('name', { ascending: true });
  query = applyPagination(query, pagination, MAX_PAGE_SIZE);

  const { data, error, count } = await query;

  if (error) {
    console.error('[cat-blocks] Admin query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  const responseData: any = {
    blocks: data || [],
    count: data?.length || 0,
    admin_view: true
  };

  if (pagination) {
    responseData.pagination = {
      page: pagination.page,
      limit: pagination.limit,
      total: count || 0,
      has_more: pagination.offset + pagination.limit < (count || 0)
    };
  }

  return createSuccessResponse(responseData, ctx.operationId, ctx.startTime);
}

// ============================================================================
// HANDLER: GET /cat-blocks?id={id}
// ============================================================================
async function handleGetBlockById(
  supabase: any,
  blockId: string,
  ctx: EdgeContext
) {
  if (!isValidUUID(blockId)) {
    return createErrorResponse('Invalid block ID format', 'INVALID_ID', 400, ctx.operationId);
  }

  const { data, error } = await supabase
    .from('cat_blocks')
    .select('*')
    .eq('id', blockId)
    .single();

  if (error) {
    if (error.code === 'PGRST116') {
      return createErrorResponse('Block not found', 'NOT_FOUND', 404, ctx.operationId);
    }
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  // Visibility check for non-admin
  if (!ctx.isAdmin) {
    const isGlobalVisible = data.tenant_id === null && data.is_active && data.visible;
    const isSeedVisible = data.is_seed && data.is_active;
    const isOwnTenant = data.tenant_id === ctx.tenantId;

    if (!isGlobalVisible && !isSeedVisible && !isOwnTenant) {
      return createErrorResponse('Block not found', 'NOT_FOUND', 404, ctx.operationId);
    }
  }

  return createSuccessResponse({ block: data }, ctx.operationId, ctx.startTime);
}

// ============================================================================
// HANDLER: POST /cat-blocks - Create with idempotency
// ============================================================================
async function handleCreateBlock(
  supabase: any,
  body: any,
  ctx: EdgeContext
) {
  // Validate required fields
  if (!body.name) {
    return createErrorResponse('Block name is required', 'VALIDATION_ERROR', 400, ctx.operationId);
  }
  if (!body.block_type_id) {
    return createErrorResponse('Block type is required', 'VALIDATION_ERROR', 400, ctx.operationId);
  }

  // Determine tenant_id
  let blockTenantId = ctx.tenantId;

  if (body.tenant_id === null || body.is_seed === true) {
    if (!ctx.isAdmin) {
      return createErrorResponse('Only admins can create global or seed blocks', 'FORBIDDEN', 403, ctx.operationId);
    }
    blockTenantId = body.tenant_id;
  } else if (body.tenant_id) {
    if (body.tenant_id !== ctx.tenantId && !ctx.isAdmin) {
      return createErrorResponse('Cannot create blocks for other tenants', 'FORBIDDEN', 403, ctx.operationId);
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
    tenant_id: blockTenantId,
    is_seed: body.is_seed ?? false,
    is_live: body.is_live ?? ctx.isLive
  };

  const { data, error } = await supabase
    .from('cat_blocks')
    .insert(insertData)
    .select()
    .single();

  if (error) {
    console.error('[cat-blocks] Create error:', error);
    return createErrorResponse(error.message, error.code || 'CREATE_ERROR', 500, ctx.operationId);
  }

  console.log(`[cat-blocks] Created block: ${data.id} for tenant: ${blockTenantId || 'GLOBAL'}`);

  // Prepare response
  const responseBody = {
    success: true,
    data: { block: data },
    metadata: {
      request_id: ctx.operationId,
      duration_ms: Date.now() - ctx.startTime,
      timestamp: new Date().toISOString()
    }
  };

  // Store idempotency
  await storeIdempotency(supabase, ctx.idempotencyKey, ctx.tenantId, responseBody);

  return new Response(JSON.stringify(responseBody), {
    status: 201,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

// ============================================================================
// HANDLER: PATCH /cat-blocks?id={id} - Update with optimistic locking
// ============================================================================
async function handleUpdateBlock(
  supabase: any,
  blockId: string,
  body: any,
  ctx: EdgeContext
) {
  if (!isValidUUID(blockId)) {
    return createErrorResponse('Invalid block ID format', 'INVALID_ID', 400, ctx.operationId);
  }

  // Get existing block with version
  const { data: existing, error: checkError } = await supabase
    .from('cat_blocks')
    .select('id, version, tenant_id, is_seed')
    .eq('id', blockId)
    .single();

  if (checkError || !existing) {
    return createErrorResponse('Block not found', 'NOT_FOUND', 404, ctx.operationId);
  }

  // Permission check
  if (!ctx.isAdmin) {
    if (existing.tenant_id === null || existing.is_seed || existing.tenant_id !== ctx.tenantId) {
      return createErrorResponse('Cannot update this block', 'FORBIDDEN', 403, ctx.operationId);
    }
  }

  // Check client-provided version if present (optional optimistic locking from client)
  if (body.expected_version !== undefined && body.expected_version !== existing.version) {
    return createErrorResponse(
      `Block was modified by another user. Expected version ${body.expected_version}, current version ${existing.version}. Please refresh and try again.`,
      'VERSION_CONFLICT',
      409,
      ctx.operationId
    );
  }

  // Prepare update data
  const updateData: any = {
    updated_at: new Date().toISOString(),
    version: existing.version + 1
  };

  const allowedFields = [
    'name', 'display_name', 'block_type_id', 'icon', 'description', 'category',
    'tags', 'config', 'pricing_mode_id', 'base_price', 'currency', 'price_type_id',
    'tax_rate', 'hsn_sac_code', 'resource_pricing', 'variant_pricing',
    'is_admin', 'visible', 'status_id', 'is_active', 'is_live', 'sequence_no', 'is_deletable', 'updated_by'
  ];

  const adminOnlyFields = ['tenant_id', 'is_seed'];

  for (const field of allowedFields) {
    if (body[field] !== undefined) {
      updateData[field] = body[field];
    }
  }

  if (ctx.isAdmin) {
    for (const field of adminOnlyFields) {
      if (body[field] !== undefined) {
        updateData[field] = body[field];
      }
    }
  }

  // ⚡ OPTIMISTIC LOCKING: Include version check in update
  const { data, error } = await supabase
    .from('cat_blocks')
    .update(updateData)
    .eq('id', blockId)
    .eq('version', existing.version)  // <-- Optimistic lock!
    .select()
    .single();

  // Check for version conflict (no rows updated)
  const conflictResponse = checkVersionConflict(data, error, 'Block', ctx.operationId);
  if (conflictResponse) {
    return conflictResponse;
  }

  if (error) {
    console.error('[cat-blocks] Update error:', error);
    return createErrorResponse(error.message, error.code || 'UPDATE_ERROR', 500, ctx.operationId);
  }

  console.log(`[cat-blocks] Updated block: ${blockId} (v${existing.version} → v${data.version})`);

  // Prepare response
  const responseBody = {
    success: true,
    data: { block: data },
    metadata: {
      request_id: ctx.operationId,
      duration_ms: Date.now() - ctx.startTime,
      timestamp: new Date().toISOString()
    }
  };

  // Store idempotency
  await storeIdempotency(supabase, ctx.idempotencyKey, ctx.tenantId, responseBody);

  return createSuccessResponse({ block: data }, ctx.operationId, ctx.startTime);
}

// ============================================================================
// HANDLER: DELETE /cat-blocks?id={id} - Soft delete
// ============================================================================
async function handleDeleteBlock(
  supabase: any,
  blockId: string,
  ctx: EdgeContext
) {
  if (!isValidUUID(blockId)) {
    return createErrorResponse('Invalid block ID format', 'INVALID_ID', 400, ctx.operationId);
  }

  // Check existence and permissions
  const { data: existing, error: checkError } = await supabase
    .from('cat_blocks')
    .select('id, is_deletable, name, tenant_id, is_seed')
    .eq('id', blockId)
    .single();

  if (checkError || !existing) {
    return createErrorResponse('Block not found', 'NOT_FOUND', 404, ctx.operationId);
  }

  // Permission check
  if (!ctx.isAdmin) {
    if (existing.tenant_id === null || existing.is_seed || existing.tenant_id !== ctx.tenantId) {
      return createErrorResponse('Cannot delete this block', 'FORBIDDEN', 403, ctx.operationId);
    }
  }

  if (!existing.is_deletable) {
    return createErrorResponse(`Block "${existing.name}" cannot be deleted`, 'NOT_DELETABLE', 400, ctx.operationId);
  }

  // Soft delete
  const { error } = await supabase
    .from('cat_blocks')
    .update({
      is_active: false,
      updated_at: new Date().toISOString()
    })
    .eq('id', blockId);

  if (error) {
    console.error('[cat-blocks] Delete error:', error);
    return createErrorResponse(error.message, error.code || 'DELETE_ERROR', 500, ctx.operationId);
  }

  console.log(`[cat-blocks] Soft deleted block: ${blockId}`);

  return createSuccessResponse({
    message: 'Block deleted successfully',
    block_id: blockId
  }, ctx.operationId, ctx.startTime);
}
