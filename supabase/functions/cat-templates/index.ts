// supabase/functions/cat-templates/index.ts
// Catalog Studio - Templates Edge Function
// Templates created from blocks (tenant-specific + global system templates)

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-internal-signature, x-timestamp, x-is-admin, x-environment',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS'
};

console.log('Cat-Templates Edge Function - Starting up');

serve(async (req: Request) => {
  const startTime = Date.now();
  const operationId = `cat_templates_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

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
    const environmentHeader = req.headers.get('x-environment') || 'live';

    // Validate required headers
    if (!authHeader) {
      return createErrorResponse('Authorization header is required', 'MISSING_AUTH', 401, operationId);
    }

    if (!tenantIdHeader) {
      return createErrorResponse('x-tenant-id header is required', 'MISSING_TENANT', 400, operationId);
    }

    if (!isValidUUID(tenantIdHeader)) {
      return createErrorResponse('Invalid tenant ID format', 'INVALID_TENANT_ID', 400, operationId);
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

    // Parse context
    const isAdmin = isAdminHeader === 'true';
    const isLive = environmentHeader === 'live';
    const tenantId = tenantIdHeader;

    // Create Supabase client
    const supabase = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });

    // Parse URL
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const lastSegment = pathSegments[pathSegments.length - 1];

    console.log(`[cat-templates] ${req.method} ${url.pathname}`, {
      operationId,
      tenantId,
      isAdmin,
      isLive,
      queryParams: Object.fromEntries(url.searchParams.entries())
    });

    // Route handlers
    switch (req.method) {
      case 'GET':
        // GET /cat-templates/health - Health check
        if (lastSegment === 'health') {
          return createSuccessResponse({
            status: 'ok',
            message: 'Cat-Templates edge function is healthy',
            timestamp: new Date().toISOString()
          }, operationId, startTime);
        }

        // GET /cat-templates/system - System templates only
        if (lastSegment === 'system') {
          return await handleGetSystemTemplates(supabase, url.searchParams, operationId, startTime);
        }

        // GET /cat-templates/public - Public templates
        if (lastSegment === 'public') {
          return await handleGetPublicTemplates(supabase, url.searchParams, operationId, startTime);
        }

        // GET /cat-templates?id={id} - Get single template
        const templateId = url.searchParams.get('id');
        if (templateId) {
          return await handleGetTemplateById(supabase, templateId, tenantId, isAdmin, isLive, operationId, startTime);
        }

        // GET /cat-templates - List tenant's templates + system templates
        return await handleGetTemplates(supabase, url.searchParams, tenantId, isAdmin, isLive, operationId, startTime);

      case 'POST':
        // POST /cat-templates/copy?id={id} - Copy system template to tenant
        if (lastSegment === 'copy') {
          const copyId = url.searchParams.get('id');
          if (!copyId) {
            return createErrorResponse('Template ID is required for copy', 'MISSING_ID', 400, operationId);
          }
          const copyBody = requestBody ? JSON.parse(requestBody) : {};
          return await handleCopyTemplate(supabase, copyId, tenantId, isLive, copyBody, operationId, startTime);
        }

        // POST /cat-templates - Create template
        const createBody = requestBody ? JSON.parse(requestBody) : {};
        return await handleCreateTemplate(supabase, createBody, tenantId, isAdmin, isLive, operationId, startTime);

      case 'PATCH':
        // PATCH /cat-templates?id={id} - Update template
        const updateId = url.searchParams.get('id');
        if (!updateId) {
          return createErrorResponse('Template ID is required for update', 'MISSING_ID', 400, operationId);
        }
        const updateBody = requestBody ? JSON.parse(requestBody) : {};
        return await handleUpdateTemplate(supabase, updateId, updateBody, tenantId, isAdmin, operationId, startTime);

      case 'DELETE':
        // DELETE /cat-templates?id={id} - Soft delete template
        const deleteId = url.searchParams.get('id');
        if (!deleteId) {
          return createErrorResponse('Template ID is required for delete', 'MISSING_ID', 400, operationId);
        }
        return await handleDeleteTemplate(supabase, deleteId, tenantId, isAdmin, operationId, startTime);

      default:
        return createErrorResponse(`Method ${req.method} not allowed`, 'METHOD_NOT_ALLOWED', 405, operationId);
    }

  } catch (error: any) {
    console.error('[cat-templates] Unhandled error:', error);
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
 * GET /cat-templates - List tenant's templates + available system templates
 */
async function handleGetTemplates(
  supabase: any,
  params: URLSearchParams,
  tenantId: string,
  isAdmin: boolean,
  isLive: boolean,
  operationId: string,
  startTime: number
) {
  // Build query for tenant's own templates
  let query = supabase
    .from('cat_templates')
    .select('*')
    .eq('is_active', true);

  if (isAdmin) {
    // Admin sees all templates
  } else {
    // Regular users see:
    // 1. Their own tenant's templates (matching is_live)
    // 2. System templates (tenant_id IS NULL, is_system = true)
    query = query.or(`tenant_id.eq.${tenantId},and(tenant_id.is.null,is_system.eq.true)`);
    query = query.or(`is_live.eq.${isLive},tenant_id.is.null`);
  }

  // Filter by category
  const category = params.get('category');
  if (category) {
    query = query.eq('category', category);
  }

  // Filter by is_system
  const isSystem = params.get('is_system');
  if (isSystem !== null) {
    query = query.eq('is_system', isSystem === 'true');
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
    console.error('[cat-templates] Query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, operationId);
  }

  // Separate own templates and system templates
  const ownTemplates = (data || []).filter((t: any) => t.tenant_id === tenantId);
  const systemTemplates = (data || []).filter((t: any) => t.tenant_id === null && t.is_system);

  return createSuccessResponse({
    templates: data || [],
    own_templates: ownTemplates,
    system_templates: systemTemplates,
    count: data?.length || 0,
    filters: { category, is_system: isSystem, search, is_live: isLive }
  }, operationId, startTime);
}

/**
 * GET /cat-templates/system - System templates only
 */
async function handleGetSystemTemplates(
  supabase: any,
  params: URLSearchParams,
  operationId: string,
  startTime: number
) {
  let query = supabase
    .from('cat_templates')
    .select('*')
    .is('tenant_id', null)
    .eq('is_system', true)
    .eq('is_active', true);

  // Filter by category
  const category = params.get('category');
  if (category) {
    query = query.eq('category', category);
  }

  // Filter by industry_tags
  const industryTag = params.get('industry');
  if (industryTag) {
    query = query.contains('industry_tags', [industryTag]);
  }

  // Search
  const search = params.get('search');
  if (search) {
    query = query.ilike('name', `%${search}%`);
  }

  query = query.order('sequence_no', { ascending: true }).order('name', { ascending: true });

  const { data, error } = await query;

  if (error) {
    console.error('[cat-templates] System query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, operationId);
  }

  return createSuccessResponse({
    templates: data || [],
    count: data?.length || 0,
    type: 'system'
  }, operationId, startTime);
}

/**
 * GET /cat-templates/public - Public templates
 */
async function handleGetPublicTemplates(
  supabase: any,
  params: URLSearchParams,
  operationId: string,
  startTime: number
) {
  let query = supabase
    .from('cat_templates')
    .select('*')
    .eq('is_public', true)
    .eq('is_active', true);

  // Filter by category
  const category = params.get('category');
  if (category) {
    query = query.eq('category', category);
  }

  // Search
  const search = params.get('search');
  if (search) {
    query = query.ilike('name', `%${search}%`);
  }

  query = query.order('sequence_no', { ascending: true });

  const { data, error } = await query;

  if (error) {
    console.error('[cat-templates] Public query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, operationId);
  }

  return createSuccessResponse({
    templates: data || [],
    count: data?.length || 0,
    type: 'public'
  }, operationId, startTime);
}

/**
 * GET /cat-templates?id={id} - Get single template
 */
async function handleGetTemplateById(
  supabase: any,
  templateId: string,
  tenantId: string,
  isAdmin: boolean,
  isLive: boolean,
  operationId: string,
  startTime: number
) {
  if (!isValidUUID(templateId)) {
    return createErrorResponse('Invalid template ID format', 'INVALID_ID', 400, operationId);
  }

  const { data, error } = await supabase
    .from('cat_templates')
    .select('*')
    .eq('id', templateId)
    .single();

  if (error) {
    if (error.code === 'PGRST116') {
      return createErrorResponse('Template not found', 'NOT_FOUND', 404, operationId);
    }
    console.error('[cat-templates] Get by ID error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, operationId);
  }

  // Check access
  if (!isAdmin) {
    const isOwner = data.tenant_id === tenantId;
    const isSystemTemplate = data.tenant_id === null && data.is_system;
    const isPublic = data.is_public;

    if (!isOwner && !isSystemTemplate && !isPublic) {
      return createErrorResponse('Access denied to this template', 'FORBIDDEN', 403, operationId);
    }
  }

  return createSuccessResponse({ template: data }, operationId, startTime);
}

/**
 * POST /cat-templates - Create template
 */
async function handleCreateTemplate(
  supabase: any,
  body: any,
  tenantId: string,
  isAdmin: boolean,
  isLive: boolean,
  operationId: string,
  startTime: number
) {
  // Validate required fields
  if (!body.name) {
    return createErrorResponse('Template name is required', 'VALIDATION_ERROR', 400, operationId);
  }

  // Determine tenant_id (admin can create system templates with tenant_id = null)
  let templateTenantId = tenantId;
  if (isAdmin && body.is_system === true) {
    templateTenantId = null; // System template
  }

  // Prepare insert data
  const insertData = {
    tenant_id: templateTenantId,
    is_live: templateTenantId === null ? true : isLive, // System templates are always "live"
    name: body.name,
    display_name: body.display_name || body.name,
    description: body.description || null,
    category: body.category || null,
    tags: body.tags || [],
    cover_image: body.cover_image || null,
    blocks: body.blocks || [],
    currency: body.currency || 'INR',
    tax_rate: body.tax_rate ?? 18.00,
    discount_config: body.discount_config || { allowed: true, max_percent: 20 },
    subtotal: body.subtotal || null,
    total: body.total || null,
    settings: body.settings || {},
    is_system: isAdmin && body.is_system === true,
    copied_from_id: null,
    industry_tags: body.industry_tags || [],
    is_public: body.is_public ?? false,
    is_active: body.is_active ?? true,
    status_id: body.status_id || null,
    sequence_no: body.sequence_no || 0,
    is_deletable: body.is_deletable ?? true,
    created_by: body.created_by || null,
    updated_by: body.created_by || null
  };

  const { data, error } = await supabase
    .from('cat_templates')
    .insert(insertData)
    .select()
    .single();

  if (error) {
    console.error('[cat-templates] Create error:', error);
    return createErrorResponse(error.message, error.code || 'CREATE_ERROR', 500, operationId);
  }

  console.log(`[cat-templates] Created template: ${data.id} (tenant: ${templateTenantId || 'SYSTEM'})`);

  return new Response(
    JSON.stringify({
      success: true,
      data: { template: data },
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
 * POST /cat-templates/copy?id={id} - Copy system template to tenant space
 */
async function handleCopyTemplate(
  supabase: any,
  templateId: string,
  tenantId: string,
  isLive: boolean,
  body: any,
  operationId: string,
  startTime: number
) {
  if (!isValidUUID(templateId)) {
    return createErrorResponse('Invalid template ID format', 'INVALID_ID', 400, operationId);
  }

  // Get the source template
  const { data: source, error: sourceError } = await supabase
    .from('cat_templates')
    .select('*')
    .eq('id', templateId)
    .single();

  if (sourceError || !source) {
    return createErrorResponse('Source template not found', 'NOT_FOUND', 404, operationId);
  }

  // Only system templates can be copied (or admin can copy any)
  if (!source.is_system && source.tenant_id !== tenantId) {
    return createErrorResponse('Can only copy system templates or your own templates', 'FORBIDDEN', 403, operationId);
  }

  // Create copy for tenant
  const copyData = {
    tenant_id: tenantId,
    is_live: isLive,
    name: body.name || `${source.name} (Copy)`,
    display_name: body.display_name || source.display_name,
    description: source.description,
    category: source.category,
    tags: source.tags,
    cover_image: source.cover_image,
    blocks: source.blocks,
    currency: source.currency,
    tax_rate: source.tax_rate,
    discount_config: source.discount_config,
    subtotal: source.subtotal,
    total: source.total,
    settings: source.settings,
    is_system: false, // Copy is never a system template
    copied_from_id: templateId,
    industry_tags: source.industry_tags,
    is_public: false, // Copies are private by default
    is_active: true,
    status_id: source.status_id,
    sequence_no: 0,
    is_deletable: true,
    created_by: body.created_by || null
  };

  const { data, error } = await supabase
    .from('cat_templates')
    .insert(copyData)
    .select()
    .single();

  if (error) {
    console.error('[cat-templates] Copy error:', error);
    return createErrorResponse(error.message, error.code || 'COPY_ERROR', 500, operationId);
  }

  console.log(`[cat-templates] Copied template ${templateId} to ${data.id} for tenant ${tenantId}`);

  return new Response(
    JSON.stringify({
      success: true,
      data: {
        template: data,
        copied_from: templateId
      },
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
 * PATCH /cat-templates?id={id} - Update template
 */
async function handleUpdateTemplate(
  supabase: any,
  templateId: string,
  body: any,
  tenantId: string,
  isAdmin: boolean,
  operationId: string,
  startTime: number
) {
  if (!isValidUUID(templateId)) {
    return createErrorResponse('Invalid template ID format', 'INVALID_ID', 400, operationId);
  }

  // Check if template exists and user has access
  const { data: existing, error: checkError } = await supabase
    .from('cat_templates')
    .select('id, tenant_id, version, is_system')
    .eq('id', templateId)
    .single();

  if (checkError || !existing) {
    return createErrorResponse('Template not found', 'NOT_FOUND', 404, operationId);
  }

  // Check ownership (admin can update any, tenant can only update their own)
  if (!isAdmin && existing.tenant_id !== tenantId) {
    return createErrorResponse('Cannot update templates you do not own', 'FORBIDDEN', 403, operationId);
  }

  // Prepare update data
  const updateData: any = {
    updated_at: new Date().toISOString(),
    version: existing.version + 1
  };

  // Map allowed update fields
  const allowedFields = [
    'name', 'display_name', 'description', 'category', 'tags', 'cover_image',
    'blocks', 'currency', 'tax_rate', 'discount_config', 'subtotal', 'total',
    'settings', 'industry_tags', 'is_public', 'is_active', 'status_id',
    'sequence_no', 'is_deletable', 'updated_by'
  ];

  // Admin-only fields
  if (isAdmin) {
    allowedFields.push('is_system', 'tenant_id');
  }

  for (const field of allowedFields) {
    if (body[field] !== undefined) {
      updateData[field] = body[field];
    }
  }

  const { data, error } = await supabase
    .from('cat_templates')
    .update(updateData)
    .eq('id', templateId)
    .select()
    .single();

  if (error) {
    console.error('[cat-templates] Update error:', error);
    return createErrorResponse(error.message, error.code || 'UPDATE_ERROR', 500, operationId);
  }

  console.log(`[cat-templates] Updated template: ${templateId}`);

  return createSuccessResponse({ template: data }, operationId, startTime);
}

/**
 * DELETE /cat-templates?id={id} - Soft delete template
 */
async function handleDeleteTemplate(
  supabase: any,
  templateId: string,
  tenantId: string,
  isAdmin: boolean,
  operationId: string,
  startTime: number
) {
  if (!isValidUUID(templateId)) {
    return createErrorResponse('Invalid template ID format', 'INVALID_ID', 400, operationId);
  }

  // Check if template exists
  const { data: existing, error: checkError } = await supabase
    .from('cat_templates')
    .select('id, tenant_id, is_deletable, name')
    .eq('id', templateId)
    .single();

  if (checkError || !existing) {
    return createErrorResponse('Template not found', 'NOT_FOUND', 404, operationId);
  }

  // Check ownership
  if (!isAdmin && existing.tenant_id !== tenantId) {
    return createErrorResponse('Cannot delete templates you do not own', 'FORBIDDEN', 403, operationId);
  }

  if (!existing.is_deletable) {
    return createErrorResponse(`Template "${existing.name}" cannot be deleted`, 'NOT_DELETABLE', 400, operationId);
  }

  // Soft delete
  const { error } = await supabase
    .from('cat_templates')
    .update({
      is_active: false,
      updated_at: new Date().toISOString()
    })
    .eq('id', templateId);

  if (error) {
    console.error('[cat-templates] Delete error:', error);
    return createErrorResponse(error.message, error.code || 'DELETE_ERROR', 500, operationId);
  }

  console.log(`[cat-templates] Soft deleted template: ${templateId}`);

  return createSuccessResponse({
    message: 'Template deleted successfully',
    template_id: templateId
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
    const requestTime = parseInt(timestamp);
    const now = Date.now();
    if (Math.abs(now - requestTime) > 5 * 60 * 1000) {
      console.warn('[cat-templates] Signature timestamp expired');
      return false;
    }

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
    console.error('[cat-templates] Signature verification error:', error);
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
