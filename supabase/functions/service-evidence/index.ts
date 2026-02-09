// supabase/functions/service-evidence/index.ts
// Edge function for service evidence CRUD operations
// Pattern: CORS → HMAC validation → single RPC per handler → response
//
// Routes:
//   GET    /service-evidence              → get_service_evidence_list
//   POST   /service-evidence              → create_service_evidence
//   PATCH  /service-evidence/:id          → update_service_evidence (verify/reject/update)

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

    // Extract evidence ID (UUID in path)
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    let evidenceId: string | null = null;
    for (const segment of pathSegments) {
      if (uuidRegex.test(segment)) {
        evidenceId = segment;
        break;
      }
    }

    // ==========================================================
    // STEP 7: Route to handler
    // ==========================================================
    let response: Response;

    switch (method) {
      case 'GET':
        response = await handleList(supabase, tenantId, isLive, url.searchParams);
        break;

      case 'POST': {
        const createData = requestBody ? JSON.parse(requestBody) : await req.json();
        response = await handleCreate(supabase, createData, tenantId, isLive, userId);
        break;
      }

      case 'PATCH': {
        if (!evidenceId) {
          response = jsonResponse(
            { success: false, error: 'Evidence ID required for update', code: 'MISSING_ID' },
            400
          );
          break;
        }
        const updateData = requestBody ? JSON.parse(requestBody) : await req.json();
        response = await handleUpdate(supabase, evidenceId, updateData, tenantId, userId);
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
    console.error('Error in service-evidence edge function:', error);
    return jsonResponse(
      { success: false, error: error.message || 'Internal server error', code: 'INTERNAL_ERROR' },
      500
    );
  }
});


// ==========================================================
// HANDLER: GET list — filtered evidence list
// RPC: get_service_evidence_list
// ==========================================================
async function handleList(
  supabase: any,
  tenantId: string,
  isLive: boolean,
  searchParams: URLSearchParams
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_service_evidence_list', {
    p_tenant_id:     tenantId,
    p_ticket_id:     searchParams.get('ticket_id') || null,
    p_contract_id:   searchParams.get('contract_id') || null,
    p_evidence_type: searchParams.get('evidence_type') || null,
    p_status:        searchParams.get('status') || null,
    p_is_live:       isLive
  });

  if (error) {
    console.error('RPC get_service_evidence_list error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: POST — create evidence record
// RPC: create_service_evidence
// ==========================================================
async function handleCreate(
  supabase: any,
  body: any,
  tenantId: string,
  isLive: boolean,
  userId: string | null
): Promise<Response> {
  if (!body.ticket_id || !body.evidence_type) {
    return jsonResponse(
      { success: false, error: 'ticket_id and evidence_type are required', code: 'VALIDATION_ERROR' },
      400
    );
  }

  const validTypes = ['upload-form', 'otp', 'service-form'];
  if (!validTypes.includes(body.evidence_type)) {
    return jsonResponse(
      { success: false, error: `evidence_type must be one of: ${validTypes.join(', ')}`, code: 'VALIDATION_ERROR' },
      400
    );
  }

  const { data, error } = await supabase.rpc('create_service_evidence', {
    p_tenant_id:          tenantId,
    p_ticket_id:          body.ticket_id,
    p_evidence_type:      body.evidence_type,
    p_event_id:           body.event_id || null,
    p_block_id:           body.block_id || null,
    p_block_name:         body.block_name || null,
    p_label:              body.label || null,
    p_description:        body.description || null,
    // File fields
    p_file_url:           body.file_url || null,
    p_file_name:          body.file_name || null,
    p_file_size:          body.file_size || null,
    p_file_type:          body.file_type || null,
    p_file_thumbnail_url: body.file_thumbnail_url || null,
    // OTP fields
    p_otp_code:           body.otp_code || null,
    p_otp_sent_to:        body.otp_sent_to || null,
    // Form fields
    p_form_template_id:   body.form_template_id || null,
    p_form_template_name: body.form_template_name || null,
    p_form_data:          body.form_data || null,
    // Meta
    p_uploaded_by:        userId || body.uploaded_by || null,
    p_uploaded_by_name:   body.uploaded_by_name || null,
    p_is_live:            isLive
  });

  if (error) {
    console.error('RPC create_service_evidence error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 201 : 400);
}


// ==========================================================
// HANDLER: PATCH /:id — update evidence (verify/reject/update)
// RPC: update_service_evidence
// ==========================================================
async function handleUpdate(
  supabase: any,
  evidenceId: string,
  body: any,
  tenantId: string,
  userId: string | null
): Promise<Response> {
  if (!body.action) {
    return jsonResponse(
      { success: false, error: 'action is required (verify, reject, verify_otp, update_file, update_form)', code: 'VALIDATION_ERROR' },
      400
    );
  }

  const validActions = ['verify', 'reject', 'verify_otp', 'update_file', 'update_form'];
  if (!validActions.includes(body.action)) {
    return jsonResponse(
      { success: false, error: `action must be one of: ${validActions.join(', ')}`, code: 'VALIDATION_ERROR' },
      400
    );
  }

  const { data, error } = await supabase.rpc('update_service_evidence', {
    p_evidence_id:      evidenceId,
    p_tenant_id:        tenantId,
    p_action:           body.action,
    p_payload:          body.payload || {},
    p_changed_by:       userId || body.changed_by || null,
    p_changed_by_name:  body.changed_by_name || null
  });

  if (error) {
    console.error('RPC update_service_evidence error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  const status = data?.success ? 200 : data?.code === 'NOT_FOUND' ? 404 : 400;
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
