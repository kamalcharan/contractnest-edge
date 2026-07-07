// ============================================================================
// Edge Function: finance
// Stage 1 Finance AR/AP (POA-OPERATIONS-READINESS-2026-07-07 §2)
// Mirrors the contract-events edge pattern: HMAC internal handshake,
// x-tenant-id / x-environment headers, thin routing onto Postgres RPCs.
//
// Routes:
//   GET  /finance?view=receivables            → get_tenant_receivables
//   GET  /finance?view=payables               → get_tenant_payables
//   POST /finance/<invoice-uuid>/approve      → approve_draft_invoice
//   POST /finance/<invoice-uuid>/remind       → send_invoice_reminder
//   POST /finance/<invoice-uuid>/cancel       → cancel_or_writeoff_invoice (reused)
// ============================================================================

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { corsHeaders } from '../_shared/cors.ts';

serve(async (req: Request) => {
  // Handle CORS preflight
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

    // Validate HMAC signature (internal handshake)
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
    let invoiceId: string | null = null;
    for (const segment of pathSegments) {
      if (uuidRegex.test(segment)) {
        invoiceId = segment;
        break;
      }
    }
    const lastSegment = pathSegments[pathSegments.length - 1] || '';

    let response: Response;

    switch (method) {
      case 'GET': {
        const view = (url.searchParams.get('view') || 'receivables').toLowerCase();
        if (view === 'payables') {
          response = await callRpc(supabase, 'get_tenant_payables', {
            p_tenant_id: tenantId,
            p_is_live: isLive
          });
        } else {
          response = await callRpc(supabase, 'get_tenant_receivables', {
            p_tenant_id: tenantId,
            p_is_live: isLive
          });
        }
        break;
      }

      case 'POST': {
        if (!invoiceId) {
          response = jsonResponse(
            { success: false, error: 'Invoice ID required', code: 'MISSING_ID' },
            400
          );
          break;
        }

        const body = requestBody ? JSON.parse(requestBody) : await req.json().catch(() => ({}));
        const performedBy = body.performed_by || userId || null;
        const performedByName = body.performed_by_name || null;

        if (lastSegment === 'approve') {
          response = await callRpc(supabase, 'approve_draft_invoice', {
            p_invoice_id: invoiceId,
            p_tenant_id: tenantId,
            p_performed_by: performedBy,
            p_performed_by_name: performedByName
          });
        } else if (lastSegment === 'remind') {
          response = await callRpc(supabase, 'send_invoice_reminder', {
            p_invoice_id: invoiceId,
            p_tenant_id: tenantId,
            p_performed_by: performedBy,
            p_performed_by_name: performedByName
          });
        } else if (lastSegment === 'cancel') {
          if (!body.contract_id) {
            response = jsonResponse(
              { success: false, error: 'contract_id is required to cancel an invoice', code: 'MISSING_CONTRACT_ID' },
              400
            );
            break;
          }
          // Reuses the existing cancel/write-off RPC (contracts/045)
          response = await callRpc(supabase, 'cancel_or_writeoff_invoice', {
            p_invoice_id: invoiceId,
            p_contract_id: body.contract_id,
            p_tenant_id: tenantId,
            p_action: 'cancel',
            p_reason: body.reason || null,
            p_performed_by: performedBy
          });
        } else {
          response = jsonResponse(
            { success: false, error: `Unknown action: ${lastSegment}`, code: 'UNKNOWN_ACTION' },
            400
          );
        }
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
    console.error('[finance] Unhandled error:', error);
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

// ─────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────

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
    console.error('[finance] Signature verification error:', error);
    return false;
  }
}
