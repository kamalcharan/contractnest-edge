// supabase/functions/cat-templates/index.ts
// Catalog Studio - Templates Edge Function
// Version: 2.0 - With optimistic locking, pagination, idempotency, and replay protection

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import {
  corsHeaders,
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
  EdgeContext
} from "../_shared/edgeUtils.ts";

console.log('Cat-Templates Edge Function v2.0 - Starting up');

serve(async (req: Request) => {
  const startTime = Date.now();
  const operationId = generateOperationId('cat_templates');

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

    if (!isValidUUID(tenantIdHeader)) {
      return createErrorResponse('Invalid tenant ID format', 'INVALID_TENANT_ID', 400, operationId);
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

    console.log(`[cat-templates] ${req.method} ${url.pathname}`, {
      operationId,
      tenantId: context.tenantId,
      isAdmin: context.isAdmin,
      isLive: context.isLive,
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
            message: 'Cat-Templates edge function is healthy',
            features: ['optimistic_locking', 'pagination', 'idempotency', 'replay_protection']
          }, operationId, startTime);
        }

        if (lastSegment === 'system') {
          return await handleGetSystemTemplates(supabase, url.searchParams, context);
        }

        if (lastSegment === 'public') {
          return await handleGetPublicTemplates(supabase, url.searchParams, context);
        }

        const templateId = url.searchParams.get('id');
        if (templateId) {
          return await handleGetTemplateById(supabase, templateId, context);
        }

        return await handleGetTemplates(supabase, url.searchParams, context);

      case 'POST':
        if (lastSegment === 'copy') {
          const copyId = url.searchParams.get('id');
          if (!copyId) {
            return createErrorResponse('Template ID is required for copy', 'MISSING_ID', 400, operationId);
          }

          // Check idempotency for copy
          const copyIdempotency = await checkIdempotency(
            supabase, context.idempotencyKey, context.tenantId, operationId, startTime
          );
          if (copyIdempotency.found && copyIdempotency.response) {
            return copyIdempotency.response;
          }

          const copyBody = requestBody ? JSON.parse(requestBody) : {};
          return await handleCopyTemplate(supabase, copyId, copyBody, context);
        }

        // Check idempotency for create
        const createIdempotency = await checkIdempotency(
          supabase, context.idempotencyKey, context.tenantId, operationId, startTime
        );
        if (createIdempotency.found && createIdempotency.response) {
          return createIdempotency.response;
        }

        const createBody = requestBody ? JSON.parse(requestBody) : {};
        return await handleCreateTemplate(supabase, createBody, context);

      case 'PATCH':
        const updateId = url.searchParams.get('id');
        if (!updateId) {
          return createErrorResponse('Template ID is required for update', 'MISSING_ID', 400, operationId);
        }

        // Check idempotency
        const updateIdempotency = await checkIdempotency(
          supabase, context.idempotencyKey, context.tenantId, operationId, startTime
        );
        if (updateIdempotency.found && updateIdempotency.response) {
          return updateIdempotency.response;
        }

        const updateBody = requestBody ? JSON.parse(requestBody) : {};
        return await handleUpdateTemplate(supabase, updateId, updateBody, context);

      case 'DELETE':
        const deleteId = url.searchParams.get('id');
        if (!deleteId) {
          return createErrorResponse('Template ID is required for delete', 'MISSING_ID', 400, operationId);
        }
        return await handleDeleteTemplate(supabase, deleteId, context);

      default:
        return createErrorResponse(`Method ${req.method} not allowed`, 'METHOD_NOT_ALLOWED', 405, operationId);
    }

  } catch (error: any) {
    console.error('[cat-templates] Unhandled error:', error);
    return createErrorResponse(error.message, 'INTERNAL_ERROR', 500, operationId);
  }
});

// ============================================================================
// HANDLER: GET /cat-templates - List templates with pagination
// ============================================================================
async function handleGetTemplates(
  supabase: any,
  params: URLSearchParams,
  ctx: EdgeContext
) {
  const pagination = parsePaginationParams(params);

  let query = supabase
    .from('cat_templates')
    .select('*', { count: 'exact' })
    .eq('is_active', true);

  // Visibility filter
  if (!ctx.isAdmin) {
    query = query.or(`tenant_id.eq.${ctx.tenantId},and(tenant_id.is.null,is_system.eq.true)`);
    query = query.or(`is_live.eq.${ctx.isLive},tenant_id.is.null`);
  }

  // Filters
  const category = params.get('category');
  if (category) query = query.eq('category', category);

  const isSystem = params.get('is_system');
  if (isSystem !== null) query = query.eq('is_system', isSystem === 'true');

  const search = params.get('search');
  if (search) query = query.ilike('name', `%${search}%`);

  // Order
  query = query.order('sequence_no', { ascending: true }).order('name', { ascending: true });

  // Apply pagination
  query = applyPagination(query, pagination, MAX_PAGE_SIZE);

  const { data, error, count } = await query;

  if (error) {
    console.error('[cat-templates] Query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  // Separate templates
  const ownTemplates = (data || []).filter((t: any) => t.tenant_id === ctx.tenantId);
  const systemTemplates = (data || []).filter((t: any) => t.tenant_id === null && t.is_system);

  const responseData: any = {
    templates: data || [],
    own_templates: ownTemplates,
    system_templates: systemTemplates,
    count: data?.length || 0,
    filters: { category, is_system: isSystem, search, is_live: ctx.isLive }
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
// HANDLER: GET /cat-templates/system - System templates with pagination
// ============================================================================
async function handleGetSystemTemplates(
  supabase: any,
  params: URLSearchParams,
  ctx: EdgeContext
) {
  const pagination = parsePaginationParams(params);

  let query = supabase
    .from('cat_templates')
    .select('*', { count: 'exact' })
    .is('tenant_id', null)
    .eq('is_system', true)
    .eq('is_active', true);

  const category = params.get('category');
  if (category) query = query.eq('category', category);

  const industryTag = params.get('industry');
  if (industryTag) query = query.contains('industry_tags', [industryTag]);

  const search = params.get('search');
  if (search) query = query.ilike('name', `%${search}%`);

  query = query.order('sequence_no', { ascending: true }).order('name', { ascending: true });
  query = applyPagination(query, pagination, MAX_PAGE_SIZE);

  const { data, error, count } = await query;

  if (error) {
    console.error('[cat-templates] System query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  const responseData: any = {
    templates: data || [],
    count: data?.length || 0,
    type: 'system'
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
// HANDLER: GET /cat-templates/public - Public templates with pagination
// ============================================================================
async function handleGetPublicTemplates(
  supabase: any,
  params: URLSearchParams,
  ctx: EdgeContext
) {
  const pagination = parsePaginationParams(params);

  let query = supabase
    .from('cat_templates')
    .select('*', { count: 'exact' })
    .eq('is_public', true)
    .eq('is_active', true);

  const category = params.get('category');
  if (category) query = query.eq('category', category);

  const search = params.get('search');
  if (search) query = query.ilike('name', `%${search}%`);

  query = query.order('sequence_no', { ascending: true });
  query = applyPagination(query, pagination, MAX_PAGE_SIZE);

  const { data, error, count } = await query;

  if (error) {
    console.error('[cat-templates] Public query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  const responseData: any = {
    templates: data || [],
    count: data?.length || 0,
    type: 'public'
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
// HANDLER: GET /cat-templates?id={id}
// ============================================================================
async function handleGetTemplateById(
  supabase: any,
  templateId: string,
  ctx: EdgeContext
) {
  if (!isValidUUID(templateId)) {
    return createErrorResponse('Invalid template ID format', 'INVALID_ID', 400, ctx.operationId);
  }

  const { data, error } = await supabase
    .from('cat_templates')
    .select('*')
    .eq('id', templateId)
    .single();

  if (error) {
    if (error.code === 'PGRST116') {
      return createErrorResponse('Template not found', 'NOT_FOUND', 404, ctx.operationId);
    }
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  // Access check
  if (!ctx.isAdmin) {
    const isOwner = data.tenant_id === ctx.tenantId;
    const isSystemTemplate = data.tenant_id === null && data.is_system;
    const isPublic = data.is_public;

    if (!isOwner && !isSystemTemplate && !isPublic) {
      return createErrorResponse('Access denied to this template', 'FORBIDDEN', 403, ctx.operationId);
    }
  }

  return createSuccessResponse({ template: data }, ctx.operationId, ctx.startTime);
}

// ============================================================================
// HANDLER: POST /cat-templates - Create with idempotency
// ============================================================================
async function handleCreateTemplate(
  supabase: any,
  body: any,
  ctx: EdgeContext
) {
  if (!body.name) {
    return createErrorResponse('Template name is required', 'VALIDATION_ERROR', 400, ctx.operationId);
  }

  // Determine tenant_id
  let templateTenantId: string | null = ctx.tenantId;
  if (ctx.isAdmin && body.is_system === true) {
    templateTenantId = null;
  }

  const insertData = {
    tenant_id: templateTenantId,
    is_live: templateTenantId === null ? true : ctx.isLive,
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
    is_system: ctx.isAdmin && body.is_system === true,
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
    return createErrorResponse(error.message, error.code || 'CREATE_ERROR', 500, ctx.operationId);
  }

  console.log(`[cat-templates] Created template: ${data.id} (tenant: ${templateTenantId || 'SYSTEM'})`);

  const responseBody = {
    success: true,
    data: { template: data },
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
// HANDLER: POST /cat-templates/copy - Copy with idempotency
// ============================================================================
async function handleCopyTemplate(
  supabase: any,
  templateId: string,
  body: any,
  ctx: EdgeContext
) {
  if (!isValidUUID(templateId)) {
    return createErrorResponse('Invalid template ID format', 'INVALID_ID', 400, ctx.operationId);
  }

  // Get source template
  const { data: source, error: sourceError } = await supabase
    .from('cat_templates')
    .select('*')
    .eq('id', templateId)
    .single();

  if (sourceError || !source) {
    return createErrorResponse('Source template not found', 'NOT_FOUND', 404, ctx.operationId);
  }

  // Permission check
  if (!source.is_system && source.tenant_id !== ctx.tenantId) {
    return createErrorResponse('Can only copy system templates or your own templates', 'FORBIDDEN', 403, ctx.operationId);
  }

  // Create copy
  const copyData = {
    tenant_id: ctx.tenantId,
    is_live: ctx.isLive,
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
    is_system: false,
    copied_from_id: templateId,
    industry_tags: source.industry_tags,
    is_public: false,
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
    return createErrorResponse(error.message, error.code || 'COPY_ERROR', 500, ctx.operationId);
  }

  console.log(`[cat-templates] Copied template ${templateId} to ${data.id}`);

  const responseBody = {
    success: true,
    data: { template: data, copied_from: templateId },
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
// HANDLER: PATCH /cat-templates?id={id} - Update with optimistic locking
// ============================================================================
async function handleUpdateTemplate(
  supabase: any,
  templateId: string,
  body: any,
  ctx: EdgeContext
) {
  if (!isValidUUID(templateId)) {
    return createErrorResponse('Invalid template ID format', 'INVALID_ID', 400, ctx.operationId);
  }

  // Get existing template with version
  const { data: existing, error: checkError } = await supabase
    .from('cat_templates')
    .select('id, tenant_id, version, is_system')
    .eq('id', templateId)
    .single();

  if (checkError || !existing) {
    return createErrorResponse('Template not found', 'NOT_FOUND', 404, ctx.operationId);
  }

  // Permission check
  if (!ctx.isAdmin && existing.tenant_id !== ctx.tenantId) {
    return createErrorResponse('Cannot update templates you do not own', 'FORBIDDEN', 403, ctx.operationId);
  }

  // Check client-provided version (optional optimistic locking from client)
  if (body.expected_version !== undefined && body.expected_version !== existing.version) {
    return createErrorResponse(
      `Template was modified by another user. Expected version ${body.expected_version}, current version ${existing.version}. Please refresh and try again.`,
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
    'name', 'display_name', 'description', 'category', 'tags', 'cover_image',
    'blocks', 'currency', 'tax_rate', 'discount_config', 'subtotal', 'total',
    'settings', 'industry_tags', 'is_public', 'is_active', 'status_id',
    'sequence_no', 'is_deletable', 'updated_by'
  ];

  if (ctx.isAdmin) {
    allowedFields.push('is_system', 'tenant_id');
  }

  for (const field of allowedFields) {
    if (body[field] !== undefined) {
      updateData[field] = body[field];
    }
  }

  // ⚡ OPTIMISTIC LOCKING: Include version check in update
  const { data, error } = await supabase
    .from('cat_templates')
    .update(updateData)
    .eq('id', templateId)
    .eq('version', existing.version)  // <-- Optimistic lock!
    .select()
    .single();

  // Check for version conflict
  const conflictResponse = checkVersionConflict(data, error, 'Template', ctx.operationId);
  if (conflictResponse) {
    return conflictResponse;
  }

  if (error) {
    console.error('[cat-templates] Update error:', error);
    return createErrorResponse(error.message, error.code || 'UPDATE_ERROR', 500, ctx.operationId);
  }

  console.log(`[cat-templates] Updated template: ${templateId} (v${existing.version} → v${data.version})`);

  const responseBody = {
    success: true,
    data: { template: data },
    metadata: {
      request_id: ctx.operationId,
      duration_ms: Date.now() - ctx.startTime,
      timestamp: new Date().toISOString()
    }
  };

  // Store idempotency
  await storeIdempotency(supabase, ctx.idempotencyKey, ctx.tenantId, responseBody);

  return createSuccessResponse({ template: data }, ctx.operationId, ctx.startTime);
}

// ============================================================================
// HANDLER: DELETE /cat-templates?id={id} - Soft delete
// ============================================================================
async function handleDeleteTemplate(
  supabase: any,
  templateId: string,
  ctx: EdgeContext
) {
  if (!isValidUUID(templateId)) {
    return createErrorResponse('Invalid template ID format', 'INVALID_ID', 400, ctx.operationId);
  }

  // Check existence
  const { data: existing, error: checkError } = await supabase
    .from('cat_templates')
    .select('id, tenant_id, is_deletable, name')
    .eq('id', templateId)
    .single();

  if (checkError || !existing) {
    return createErrorResponse('Template not found', 'NOT_FOUND', 404, ctx.operationId);
  }

  // Permission check
  if (!ctx.isAdmin && existing.tenant_id !== ctx.tenantId) {
    return createErrorResponse('Cannot delete templates you do not own', 'FORBIDDEN', 403, ctx.operationId);
  }

  if (!existing.is_deletable) {
    return createErrorResponse(`Template "${existing.name}" cannot be deleted`, 'NOT_DELETABLE', 400, ctx.operationId);
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
    return createErrorResponse(error.message, error.code || 'DELETE_ERROR', 500, ctx.operationId);
  }

  console.log(`[cat-templates] Soft deleted template: ${templateId}`);

  return createSuccessResponse({
    message: 'Template deleted successfully',
    template_id: templateId
  }, ctx.operationId, ctx.startTime);
}
