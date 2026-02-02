// supabase/functions/contracts/index.ts
// Edge function for contract & RFQ CRUD operations
// Pattern: CORS → HMAC validation → single RPC per handler → response
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { corsHeaders } from '../_shared/cors.ts';

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
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

    const lastSegment = pathSegments[pathSegments.length - 1];
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    // For sub-resource routes: /contracts/{id}/status, /contracts/{id}/invoices, etc.
    let contractId: string | null = null;
    if (isStatusRequest || isInvoicesRequest) {
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

    switch (method) {
      case 'GET':
        if (isStatsRequest) {
          response = await handleGetStats(supabase, tenantId, isLive);
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
        if (isRecordPaymentRequest && isInvoicesRequest && contractId) {
          response = await handleRecordPayment(supabase, createData, contractId, tenantId, isLive, userId);
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
  const { data, error } = await supabase.rpc('get_contracts_list', {
    p_tenant_id: tenantId,
    p_is_live: isLive,
    p_record_type: searchParams.get('record_type') || null,
    p_contract_type: searchParams.get('contract_type') || null,
    p_status: searchParams.get('status') || null,
    p_search: searchParams.get('search')?.trim() || null,
    p_page: parseInt(searchParams.get('page') || '1', 10),
    p_per_page: Math.min(parseInt(searchParams.get('per_page') || '20', 10), 100),
    p_sort_by: searchParams.get('sort_by') || 'created_at',
    p_sort_order: searchParams.get('sort_order') || 'desc'
  });

  if (error) {
    console.error('RPC get_contracts_list error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  // RPC returns { success, data, pagination, ... } — pass through
  return jsonResponse(data, data?.success ? 200 : 400);
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
// Single RPC: get_contract_stats
// ==========================================================
async function handleGetStats(
  supabase: any,
  tenantId: string,
  isLive: boolean
): Promise<Response> {
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


// ==========================================================
// HANDLER: POST create
// Single RPC: create_contract_transaction
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

  const { data, error } = await supabase.rpc('create_contract_transaction', {
    p_payload: payload,
    p_idempotency_key: idempotencyKey || null
  });

  if (error) {
    console.error('RPC create_contract_transaction error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

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
