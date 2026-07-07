// ============================================================================
// Edge Function: appointments
// Stage 3 Appointments (POA §4). Mirrors the finance edge pattern:
// HMAC internal handshake, x-tenant-id / x-environment headers, thin routing
// onto Postgres RPCs.
//
// Routes:
//   GET   /appointments?status=          → get_appointments_list
//   POST  /appointments                  → create_appointment
//   PATCH /appointments/<appointment-id> → update_appointment
// ============================================================================

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { corsHeaders } from '../_shared/cors.ts';

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const tenantId = req.headers.get('x-tenant-id');
    const environment = req.headers.get('x-environment') || 'live';
    const userId = req.headers.get('x-user-id');

    const isLive = environment.toLowerCase() !== 'test';

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSigningSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');

    if (!supabaseUrl || !supabaseServiceKey) {
      throw new Error('Missing required environment variables');
    }

    if (!tenantId) {
      return jsonResponse(
        { success: false, error: 'x-tenant-id header is required', code: 'MISSING_TENANT_ID' },
        400
      );
    }

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

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const url = new URL(req.url);
    const method = req.method;
    const pathSegments = url.pathname.split('/').filter((s) => s);

    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    let appointmentId: string | null = null;
    for (const segment of pathSegments) {
      if (uuidRegex.test(segment)) {
        appointmentId = segment;
        break;
      }
    }

    let response: Response;

    switch (method) {
      case 'GET': {
        response = await callRpc(supabase, 'get_appointments_list', {
          p_tenant_id: tenantId,
          p_is_live: isLive,
          p_status: url.searchParams.get('status') || null
        });
        break;
      }

      case 'POST': {
        const body = requestBody ? JSON.parse(requestBody) : await req.json().catch(() => ({}));
        response = await callRpc(supabase, 'create_appointment', {
          p_tenant_id: tenantId,
          p_event_id: body.event_id,
          p_notes: body.notes || null,
          p_created_by: body.performed_by || userId || null,
          p_created_by_name: body.performed_by_name || null
        });
        break;
      }

      case 'PATCH': {
        if (!appointmentId) {
          response = jsonResponse(
            { success: false, error: 'Appointment ID required', code: 'MISSING_ID' },
            400
          );
          break;
        }
        const body = requestBody ? JSON.parse(requestBody) : await req.json().catch(() => ({}));
        response = await callRpc(supabase, 'update_appointment', {
          p_appointment_id: appointmentId,
          p_tenant_id: tenantId,
          p_payload: {
            status: body.status,
            scheduled_at: body.scheduled_at,
            notes: body.notes,
            proposed_slots: body.proposed_slots,
            assigned_to: body.assigned_to,
            assigned_to_name: body.assigned_to_name
          },
          p_expected_version: body.version ?? null,
          p_changed_by: body.performed_by || userId || null,
          p_changed_by_name: body.performed_by_name || null
        });
        break;
      }

      default:
        response = jsonResponse(
          { success: false, error: 'Method not allowed', code: 'METHOD_NOT_ALLOWED' },
          405
        );
    }

    return response;
  } catch (error) {
    console.error('[appointments] Unhandled error:', error);
    return jsonResponse(
      {
        success: false,
        error: error instanceof Error ? error.message : 'Internal server error',
        code: 'INTERNAL_ERROR'
      },
      500
    );
  }
});

async function callRpc(
  supabase: any,
  fnName: string,
  params: Record<string, unknown>
): Promise<Response> {
  const { data, error } = await supabase.rpc(fnName, params);

  if (error) {
    console.error(`RPC ${fnName} error:`, error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

async function verifyInternalSignature(
  payload: string,
  signature: string,
  secret: string
): Promise<boolean> {
  try {
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      'raw',
      encoder.encode(secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );

    const signatureBytes = await crypto.subtle.sign('HMAC', key, encoder.encode(payload));
    const computedSignature = Array.from(new Uint8Array(signatureBytes))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');

    return computedSignature === signature;
  } catch (error) {
    console.error('[appointments] Signature verification error:', error);
    return false;
  }
}
