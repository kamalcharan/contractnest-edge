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
  provider?: string
): Promise<{ success: boolean; provider?: string; credentials?: any; isLive?: boolean; error?: string }> {
  const { data, error } = await supabase.rpc('get_tenant_gateway_credentials', {
    p_tenant_id: tenantId,
    p_provider: provider || null
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
    const decrypted = await decryptData(info.credentials, encryptionKey);
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

  // 1. Get gateway credentials
  const gw = await getGatewayCredentials(supabase, tenantId, encryptionKey);
  if (!gw.success) {
    return jsonResponse({ success: false, error: gw.error, code: 'NO_GATEWAY' }, 400);
  }

  // 2. Create order with provider
  let gatewayOrderId: string;
  let gatewayResponse: any;

  if (gw.provider === 'razorpay') {
    // Inject tenant_id + invoice_id into Razorpay notes for webhook tenant identification
    const mergedNotes = { ...(notes || {}), tenant_id: tenantId, invoice_id };
    const result = await razorpay.createOrder(gw.credentials, {
      amount: Math.round(amount * 100),  // rupees → paise
      currency: currency || 'INR',
      receipt: invoice_id,
      notes: mergedNotes
    });

    if (!result.success) {
      return jsonResponse({ success: false, error: result.error, code: 'GATEWAY_ERROR' }, 502);
    }

    gatewayOrderId = result.order!.id;
    gatewayResponse = result.order;
  } else {
    return jsonResponse({ success: false, error: `Provider ${gw.provider} not yet supported`, code: 'UNSUPPORTED_PROVIDER' }, 400);
  }

  // 3. Create payment request record
  const { data: reqData, error: reqError } = await supabase.rpc('create_payment_request', {
    p_payload: {
      invoice_id,
      tenant_id: tenantId,
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

  // 1. Get gateway credentials
  const gw = await getGatewayCredentials(supabase, tenantId, encryptionKey);
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

    // Inject tenant_id + invoice_id into Razorpay notes for webhook tenant identification
    const mergedNotes = { ...(notes || {}), tenant_id: tenantId, invoice_id };
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
      return jsonResponse({ success: false, error: result.error, code: 'GATEWAY_ERROR' }, 502);
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
      tenant_id: tenantId,
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
      tenantId,
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

  // 1. Get gateway credentials (need key_secret for signature verification)
  const gw = await getGatewayCredentials(supabase, tenantId, encryptionKey);
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
      tenant_id: tenantId,
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

  const { data, error } = await supabase.rpc('get_payment_requests', {
    p_payload: {
      invoice_id: invoice_id || null,
      contract_id: contract_id || null,
      tenant_id: tenantId
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
