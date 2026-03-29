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

        if (lastSegment === 'coverage') {
          return await handleGetCoverage(supabase, context);
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

  // Build base query — try with is_latest first; fallback without if column missing
  const buildListQuery = (withLatest: boolean) => {
    let q = supabase
      .from('t_cat_templates')
      .select('*', { count: 'exact' })
      .eq('is_active', true);

    if (withLatest) q = q.eq('is_latest', true);

    // Visibility filter
    if (!ctx.isAdmin) {
      q = q.or(`tenant_id.eq.${ctx.tenantId},and(tenant_id.is.null,is_system.eq.true)`);
      q = q.or(`is_live.eq.${ctx.isLive},tenant_id.is.null`);
    }

    // Filters
    const category = params.get('category');
    if (category) q = q.eq('category', category);

    const isSystem = params.get('is_system');
    if (isSystem !== null) q = q.eq('is_system', isSystem === 'true');

    const search = params.get('search');
    if (search) q = q.ilike('name', `%${search}%`);

    // Order
    q = q.order('sequence_no', { ascending: true }).order('name', { ascending: true });

    return applyPagination(q, pagination, MAX_PAGE_SIZE);
  };

  let result = await buildListQuery(true);
  // Graceful fallback: if is_latest column doesn't exist yet, retry without it
  if (result.error && result.error.message?.includes('is_latest')) {
    console.warn('[cat-templates] is_latest column not found, falling back without version filter');
    result = await buildListQuery(false);
  }

  const { data, error, count } = result;

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

  const buildSystemQuery = (withLatest: boolean) => {
    let q = supabase
      .from('t_cat_templates')
      .select('*', { count: 'exact' })
      .is('tenant_id', null)
      .eq('is_system', true);

    // is_active filter — defaults to true unless explicitly overridden
    const isActiveParam = params.get('is_active');
    if (isActiveParam === 'false') {
      q = q.eq('is_active', false);
    } else if (isActiveParam === 'all') {
      // No filter — return both active and inactive
    } else {
      q = q.eq('is_active', true);
    }

    if (withLatest) q = q.eq('is_latest', true);

    const category = params.get('category');
    if (category) q = q.eq('category', category);

    const industryTag = params.get('industry');
    if (industryTag) q = q.contains('industry_tags', [industryTag]);

    const search = params.get('search');
    if (search) q = q.ilike('name', `%${search}%`);

    q = q.order('sequence_no', { ascending: true }).order('name', { ascending: true });
    return applyPagination(q, pagination, MAX_PAGE_SIZE);
  };

  let result = await buildSystemQuery(true);
  if (result.error && result.error.message?.includes('is_latest')) {
    console.warn('[cat-templates] is_latest column not found, falling back without version filter');
    result = await buildSystemQuery(false);
  }

  const { data, error, count } = result;

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
// HANDLER: GET /cat-templates/coverage - Template coverage statistics
// Joins t_cat_templates (system) with m_catalog_industries to produce
// per-industry counts, overall stats, and uncovered industries list.
// ============================================================================
async function handleGetCoverage(
  supabase: any,
  ctx: EdgeContext
) {
  try {
    // 1. Fetch all active system templates
    const { data: templates, error: tplErr } = await supabase
      .from('t_cat_templates')
      .select('id, name, display_name, category, industry_tags, tags, is_public, status_id, blocks, created_at, updated_at')
      .is('tenant_id', null)
      .eq('is_system', true)
      .eq('is_active', true)
      .eq('is_latest', true);

    if (tplErr) {
      console.error('[cat-templates] Coverage templates query error:', tplErr);
      return createErrorResponse(tplErr.message, tplErr.code || 'QUERY_ERROR', 500, ctx.operationId);
    }

    // 2. Fetch all level-0 industries (parent segments)
    const { data: industries, error: indErr } = await supabase
      .from('m_catalog_industries')
      .select('id, name, icon, description, sort_order, is_active')
      .eq('level', 0)
      .eq('is_active', true)
      .order('sort_order', { ascending: true });

    if (indErr) {
      console.error('[cat-templates] Coverage industries query error:', indErr);
      return createErrorResponse(indErr.message, indErr.code || 'QUERY_ERROR', 500, ctx.operationId);
    }

    const allTemplates = templates || [];
    const allIndustries = industries || [];

    // 3. Build per-industry coverage map
    const industryMap: Record<string, number> = {};
    for (const tpl of allTemplates) {
      const tags: string[] = tpl.industry_tags || [];
      for (const tag of tags) {
        industryMap[tag] = (industryMap[tag] || 0) + 1;
      }
    }

    // 4. Build industry coverage array
    const industryCoverage = allIndustries.map((ind: any) => ({
      id: ind.id,
      name: ind.name,
      icon: ind.icon || null,
      description: ind.description || null,
      templateCount: industryMap[ind.id] || 0,
      hasCoverage: (industryMap[ind.id] || 0) > 0,
    }));

    // 5. Compute summary stats
    const coveredIndustries = industryCoverage.filter((i: any) => i.hasCoverage);
    const uncoveredIndustries = industryCoverage.filter((i: any) => !i.hasCoverage);

    // 6. Count unique categories
    const categories = new Set(allTemplates.map((t: any) => t.category).filter(Boolean));

    const responseData = {
      summary: {
        totalTemplates: allTemplates.length,
        totalIndustries: allIndustries.length,
        coveredIndustries: coveredIndustries.length,
        uncoveredIndustries: uncoveredIndustries.length,
        coveragePercent: allIndustries.length > 0
          ? Math.round((coveredIndustries.length / allIndustries.length) * 100)
          : 0,
        totalCategories: categories.size,
        publicTemplates: allTemplates.filter((t: any) => t.is_public).length,
      },
      industries: industryCoverage,
      uncovered: uncoveredIndustries.map((i: any) => ({ id: i.id, name: i.name, icon: i.icon })),
    };

    return createSuccessResponse(responseData, ctx.operationId, ctx.startTime);
  } catch (error: any) {
    console.error('[cat-templates] Coverage handler error:', error);
    return createErrorResponse(error.message, 'COVERAGE_ERROR', 500, ctx.operationId);
  }
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

  const buildPublicQuery = (withLatest: boolean) => {
    let q = supabase
      .from('t_cat_templates')
      .select('*', { count: 'exact' })
      .eq('is_public', true)
      .eq('is_active', true);

    if (withLatest) q = q.eq('is_latest', true);

    const category = params.get('category');
    if (category) q = q.eq('category', category);

    const search = params.get('search');
    if (search) q = q.ilike('name', `%${search}%`);

    q = q.order('sequence_no', { ascending: true });
    return applyPagination(q, pagination, MAX_PAGE_SIZE);
  };

  let result = await buildPublicQuery(true);
  if (result.error && result.error.message?.includes('is_latest')) {
    console.warn('[cat-templates] is_latest column not found, falling back without version filter');
    result = await buildPublicQuery(false);
  }

  const { data, error, count } = result;

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
    .from('t_cat_templates')
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
    tax_rate: body.tax_rate ?? null,
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
    updated_by: body.created_by || null,
    is_latest: true,
    parent_template_id: null  // Will be set to own id after insert
  };

  const { data, error } = await supabase
    .from('t_cat_templates')
    .insert(insertData)
    .select()
    .single();

  if (error) {
    console.error('[cat-templates] Create error:', error);
    return createErrorResponse(error.message, error.code || 'CREATE_ERROR', 500, ctx.operationId);
  }

  // Set parent_template_id to own id (first version points to itself)
  if (data && !data.parent_template_id) {
    await supabase
      .from('t_cat_templates')
      .update({ parent_template_id: data.id })
      .eq('id', data.id);
    data.parent_template_id = data.id;
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
    .from('t_cat_templates')
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
    created_by: body.created_by || null,
    is_latest: true,
    parent_template_id: null  // Will be set to own id after insert
  };

  const { data, error } = await supabase
    .from('t_cat_templates')
    .insert(copyData)
    .select()
    .single();

  if (error) {
    console.error('[cat-templates] Copy error:', error);
    return createErrorResponse(error.message, error.code || 'COPY_ERROR', 500, ctx.operationId);
  }

  // Set parent_template_id to own id (new copy is first version of a new chain)
  if (data && !data.parent_template_id) {
    await supabase
      .from('t_cat_templates')
      .update({ parent_template_id: data.id })
      .eq('id', data.id);
    data.parent_template_id = data.id;
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
// Metadata-only fields that should NOT trigger copy-on-write versioning.
// These are status/admin toggles that update the row in place.
// ============================================================================
const METADATA_ONLY_FIELDS = new Set([
  'is_active', 'is_public', 'is_deletable', 'sequence_no', 'status_id',
]);

/**
 * Returns true when the request body touches ONLY metadata fields
 * (no content changes that warrant a new version).
 */
function isMetadataOnlyUpdate(body: any): boolean {
  const bodyKeys = Object.keys(body).filter(
    (k) => !['expected_version', 'updated_by', 'skip_versioning'].includes(k)
  );
  return bodyKeys.length > 0 && bodyKeys.every((k) => METADATA_ONLY_FIELDS.has(k));
}

// ============================================================================
// HANDLER: PATCH /cat-templates?id={id} - Smart update
// Metadata-only changes (is_active toggle, etc.) → in-place update.
// Content changes (name, blocks, tags, etc.) → copy-on-write versioning.
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

  // Get the full existing template
  const { data: existing, error: checkError } = await supabase
    .from('t_cat_templates')
    .select('*')
    .eq('id', templateId)
    .single();

  if (checkError || !existing) {
    return createErrorResponse('Template not found', 'NOT_FOUND', 404, ctx.operationId);
  }

  // Permission check
  if (!ctx.isAdmin && existing.tenant_id !== ctx.tenantId) {
    return createErrorResponse('Cannot update templates you do not own', 'FORBIDDEN', 403, ctx.operationId);
  }

  // ── Route: metadata-only OR explicit skip_versioning → in-place update ──
  if (isMetadataOnlyUpdate(body) || body.skip_versioning === true) {
    return handleInPlaceUpdate(supabase, templateId, existing, body, ctx);
  }

  // ── Route: content change → copy-on-write versioning ──
  return handleVersionedUpdate(supabase, templateId, existing, body, ctx);
}

// ============================================================================
// In-place update (no versioning) for metadata fields like is_active, etc.
// ============================================================================
async function handleInPlaceUpdate(
  supabase: any,
  templateId: string,
  existing: any,
  body: any,
  ctx: EdgeContext
) {
  const allowedMeta = [
    'is_active', 'is_public', 'is_deletable', 'sequence_no', 'status_id', 'updated_by',
  ];
  if (ctx.isAdmin) allowedMeta.push('is_system');

  const updateData: any = { updated_at: new Date().toISOString() };
  for (const field of allowedMeta) {
    if (body[field] !== undefined) {
      updateData[field] = body[field];
    }
  }
  if (!updateData.updated_by) {
    updateData.updated_by = existing.updated_by;
  }

  const { data, error } = await supabase
    .from('t_cat_templates')
    .update(updateData)
    .eq('id', templateId)
    .select()
    .single();

  if (error) {
    console.error('[cat-templates] In-place update error:', error);
    return createErrorResponse(error.message, error.code || 'UPDATE_ERROR', 500, ctx.operationId);
  }

  console.log(`[cat-templates] In-place updated template: ${templateId} (fields: ${Object.keys(updateData).join(', ')})`);

  return createSuccessResponse({ template: data }, ctx.operationId, ctx.startTime);
}

// ============================================================================
// Versioned update (copy-on-write) for content changes
// ============================================================================
async function handleVersionedUpdate(
  supabase: any,
  templateId: string,
  existing: any,
  body: any,
  ctx: EdgeContext
) {
  // Optimistic locking check
  if (body.expected_version !== undefined && body.expected_version !== existing.version) {
    return createErrorResponse(
      `Template was modified by another user. Expected version ${body.expected_version}, current version ${existing.version}. Please refresh and try again.`,
      'VERSION_CONFLICT',
      409,
      ctx.operationId
    );
  }

  // Determine parent_template_id (version chain root)
  const parentId = existing.parent_template_id || existing.id;

  // ── STEP 1: Mark old row as legacy (is_latest = false) ──
  const { error: legacyError } = await supabase
    .from('t_cat_templates')
    .update({
      is_latest: false,
      updated_at: new Date().toISOString(),
    })
    .eq('id', templateId)
    .eq('version', existing.version);  // Optimistic lock on old row

  if (legacyError) {
    console.error('[cat-templates] Legacy mark error:', legacyError);
    return createErrorResponse(legacyError.message, legacyError.code || 'UPDATE_ERROR', 500, ctx.operationId);
  }

  // ── STEP 2: Build new version row (copy all fields + apply changes) ──
  const allowedFields = [
    'name', 'display_name', 'description', 'category', 'tags', 'cover_image',
    'blocks', 'currency', 'tax_rate', 'discount_config', 'subtotal', 'total',
    'settings', 'industry_tags', 'is_public', 'is_active', 'status_id',
    'sequence_no', 'is_deletable', 'updated_by'
  ];

  if (ctx.isAdmin) {
    allowedFields.push('is_system', 'tenant_id');
  }

  // Start from existing data (copy all fields)
  const newRow: any = {
    // Carry over all existing fields
    tenant_id: existing.tenant_id,
    is_live: existing.is_live,
    name: existing.name,
    display_name: existing.display_name,
    description: existing.description,
    category: existing.category,
    tags: existing.tags,
    cover_image: existing.cover_image,
    blocks: existing.blocks,
    currency: existing.currency,
    tax_rate: existing.tax_rate,
    discount_config: existing.discount_config,
    subtotal: existing.subtotal,
    total: existing.total,
    settings: existing.settings,
    is_system: existing.is_system,
    copied_from_id: existing.copied_from_id,
    industry_tags: existing.industry_tags,
    is_public: existing.is_public,
    is_active: existing.is_active,
    status_id: existing.status_id,
    sequence_no: existing.sequence_no,
    is_deletable: existing.is_deletable,
    created_by: existing.created_by,
    updated_by: body.updated_by || existing.updated_by,
    // Versioning fields
    version: (existing.version || 1) + 1,
    is_latest: true,
    parent_template_id: parentId,
    // Timestamps
    created_at: existing.created_at,  // Preserve original creation time
    updated_at: new Date().toISOString(),
  };

  // Apply changes from request body
  for (const field of allowedFields) {
    if (body[field] !== undefined) {
      newRow[field] = body[field];
    }
  }

  // ── STEP 3: Insert new version ──
  const { data: newVersion, error: insertError } = await supabase
    .from('t_cat_templates')
    .insert(newRow)
    .select()
    .single();

  if (insertError) {
    console.error('[cat-templates] Version insert error:', insertError);
    // Rollback: mark old row back as latest
    await supabase
      .from('t_cat_templates')
      .update({ is_latest: true })
      .eq('id', templateId);
    return createErrorResponse(insertError.message, insertError.code || 'VERSION_ERROR', 500, ctx.operationId);
  }

  console.log(`[cat-templates] Versioned template: ${templateId} → ${newVersion.id} (v${existing.version} → v${newVersion.version})`);

  const responseBody = {
    success: true,
    data: { template: newVersion, previous_version_id: templateId },
    metadata: {
      request_id: ctx.operationId,
      duration_ms: Date.now() - ctx.startTime,
      timestamp: new Date().toISOString()
    }
  };

  // Store idempotency
  await storeIdempotency(supabase, ctx.idempotencyKey, ctx.tenantId, responseBody);

  return createSuccessResponse({ template: newVersion, previous_version_id: templateId }, ctx.operationId, ctx.startTime);
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
    .from('t_cat_templates')
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
    .from('t_cat_templates')
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
