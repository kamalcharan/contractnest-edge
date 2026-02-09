// supabase/functions/event-status-config/index.ts
// Edge function for event status configuration CRUD
// Pattern: CORS → HMAC validation → single RPC per handler → response
//
// Routes:
//   GET    /event-status-config/statuses      → get_event_status_config
//   GET    /event-status-config/transitions    → get_event_status_transitions
//   POST   /event-status-config/statuses      → upsert_event_status_config
//   POST   /event-status-config/transitions    → upsert_event_status_transition
//   DELETE /event-status-config/statuses       → delete_event_status_config
//   DELETE /event-status-config/transitions    → delete_event_status_transition
//   POST   /event-status-config/seed           → seed_event_status_defaults

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

    const isStatuses = pathSegments.includes('statuses');
    const isTransitions = pathSegments.includes('transitions');
    const isSeed = pathSegments.includes('seed');

    // ==========================================================
    // STEP 7: Route to handler
    // ==========================================================
    let response: Response;

    if (isSeed && method === 'POST') {
      response = await handleSeed(supabase, tenantId);
    } else if (isStatuses) {
      switch (method) {
        case 'GET':
          response = await handleGetStatuses(supabase, tenantId, url.searchParams);
          break;
        case 'POST': {
          const body = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleUpsertStatus(supabase, tenantId, body);
          break;
        }
        case 'DELETE': {
          const body = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleDeleteStatus(supabase, tenantId, body);
          break;
        }
        default:
          response = jsonResponse(
            { success: false, error: 'Method not allowed', code: 'METHOD_NOT_ALLOWED' },
            405
          );
      }
    } else if (isTransitions) {
      switch (method) {
        case 'GET':
          response = await handleGetTransitions(supabase, tenantId, url.searchParams);
          break;
        case 'POST': {
          const body = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleUpsertTransition(supabase, tenantId, body);
          break;
        }
        case 'DELETE': {
          const body = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleDeleteTransition(supabase, body);
          break;
        }
        default:
          response = jsonResponse(
            { success: false, error: 'Method not allowed', code: 'METHOD_NOT_ALLOWED' },
            405
          );
      }
    } else {
      response = jsonResponse(
        { success: false, error: 'Invalid path. Use /statuses, /transitions, or /seed', code: 'INVALID_PATH' },
        404
      );
    }

    return response;

  } catch (error: any) {
    console.error('Error in event-status-config edge function:', error);
    return jsonResponse(
      { success: false, error: error.message || 'Internal server error', code: 'INTERNAL_ERROR' },
      500
    );
  }
});


// ==========================================================
// HANDLER: GET /statuses?event_type=service
// RPC: get_event_status_config
// ==========================================================
async function handleGetStatuses(
  supabase: any,
  tenantId: string,
  searchParams: URLSearchParams
): Promise<Response> {
  const eventType = searchParams.get('event_type');

  if (!eventType) {
    return jsonResponse(
      { success: false, error: 'event_type query parameter is required', code: 'VALIDATION_ERROR' },
      400
    );
  }

  const { data, error } = await supabase.rpc('get_event_status_config', {
    p_tenant_id: tenantId,
    p_event_type: eventType
  });

  if (error) {
    console.error('RPC get_event_status_config error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: GET /transitions?event_type=service&from_status=scheduled
// RPC: get_event_status_transitions
// ==========================================================
async function handleGetTransitions(
  supabase: any,
  tenantId: string,
  searchParams: URLSearchParams
): Promise<Response> {
  const eventType = searchParams.get('event_type');

  if (!eventType) {
    return jsonResponse(
      { success: false, error: 'event_type query parameter is required', code: 'VALIDATION_ERROR' },
      400
    );
  }

  const { data, error } = await supabase.rpc('get_event_status_transitions', {
    p_tenant_id: tenantId,
    p_event_type: eventType,
    p_from_status: searchParams.get('from_status') || null
  });

  if (error) {
    console.error('RPC get_event_status_transitions error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: POST /statuses — create or update a status definition
// RPC: upsert_event_status_config
// ==========================================================
async function handleUpsertStatus(
  supabase: any,
  tenantId: string,
  body: any
): Promise<Response> {
  const { event_type, status_code, display_name } = body;

  if (!event_type || !status_code || !display_name) {
    return jsonResponse(
      { success: false, error: 'event_type, status_code, and display_name are required', code: 'VALIDATION_ERROR' },
      400
    );
  }

  const { data, error } = await supabase.rpc('upsert_event_status_config', {
    p_tenant_id:    tenantId,
    p_event_type:   event_type,
    p_status_code:  status_code,
    p_display_name: display_name,
    p_description:  body.description || null,
    p_hex_color:    body.hex_color || '#6B7280',
    p_icon_name:    body.icon_name || null,
    p_display_order: body.display_order ?? 0,
    p_is_initial:   body.is_initial ?? false,
    p_is_terminal:  body.is_terminal ?? false
  });

  if (error) {
    console.error('RPC upsert_event_status_config error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: DELETE /statuses — soft-delete a status
// RPC: delete_event_status_config
// ==========================================================
async function handleDeleteStatus(
  supabase: any,
  tenantId: string,
  body: any
): Promise<Response> {
  const { event_type, status_code } = body;

  if (!event_type || !status_code) {
    return jsonResponse(
      { success: false, error: 'event_type and status_code are required', code: 'VALIDATION_ERROR' },
      400
    );
  }

  const { data, error } = await supabase.rpc('delete_event_status_config', {
    p_tenant_id:  tenantId,
    p_event_type: event_type,
    p_status_code: status_code
  });

  if (error) {
    console.error('RPC delete_event_status_config error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: POST /transitions — create or update a transition
// RPC: upsert_event_status_transition
// ==========================================================
async function handleUpsertTransition(
  supabase: any,
  tenantId: string,
  body: any
): Promise<Response> {
  const { event_type, from_status, to_status } = body;

  if (!event_type || !from_status || !to_status) {
    return jsonResponse(
      { success: false, error: 'event_type, from_status, and to_status are required', code: 'VALIDATION_ERROR' },
      400
    );
  }

  const { data, error } = await supabase.rpc('upsert_event_status_transition', {
    p_tenant_id:        tenantId,
    p_event_type:       event_type,
    p_from_status:      from_status,
    p_to_status:        to_status,
    p_requires_reason:  body.requires_reason ?? false,
    p_requires_evidence: body.requires_evidence ?? false
  });

  if (error) {
    console.error('RPC upsert_event_status_transition error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: DELETE /transitions — remove a transition
// RPC: delete_event_status_transition
// ==========================================================
async function handleDeleteTransition(
  supabase: any,
  body: any
): Promise<Response> {
  const { id } = body;

  if (!id) {
    return jsonResponse(
      { success: false, error: 'id is required', code: 'VALIDATION_ERROR' },
      400
    );
  }

  const { data, error } = await supabase.rpc('delete_event_status_transition', {
    p_id: id
  });

  if (error) {
    console.error('RPC delete_event_status_transition error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: POST /seed — seed system defaults for tenant
// RPC: seed_event_status_defaults
// ==========================================================
async function handleSeed(
  supabase: any,
  tenantId: string
): Promise<Response> {
  const { data, error } = await supabase.rpc('seed_event_status_defaults', {
    p_tenant_id: tenantId
  });

  if (error) {
    console.error('RPC seed_event_status_defaults error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
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
