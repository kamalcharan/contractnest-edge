// supabase/functions/contracts/index.ts
// Edge function for contract & RFQ CRUD operations
// Pattern: CORS → HMAC validation → single RPC per handler → response
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { corsHeaders } from '../_shared/cors.ts';
import { sendContractSignoffNotification } from './jtd-integration.ts';

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // ==========================================================
    // PUBLIC ROUTES (no auth / HMAC required)
    // Must be checked BEFORE tenant/signature validation
    // ==========================================================
    const publicUrl = new URL(req.url);
    const publicSegments = publicUrl.pathname.split('/').filter(s => s);
    const isPublicRoute = publicSegments.includes('public');

    if (isPublicRoute && req.method === 'POST') {
      const supabaseUrlPublic = Deno.env.get('SUPABASE_URL');
      const supabaseKeyPublic = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

      if (!supabaseUrlPublic || !supabaseKeyPublic) {
        throw new Error('Missing required environment variables');
      }

      const supabasePublic = createClient(supabaseUrlPublic, supabaseKeyPublic);
      const publicBody = await req.json();
      const publicLastSegment = publicSegments[publicSegments.length - 1];

      // POST /contracts/public/validate
      if (publicLastSegment === 'validate') {
        return await handlePublicValidate(supabasePublic, publicBody);
      }

      // POST /contracts/public/respond
      if (publicLastSegment === 'respond') {
        return await handlePublicRespond(supabasePublic, publicBody);
      }

      return jsonResponse({ success: false, error: 'Unknown public endpoint', code: 'NOT_FOUND' }, 404);
    }

    // ==========================================================
    // STEP 1: Extract and validate headers
    // ==========================================================
    const tenantId = req.headers.get('x-tenant-id');
    const environment = req.headers.get('x-environment') || 'live';
    const idempotencyKey = req.headers.get('x-idempotency-key');
    const userId = req.headers.get('x-user-id');

    const isLive = environment.toLowerCase() !== 'test';

    // ==========================================================
    // STEP 2: Validate environment variables
    // ==========================================================
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSigningSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');

    if (!supabaseUrl || !supabaseServiceKey) {
      throw new Error('Missing required environment variables');
    }

    // ==========================================================
    // STEP 3: Validate tenant ID
    // ==========================================================
    if (!tenantId) {
      return new Response(
        JSON.stringify({
          success: false,
          error: 'x-tenant-id header is required',
          code: 'MISSING_TENANT_ID'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ==========================================================
    // STEP 4: Validate HMAC signature (internal_handshake)
    // ==========================================================
    const signature = req.headers.get('x-internal-signature');
    if (internalSigningSecret && !signature) {
      return new Response(
        JSON.stringify({
          success: false,
          error: 'Missing internal signature',
          code: 'MISSING_SIGNATURE'
        }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    let requestBody = '';
    if (internalSigningSecret && signature) {
      requestBody = req.method !== 'GET' ? await req.text() : '';
      const isValid = await verifyInternalSignature(requestBody, signature, internalSigningSecret);

      if (!isValid) {
        return new Response(
          JSON.stringify({
            success: false,
            error: 'Invalid internal signature',
            code: 'INVALID_SIGNATURE'
          }),
          { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // ==========================================================
    // STEP 5: Initialize Supabase client
    // ==========================================================
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // ==========================================================
    // STEP 6: Parse URL and route
    // ==========================================================
    const url = new URL(req.url);
    const method = req.method;
    const pathSegments = url.pathname.split('/').filter(s => s);

    const isStatsRequest = pathSegments.includes('stats');
    const isStatusRequest = pathSegments.includes('status');
    const isInvoicesRequest = pathSegments.includes('invoices');
    const isRecordPaymentRequest = pathSegments.includes('record-payment');
    const isCancelInvoiceRequest = pathSegments.includes('cancel') && isInvoicesRequest;
    const isNotifyRequest = pathSegments.includes('notify');
    const isClaimRequest = pathSegments.includes('claim');
    const isCockpitSummaryRequest = pathSegments.includes('cockpit-summary');

    const lastSegment = pathSegments[pathSegments.length - 1];
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    // For sub-resource routes: /contracts/{id}/status, /contracts/{id}/invoices, etc.
    let contractId: string | null = null;
    if (isStatusRequest || isInvoicesRequest || isNotifyRequest) {
      // ID is before the sub-resource segment
      for (let i = 0; i < pathSegments.length - 1; i++) {
        if (uuidRegex.test(pathSegments[i])) {
          contractId = pathSegments[i];
          break;
        }
      }
    } else {
      contractId = uuidRegex.test(lastSegment) && !isStatsRequest ? lastSegment : null;
    }

    // ==========================================================
    // STEP 7: Route to handler
    // ==========================================================
    let response: Response;

    // ── DEBUG: log routing info ──
    console.log('[DEBUG-ROUTE] method:', method, 'pathSegments:', JSON.stringify(pathSegments), 'contractId:', contractId);

    switch (method) {
      case 'GET':
        if (isStatsRequest) {
          response = await handleGetStats(supabase, tenantId, isLive, url.searchParams);
        } else if (isInvoicesRequest && contractId) {
          response = await handleGetInvoices(supabase, contractId, tenantId);
        } else if (contractId) {
          response = await handleGetById(supabase, contractId, tenantId);
        } else {
          response = await handleList(supabase, tenantId, isLive, url.searchParams);
        }
        break;

      case 'POST': {
        const createData = requestBody ? JSON.parse(requestBody) : await req.json();
        if (isCockpitSummaryRequest) {
          response = await handleCockpitSummary(supabase, createData, tenantId, isLive);
        } else if (isNotifyRequest && contractId) {
          response = await handleSendNotification(supabase, contractId, createData, tenantId, isLive);
        } else if (isRecordPaymentRequest && isInvoicesRequest && contractId) {
          response = await handleRecordPayment(supabase, createData, contractId, tenantId, isLive, userId);
        } else if (isCancelInvoiceRequest && contractId) {
          response = await handleCancelInvoice(supabase, createData, contractId, tenantId, userId);
        } else if (isClaimRequest) {
          response = await handleClaimContract(supabase, createData, tenantId);
        } else {
          response = await handleCreate(supabase, createData, tenantId, isLive, userId, idempotencyKey);
        }
        break;
      }

      case 'PUT': {
        if (!contractId) {
          response = jsonResponse({ success: false, error: 'Contract ID required for update', code: 'MISSING_ID' }, 400);
          break;
        }
        const updateData = requestBody ? JSON.parse(requestBody) : await req.json();
        response = await handleUpdate(supabase, contractId, updateData, tenantId, userId, idempotencyKey);
        break;
      }

      case 'PATCH': {
        if (!contractId || !isStatusRequest) {
          response = jsonResponse({ success: false, error: 'Contract ID required for status update', code: 'MISSING_ID' }, 400);
          break;
        }
        const statusData = requestBody ? JSON.parse(requestBody) : await req.json();
        response = await handleStatusUpdate(supabase, contractId, statusData, tenantId, userId);
        break;
      }

      case 'DELETE': {
        if (!contractId) {
          response = jsonResponse({ success: false, error: 'Contract ID required for deletion', code: 'MISSING_ID' }, 400);
          break;
        }
        const deleteData = requestBody ? JSON.parse(requestBody) : await req.json().catch(() => ({}));
        response = await handleDelete(supabase, contractId, deleteData, tenantId, userId);
        break;
      }

      default:
        response = jsonResponse({ success: false, error: 'Method not allowed', code: 'METHOD_NOT_ALLOWED' }, 405);
    }

    return response;

  } catch (error: any) {
    console.error('Error in contracts edge function:', error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message || 'Internal server error',
        code: 'INTERNAL_ERROR'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});


// ==========================================================
// HANDLER: GET list (paginated)
// Single RPC: get_contracts_list
// ==========================================================
async function handleList(
  supabase: any,
  tenantId: string,
  isLive: boolean,
  searchParams: URLSearchParams
): Promise<Response> {
  // Extract group_by BEFORE calling RPC
  const groupBy = searchParams.get('group_by') || null;
  const requestedContractType = searchParams.get('contract_type') || null;

  // ── Perspective-aware fetching ──
  // Claimed contracts (via t_contract_access) are stored with the seller's
  // perspective: seller's "client" contract = buyer's "vendor" (expense).
  // To handle this correctly we ALWAYS fetch without contract_type filter,
  // then: (1) flip contract_type for accessor contracts, (2) filter by
  // requested type in JS. This covers both expense AND revenue views.
  const requestedPerPage = Math.min(parseInt(searchParams.get('per_page') || searchParams.get('limit') || '20', 10), 100);
  const requestedPage = parseInt(searchParams.get('page') || '1', 10);
  const needsJsProcessing = !!groupBy || !!requestedContractType;
  const perPage = needsJsProcessing ? 500 : requestedPerPage;
  const page = needsJsProcessing ? 1 : requestedPage;

  const { data, error } = await supabase.rpc('get_contracts_list', {
    p_tenant_id: tenantId,
    p_is_live: isLive,
    p_record_type: searchParams.get('record_type') || null,
    p_contract_type: null,  // Always null — filter in JS after perspective mapping
    p_status: searchParams.get('status') || null,
    p_search: searchParams.get('search')?.trim() || null,
    p_page: page,
    p_per_page: perPage,
    p_sort_by: searchParams.get('sort_by') || 'created_at',
    p_sort_order: searchParams.get('sort_order') || 'desc',
    p_group_by: null,  // Grouping handled in JS below
  });

  if (error) {
    console.error('RPC get_contracts_list error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  // ── Step 1: Perspective mapping for accessor (claimed) contracts ──
  // Seller stores contract_type from their view (client = revenue).
  // Buyer who claimed it sees the flipped perspective (client → vendor).
  if (data?.success && Array.isArray(data.data)) {
    data.data = data.data.map((c: any) => {
      if (c.tenant_id !== tenantId) {
        // Accessor contract: flip perspective
        const mappedType = c.contract_type === 'client' ? 'vendor'
                         : c.contract_type === 'vendor' ? 'client'
                         : c.contract_type;
        return { ...c, contract_type: mappedType };
      }
      return c;
    });
  }

  // ── Step 2: Filter by contract_type (after perspective mapping) ──
  if (requestedContractType && data?.success && Array.isArray(data.data)) {
    data.data = data.data.filter((c: any) => c.contract_type === requestedContractType);

    // Update pagination counts after filtering
    const totalFiltered = data.data.length;

    if (!groupBy) {
      // Re-paginate for flat view
      const totalPages = Math.ceil(totalFiltered / requestedPerPage) || 1;
      const offset = (requestedPage - 1) * requestedPerPage;
      data.data = data.data.slice(offset, offset + requestedPerPage);
      data.pagination = {
        page: requestedPage,
        per_page: requestedPerPage,
        total: totalFiltered,
        total_pages: totalPages,
      };
    } else {
      // Update total for grouped view (grouping handles its own structure)
      if (data.pagination) data.pagination.total = totalFiltered;
    }
  }

  // If grouping requested, group the flat results by buyer in JavaScript
  if (groupBy === 'buyer' && data?.success && Array.isArray(data.data)) {
    const groups = groupContractsByBuyer(data.data);
    return jsonResponse({
      success: true,
      groups,
      total_count: data.pagination?.total || data.data.length,
      pagination: data.pagination || { page: 1, per_page: perPage, total: data.data.length, total_pages: 1 },
      filters: data.filters,
      retrieved_at: data.retrieved_at,
    }, 200);
  }

  // Otherwise pass through flat response
  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HELPER: Group contracts by buyer (for "By Client" view)
// Groups flat contract array into buyer groups with totals
// ==========================================================
function groupContractsByBuyer(contracts: any[]): any[] {
  const map = new Map<string, any>();

  for (const c of contracts) {
    const key = c.buyer_id || c.buyer_company || c.buyer_name || 'unknown';
    if (!map.has(key)) {
      map.set(key, {
        buyer_id: c.buyer_id || null,
        buyer_name: c.buyer_name || '',
        buyer_company: c.buyer_company || c.buyer_name || 'Unknown',
        contracts: [],
        group_totals: {
          contract_count: 0,
          total_value: 0,
          total_collected: 0,
          avg_health: 0,
          total_overdue: 0,
        },
      });
    }
    const group = map.get(key)!;
    group.contracts.push(c);
    group.group_totals.contract_count++;
    group.group_totals.total_value += (c.grand_total || c.total_value || 0);
    group.group_totals.total_collected += (c.total_collected || 0);
    group.group_totals.total_overdue += (c.events_overdue || 0);
  }

  // Calculate average health per group
  for (const group of map.values()) {
    const healthSum = group.contracts.reduce(
      (sum: number, c: any) => sum + (c.health_score ?? 100), 0
    );
    group.group_totals.avg_health = group.contracts.length > 0
      ? Math.round(healthSum / group.contracts.length)
      : 0;
  }

  // Sort groups by total_value descending (biggest clients first)
  return Array.from(map.values()).sort(
    (a, b) => b.group_totals.total_value - a.group_totals.total_value
  );
}


// ==========================================================
// HANDLER: GET by ID
// Single RPC: get_contract_by_id
// ==========================================================
async function handleGetById(
  supabase: any,
  contractId: string,
  tenantId: string
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_contract_by_id', {
    p_contract_id: contractId,
    p_tenant_id: tenantId
  });

  if (error) {
    console.error('RPC get_contract_by_id error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  const status = data?.success ? 200 : (data?.error?.includes('not found') ? 404 : 400);
  return jsonResponse(data, status);
}


// ==========================================================
// HANDLER: GET stats
// Perspective-aware: when contract_type is provided, computes
// stats from list RPC (handles claimed contracts correctly).
// Without contract_type, uses fast get_contract_stats RPC.
// ==========================================================
async function handleGetStats(
  supabase: any,
  tenantId: string,
  isLive: boolean,
  searchParams: URLSearchParams
): Promise<Response> {
  const contractType = searchParams.get('contract_type') || null;

  // No perspective filter — use existing fast stats RPC
  if (!contractType) {
    const { data, error } = await supabase.rpc('get_contract_stats', {
      p_tenant_id: tenantId,
      p_is_live: isLive
    });

    if (error) {
      console.error('RPC get_contract_stats error:', error);
      return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
    }

    return jsonResponse(data, data?.success ? 200 : 400);
  }

  // ── Perspective filter requested ──
  // Always fetch without contract_type filter so we can do perspective
  // mapping for accessor (claimed) contracts, then filter by type.
  const { data: listResult, error } = await supabase.rpc('get_contracts_list', {
    p_tenant_id: tenantId,
    p_is_live: isLive,
    p_record_type: null,
    p_contract_type: null,  // Always null — filter after perspective mapping
    p_status: null,
    p_search: null,
    p_page: 1,
    p_per_page: 500,
    p_sort_by: 'created_at',
    p_sort_order: 'desc',
    p_group_by: null,
  });

  if (error) {
    console.error('RPC get_contracts_list (for stats) error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  let contracts = listResult?.data || [];

  // Perspective mapping: flip contract_type for accessor (claimed) contracts
  contracts = contracts.map((c: any) => {
    if (c.tenant_id !== tenantId) {
      const mappedType = c.contract_type === 'client' ? 'vendor'
                       : c.contract_type === 'vendor' ? 'client'
                       : c.contract_type;
      return { ...c, contract_type: mappedType };
    }
    return c;
  });

  // Filter by requested contract_type (after perspective mapping)
  contracts = contracts.filter((c: any) => c.contract_type === contractType);

  // Compute aggregated stats
  const by_status: Record<string, number> = {};
  const by_record_type: Record<string, number> = {};
  const by_contract_type: Record<string, number> = {};
  let totalValue = 0, grandTotal = 0, activeValue = 0, draftValue = 0;

  for (const c of contracts) {
    by_status[c.status] = (by_status[c.status] || 0) + 1;
    if (c.record_type) by_record_type[c.record_type] = (by_record_type[c.record_type] || 0) + 1;
    by_contract_type[c.contract_type] = (by_contract_type[c.contract_type] || 0) + 1;
    totalValue += (c.total_value || 0);
    grandTotal += (c.grand_total || 0);
    if (c.status === 'active') activeValue += (c.grand_total || 0);
    if (c.status === 'draft') draftValue += (c.grand_total || 0);
  }

  return jsonResponse({
    success: true,
    data: {
      total_count: contracts.length,
      by_status,
      by_record_type,
      by_contract_type,
      financials: {
        total_value: totalValue,
        grand_total: grandTotal,
        active_value: activeValue,
        draft_value: draftValue,
      }
    },
    retrieved_at: new Date().toISOString()
  }, 200);
}


// ==========================================================
// HANDLER: POST create
// Single RPC: create_contract_transaction
// ── DEBUG LOGGING ADDED ──
// ==========================================================
async function handleCreate(
  supabase: any,
  body: any,
  tenantId: string,
  isLive: boolean,
  userId: string | null,
  idempotencyKey: string | null
): Promise<Response> {
  const payload = {
    ...body,
    tenant_id: tenantId,
    is_live: isLive,
    created_by: userId || body.created_by,
    performed_by_type: 'user',
    performed_by_name: body.performed_by_name || null
  };

  // ── DEBUG: log the full payload going into the RPC ──
  console.log('[DEBUG-CREATE] tenantId:', tenantId, 'userId:', userId, 'isLive:', isLive, 'idempotencyKey:', idempotencyKey);
  console.log('[DEBUG-CREATE] payload keys:', Object.keys(payload));
  console.log('[DEBUG-CREATE] payload:', JSON.stringify(payload).substring(0, 2000));

  const { data, error } = await supabase.rpc('create_contract_transaction', {
    p_payload: payload,
    p_idempotency_key: idempotencyKey || null
  });

  // ── DEBUG: log the full RPC response ──
  if (error) {
    console.error('[DEBUG-CREATE] RPC supabase error:', JSON.stringify(error));
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  console.log('[DEBUG-CREATE] RPC result:', JSON.stringify(data).substring(0, 2000));
  console.log('[DEBUG-CREATE] data.success:', data?.success, 'returning status:', data?.success ? 201 : 400);

  return jsonResponse(data, data?.success ? 201 : 400);
}


// ==========================================================
// HANDLER: PUT update
// Single RPC: update_contract_transaction
// ==========================================================
async function handleUpdate(
  supabase: any,
  contractId: string,
  body: any,
  tenantId: string,
  userId: string | null,
  idempotencyKey: string | null
): Promise<Response> {
  const payload = {
    ...body,
    tenant_id: tenantId,
    updated_by: userId || body.updated_by,
    performed_by_type: 'user',
    performed_by_name: body.performed_by_name || null
  };

  const { data, error } = await supabase.rpc('update_contract_transaction', {
    p_contract_id: contractId,
    p_payload: payload,
    p_idempotency_key: idempotencyKey || null
  });

  if (error) {
    console.error('RPC update_contract_transaction error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  const status = data?.success ? 200 :
    data?.error_code === 'VERSION_CONFLICT' ? 409 : 400;
  return jsonResponse(data, status);
}


// ==========================================================
// HANDLER: PATCH status
// Single RPC: update_contract_status
// ==========================================================
async function handleStatusUpdate(
  supabase: any,
  contractId: string,
  body: any,
  tenantId: string,
  userId: string | null
): Promise<Response> {
  const { data, error } = await supabase.rpc('update_contract_status', {
    p_contract_id: contractId,
    p_tenant_id: tenantId,
    p_new_status: body.status,
    p_performed_by_id: userId || body.performed_by_id || null,
    p_performed_by_name: body.performed_by_name || null,
    p_performed_by_type: body.performed_by_type || 'user',
    p_note: body.note || null,
    p_version: body.version || null
  });

  if (error) {
    console.error('RPC update_contract_status error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  const status = data?.success ? 200 :
    data?.error_code === 'VERSION_CONFLICT' ? 409 :
    data?.error_code === 'INVALID_TRANSITION' ? 422 : 400;
  return jsonResponse(data, status);
}


// ==========================================================
// HANDLER: DELETE soft delete
// Single RPC: soft_delete_contract
// ==========================================================
async function handleDelete(
  supabase: any,
  contractId: string,
  body: any,
  tenantId: string,
  userId: string | null
): Promise<Response> {
  const { data, error } = await supabase.rpc('soft_delete_contract', {
    p_contract_id: contractId,
    p_tenant_id: tenantId,
    p_performed_by_id: userId || body.performed_by_id || null,
    p_performed_by_name: body.performed_by_name || null,
    p_version: body.version || null,
    p_note: body.note || null
  });

  if (error) {
    console.error('RPC soft_delete_contract error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  const status = data?.success ? 200 :
    data?.error_code === 'DELETE_NOT_ALLOWED' ? 422 :
    data?.error_code === 'VERSION_CONFLICT' ? 409 : 400;
  return jsonResponse(data, status);
}


// ==========================================================
// HANDLER: GET invoices for a contract
// Single RPC: get_contract_invoices
// ==========================================================
async function handleGetInvoices(
  supabase: any,
  contractId: string,
  tenantId: string
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_contract_invoices', {
    p_contract_id: contractId,
    p_tenant_id: tenantId
  });

  if (error) {
    console.error('RPC get_contract_invoices error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: POST record payment against invoice
// Single RPC: record_invoice_payment
// ==========================================================
async function handleRecordPayment(
  supabase: any,
  body: any,
  contractId: string,
  tenantId: string,
  isLive: boolean,
  userId: string | null
): Promise<Response> {
  const payload = {
    ...body,
    contract_id: contractId,
    tenant_id: tenantId,
    is_live: isLive,
    recorded_by: userId || body.recorded_by
  };

  const { data, error } = await supabase.rpc('record_invoice_payment', {
    p_payload: payload
  });

  if (error) {
    console.error('RPC record_invoice_payment error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 201 : 400);
}


// ==========================================================
// HANDLER: POST cancel or write-off an invoice
// Single RPC: cancel_or_writeoff_invoice
// ==========================================================
async function handleCancelInvoice(
  supabase: any,
  body: any,
  contractId: string,
  tenantId: string,
  userId: string | null
): Promise<Response> {
  const { invoice_id, action, reason } = body;

  if (!invoice_id || !action) {
    return jsonResponse({ success: false, error: 'invoice_id and action are required', code: 'VALIDATION_ERROR' }, 400);
  }

  if (!['cancel', 'bad_debt'].includes(action)) {
    return jsonResponse({ success: false, error: 'action must be "cancel" or "bad_debt"', code: 'VALIDATION_ERROR' }, 400);
  }

  const { data, error } = await supabase.rpc('cancel_or_writeoff_invoice', {
    p_invoice_id: invoice_id,
    p_contract_id: contractId,
    p_tenant_id: tenantId,
    p_action: action,
    p_reason: reason || null,
    p_performed_by: userId || null
  });

  if (error) {
    console.error('RPC cancel_or_writeoff_invoice error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: POST /contracts/{id}/notify
// Sends sign-off notification to buyer via email/WhatsApp
// Uses JTD framework for async delivery
// ==========================================================
async function handleSendNotification(
  supabase: any,
  contractId: string,
  body: any,
  tenantId: string,
  isLive: boolean
): Promise<Response> {
  try {
    // Step 1: Fetch full contract data to get buyer info + CNAK
    const { data: contractData, error: contractError } = await supabase.rpc('get_contract_by_id', {
      p_contract_id: contractId,
      p_tenant_id: tenantId
    });

    if (contractError || !contractData?.success || !contractData?.data) {
      return jsonResponse({ success: false, error: 'Contract not found', code: 'NOT_FOUND' }, 404);
    }

    const contract = contractData.data;
    const cnak = contract.global_access_id;

    if (!cnak) {
      return jsonResponse({ success: false, error: 'Contract has no CNAK — cannot send notification', code: 'VALIDATION_ERROR' }, 400);
    }

    // Step 2: Get secret_code from t_contract_access
    const { data: accessData } = await supabase
      .from('t_contract_access')
      .select('secret_code, accessor_email, accessor_name')
      .eq('global_access_id', cnak)
      .eq('is_active', true)
      .limit(1)
      .single();

    const secretCode = accessData?.secret_code || '';

    // Step 3: Get tenant profile for sender name
    const { data: tenantProfile } = await supabase
      .from('t_tenant_profiles')
      .select('business_name')
      .eq('tenant_id', tenantId)
      .limit(1)
      .single();

    const { data: tenant } = await supabase
      .from('t_tenants')
      .select('name')
      .eq('id', tenantId)
      .single();

    const senderName = tenantProfile?.business_name || tenant?.name || 'Your provider';

    // Step 4: Build review link
    const frontendUrl = Deno.env.get('FRONTEND_URL') || 'http://localhost:3000';
    const reviewLink = `${frontendUrl}/contract-review?cnak=${encodeURIComponent(cnak)}&secret=${encodeURIComponent(secretCode)}`;

    // Step 5: Determine recipient info
    // Priority: body overrides > contract buyer fields > access record > contact lookup
    let recipientName = body.recipient_name || contract.buyer_name || accessData?.accessor_name || 'there';
    let recipientEmail = body.recipient_email || contract.buyer_email || accessData?.accessor_email;
    let recipientMobile = body.recipient_mobile || contract.buyer_phone;

    console.log('[notify] buyer fields from contract:', JSON.stringify({
      buyer_id: contract.buyer_id,
      buyer_email: contract.buyer_email,
      buyer_phone: contract.buyer_phone,
      buyer_contact_person_id: contract.buyer_contact_person_id,
      contact_id: contract.contact_id,
      accessor_email: accessData?.accessor_email,
    }));
    console.log('[notify] after direct fields — email:', recipientEmail, 'mobile:', recipientMobile);

    // Fallback: look up email/phone from t_contact_channels
    // (t_contacts does NOT have email/phone columns — they're in t_contact_channels)
    if (!recipientEmail && !recipientMobile) {
      // Determine which contact ID to look up channels for
      // Contact persons are also t_contacts records (type='contact_person')
      const lookupId = contract.buyer_contact_person_id || contract.contact_id || contract.buyer_id;
      console.log('[notify] fallback lookupId:', lookupId);

      if (lookupId) {
        // Fetch email channel (use array + [0] instead of single() to handle 0 or multiple rows)
        const { data: emailChannels, error: emailErr } = await supabase
          .from('t_contact_channels')
          .select('value')
          .eq('contact_id', lookupId)
          .eq('channel_type', 'email')
          .order('is_primary', { ascending: false })
          .limit(1);

        const emailChannel = emailChannels?.[0];
        console.log('[notify] email channel query:', JSON.stringify({ data: emailChannel || null, error: emailErr?.message }));

        if (emailChannel?.value) {
          recipientEmail = emailChannel.value;
        }

        // Fetch mobile/whatsapp/phone channel (contacts may store numbers under different types)
        const { data: mobileChannels, error: mobileErr } = await supabase
          .from('t_contact_channels')
          .select('value, country_code, channel_type')
          .eq('contact_id', lookupId)
          .in('channel_type', ['mobile', 'whatsapp', 'phone'])
          .order('is_primary', { ascending: false })
          .limit(1);

        const mobileChannel = mobileChannels?.[0];
        console.log('[notify] mobile channel query:', JSON.stringify({ data: mobileChannel || null, error: mobileErr?.message }));

        if (mobileChannel?.value) {
          recipientMobile = mobileChannel.value;
        }

        // Get name from the contact record if we don't have one
        if (recipientName === 'there') {
          const { data: contactRecord } = await supabase
            .from('t_contacts')
            .select('name, company_name')
            .eq('id', lookupId)
            .single();

          if (contactRecord) {
            recipientName = contactRecord.name || contactRecord.company_name || 'there';
          }
        }
      }
    }

    console.log('[notify] final — email:', recipientEmail, 'mobile:', recipientMobile, 'name:', recipientName);

    if (!recipientEmail && !recipientMobile) {
      return jsonResponse({
        success: false,
        error: 'No buyer email or phone available — cannot send notification',
        code: 'VALIDATION_ERROR'
      }, 400);
    }

    // Step 6: Format contract value
    const currencySymbols: Record<string, string> = { USD: '$', EUR: '€', GBP: '£', INR: '₹', AED: 'AED ' };
    const symbol = currencySymbols[contract.currency || 'USD'] || (contract.currency + ' ');
    const grandTotal = contract.grand_total || contract.total_value || 0;
    const contractValue = `${symbol}${grandTotal.toLocaleString('en', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

    // Step 7: Create JTD entries via multi-channel integration
    const result = await sendContractSignoffNotification(supabase, {
      tenantId,
      contractId,
      recipientName,
      recipientEmail,
      recipientMobile,
      recipientCountryCode: body.recipient_country_code,
      senderName,
      contractTitle: contract.name || contract.title || 'Untitled Contract',
      contractNumber: contract.contract_number || '',
      contractValue,
      cnak,
      secretCode,
      reviewLink,
      isLive
    });

    const notifyResponse: any = {
      success: result.anySuccess,
      notification: {
        channels: result.channels,
        review_link: reviewLink,
        cnak
      }
    };
    if (!result.anySuccess) {
      notifyResponse.code = 'NOTIFICATION_FAILED';
    }
    return jsonResponse(notifyResponse, result.anySuccess ? 200 : 500);

  } catch (error) {
    console.error('handleSendNotification error:', error);
    return jsonResponse({
      success: false,
      error: error instanceof Error ? error.message : 'Failed to send notification',
      code: 'INTERNAL_ERROR'
    }, 500);
  }
}


// ==========================================================
// HANDLER: PUBLIC validate contract access
// Single RPC: validate_contract_access
// ==========================================================
async function handlePublicValidate(
  supabase: any,
  body: any
): Promise<Response> {
  const { cnak, secret_code } = body;

  if (!cnak || !secret_code) {
    return jsonResponse({ valid: false, error: 'CNAK and secret code are required' }, 400);
  }

  // Step 1: Validate access
  const { data, error } = await supabase.rpc('validate_contract_access', {
    p_cnak: cnak,
    p_secret_code: secret_code
  });

  if (error) {
    console.error('RPC validate_contract_access error:', error);
    return jsonResponse({ valid: false, error: error.message }, 500);
  }

  if (!data?.valid) {
    return jsonResponse(data, 200);
  }

  // Step 2: Fetch full contract data via existing get_contract_by_id RPC
  const contractId = data.contract?.id;
  const tenantId = data.tenant?.id;

  if (contractId && tenantId) {
    const { data: fullContract, error: fullError } = await supabase.rpc('get_contract_by_id', {
      p_contract_id: contractId,
      p_tenant_id: tenantId
    });

    if (!fullError && fullContract?.success && fullContract?.data) {
      // Replace the minimal contract with the full contract data
      data.contract = fullContract.data;
    }
  }

  return jsonResponse(data, 200);
}


// ==========================================================
// HANDLER: PUBLIC respond to contract
// Single RPC: respond_to_contract
// ==========================================================
async function handlePublicRespond(
  supabase: any,
  body: any
): Promise<Response> {
  const { cnak, secret_code, action, responded_by, responder_name, responder_email, rejection_reason } = body;

  if (!cnak || !secret_code || !action) {
    return jsonResponse({ success: false, error: 'CNAK, secret code, and action are required' }, 400);
  }

  if (!['accept', 'reject'].includes(action)) {
    return jsonResponse({ success: false, error: 'Action must be accept or reject' }, 400);
  }

  const { data, error } = await supabase.rpc('respond_to_contract', {
    p_cnak: cnak,
    p_secret_code: secret_code,
    p_action: action,
    p_responded_by: responded_by || null,
    p_responder_name: responder_name || null,
    p_responder_email: responder_email || null,
    p_rejection_reason: rejection_reason || null
  });

  if (error) {
    console.error('RPC respond_to_contract error:', error);
    return jsonResponse({ success: false, error: error.message }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: POST /contracts/claim
// Claim a contract using CNAK (authenticated)
// Single RPC: claim_contract_by_cnak
// ==========================================================
async function handleClaimContract(
  supabase: any,
  body: any,
  tenantId: string
): Promise<Response> {
  const { cnak, user_id } = body;

  if (!cnak) {
    return jsonResponse({ success: false, error: 'CNAK is required', code: 'VALIDATION_ERROR' }, 400);
  }

  if (!tenantId) {
    return jsonResponse({ success: false, error: 'tenant_id is required', code: 'MISSING_TENANT_ID' }, 400);
  }

  try {
    const { data, error } = await supabase.rpc('claim_contract_by_cnak', {
      p_cnak: cnak,
      p_tenant_id: tenantId,
      p_user_id: user_id || null
    });

    if (error) {
      console.error('RPC claim_contract_by_cnak error:', error);
      return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
    }

    // RPC returns { success: true/false, ... }
    return jsonResponse(data, data?.success ? 200 : 400);
  } catch (err) {
    console.error('handleClaimContract error:', err);
    return jsonResponse({ success: false, error: 'Failed to claim contract', code: 'INTERNAL_ERROR' }, 500);
  }
}


// ==========================================================
// HANDLER: POST /contracts/cockpit-summary
// Contact cockpit summary (contracts, events, financials)
// Single RPC: get_contact_cockpit_summary
// ==========================================================
async function handleCockpitSummary(
  supabase: any,
  body: any,
  tenantId: string,
  isLive: boolean
): Promise<Response> {
  const { contact_id, days_ahead } = body;

  if (!contact_id) {
    return jsonResponse({ success: false, error: 'contact_id is required', code: 'VALIDATION_ERROR' }, 400);
  }

  const { data, error } = await supabase.rpc('get_contact_cockpit_summary', {
    p_contact_id: contact_id,
    p_tenant_id: tenantId,
    p_is_live: isLive,
    p_days_ahead: days_ahead || 7
  });

  if (error) {
    console.error('RPC get_contact_cockpit_summary error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// UTILITY: JSON Response helper
// ==========================================================
function jsonResponse(data: any, status: number = 200): Response {
  return new Response(
    JSON.stringify(data),
    { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}


// ==========================================================
// UTILITY: HMAC signature verification (Deno Web Crypto)
// ==========================================================
async function verifyInternalSignature(
  body: string,
  signature: string,
  secret: string
): Promise<boolean> {
  try {
    const encoder = new TextEncoder();
    const keyData = encoder.encode(secret);
    const messageData = encoder.encode(body);

    const cryptoKey = await crypto.subtle.importKey(
      'raw',
      keyData,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );

    const signatureBuffer = await crypto.subtle.sign('HMAC', cryptoKey, messageData);
    const expectedSignature = Array.from(new Uint8Array(signatureBuffer))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    return signature === expectedSignature;
  } catch (error) {
    console.error('Signature verification error:', error);
    return false;
  }
}