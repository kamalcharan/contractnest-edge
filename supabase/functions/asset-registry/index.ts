// supabase/functions/asset-registry/index.ts
// Edge function: CRUD for t_tenant_asset_registry
// Pattern: Protect → Route → single DB call. No loops, no transformation.
// Updated: February 2025

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-idempotency-key',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS'
};

function jsonResponse(data: any, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

function errorResponse(message: string, code: string, status: number): Response {
  return jsonResponse({ error: message, code }, status);
}

// ============================================
// MAIN HANDLER
// ============================================
serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

    const authHeader = req.headers.get('Authorization');
    const tenantId = req.headers.get('x-tenant-id');

    console.log(`[AssetRegistry] ${req.method} ${req.url}`);

    if (!authHeader) {
      return errorResponse('Authorization header is required', 'UNAUTHORIZED', 401);
    }
    if (!tenantId) {
      return errorResponse('x-tenant-id header is required', 'MISSING_TENANT', 400);
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false }
    });

    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const lastSegment = pathSegments[pathSegments.length - 1];

    // ── Route: GET /health ──────────────────────────────────────
    if (lastSegment === 'health') {
      return jsonResponse({ status: 'ok', timestamp: new Date().toISOString() });
    }

    // ── Route: GET /contract-assets?contract_id=... ─────────────
    if (lastSegment === 'contract-assets' && req.method === 'GET') {
      return await handleGetContractAssets(supabase, tenantId, url.searchParams);
    }

    // ── Route: POST /contract-assets ────────────────────────────
    if (lastSegment === 'contract-assets' && req.method === 'POST') {
      return await handleLinkContractAssets(supabase, tenantId, req);
    }

    // ── Route: DELETE /contract-assets?contract_id=...&asset_id=...
    if (lastSegment === 'contract-assets' && req.method === 'DELETE') {
      return await handleUnlinkContractAsset(supabase, tenantId, url.searchParams);
    }

    // ── Route: GET /children?parent_asset_id=... ────────────────
    if (lastSegment === 'children' && req.method === 'GET') {
      return await handleGetChildren(supabase, tenantId, url.searchParams);
    }

    // ── Main CRUD routes ────────────────────────────────────────
    if (req.method === 'GET') {
      return await handleGet(supabase, tenantId, url.searchParams);
    }

    if (req.method === 'POST') {
      return await handleCreate(supabase, tenantId, req);
    }

    if (req.method === 'PATCH') {
      const assetId = url.searchParams.get('id');
      if (!assetId) {
        return errorResponse('id query parameter is required for update', 'VALIDATION_ERROR', 400);
      }
      return await handleUpdate(supabase, tenantId, assetId, req);
    }

    if (req.method === 'DELETE') {
      const assetId = url.searchParams.get('id');
      if (!assetId) {
        return errorResponse('id query parameter is required for delete', 'VALIDATION_ERROR', 400);
      }
      return await handleDelete(supabase, tenantId, assetId);
    }

    return errorResponse('Invalid endpoint or method', 'NOT_FOUND', 404);

  } catch (error: any) {
    console.error('Asset registry edge function error:', error);
    return errorResponse('Internal server error', 'INTERNAL_ERROR', 500);
  }
});

// ============================================
// HANDLER: GET assets (list or single)
// ============================================
async function handleGet(supabase: any, tenantId: string, params: URLSearchParams) {
  const assetId = params.get('id');
  const resourceTypeId = params.get('resource_type_id');
  const status = params.get('status');
  const isLive = params.get('is_live') !== 'false'; // default true
  const limit = Math.min(Number(params.get('limit') || 100), 500);
  const offset = Number(params.get('offset') || 0);

  // Single asset by ID
  if (assetId) {
    const { data, error } = await supabase
      .from('t_tenant_asset_registry')
      .select('*')
      .eq('id', assetId)
      .eq('tenant_id', tenantId)
      .eq('is_live', isLive)
      .single();

    if (error) {
      if (error.code === 'PGRST116') {
        return errorResponse('Asset not found', 'NOT_FOUND', 404);
      }
      return errorResponse(error.message, 'GET_ASSET_ERROR', 500);
    }
    return jsonResponse({ success: true, data });
  }

  // List with filters
  let query = supabase
    .from('t_tenant_asset_registry')
    .select('*', { count: 'exact' })
    .eq('tenant_id', tenantId)
    .eq('is_live', isLive)
    .eq('is_active', true)
    .order('created_at', { ascending: false })
    .range(offset, offset + limit - 1);

  if (resourceTypeId) {
    query = query.eq('resource_type_id', resourceTypeId);
  }
  if (status) {
    query = query.eq('status', status);
  }

  const { data, error, count } = await query;

  if (error) {
    return errorResponse(error.message, 'LIST_ASSETS_ERROR', 500);
  }

  return jsonResponse({
    success: true,
    data,
    pagination: { total: count, limit, offset, has_more: (offset + limit) < (count || 0) }
  });
}

// ============================================
// HANDLER: POST create asset
// ============================================
async function handleCreate(supabase: any, tenantId: string, req: Request) {
  const body = await req.json();

  if (!body.name || !body.resource_type_id) {
    return errorResponse('name and resource_type_id are required', 'VALIDATION_ERROR', 400);
  }

  const record = {
    tenant_id: tenantId,
    resource_type_id: body.resource_type_id,
    asset_type_id: body.asset_type_id || null,
    parent_asset_id: body.parent_asset_id || null,
    template_id: body.template_id || null,
    industry_id: body.industry_id || null,
    name: body.name.trim(),
    code: body.code?.trim() || null,
    description: body.description?.trim() || null,
    status: body.status || 'active',
    condition: body.condition || 'good',
    criticality: body.criticality || 'medium',
    owner_contact_id: body.owner_contact_id || null,
    location: body.location?.trim() || null,
    make: body.make?.trim() || null,
    model: body.model?.trim() || null,
    serial_number: body.serial_number?.trim() || null,
    purchase_date: body.purchase_date || null,
    warranty_expiry: body.warranty_expiry || null,
    last_service_date: body.last_service_date || null,
    area_sqft: body.area_sqft || null,
    dimensions: body.dimensions || null,
    capacity: body.capacity || null,
    specifications: body.specifications || {},
    tags: body.tags || [],
    image_url: body.image_url || null,
    is_active: true,
    is_live: body.is_live !== false,
    created_by: body.created_by || null
  };

  const { data, error } = await supabase
    .from('t_tenant_asset_registry')
    .insert([record])
    .select()
    .single();

  if (error) {
    console.error('Error creating asset:', error);
    return errorResponse(error.message, 'CREATE_ASSET_ERROR', 500);
  }

  return jsonResponse({ success: true, data, message: 'Asset created successfully' }, 201);
}

// ============================================
// HANDLER: PATCH update asset
// ============================================
async function handleUpdate(supabase: any, tenantId: string, assetId: string, req: Request) {
  const body = await req.json();

  // Verify ownership
  const { data: current, error: fetchError } = await supabase
    .from('t_tenant_asset_registry')
    .select('id')
    .eq('id', assetId)
    .eq('tenant_id', tenantId)
    .single();

  if (fetchError || !current) {
    return errorResponse('Asset not found', 'NOT_FOUND', 404);
  }

  // Build update payload — only set fields that were sent
  const updateData: Record<string, any> = { updated_at: new Date().toISOString() };
  const allowedFields = [
    'name', 'code', 'description', 'resource_type_id', 'asset_type_id',
    'parent_asset_id', 'template_id', 'industry_id', 'status', 'condition',
    'criticality', 'owner_contact_id', 'location', 'make', 'model',
    'serial_number', 'purchase_date', 'warranty_expiry', 'last_service_date',
    'area_sqft', 'dimensions', 'capacity', 'specifications', 'tags',
    'image_url', 'is_active', 'updated_by'
  ];

  for (const field of allowedFields) {
    if (body[field] !== undefined) {
      updateData[field] = body[field];
    }
  }

  const { data, error } = await supabase
    .from('t_tenant_asset_registry')
    .update(updateData)
    .eq('id', assetId)
    .eq('tenant_id', tenantId)
    .select()
    .single();

  if (error) {
    return errorResponse(error.message, 'UPDATE_ASSET_ERROR', 500);
  }

  return jsonResponse({ success: true, data, message: 'Asset updated successfully' });
}

// ============================================
// HANDLER: DELETE (soft-delete) asset
// ============================================
async function handleDelete(supabase: any, tenantId: string, assetId: string) {
  // Verify ownership
  const { data: current, error: fetchError } = await supabase
    .from('t_tenant_asset_registry')
    .select('id, is_active')
    .eq('id', assetId)
    .eq('tenant_id', tenantId)
    .single();

  if (fetchError || !current) {
    return errorResponse('Asset not found', 'NOT_FOUND', 404);
  }

  if (!current.is_active) {
    return errorResponse('Asset is already deleted', 'ALREADY_DELETED', 400);
  }

  // Soft delete
  const { data, error } = await supabase
    .from('t_tenant_asset_registry')
    .update({ is_active: false, updated_at: new Date().toISOString() })
    .eq('id', assetId)
    .eq('tenant_id', tenantId)
    .select('id, name')
    .single();

  if (error) {
    return errorResponse(error.message, 'DELETE_ASSET_ERROR', 500);
  }

  return jsonResponse({ success: true, data, message: 'Asset deleted successfully' });
}

// ============================================
// HANDLER: GET children assets (hierarchy)
// ============================================
async function handleGetChildren(supabase: any, tenantId: string, params: URLSearchParams) {
  const parentId = params.get('parent_asset_id');
  if (!parentId) {
    return errorResponse('parent_asset_id is required', 'VALIDATION_ERROR', 400);
  }

  const { data, error } = await supabase
    .from('t_tenant_asset_registry')
    .select('*')
    .eq('tenant_id', tenantId)
    .eq('parent_asset_id', parentId)
    .eq('is_active', true)
    .eq('is_live', true)
    .order('name', { ascending: true });

  if (error) {
    return errorResponse(error.message, 'GET_CHILDREN_ERROR', 500);
  }

  return jsonResponse({ success: true, data });
}

// ============================================
// HANDLER: GET contract assets
// ============================================
async function handleGetContractAssets(supabase: any, tenantId: string, params: URLSearchParams) {
  const contractId = params.get('contract_id');
  if (!contractId) {
    return errorResponse('contract_id is required', 'VALIDATION_ERROR', 400);
  }

  const { data, error } = await supabase
    .from('t_contract_assets')
    .select('*, asset:t_tenant_asset_registry(*)')
    .eq('contract_id', contractId)
    .eq('tenant_id', tenantId)
    .eq('is_active', true);

  if (error) {
    return errorResponse(error.message, 'GET_CONTRACT_ASSETS_ERROR', 500);
  }

  return jsonResponse({ success: true, data });
}

// ============================================
// HANDLER: POST link assets to contract
// ============================================
async function handleLinkContractAssets(supabase: any, tenantId: string, req: Request) {
  const body = await req.json();

  if (!body.contract_id || !body.assets || !Array.isArray(body.assets) || body.assets.length === 0) {
    return errorResponse('contract_id and assets[] are required', 'VALIDATION_ERROR', 400);
  }

  const rows = body.assets.map((a: any) => ({
    contract_id: body.contract_id,
    asset_id: a.asset_id,
    tenant_id: tenantId,
    coverage_type: a.coverage_type || null,
    service_terms: a.service_terms || {},
    pricing_override: a.pricing_override || null,
    notes: a.notes || null,
    is_active: true,
    is_live: body.is_live !== false
  }));

  const { data, error } = await supabase
    .from('t_contract_assets')
    .upsert(rows, { onConflict: 'contract_id,asset_id' })
    .select();

  if (error) {
    return errorResponse(error.message, 'LINK_ASSETS_ERROR', 500);
  }

  // Update denormalized summary on t_contracts
  const { data: allLinked } = await supabase
    .from('t_contract_assets')
    .select('asset_id, asset:t_tenant_asset_registry(id, name, resource_type_id)')
    .eq('contract_id', body.contract_id)
    .eq('tenant_id', tenantId)
    .eq('is_active', true);

  const assetSummary = (allLinked || []).map((row: any) => ({
    id: row.asset?.id,
    name: row.asset?.name,
    type: row.asset?.resource_type_id
  }));

  await supabase
    .from('t_contracts')
    .update({ asset_count: assetSummary.length, asset_summary: assetSummary })
    .eq('id', body.contract_id)
    .eq('tenant_id', tenantId);

  return jsonResponse({ success: true, data, asset_count: assetSummary.length }, 201);
}

// ============================================
// HANDLER: DELETE unlink asset from contract
// ============================================
async function handleUnlinkContractAsset(supabase: any, tenantId: string, params: URLSearchParams) {
  const contractId = params.get('contract_id');
  const assetId = params.get('asset_id');

  if (!contractId || !assetId) {
    return errorResponse('contract_id and asset_id are required', 'VALIDATION_ERROR', 400);
  }

  const { error } = await supabase
    .from('t_contract_assets')
    .delete()
    .eq('contract_id', contractId)
    .eq('asset_id', assetId)
    .eq('tenant_id', tenantId);

  if (error) {
    return errorResponse(error.message, 'UNLINK_ASSET_ERROR', 500);
  }

  // Update denormalized summary
  const { data: remaining } = await supabase
    .from('t_contract_assets')
    .select('asset_id, asset:t_tenant_asset_registry(id, name, resource_type_id)')
    .eq('contract_id', contractId)
    .eq('tenant_id', tenantId)
    .eq('is_active', true);

  const assetSummary = (remaining || []).map((row: any) => ({
    id: row.asset?.id,
    name: row.asset?.name,
    type: row.asset?.resource_type_id
  }));

  await supabase
    .from('t_contracts')
    .update({ asset_count: assetSummary.length, asset_summary: assetSummary })
    .eq('id', contractId)
    .eq('tenant_id', tenantId);

  return jsonResponse({ success: true, message: 'Asset unlinked', asset_count: assetSummary.length });
}
