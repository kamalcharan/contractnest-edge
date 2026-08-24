// supabase/functions/contracts-v2/index.ts
// JTD Nucleus initiative — Milestone 1. New, versioned edge function,
// alongside (not replacing) supabase/functions/contracts/index.ts.
//
// Scope:
//   POST  /               — create a contract via create_contract_transaction_v2
//   GET   /:id/details    — single-call contract view aggregate via
//                           get_contract_details_v2 (JTD Nucleus Step 3):
//                           contract + blocks + events (n_jtd JOBS, legacy
//                           fallback) + CNAK + invoices, one round-trip.
//   PATCH /:id/status     — update_contract_status_v2: on activation,
//                           materializes n_jtd JOB rows from computed_events
//                           (wizard draft→activate path, the CN-1019 gap)
//                           then delegates to the untouched V1 status engine.
//   POST  /:id/record-payment — record_invoice_payment_v2 (JTD Nucleus
//                           Step 4): consumes computed_events into jobs
//                           first (pay-before-activate safe), delegates
//                           receipt/invoice/auto-activation to the untouched
//                           V1 record_invoice_payment, then settles JOB rows
//                           (allocations carry jtd_id; job → paid /
//                           partial_payment). Payload mirrors V1's
//                           handleRecordPayment exactly.
// Nothing else (list/update/etc.) is implemented here;
// contracts/index.ts is completely untouched.
//
// seller_id/buyer_id resolution: mirrors V1's current behavior exactly
// (seller = tenant, buyer = body.buyer_id) — the Revenue/Expense-mode
// inversion found in Sprint 3 is a known, separately-tracked gap, not
// fixed here. This endpoint is behavior-equivalent to V1 for the normal
// case, plus the CNAK-grant fix and the atomic JTD insert.
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';

// Inlined rather than imported from ../_shared/cors.ts — identical content,
// avoids a relative-import bundling issue specific to this function's
// deploy path. contracts/index.ts's own import is untouched.
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-user-id, x-request-id, idempotency-key',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Max-Age': '86400',
};

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    if (req.method !== 'POST' && req.method !== 'GET' && req.method !== 'PATCH') {
      return jsonResponse({ success: false, error: 'Only POST, GET /:id/details and PATCH /:id/status are implemented on contracts-v2', code: 'NOT_IMPLEMENTED' }, 405);
    }

    const tenantId = req.headers.get('x-tenant-id');
    const environment = req.headers.get('x-environment') || 'live';
    const idempotencyKey = req.headers.get('x-idempotency-key');
    const userId = req.headers.get('x-user-id');
    const isLive = environment.toLowerCase() !== 'test';

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSigningSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');

    if (!supabaseUrl || !supabaseServiceKey) {
      throw new Error('Missing required environment variables');
    }

    if (!tenantId) {
      return jsonResponse({ success: false, error: 'x-tenant-id header is required', code: 'MISSING_TENANT_ID' }, 400);
    }

    const signature = req.headers.get('x-internal-signature');
    if (internalSigningSecret && !signature) {
      return jsonResponse({ success: false, error: 'Missing internal signature', code: 'MISSING_SIGNATURE' }, 401);
    }

    const requestBody = await req.text();
    if (internalSigningSecret && signature) {
      const isValid = await verifyInternalSignature(requestBody, signature, internalSigningSecret);
      if (!isValid) {
        return jsonResponse({ success: false, error: 'Invalid internal signature', code: 'INVALID_SIGNATURE' }, 403);
      }
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // ── GET /:id/details — JTD Nucleus Step 3 aggregate (read-only) ──
    if (req.method === 'GET') {
      const url = new URL(req.url);
      const match = url.pathname.match(/\/contracts-v2\/([0-9a-f-]{36})\/details\/?$/i);
      if (!match) {
        return jsonResponse({ success: false, error: 'GET supports only /:id/details', code: 'NOT_FOUND' }, 404);
      }
      const contractId = match[1];

      const { data, error } = await supabase.rpc('get_contract_details_v2', {
        p_tenant_id: tenantId,
        p_contract_id: contractId
      });

      if (error) {
        console.error('[contracts-v2] details RPC error:', JSON.stringify(error));
        return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
      }

      return jsonResponse(data, data?.success ? 200 : 404);
    }

    const body = requestBody ? JSON.parse(requestBody) : {};

    // ── POST /:id/record-payment — V2 payment (JTD Nucleus Step 4) ──
    // Same payload construction as V1's handleRecordPayment; the RPC
    // settles JOB rows instead of t_contract_events rows.
    if (req.method === 'POST') {
      const url = new URL(req.url);
      const payMatch = url.pathname.match(/\/contracts-v2\/([0-9a-f-]{36})\/record-payment\/?$/i);
      if (payMatch) {
        const contractId = payMatch[1];

        const payload = {
          ...body,
          contract_id: contractId,
          tenant_id: tenantId,
          is_live: isLive,
          recorded_by: userId || body.recorded_by
        };

        const { data, error } = await supabase.rpc('record_invoice_payment_v2', {
          p_payload: payload
        });

        if (error) {
          console.error('[contracts-v2] record-payment RPC error:', JSON.stringify(error));
          return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
        }

        return jsonResponse(data, data?.success ? 201 : 400);
      }
    }

    // ── PATCH /:id/status — V2 status transition (JTD Nucleus) ──
    // On 'active': jobs materialize from computed_events FIRST (same
    // transaction, inside the RPC), so the V1 events trigger skips by its
    // own computed_events-NOT-NULL guard. Everything else (validation,
    // CNAK minting, invoices, history) is the untouched V1 engine.
    if (req.method === 'PATCH') {
      const url = new URL(req.url);
      const match = url.pathname.match(/\/contracts-v2\/([0-9a-f-]{36})\/status\/?$/i);
      if (!match) {
        return jsonResponse({ success: false, error: 'PATCH supports only /:id/status', code: 'NOT_FOUND' }, 404);
      }
      const contractId = match[1];

      if (!body.status) {
        return jsonResponse({ success: false, error: 'status is required', code: 'VALIDATION_ERROR' }, 400);
      }

      const statusActor = userId || body.updated_by || null;
      const { data, error } = await supabase.rpc('update_contract_status_v2', {
        p_contract_id: contractId,
        p_tenant_id: tenantId,
        p_new_status: body.status,
        p_performed_by_id: statusActor,
        p_performed_by_name: body.performed_by_name || null,
        p_performed_by_type: statusActor ? 'user' : 'system',
        p_note: body.note || null,
        p_version: body.version ?? null
      });

      if (error) {
        console.error('[contracts-v2] status RPC error:', JSON.stringify(error));
        return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
      }

      return jsonResponse(data, data?.success ? 200 : 400);
    }

    // Same resolution V1 uses today: seller is always the creating tenant,
    // buyer is whatever the client sent. contract_type='vendor' (Expense
    // mode) is NOT swapped here — tracked separately, not fixed yet.
    const sellerId = tenantId;
    const buyerId = body.buyer_id || null;

    if (!buyerId) {
      return jsonResponse({ success: false, error: 'buyer_id is required', code: 'VALIDATION_ERROR' }, 400);
    }

    // x-user-id is read for parity with contracts/index.ts, but the API
    // layer actually sends the real user id in the body (created_by), not
    // this header — same as V1. Resolve performed_by_type from whichever
    // one actually landed, not just the header, or every real call would
    // fall through to 'system' even with a real user attached.
    const resolvedCreatedBy = userId || body.created_by;
    const payload = {
      ...body,
      created_by: resolvedCreatedBy,
      performed_by_type: resolvedCreatedBy ? 'user' : 'system',
      performed_by_name: body.performed_by_name || null
    };

    console.log('[contracts-v2] tenantId:', tenantId, 'sellerId:', sellerId, 'buyerId:', buyerId, 'isLive:', isLive);

    const { data, error } = await supabase.rpc('create_contract_transaction_v2', {
      p_tenant_id: tenantId,
      p_seller_id: sellerId,
      p_buyer_id: buyerId,
      p_payload: payload,
      p_is_live: isLive,
      p_idempotency_key: idempotencyKey || null
    });

    if (error) {
      console.error('[contracts-v2] RPC error:', JSON.stringify(error));
      return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
    }

    console.log('[contracts-v2] RPC result:', JSON.stringify(data).substring(0, 2000));
    return jsonResponse(data, data?.success ? 201 : 400);

  } catch (error) {
    console.error('[contracts-v2] Unhandled error:', error);
    return jsonResponse({ success: false, error: error instanceof Error ? error.message : 'Unknown error', code: 'INTERNAL_ERROR' }, 500);
  }
});

function jsonResponse(data: any, status: number = 200): Response {
  return new Response(
    JSON.stringify(data),
    { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}

async function verifyInternalSignature(body: string, signature: string, secret: string): Promise<boolean> {
  try {
    const encoder = new TextEncoder();
    const keyData = encoder.encode(secret);
    const messageData = encoder.encode(body);

    const cryptoKey = await crypto.subtle.importKey(
      'raw', keyData, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
    );

    const signatureBuffer = await crypto.subtle.sign('HMAC', cryptoKey, messageData);
    const expectedSignature = Array.from(new Uint8Array(signatureBuffer))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    return signature === expectedSignature;
  } catch (error) {
    console.error('[contracts-v2] Signature verification error:', error);
    return false;
  }
}
