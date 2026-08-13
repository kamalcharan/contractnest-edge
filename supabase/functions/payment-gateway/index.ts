// supabase/functions/payment-gateway/index.ts
// Gateway-agnostic payment operations edge function
// Routes: create-order, create-link, verify-payment, payment-status
// Pattern: CORS → HMAC → fetch credentials → route to provider → RPC

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { corsHeaders } from '../_shared/cors.ts';

// Provider imports
import * as razorpay from './providers/razorpay.ts';
// JTD notification dispatch
import { sendPaymentRequestNotification } from './jtd-integration.ts';

// ─── Encryption (same as integrations edge function) ──────

async function decryptData(encryptedData: string, encryptionKey: string): Promise<any> {
  const encryptedBytes = new Uint8Array(atob(encryptedData).split('').map(c => c.charCodeAt(0)));
  const iv = encryptedBytes.slice(0, 12);
  const ciphertext = encryptedBytes.slice(12);

  const keyBytes = new TextEncoder().encode(encryptionKey.padEnd(32, '0').slice(0, 32));
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    keyBytes,
    { name: 'AES-GCM', length: 256 },
    false,
    ['decrypt']
  );

  const decryptedContent = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: iv },
    cryptoKey,
    ciphertext
  );

  const jsonString = new TextDecoder().decode(decryptedContent);
  return JSON.parse(jsonString);
}

// ─── HMAC Verification ────────────────────────────────────

async function verifyInternalSignature(body: string, signature: string, secret: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const signatureBytes = await crypto.subtle.sign('HMAC', key, encoder.encode(body));
  const expectedSignature = Array.from(new Uint8Array(signatureBytes))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
  return expectedSignature === signature;
}

// ─── Response Helper ──────────────────────────────────────

function jsonResponse(data: any, status = 200): Response {
  return new Response(
    JSON.stringify(data),
    { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}

// ─── Fetch & Decrypt Gateway Credentials ──────────────────

async function getGatewayCredentials(
  supabase: any,
  tenantId: string,
  encryptionKey: string,
  provider?: string,
  isLive?: boolean
): Promise<{ success: boolean; provider?: string; credentials?: any; isLive?: boolean; error?: string }> {
  const { data, error } = await supabase.rpc('get_tenant_gateway_credentials', {
    p_tenant_id: tenantId,
    p_provider: provider || null,
    // Environment must match. Previously the newest-updated row won whatever
    // its environment, so a re-saved TEST gateway could take LIVE money.
    p_is_live: typeof isLive === 'boolean' ? isLive : null
  });

  if (error) {
    console.error('[PayGateway] RPC error:', error);
    return { success: false, error: 'Failed to fetch gateway credentials' };
  }

  if (!data?.success) {
    return { success: false, error: data?.error || 'No active payment gateway' };
  }

  const info = data.data;

  // Decrypt credentials
  try {
    // UNWRAP FIRST. The integrations function stores credentials as
    // `{ encrypted: "<base64>" }` (see integrations/index.ts — it builds
    // credentialsJsonb = { encrypted: ... } on save, and unwraps the same way
    // on read), and for config-only providers it also keeps a plaintext
    // `public` copy alongside. Only the very oldest rows are a bare base64
    // string.
    //
    // This function passed the raw JSONB straight to decryptData, so atob()
    // received an object and threw "Failed to decode base64" — meaning every
    // tenant whose gateway was saved in the current format could not be
    // charged at all. It stayed hidden because the credential lookup used to
    // resolve to the PAYER, who typically has no gateway and failed earlier
    // with NO_GATEWAY; once the lookup correctly resolved to the seller
    // (vikuna, saved in the new format) this surfaced immediately.
    const raw = info.credentials;
    const encryptedString =
      raw && typeof raw === 'object' && typeof raw.encrypted === 'string'
        ? raw.encrypted
        : raw;

    if (typeof encryptedString !== 'string') {
      console.error('[PayGateway] Credentials are not decryptable; keys:',
        raw && typeof raw === 'object' ? Object.keys(raw) : typeof raw);
      return {
        success: false,
        error: 'Stored payment credentials are in an unrecognised format. Re-save the gateway in Settings → Integrations.',
      };
    }

    const decrypted = await decryptData(encryptedString, encryptionKey);
    return {
      success: true,
      provider: info.provider,
      credentials: decrypted,
      isLive: info.is_live
    };
  } catch (err) {
    console.error('[PayGateway] Decryption failed:', err);
    return { success: false, error: 'Failed to decrypt gateway credentials' };
  }
}

// A gateway failure is not one kind of thing. Razorpay rejecting the API key
// ("Authentication failed") is a PERMANENT configuration fault that no amount
// of retrying will clear — the seller has to re-save their keys. Returning 502
// for it tells the caller "upstream is having a moment, try again", so the
// tenant retries forever against a wall and nobody is told what to fix.
//
// 502 is kept for what it means: the gateway genuinely could not be reached.
function classifyGatewayError(rawError: string | undefined, sellerName?: string) {
  const msg = (rawError || '').toLowerCase();
  const isAuth =
    msg.includes('authentication failed') ||
    msg.includes('unauthorized') ||
    msg.includes('invalid api key') ||
    msg.includes('key_id');

  if (isAuth) {
    const who = sellerName || 'The seller';
    return {
      status: 400,
      code: 'GATEWAY_AUTH_FAILED',
      // Addressed to the payer, who can do nothing about it themselves, so it
      // says who has been told rather than issuing them an instruction.
      error: `${who} cannot accept payments right now — their payment gateway rejected the request. They have been notified and will be in touch to complete this.`,
      seller_message: 'Razorpay rejected your API keys. Re-save them in Settings → Integrations with the current key_id and key_secret from your Razorpay dashboard, and check the live/test environment matches.',
    };
  }

  return {
    status: 502,
    code: 'GATEWAY_ERROR',
    error: rawError || 'The payment gateway could not be reached. Please try again.',
  };
}

// ─── Settlement Resolution (B5) ───────────────────────────
//
// WHO IS ASKING and WHOSE GATEWAY RUNS are two different questions, and
// conflating them was the bug: every handler below used to pass the
// x-tenant-id header — the PAYER — into getGatewayCredentials.
//
// An invoice is settled by the tenant that OWNS it. When Trinity pays
// vikuna's ₹23,996 subscription invoice, the header says Trinity, Trinity
// has no gateway configured, and the whole checkout died on a bare 400
// ("Could not start payment"). Nothing subscription-specific about it — a
// BBB partner paying BBB failed the same way.
//
// resolve_invoice_settlement (migration 037) answers all of it from the
// invoice row: who is owed, whether the caller is a party to it, and
// whether that payee can actually be paid. The header is still what
// AUTHORISES the call; it no longer decides where the money goes.
interface Settlement {
  ok: boolean;
  status?: number;
  error?: string;
  code?: string;
  settlementTenantId?: string;
  settlementTenantName?: string;
  callerRole?: string;
  canCollect?: boolean;
  online?: boolean;
  offlineUpi?: boolean;
  amountDue?: number;
  currency?: string;
  contractId?: string;
}

async function resolveSettlement(
  supabase: any,
  invoiceId: string,
  callerTenantId: string | null
): Promise<Settlement> {
  const { data, error } = await supabase.rpc('resolve_invoice_settlement', {
    p_invoice_id: invoiceId,
    p_caller_tenant_id: callerTenantId,
  });

  if (error) {
    console.error('[PayGateway] resolve_invoice_settlement error:', error);
    return { ok: false, status: 500, error: 'Could not resolve who settles this invoice', code: 'INTERNAL_ERROR' };
  }

  if (!data?.success) {
    // NOT_A_PARTY is a 403: the invoice exists, this tenant may not touch it.
    const code = data?.error_code || 'SETTLEMENT_ERROR';
    return {
      ok: false,
      status: code === 'NOT_A_PARTY' ? 403 : code === 'NOT_FOUND' ? 404 : 400,
      error: data?.error || 'Could not resolve invoice settlement',
      code,
    };
  }

  return {
    ok: true,
    settlementTenantId: data.settlement_tenant_id,
    settlementTenantName: data.settlement_tenant_name,
    callerRole: data.caller_role,
    canCollect: data.can_collect,
    online: data.online,
    offlineUpi: data.offline_upi,
    amountDue: Number(data.amount_due ?? 0),
    currency: data.currency || 'INR',
    contractId: data.contract_id,
  };
}

// The payee has no ONLINE gateway. This must never surface as a raw failure:
// the buyer did nothing wrong and there is a real path forward, so say who
// will be in touch and let the caller render it as an outcome rather than an
// error. `seller_name` is what makes that sentence nameable in the UI.
function noOnlineGatewayResponse(s: Settlement): Response {
  const seller = s.settlementTenantName || 'The seller';
  return jsonResponse({
    success: false,
    code: s.offlineUpi ? 'OFFLINE_ONLY' : 'NO_GATEWAY',
    error: s.offlineUpi
      ? `${seller} does not take card payments online — pay by UPI, or ${seller} will be in touch to complete this.`
      : `${seller} is not set up to take payment online yet. ${seller} has been notified and will be in touch to complete this.`,
    seller_name: seller,
    settlement_tenant_id: s.settlementTenantId,
    can_collect: s.canCollect,
    online: s.online,
    offline_upi: s.offlineUpi,
  }, 400);
}

// ═══════════════════════════════════════════════════════════
// HANDLER: Create Order (terminal checkout)
// ═══════════════════════════════════════════════════════════

async function handleCreateOrder(
  supabase: any,
  body: any,
  tenantId: string,
  userId: string,
  isLive: boolean,
  encryptionKey: string
): Promise<Response> {
  const { invoice_id, amount, currency, notes } = body;

  if (!invoice_id || !amount) {
    return jsonResponse({ success: false, error: 'invoice_id and amount are required', code: 'VALIDATION_ERROR' }, 400);
  }

  // 0. Who settles this, and may the caller act on it? (B5)
  const settle = await resolveSettlement(supabase, invoice_id, tenantId);
  if (!settle.ok) {
    return jsonResponse({ success: false, error: settle.error, code: settle.code }, settle.status || 400);
  }
  if (!settle.online) {
    return noOnlineGatewayResponse(settle);
  }

  // 1. Get gateway credentials — the SELLER's, resolved from the invoice.
  const gw = await getGatewayCredentials(supabase, settle.settlementTenantId!, encryptionKey, 'razorpay', isLive);
  if (!gw.success) {
    return jsonResponse({ success: false, error: gw.error, code: 'NO_GATEWAY' }, 400);
  }

  // 2. Create order with provider
  let gatewayOrderId: string;
  let gatewayResponse: any;

  if (gw.provider === 'razorpay') {
    // tenant_id here is how the WEBHOOK later identifies whose books the
    // payment belongs to, so it must be the settlement tenant. Sending the
    // payer's id would have filed the receipt against the wrong tenant.
    // payer_tenant_id is kept alongside it for traceability.
    const mergedNotes = {
      ...(notes || {}),
      tenant_id: settle.settlementTenantId,
      payer_tenant_id: tenantId,
      invoice_id,
    };
    const result = await razorpay.createOrder(gw.credentials, {
      amount: Math.round(amount * 100),  // rupees → paise
      currency: currency || 'INR',
      receipt: invoice_id,
      notes: mergedNotes
    });

    if (!result.success) {
      const cls = classifyGatewayError(result.error, settle.settlementTenantName);
      console.error('[PayGateway] create-order gateway failure:', cls.code, result.error);
      return jsonResponse({
        success: false, error: cls.error, code: cls.code,
        seller_name: settle.settlementTenantName,
        seller_message: (cls as any).seller_message,
      }, cls.status);
    }

    gatewayOrderId = result.order!.id;
    gatewayResponse = result.order;
  } else {
    return jsonResponse({ success: false, error: `Provider ${gw.provider} not yet supported`, code: 'UNSUPPORTED_PROVIDER' }, 400);
  }

  // 3. Create payment request record
  // tenant_id = the SELLER. verify_gateway_payment looks the request back up
  // by (id, tenant_id) and then hands that same tenant_id to
  // record_invoice_payment, so storing the payer here would both break the
  // lookup at verify time and try to write the receipt on the wrong books.
  const { data: reqData, error: reqError } = await supabase.rpc('create_payment_request', {
    p_payload: {
      invoice_id,
      tenant_id: settle.settlementTenantId,
      amount,
      currency: currency || 'INR',
      collection_mode: 'terminal',
      gateway_provider: gw.provider,
      gateway_order_id: gatewayOrderId,
      gateway_response: gatewayResponse,
      created_by: userId,
      is_live: isLive
    }
  });

  if (reqError || !reqData?.success) {
    console.error('[PayGateway] create_payment_request failed:', reqError || reqData?.error);
    // Order was created on Razorpay but DB insert failed — log and return order anyway
    return jsonResponse({
      success: true,
      warning: 'Payment request DB record failed, but order was created',
      data: {
        gateway_provider: gw.provider,
        gateway_order_id: gatewayOrderId,
        gateway_key_id: gw.credentials.key_id,  // needed for checkout SDK
        amount,
        currency: currency || 'INR'
      }
    });
  }

  return jsonResponse({
    success: true,
    data: {
      request_id: reqData.data.request_id,
      gateway_provider: gw.provider,
      gateway_order_id: gatewayOrderId,
      gateway_key_id: gw.credentials.key_id,  // needed for checkout SDK
      amount,
      currency: currency || 'INR',
      attempt_number: reqData.data.attempt_number
    }
  });
}

// ═══════════════════════════════════════════════════════════
// HANDLER: Create Payment Link (email/whatsapp)
// ═══════════════════════════════════════════════════════════

async function handleCreateLink(
  supabase: any,
  body: any,
  tenantId: string,
  userId: string,
  isLive: boolean,
  encryptionKey: string
): Promise<Response> {
  const { invoice_id, amount, currency, collection_mode, customer, description, expire_hours, notes, callback_url } = body;

  if (!invoice_id || !amount || !collection_mode) {
    return jsonResponse({ success: false, error: 'invoice_id, amount, and collection_mode are required', code: 'VALIDATION_ERROR' }, 400);
  }

  if (!['email_link', 'whatsapp_link'].includes(collection_mode)) {
    return jsonResponse({ success: false, error: 'collection_mode must be email_link or whatsapp_link', code: 'VALIDATION_ERROR' }, 400);
  }

  // 0. Same settlement resolution as create-order (B5). A payment LINK is
  // sent to the buyer to pay the seller, so the gateway is the seller's here
  // too — this handler had the identical header-based bug.
  const settle = await resolveSettlement(supabase, invoice_id, tenantId);
  if (!settle.ok) {
    return jsonResponse({ success: false, error: settle.error, code: settle.code }, settle.status || 400);
  }
  if (!settle.online) {
    return noOnlineGatewayResponse(settle);
  }

  // 1. Get gateway credentials — the SELLER's, resolved from the invoice.
  const gw = await getGatewayCredentials(supabase, settle.settlementTenantId!, encryptionKey, 'razorpay', isLive);
  if (!gw.success) {
    return jsonResponse({ success: false, error: gw.error, code: 'NO_GATEWAY' }, 400);
  }

  // 2. Create payment link with provider
  let gatewayLinkId: string;
  let gatewayShortUrl: string;
  let gatewayResponse: any;
  let expiresAt: string | null = null;

  if (gw.provider === 'razorpay') {
    const expireBy = expire_hours
      ? Math.floor(Date.now() / 1000) + (expire_hours * 3600)
      : Math.floor(Date.now() / 1000) + (72 * 3600);  // default 72 hours

    // Settlement tenant, for the same webhook-identification reason as
    // create-order above.
    const mergedNotes = {
      ...(notes || {}),
      tenant_id: settle.settlementTenantId,
      payer_tenant_id: tenantId,
      invoice_id,
    };
    const result = await razorpay.createPaymentLink(gw.credentials, {
      amount: Math.round(amount * 100),
      currency: currency || 'INR',
      description: description || 'Invoice Payment',
      customer: customer || {},
      notify: { sms: false, email: false },  // we send via JTD
      reminder_enable: false,
      callback_url: callback_url || undefined,
      callback_method: callback_url ? 'get' : undefined,
      expire_by: expireBy,
      notes: mergedNotes
    });

    if (!result.success) {
      {
        const cls = classifyGatewayError(result.error, settle.settlementTenantName);
        console.error('[PayGateway] create-link gateway failure:', cls.code, result.error);
        return jsonResponse({
          success: false, error: cls.error, code: cls.code,
          seller_name: settle.settlementTenantName,
          seller_message: (cls as any).seller_message,
        }, cls.status);
      }
    }

    gatewayLinkId = result.link!.id;
    gatewayShortUrl = result.link!.short_url;
    gatewayResponse = result.link;
    expiresAt = new Date(expireBy * 1000).toISOString();
  } else {
    return jsonResponse({ success: false, error: `Provider ${gw.provider} not yet supported`, code: 'UNSUPPORTED_PROVIDER' }, 400);
  }

  // 3. Create payment request record
  const { data: reqData, error: reqError } = await supabase.rpc('create_payment_request', {
    p_payload: {
      invoice_id,
      tenant_id: settle.settlementTenantId,
      amount,
      currency: currency || 'INR',
      collection_mode,
      gateway_provider: gw.provider,
      gateway_link_id: gatewayLinkId,
      gateway_short_url: gatewayShortUrl,
      gateway_response: gatewayResponse,
      expires_at: expiresAt,
      created_by: userId,
      is_live: isLive
    }
  });

  if (reqError || !reqData?.success) {
    console.error('[PayGateway] create_payment_request failed:', reqError || reqData?.error);
  }

  // 4. Send notification via JTD (fire-and-forget — don't block response)
  const requestId = reqData?.data?.request_id;
  if (requestId && (customer?.email || customer?.contact)) {
    sendPaymentRequestNotification(supabase, {
      // The seller sends the payment request, and it is the seller's
      // notification credits that are consumed — so this is the settlement
      // tenant, not whoever happened to click.
      tenantId: settle.settlementTenantId!,
      requestId,
      invoiceId: invoice_id,
      customerName: customer?.name,
      customerEmail: customer?.email,
      customerPhone: customer?.contact,
      amount: amount.toString(),
      currency: currency || 'INR',
      paymentLink: gatewayShortUrl,
      collectionMode: collection_mode as 'email_link' | 'whatsapp_link',
      expireHours: expire_hours || 72,
      isLive,
    }).then(r => {
      console.log(`[PayGateway] JTD notification result: ${r.success ? 'sent' : r.skipped ? 'skipped' : 'failed'}${r.jtdId ? ` (jtd:${r.jtdId})` : ''}${r.error ? ` — ${r.error}` : ''}`);
    }).catch(err => {
      console.error('[PayGateway] JTD notification error:', err);
    });
  }

  return jsonResponse({
    success: true,
    data: {
      request_id: requestId || null,
      gateway_provider: gw.provider,
      gateway_link_id: gatewayLinkId,
      gateway_short_url: gatewayShortUrl,
      amount,
      currency: currency || 'INR',
      collection_mode,
      expires_at: expiresAt,
      attempt_number: reqData?.data?.attempt_number || null
    }
  });
}

// ═══════════════════════════════════════════════════════════
// HANDLER: Verify Payment (after checkout callback)
// ═══════════════════════════════════════════════════════════

async function handleVerifyPayment(
  supabase: any,
  body: any,
  tenantId: string,
  encryptionKey: string
): Promise<Response> {
  const { request_id, gateway_order_id, gateway_payment_id, gateway_signature } = body;

  if (!request_id || !gateway_payment_id) {
    return jsonResponse({ success: false, error: 'request_id and gateway_payment_id are required', code: 'VALIDATION_ERROR' }, 400);
  }

  // 0. The settlement tenant comes from the payment request itself — the row
  // create-order already stamped with the seller. Two reasons it cannot come
  // from the header:
  //   · the key_secret used to verify the signature must be the SAME
  //     credentials the order was created with, i.e. the seller's;
  //   · verify_gateway_payment fetches the request by (id, tenant_id) and
  //     passes that tenant_id to record_invoice_payment, so a payer's id
  //     would fail the lookup outright and, if it didn't, would write the
  //     receipt on the wrong tenant's books.
  const { data: reqRow, error: reqLookupErr } = await supabase
    .from('t_contract_payment_requests')
    .select('id, tenant_id, invoice_id')
    .eq('id', request_id)
    .maybeSingle();

  if (reqLookupErr) {
    console.error('[PayGateway] payment request lookup failed:', reqLookupErr);
    return jsonResponse({ success: false, error: 'Could not load payment request', code: 'INTERNAL_ERROR' }, 500);
  }
  if (!reqRow) {
    return jsonResponse({ success: false, error: 'Payment request not found', code: 'NOT_FOUND' }, 404);
  }

  // The caller must still be a party to the invoice — the request row tells
  // us WHOSE money it is, not that this caller may confirm it.
  const settle = await resolveSettlement(supabase, reqRow.invoice_id, tenantId);
  if (!settle.ok) {
    return jsonResponse({ success: false, error: settle.error, code: settle.code }, settle.status || 400);
  }

  const settlementTenantId = reqRow.tenant_id;

  // 1. Get gateway credentials (need key_secret for signature verification)
  const gw = await getGatewayCredentials(supabase, settlementTenantId, encryptionKey, 'razorpay', isLive);
  if (!gw.success) {
    return jsonResponse({ success: false, error: gw.error, code: 'NO_GATEWAY' }, 400);
  }

  // 2. Verify signature with provider
  if (gw.provider === 'razorpay') {
    if (!gateway_order_id || !gateway_signature) {
      return jsonResponse({ success: false, error: 'gateway_order_id and gateway_signature required for Razorpay', code: 'VALIDATION_ERROR' }, 400);
    }

    const isValid = await razorpay.verifyPaymentSignature(
      gateway_order_id,
      gateway_payment_id,
      gateway_signature,
      gw.credentials.key_secret
    );

    if (!isValid) {
      console.error('[PayGateway] Invalid Razorpay signature');
      return jsonResponse({ success: false, error: 'Invalid payment signature', code: 'INVALID_SIGNATURE' }, 400);
    }

    console.log(`[PayGateway] Razorpay signature verified for payment ${gateway_payment_id}`);
  }

  // 3. Record payment via RPC
  const { data, error } = await supabase.rpc('verify_gateway_payment', {
    p_payload: {
      request_id,
      tenant_id: settlementTenantId,
      gateway_payment_id,
      gateway_provider: gw.provider
    }
  });

  if (error) {
    console.error('[PayGateway] verify_gateway_payment RPC error:', error);
    return jsonResponse({ success: false, error: 'Failed to record payment', code: 'INTERNAL_ERROR' }, 500);
  }

  if (!data?.success) {
    return jsonResponse({ success: false, error: data?.error || 'Payment verification failed', code: 'VERIFICATION_FAILED' }, 400);
  }

  return jsonResponse({
    success: true,
    data: data.data
  });
}

// ═══════════════════════════════════════════════════════════
// HANDLER: Payment Status
// ═══════════════════════════════════════════════════════════

async function handlePaymentStatus(
  supabase: any,
  body: any,
  tenantId: string
): Promise<Response> {
  const { invoice_id, contract_id } = body;

  // Payment requests are stored under the SELLER, so a buyer asking about an
  // invoice they are paying would otherwise get an empty list. Resolve the
  // owner when we have an invoice to resolve it from; the resolver refuses
  // any caller who is not a party, so this widens visibility to the two
  // parties without widening it to everyone.
  let scopeTenantId = tenantId;
  if (invoice_id) {
    const settle = await resolveSettlement(supabase, invoice_id, tenantId);
    if (!settle.ok) {
      return jsonResponse({ success: false, error: settle.error, code: settle.code }, settle.status || 400);
    }
    scopeTenantId = settle.settlementTenantId!;
  }

  const { data, error } = await supabase.rpc('get_payment_requests', {
    p_payload: {
      invoice_id: invoice_id || null,
      contract_id: contract_id || null,
      tenant_id: scopeTenantId
    }
  });

  if (error) {
    console.error('[PayGateway] get_payment_requests error:', error);
    return jsonResponse({ success: false, error: 'Failed to fetch payment requests', code: 'INTERNAL_ERROR' }, 500);
  }

  return jsonResponse(data);
}

// ═══════════════════════════════════════════════════════════
// MAIN SERVE
// ═══════════════════════════════════════════════════════════

serve(async (req: Request) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // ── Environment ───────────────────────────────────────
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSigningSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');
    const encryptionKey = Deno.env.get('INTEGRATION_ENCRYPTION_KEY') || 'default-encryption-key-change-in-prod';

    if (!supabaseUrl || !supabaseServiceKey) {
      throw new Error('Missing required environment variables');
    }

    // ── Headers ───────────────────────────────────────────
    const tenantId = req.headers.get('x-tenant-id');
    const userId = req.headers.get('x-user-id') || '';
    const environment = req.headers.get('x-environment') || 'live';
    const isLive = environment.toLowerCase() !== 'test';

    if (!tenantId) {
      return jsonResponse({ success: false, error: 'x-tenant-id header is required', code: 'MISSING_TENANT_ID' }, 400);
    }

    // ── HMAC Signature ────────────────────────────────────
    const signature = req.headers.get('x-internal-signature');
    let requestBody = '';

    if (internalSigningSecret) {
      if (!signature) {
        return jsonResponse({ success: false, error: 'Missing internal signature', code: 'MISSING_SIGNATURE' }, 401);
      }

      requestBody = req.method !== 'GET' ? await req.text() : '';
      const isValid = await verifyInternalSignature(requestBody, signature, internalSigningSecret);

      if (!isValid) {
        return jsonResponse({ success: false, error: 'Invalid internal signature', code: 'INVALID_SIGNATURE' }, 403);
      }
    } else {
      requestBody = req.method !== 'GET' ? await req.text() : '';
    }

    // ── Supabase Client ───────────────────────────────────
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // ── Route ─────────────────────────────────────────────
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(s => s);
    const lastSegment = pathSegments[pathSegments.length - 1];
    const body = requestBody ? JSON.parse(requestBody) : {};

    if (req.method === 'POST') {
      switch (lastSegment) {
        case 'create-order':
          return await handleCreateOrder(supabase, body, tenantId, userId, isLive, encryptionKey);

        case 'create-link':
          return await handleCreateLink(supabase, body, tenantId, userId, isLive, encryptionKey);

        case 'verify-payment':
          return await handleVerifyPayment(supabase, body, tenantId, encryptionKey);

        case 'payment-status':
          return await handlePaymentStatus(supabase, body, tenantId);

        default:
          return jsonResponse({ success: false, error: 'Unknown endpoint', code: 'NOT_FOUND' }, 404);
      }
    }

    return jsonResponse({ success: false, error: 'Method not allowed', code: 'METHOD_NOT_ALLOWED' }, 405);

  } catch (error) {
    console.error('[PayGateway] Error:', error);
    return jsonResponse({
      success: false,
      error: error instanceof Error ? error.message : 'Internal server error',
      code: 'INTERNAL_ERROR'
    }, 500);
  }
});
