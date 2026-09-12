// supabase/functions/client-asset-registry/index.ts
// Edge function: CRUD for t_client_asset_registry (client-owned & self-owned assets)
// Pattern: Protect → Route → single DB call. No loops, no transformation.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const TABLE = 't_client_asset_registry';
const JUNCTION = 't_contract_assets';

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

    console.log(`[ClientAssetRegistry] ${req.method} ${req.url}`);

    if (!authHeader) {
      return errorResponse('Authorization header is required', 'UNAUTHORIZED', 401);
    }
    if (!tenantId) {
      return errorResponse('x-tenant-id header is required', 'MISSING_TENANT', 400);
    }

    // Use service role key without user JWT to bypass RLS
    // (matches contacts/contracts pattern — tenant isolation enforced via tenant_id in every query)
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const lastSegment = pathSegments[pathSegments.length - 1];

    // ── Route: GET /health
    if (lastSegment === 'health') {
      return jsonResponse({ status: 'ok', timestamp: new Date().toISOString() });
    }

    // ── Route: GET /contract-assets?contract_id=...
    if (lastSegment === 'contract-assets' && req.method === 'GET') {
      return await handleGetContractAssets(supabase, tenantId, url.searchParams);
    }

    // ── Route: POST /contract-assets
    if (lastSegment === 'contract-assets' && req.method === 'POST') {
      return await handleLinkContractAssets(supabase, tenantId, req);
    }

    // ── Route: DELETE /contract-assets?contract_id=...&asset_id=...
    if (lastSegment === 'contract-assets' && req.method === 'DELETE') {
      return await handleUnlinkContractAsset(supabase, tenantId, url.searchParams);
    }

    // ── Route: GET /children?parent_asset_id=...
    if (lastSegment === 'children' && req.method === 'GET') {
      return await handleGetChildren(supabase, tenantId, url.searchParams);
    }

    // ── Main CRUD routes
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
    console.error('Client asset registry edge function error:', error);
    return errorResponse('Internal server error', 'INTERNAL_ERROR', 500);
  }
});

// ============================================
// SHARED: live-contract lookup (R3 guard + R4 chips)
// ============================================
// Live (non-terminal) contract statuses — a contract in one of these states
// still binds its equipment; terminal ones (expired/cancelled/completed) do not.
const LIVE_CONTRACT_STATUSES = ['active', 'draft', 'pending_acceptance', 'sent'];

// Map asset id -> [{id, contract_number, status}] by scanning equipment_details
// of the tenant's live contracts. equipment_details items reference a registry
// asset via asset_registry_id (attach flow) or id (legacy direct add).
// Throws on query error — callers decide whether that is fatal.
async function fetchContractRefsByAsset(supabase: any, tenantId: string, assetIds: string[]) {
  const map = new Map<string, { id: string; contract_number: string; status: string }[]>();
  // equipment_details item id -> registry asset id, for items that carry both.
  // Per-asset event rows key asset_ref by COALESCE(asset_registry_id, item id),
  // so service-state lookups must match either spelling.
  const aliases = new Map<string, string>();
  if (assetIds.length === 0) return { map, aliases };
  const wanted = new Set(assetIds);

  const { data, error } = await supabase
    .from('t_contracts')
    .select('id, contract_number, status, equipment_details')
    .eq('tenant_id', tenantId)
    .eq('record_type', 'contract')
    .in('status', LIVE_CONTRACT_STATUSES)
    .not('equipment_details', 'is', null);

  if (error) {
    throw new Error(`contract-ref lookup failed: ${error.message}`);
  }

  for (const c of data || []) {
    const items = Array.isArray(c.equipment_details) ? c.equipment_details : [];
    const seen = new Set<string>();
    for (const item of items) {
      const ref = item?.asset_registry_id || item?.id;
      if (ref && wanted.has(ref) && !seen.has(ref)) {
        seen.add(ref);
        if (!map.has(ref)) map.set(ref, []);
        map.get(ref)!.push({ id: c.id, contract_number: c.contract_number, status: c.status });
      }
      if (item?.asset_registry_id && item?.id && wanted.has(item.asset_registry_id)) {
        aliases.set(item.id, item.asset_registry_id);
      }
    }
  }
  return { map, aliases };
}

// ============================================
// SHARED: per-asset service state (single-card reuse — registry renders the
// contract view's MachineCard, so it needs the same visits-proven numbers)
// ============================================
// Aggregates t_contract_event_assets × t_contract_events per registry asset,
// across the asset's LIVE contracts, mirroring the UI's buildFleetServiceMap
// semantics (fleetTypes.ts). "Today" is IST, per platform convention.
// NOTE (Phase 6): event dates come from t_contract_events, which the JTD
// cutover keeps id-identical and mirrored until retirement; repoint to n_jtd
// when t_contract_events is retired.
const CLOSED_EVENT_STATUSES = new Set(['completed', 'cancelled', 'skipped']);

function istTodayKey(): string {
  return new Date(Date.now() + 5.5 * 3600 * 1000).toISOString().split('T')[0];
}

async function fetchServiceStateByAsset(
  supabase: any,
  tenantId: string,
  isLive: boolean,
  refs: { map: Map<string, any[]>; aliases: Map<string, string> }
) {
  const stateMap = new Map<string, any>();
  // Only assets inside live contracts can have visits
  const assetIds = [...refs.map.keys()];
  if (assetIds.length === 0) return stateMap;

  // asset_ref spellings to query: registry id + any item-id aliases
  const refToAsset = new Map<string, string>();
  for (const id of assetIds) refToAsset.set(id, id);
  for (const [itemId, registryId] of refs.aliases) refToAsset.set(itemId, registryId);
  const allRefs = [...refToAsset.keys()];

  // Chunked fetch of per-asset rows (keep .in() lists bounded)
  const rows: any[] = [];
  for (let i = 0; i < allRefs.length; i += 100) {
    const { data, error } = await supabase
      .from('t_contract_event_assets')
      .select('asset_ref, event_id, status, proven_at')
      .eq('tenant_id', tenantId)
      .eq('is_live', isLive)
      .eq('is_active', true)
      .in('asset_ref', allRefs.slice(i, i + 100));
    if (error) throw new Error(`event-asset lookup failed: ${error.message}`);
    rows.push(...(data || []));
  }
  if (rows.length === 0) return stateMap;

  // Fetch the parent events (dates + statuses), chunked.
  // event_id points at t_contract_events (V1 / migrated contracts) OR at an
  // n_jtd service job (V2-native contracts — same id space post-cutover but
  // jobs created after the copy exist ONLY in n_jtd). Resolve from events
  // first, then fall back to n_jtd for any ids not found there.
  const eventIds = [...new Set(rows.map((r) => r.event_id).filter(Boolean))];
  const eventById = new Map<string, any>();
  for (let i = 0; i < eventIds.length; i += 100) {
    const { data, error } = await supabase
      .from('t_contract_events')
      .select('id, scheduled_date, status')
      .eq('tenant_id', tenantId)
      .in('id', eventIds.slice(i, i + 100));
    if (error) throw new Error(`event lookup failed: ${error.message}`);
    for (const e of data || []) eventById.set(e.id, e);
  }
  const missingIds = eventIds.filter((id) => !eventById.has(id));
  for (let i = 0; i < missingIds.length; i += 100) {
    const { data, error } = await supabase
      .from('n_jtd')
      .select('id, scheduled_at, status_code')
      .eq('tenant_id', tenantId)
      .in('id', missingIds.slice(i, i + 100));
    if (error) throw new Error(`jtd lookup failed: ${error.message}`);
    for (const j of data || []) {
      eventById.set(j.id, { id: j.id, scheduled_date: j.scheduled_at, status: j.status_code });
    }
  }

  const today = istTodayKey();

  for (const r of rows) {
    if (r.status === 'blocked_placeholder') continue; // locked slots aren't visits
    const assetId = refToAsset.get(r.asset_ref);
    if (!assetId) continue;

    let s = stateMap.get(assetId);
    if (!s) {
      s = {
        proven_count: 0, total_visits: 0, overdue_count: 0,
        next_due_date: null as string | null,
        first_overdue_date: null as string | null,
        last_proven_date: null as string | null,
      };
      stateMap.set(assetId, s);
    }

    const event = eventById.get(r.event_id) || null;
    const dateKey = event?.scheduled_date ? String(event.scheduled_date).split('T')[0] : '';
    const isProven = r.status === 'proven';
    const isOverdue =
      !isProven && !!event &&
      (event.status === 'overdue' ||
        (!!dateKey && dateKey < today && !CLOSED_EVENT_STATUSES.has(event.status)));

    s.total_visits += 1;
    if (isProven) {
      s.proven_count += 1;
      const provenKey = r.proven_at ? String(r.proven_at).split('T')[0] : dateKey || null;
      if (provenKey && (!s.last_proven_date || provenKey > s.last_proven_date)) {
        s.last_proven_date = provenKey;
      }
    } else {
      if (isOverdue) {
        s.overdue_count += 1;
        if (dateKey && (!s.first_overdue_date || dateKey < s.first_overdue_date)) {
          s.first_overdue_date = dateKey;
        }
      }
      if (dateKey && dateKey >= today && (!s.next_due_date || dateKey < s.next_due_date)) {
        s.next_due_date = dateKey;
      }
    }
  }
  return stateMap;
}

// ============================================
// HANDLER: GET assets (list or single)
// ============================================
async function handleGet(supabase: any, tenantId: string, params: URLSearchParams) {
  const assetId = params.get('id');
  const contactId = params.get('contact_id');
  const ownershipType = params.get('ownership_type'); // 'client' | 'self'
  const resourceTypeId = params.get('resource_type_id');
  const status = params.get('status');
  const isLive = params.get('is_live') !== 'false';
  const includeInactive = params.get('include_inactive') === 'true';   // R2: show deactivated assets too
  const withContracts = params.get('with_contracts') === 'true';       // R4: enrich rows with live-contract refs
  const limit = Math.min(Number(params.get('limit') || 100), 500);
  const offset = Number(params.get('offset') || 0);

  // Single asset by ID
  if (assetId) {
    const { data, error } = await supabase
      .from(TABLE)
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
    .from(TABLE)
    .select('*', { count: 'exact' })
    .eq('tenant_id', tenantId)
    .eq('is_live', isLive)
    .order('created_at', { ascending: false })
    .range(offset, offset + limit - 1);

  // Default: active only. include_inactive=true returns both so the UI's
  // Inactive filter can list (and reactivate) deactivated assets.
  if (!includeInactive) {
    query = query.eq('is_active', true);
  }

  // Primary filter: by contact (client) owner
  if (contactId) {
    query = query.eq('owner_contact_id', contactId);
  }
  // Filter by ownership type
  if (ownershipType === 'self') {
    query = query.eq('ownership_type', 'self');
  } else if (ownershipType === 'client') {
    query = query.eq('ownership_type', 'client');
  }
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

  // R4: attach live-contract refs (chips on registry cards). Non-fatal —
  // if the lookup fails the list still returns, just without contracts.
  let rows = data;
  if (withContracts && data && data.length > 0) {
    try {
      const refs = await fetchContractRefsByAsset(supabase, tenantId, data.map((a: any) => a.id));
      const stateMap = await fetchServiceStateByAsset(supabase, tenantId, isLive, refs);
      rows = data.map((a: any) => ({
        ...a,
        contracts: refs.map.get(a.id) || [],
        service_state: stateMap.get(a.id) || null,
      }));
    } catch (e: any) {
      console.error('[ClientAssetRegistry] with_contracts enrichment skipped:', e?.message);
    }
  }

  return jsonResponse({
    success: true,
    data: rows,
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

  const ownershipType = body.ownership_type || 'client';
  if (ownershipType !== 'client' && ownershipType !== 'self') {
    return errorResponse('ownership_type must be "client" or "self"', 'VALIDATION_ERROR', 400);
  }
  // owner_contact_id is required for client-owned assets, optional for self-owned
  if (ownershipType === 'client' && !body.owner_contact_id) {
    return errorResponse('owner_contact_id is required for client-owned assets', 'VALIDATION_ERROR', 400);
  }

  const record = {
    tenant_id: tenantId,
    ownership_type: ownershipType,
    owner_contact_id: ownershipType === 'self' ? null : body.owner_contact_id,
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
    .from(TABLE)
    .insert([record])
    .select()
    .single();

  if (error) {
    console.error('Error creating client asset:', error);
    return errorResponse(error.message, 'CREATE_ASSET_ERROR', 500);
  }

  return jsonResponse({ success: true, data, message: 'Asset created successfully' }, 201);
}

// ============================================
// HANDLER: PATCH update asset
// ============================================
async function handleUpdate(supabase: any, tenantId: string, assetId: string, req: Request) {
  const body = await req.json();

  const { data: current, error: fetchError } = await supabase
    .from(TABLE)
    .select('id')
    .eq('id', assetId)
    .eq('tenant_id', tenantId)
    .single();

  if (fetchError || !current) {
    return errorResponse('Asset not found', 'NOT_FOUND', 404);
  }

  const updateData: Record<string, any> = { updated_at: new Date().toISOString() };
  const allowedFields = [
    'name', 'code', 'description', 'resource_type_id', 'asset_type_id',
    'parent_asset_id', 'template_id', 'industry_id', 'status', 'condition',
    'criticality', 'ownership_type', 'owner_contact_id', 'location', 'make', 'model',
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
    .from(TABLE)
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
  const { data: current, error: fetchError } = await supabase
    .from(TABLE)
    .select('id, name, is_active')
    .eq('id', assetId)
    .eq('tenant_id', tenantId)
    .single();

  if (fetchError || !current) {
    return errorResponse('Asset not found', 'NOT_FOUND', 404);
  }

  if (!current.is_active) {
    return errorResponse('Asset is already inactive', 'ALREADY_DELETED', 400);
  }

  // R3 guard: an asset attached to a live contract cannot be deactivated —
  // it must be removed from the contract first. Guard failure is fatal
  // (bubbles to the 500 handler) so a broken lookup never lets a delete through.
  const refs = await fetchContractRefsByAsset(supabase, tenantId, [assetId]);
  const inContracts = refs.map.get(assetId) || [];
  if (inContracts.length > 0) {
    const nums = inContracts.map((c) => c.contract_number).filter(Boolean).join(', ');
    return jsonResponse({
      error: `Cannot deactivate "${current.name}" — it is attached to contract${inContracts.length > 1 ? 's' : ''} ${nums}. Remove it from the contract first, then deactivate it here.`,
      code: 'ASSET_IN_CONTRACT',
      contracts: inContracts
    }, 409);
  }

  const { data, error } = await supabase
    .from(TABLE)
    .update({ is_active: false, updated_at: new Date().toISOString() })
    .eq('id', assetId)
    .eq('tenant_id', tenantId)
    .select('id, name')
    .single();

  if (error) {
    return errorResponse(error.message, 'DELETE_ASSET_ERROR', 500);
  }

  return jsonResponse({ success: true, data, message: 'Asset deactivated successfully' });
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
    .from(TABLE)
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
    .from(JUNCTION)
    .select(`*, asset:${TABLE}(*)`)
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
    .from(JUNCTION)
    .upsert(rows, { onConflict: 'contract_id,asset_id' })
    .select();

  if (error) {
    return errorResponse(error.message, 'LINK_ASSETS_ERROR', 500);
  }

  // Update denormalized summary on t_contracts
  const { data: allLinked } = await supabase
    .from(JUNCTION)
    .select(`asset_id, asset:${TABLE}(id, name, resource_type_id)`)
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
    .from(JUNCTION)
    .delete()
    .eq('contract_id', contractId)
    .eq('asset_id', assetId)
    .eq('tenant_id', tenantId);

  if (error) {
    return errorResponse(error.message, 'UNLINK_ASSET_ERROR', 500);
  }

  // Update denormalized summary
  const { data: remaining } = await supabase
    .from(JUNCTION)
    .select(`asset_id, asset:${TABLE}(id, name, resource_type_id)`)
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
