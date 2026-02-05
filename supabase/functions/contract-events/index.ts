// supabase/functions/contract-events/index.ts
// Edge function for contract event operations
// Pattern: CORS → HMAC validation → single RPC per handler → response
//
// Routes:
//   GET    /contract-events              → get_contract_events_list
//   GET    /contract-events/dates        → get_contract_events_date_summary
//   POST   /contract-events              → insert_contract_events_batch
//   PATCH  /contract-events/:eventId     → update_contract_event
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
      return jsonResponse(
        { success: false, error: 'x-tenant-id header is required', code: 'MISSING_TENANT_ID' },
        400
      );
    }

    // ==========================================================
    // STEP 4: Validate HMAC signature (internal handshake)
    // ==========================================================
    const signature = req.headers.get('x-internal-signature');
    if (internalSigningSecret && !signature) {
      return jsonResponse(
        { success: false, error: 'Missing internal signature', code: 'MISSING_SIGNATURE' },
        401
      );
    }

    let requestBody = '';
    if (internalSigningSecret && signature) {
      requestBody = req.method !== 'GET' ? await req.text() : '';
      const isValid = await verifyInternalSignature(requestBody, signature, internalSigningSecret);

      if (!isValid) {
        return jsonResponse(
          { success: false, error: 'Invalid internal signature', code: 'INVALID_SIGNATURE' },
          403
        );
      }
    }

    // ==========================================================
    // STEP 5: Initialize Supabase client (service_role)
    // ==========================================================
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // ==========================================================
    // STEP 6: Parse URL and route
    // ==========================================================
    const url = new URL(req.url);
    const method = req.method;
    const pathSegments = url.pathname.split('/').filter(s => s);

    const isDatesRequest = pathSegments.includes('dates');

    // Extract eventId (UUID in path for PATCH)
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    let eventId: string | null = null;
    for (const segment of pathSegments) {
      if (uuidRegex.test(segment)) {
        eventId = segment;
        break;
      }
    }

    // ==========================================================
    // STEP 7: Route to handler
    // ==========================================================
    let response: Response;

    switch (method) {
      case 'GET':
        if (isDatesRequest) {
          response = await handleDateSummary(supabase, tenantId, isLive, url.searchParams);
        } else {
          response = await handleList(supabase, tenantId, isLive, url.searchParams);
        }
        break;

      case 'POST': {
        const createData = requestBody ? JSON.parse(requestBody) : await req.json();
        response = await handleBulkInsert(supabase, createData, tenantId, isLive, userId, idempotencyKey);
        break;
      }

      case 'PATCH': {
        if (!eventId) {
          response = jsonResponse(
            { success: false, error: 'Event ID required for update', code: 'MISSING_ID' },
            400
          );
          break;
        }
        const updateData = requestBody ? JSON.parse(requestBody) : await req.json();
        response = await handleUpdate(supabase, eventId, updateData, tenantId, userId);
        break;
      }

      default:
        response = jsonResponse(
          { success: false, error: 'Method not allowed', code: 'METHOD_NOT_ALLOWED' },
          405
        );
    }

    return response;

  } catch (error: any) {
    console.error('Error in contract-events edge function:', error);
    return jsonResponse(
      { success: false, error: error.message || 'Internal server error', code: 'INTERNAL_ERROR' },
      500
    );
  }
});


// ==========================================================
// HANDLER: GET list (paginated, multi-scope)
// Single RPC: get_contract_events_list
// ==========================================================
async function handleList(
  supabase: any,
  tenantId: string,
  isLive: boolean,
  searchParams: URLSearchParams
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_contract_events_list', {
    p_tenant_id:   tenantId,
    p_is_live:     isLive,
    p_contract_id: searchParams.get('contract_id') || null,
    p_contact_id:  searchParams.get('contact_id') || null,
    p_assigned_to: searchParams.get('assigned_to') || null,
    p_status:      searchParams.get('status') || null,
    p_event_type:  searchParams.get('event_type') || null,
    p_date_from:   searchParams.get('date_from') || null,
    p_date_to:     searchParams.get('date_to') || null,
    p_page:        parseInt(searchParams.get('page') || '1', 10),
    p_per_page:    Math.min(parseInt(searchParams.get('per_page') || '50', 10), 100),
    p_sort_by:     searchParams.get('sort_by') || 'scheduled_date',
    p_sort_order:  searchParams.get('sort_order') || 'asc'
  });

  if (error) {
    console.error('RPC get_contract_events_list error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: GET /dates — date bucket summary
// Single RPC: get_contract_events_date_summary
// ==========================================================
async function handleDateSummary(
  supabase: any,
  tenantId: string,
  isLive: boolean,
  searchParams: URLSearchParams
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_contract_events_date_summary', {
    p_tenant_id:   tenantId,
    p_is_live:     isLive,
    p_contract_id: searchParams.get('contract_id') || null,
    p_contact_id:  searchParams.get('contact_id') || null,
    p_assigned_to: searchParams.get('assigned_to') || null,
    p_event_type:  searchParams.get('event_type') || null
  });

  if (error) {
    console.error('RPC get_contract_events_date_summary error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: POST — bulk insert events
// Single RPC: insert_contract_events_batch
// ==========================================================
async function handleBulkInsert(
  supabase: any,
  body: any,
  tenantId: string,
  isLive: boolean,
  userId: string | null,
  idempotencyKey: string | null
): Promise<Response> {
  const { data, error } = await supabase.rpc('insert_contract_events_batch', {
    p_tenant_id:       tenantId,
    p_contract_id:     body.contract_id,
    p_events:          body.events,
    p_created_by:      userId || body.created_by,
    p_is_live:         isLive,
    p_idempotency_key: idempotencyKey || null
  });

  if (error) {
    console.error('RPC insert_contract_events_batch error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 201 : 400);
}


// ==========================================================
// HANDLER: PATCH /:eventId — update single event
// Single RPC: update_contract_event
// ==========================================================
async function handleUpdate(
  supabase: any,
  eventId: string,
  body: any,
  tenantId: string,
  userId: string | null
): Promise<Response> {
  const { data, error } = await supabase.rpc('update_contract_event', {
    p_event_id:         eventId,
    p_tenant_id:        tenantId,
    p_payload:          body.payload || body,
    p_expected_version: body.version,
    p_changed_by:       userId || body.changed_by,
    p_changed_by_name:  body.changed_by_name || null,
    p_reason:           body.reason || null
  });

  if (error) {
    console.error('RPC update_contract_event error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  const status = data?.success ? 200 :
    data?.error_code === 'VERSION_CONFLICT' ? 409 :
    data?.error_code === 'INVALID_TRANSITION' ? 422 : 400;
  return jsonResponse(data, status);
}


// ==========================================================
// UTILITY: JSON response with CORS headers
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
