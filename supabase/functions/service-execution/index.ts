// supabase/functions/service-execution/index.ts
// Unified edge function for service ticket execution
// Pattern: CORS → HMAC validation → single RPC per handler → response
//
// Routes:
//   GET    /service-execution                              → get_service_tickets_list
//   GET    /service-execution/:ticketId                    → get_service_ticket_detail
//   POST   /service-execution                              → create_service_ticket
//   PATCH  /service-execution/:ticketId                    → update_service_ticket
//   GET    /service-execution/:ticketId/evidence           → get_service_evidence_list (scoped to ticket)
//   POST   /service-execution/:ticketId/evidence           → create_service_evidence
//   PATCH  /service-execution/:ticketId/evidence/:evidId   → update_service_evidence
//   GET    /service-execution/audit                        → get_audit_log
//   GET    /service-execution/evidence                     → get_service_evidence_list (contract-wide)

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
    // STEP 6: Parse URL and extract route segments
    // ==========================================================
    const url = new URL(req.url);
    const method = req.method;
    const pathSegments = url.pathname.split('/').filter(s => s);

    // Parse route structure:
    //   /service-execution                              → ticket list / create
    //   /service-execution/audit                        → audit log
    //   /service-execution/evidence                     → evidence list (contract-wide)
    //   /service-execution/:ticketId                    → ticket detail / update
    //   /service-execution/:ticketId/evidence           → evidence for ticket
    //   /service-execution/:ticketId/evidence/:evidId   → update evidence

    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    const route = parseRoute(pathSegments, uuidRegex);

    // ==========================================================
    // STEP 7: Route to handler
    // ==========================================================
    let response: Response;

    // ── Audit sub-route ──
    if (route.isAudit) {
      if (method !== 'GET') {
        return jsonResponse({ success: false, error: 'Audit log is read-only', code: 'METHOD_NOT_ALLOWED' }, 405);
      }
      response = await handleAuditList(supabase, tenantId, url.searchParams);

    // ── Evidence sub-route (contract-wide: /evidence?contract_id=...) ──
    } else if (route.isEvidenceRoot && !route.ticketId) {
      if (method !== 'GET') {
        return jsonResponse({ success: false, error: 'Use /:ticketId/evidence for POST', code: 'VALIDATION_ERROR' }, 400);
      }
      response = await handleEvidenceList(supabase, tenantId, isLive, url.searchParams, null);

    // ── Ticket + Evidence sub-route (/:ticketId/evidence) ──
    } else if (route.ticketId && route.isEvidence) {
      switch (method) {
        case 'GET':
          response = await handleEvidenceList(supabase, tenantId, isLive, url.searchParams, route.ticketId);
          break;

        case 'POST': {
          const body = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleEvidenceCreate(supabase, body, tenantId, isLive, userId, route.ticketId);
          break;
        }

        case 'PATCH': {
          if (!route.evidenceId) {
            return jsonResponse({ success: false, error: 'Evidence ID required for update', code: 'MISSING_ID' }, 400);
          }
          const body = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleEvidenceUpdate(supabase, route.evidenceId, body, tenantId, userId);
          break;
        }

        default:
          response = jsonResponse({ success: false, error: 'Method not allowed', code: 'METHOD_NOT_ALLOWED' }, 405);
      }

    // ── Ticket routes ──
    } else {
      switch (method) {
        case 'GET':
          if (route.ticketId) {
            response = await handleTicketDetail(supabase, route.ticketId, tenantId);
          } else {
            response = await handleTicketList(supabase, tenantId, isLive, url.searchParams);
          }
          break;

        case 'POST': {
          const body = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleTicketCreate(supabase, body, tenantId, isLive, userId);
          break;
        }

        case 'PATCH': {
          if (!route.ticketId) {
            return jsonResponse({ success: false, error: 'Ticket ID required for update', code: 'MISSING_ID' }, 400);
          }
          const body = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleTicketUpdate(supabase, route.ticketId, body, tenantId, userId);
          break;
        }

        default:
          response = jsonResponse({ success: false, error: 'Method not allowed', code: 'METHOD_NOT_ALLOWED' }, 405);
      }
    }

    return response;

  } catch (error: any) {
    console.error('Error in service-execution edge function:', error);
    return jsonResponse(
      { success: false, error: error.message || 'Internal server error', code: 'INTERNAL_ERROR' },
      500
    );
  }
});


// ==========================================================
// ROUTE PARSER
// Extracts ticketId, evidenceId, and sub-route flags
// ==========================================================
interface ParsedRoute {
  ticketId: string | null;
  evidenceId: string | null;
  isEvidence: boolean;
  isEvidenceRoot: boolean;
  isAudit: boolean;
}

function parseRoute(segments: string[], uuidRegex: RegExp): ParsedRoute {
  const result: ParsedRoute = {
    ticketId: null,
    evidenceId: null,
    isEvidence: false,
    isEvidenceRoot: false,
    isAudit: false,
  };

  // Walk segments after the function name
  // Segments: ['service-execution', ...rest]
  let afterFunction = false;
  let expectEvidenceId = false;

  for (const seg of segments) {
    if (seg === 'service-execution') {
      afterFunction = true;
      continue;
    }
    if (!afterFunction) continue;

    if (seg === 'audit') {
      result.isAudit = true;
      break;
    }

    if (seg === 'evidence') {
      result.isEvidence = true;
      if (!result.ticketId) {
        result.isEvidenceRoot = true;
      }
      expectEvidenceId = true;
      continue;
    }

    if (uuidRegex.test(seg)) {
      if (expectEvidenceId) {
        result.evidenceId = seg;
      } else if (!result.ticketId) {
        result.ticketId = seg;
      }
      continue;
    }
  }

  return result;
}


// ==========================================================
// TICKET HANDLERS
// ==========================================================

// GET / — list tickets
async function handleTicketList(
  supabase: any, tenantId: string, isLive: boolean, params: URLSearchParams
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_service_tickets_list', {
    p_tenant_id:   tenantId,
    p_contract_id: params.get('contract_id') || null,
    p_status:      params.get('status') || null,
    p_assigned_to: params.get('assigned_to') || null,
    p_date_from:   params.get('date_from') || null,
    p_date_to:     params.get('date_to') || null,
    p_page:        parseInt(params.get('page') || '1', 10),
    p_per_page:    Math.min(parseInt(params.get('per_page') || '20', 10), 100),
    p_is_live:     isLive
  });

  if (error) {
    console.error('RPC get_service_tickets_list error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }
  return jsonResponse(data, data?.success ? 200 : 400);
}

// GET /:ticketId — ticket detail with events + evidence
async function handleTicketDetail(
  supabase: any, ticketId: string, tenantId: string
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_service_ticket_detail', {
    p_ticket_id: ticketId,
    p_tenant_id: tenantId
  });

  if (error) {
    console.error('RPC get_service_ticket_detail error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }
  return jsonResponse(data, data?.success ? 200 : data?.code === 'NOT_FOUND' ? 404 : 400);
}

// POST / — create ticket
async function handleTicketCreate(
  supabase: any, body: any, tenantId: string, isLive: boolean, userId: string | null
): Promise<Response> {
  if (!body.contract_id) {
    return jsonResponse({ success: false, error: 'contract_id is required', code: 'VALIDATION_ERROR' }, 400);
  }

  const { data, error } = await supabase.rpc('create_service_ticket', {
    p_tenant_id:        tenantId,
    p_contract_id:      body.contract_id,
    p_scheduled_date:   body.scheduled_date || null,
    p_assigned_to:      body.assigned_to || null,
    p_assigned_to_name: body.assigned_to_name || null,
    p_notes:            body.notes || null,
    p_event_ids:        body.event_ids || [],
    p_created_by:       userId || body.created_by || null,
    p_created_by_name:  body.created_by_name || null,
    p_is_live:          isLive
  });

  if (error) {
    console.error('RPC create_service_ticket error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }
  return jsonResponse(data, data?.success ? 201 : 400);
}

// PATCH /:ticketId — update ticket
async function handleTicketUpdate(
  supabase: any, ticketId: string, body: any, tenantId: string, userId: string | null
): Promise<Response> {
  const { data, error } = await supabase.rpc('update_service_ticket', {
    p_ticket_id:        ticketId,
    p_tenant_id:        tenantId,
    p_payload:          body.payload || body,
    p_expected_version: body.version ?? null,
    p_changed_by:       userId || body.changed_by || null,
    p_changed_by_name:  body.changed_by_name || null
  });

  if (error) {
    console.error('RPC update_service_ticket error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }
  const status = data?.success ? 200 :
    data?.code === 'VERSION_CONFLICT' ? 409 :
    data?.code === 'NOT_FOUND' ? 404 : 400;
  return jsonResponse(data, status);
}


// ==========================================================
// EVIDENCE HANDLERS
// ==========================================================

// GET /evidence OR /:ticketId/evidence — list evidence
async function handleEvidenceList(
  supabase: any, tenantId: string, isLive: boolean, params: URLSearchParams, ticketId: string | null
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_service_evidence_list', {
    p_tenant_id:     tenantId,
    p_ticket_id:     ticketId || params.get('ticket_id') || null,
    p_contract_id:   params.get('contract_id') || null,
    p_evidence_type: params.get('evidence_type') || null,
    p_status:        params.get('status') || null,
    p_is_live:       isLive
  });

  if (error) {
    console.error('RPC get_service_evidence_list error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }
  return jsonResponse(data, data?.success ? 200 : 400);
}

// POST /:ticketId/evidence — create evidence
async function handleEvidenceCreate(
  supabase: any, body: any, tenantId: string, isLive: boolean, userId: string | null, ticketId: string
): Promise<Response> {
  if (!body.evidence_type) {
    return jsonResponse({ success: false, error: 'evidence_type is required', code: 'VALIDATION_ERROR' }, 400);
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
    p_ticket_id:          ticketId,
    p_evidence_type:      body.evidence_type,
    p_event_id:           body.event_id || null,
    p_block_id:           body.block_id || null,
    p_block_name:         body.block_name || null,
    p_label:              body.label || null,
    p_description:        body.description || null,
    p_file_url:           body.file_url || null,
    p_file_name:          body.file_name || null,
    p_file_size:          body.file_size || null,
    p_file_type:          body.file_type || null,
    p_file_thumbnail_url: body.file_thumbnail_url || null,
    p_otp_code:           body.otp_code || null,
    p_otp_sent_to:        body.otp_sent_to || null,
    p_form_template_id:   body.form_template_id || null,
    p_form_template_name: body.form_template_name || null,
    p_form_data:          body.form_data || null,
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

// PATCH /:ticketId/evidence/:evidenceId — update evidence
async function handleEvidenceUpdate(
  supabase: any, evidenceId: string, body: any, tenantId: string, userId: string | null
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
  return jsonResponse(data, data?.success ? 200 : data?.code === 'NOT_FOUND' ? 404 : 400);
}


// ==========================================================
// AUDIT HANDLER
// ==========================================================

// GET /audit — paginated audit log
async function handleAuditList(
  supabase: any, tenantId: string, params: URLSearchParams
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_audit_log', {
    p_tenant_id:    tenantId,
    p_contract_id:  params.get('contract_id') || null,
    p_entity_type:  params.get('entity_type') || null,
    p_entity_id:    params.get('entity_id') || null,
    p_category:     params.get('category') || null,
    p_performed_by: params.get('performed_by') || null,
    p_date_from:    params.get('date_from') || null,
    p_date_to:      params.get('date_to') || null,
    p_page:         parseInt(params.get('page') || '1', 10),
    p_per_page:     Math.min(parseInt(params.get('per_page') || '20', 10), 100)
  });

  if (error) {
    console.error('RPC get_audit_log error:', error);
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
