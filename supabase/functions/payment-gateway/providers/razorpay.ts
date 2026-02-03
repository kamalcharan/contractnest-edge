// supabase/functions/payment-gateway/providers/razorpay.ts
// Razorpay-specific API operations
// Docs: https://razorpay.com/docs/api

interface RazorpayCredentials {
  key_id: string;
  key_secret: string;
  test_mode?: boolean;
}

interface CreateOrderParams {
  amount: number;        // in smallest currency unit (paise for INR)
  currency: string;
  receipt: string;       // invoice number or reference
  notes?: Record<string, string>;
}

interface CreatePaymentLinkParams {
  amount: number;        // in smallest currency unit (paise)
  currency: string;
  description: string;
  customer: {
    name?: string;
    email?: string;
    contact?: string;
  };
  notify?: {
    sms?: boolean;
    email?: boolean;
  };
  reminder_enable?: boolean;
  callback_url?: string;
  callback_method?: string;
  expire_by?: number;    // Unix timestamp
  notes?: Record<string, string>;
}

interface RazorpayOrder {
  id: string;            // order_XXXXX
  amount: number;
  currency: string;
  receipt: string;
  status: string;        // 'created' | 'attempted' | 'paid'
}

interface RazorpayPaymentLink {
  id: string;            // plink_XXXXX
  amount: number;
  currency: string;
  short_url: string;
  status: string;
  expire_by?: number;
}

// ─── Helpers ──────────────────────────────────────────────

function getAuthHeader(credentials: RazorpayCredentials): string {
  return 'Basic ' + btoa(`${credentials.key_id}:${credentials.key_secret}`);
}

function getBaseUrl(): string {
  return 'https://api.razorpay.com/v1';
}

// ─── Create Order ─────────────────────────────────────────

export async function createOrder(
  credentials: RazorpayCredentials,
  params: CreateOrderParams
): Promise<{ success: boolean; order?: RazorpayOrder; error?: string }> {
  try {
    const response = await fetch(`${getBaseUrl()}/orders`, {
      method: 'POST',
      headers: {
        'Authorization': getAuthHeader(credentials),
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        amount: params.amount,
        currency: params.currency,
        receipt: params.receipt,
        notes: params.notes || {}
      })
    });

    const data = await response.json();

    if (!response.ok) {
      console.error('[Razorpay] Create order failed:', JSON.stringify(data));
      return {
        success: false,
        error: data.error?.description || `Razorpay API error: ${response.status}`
      };
    }

    console.log(`[Razorpay] Order created: ${data.id}`);
    return { success: true, order: data };

  } catch (error) {
    console.error('[Razorpay] Create order exception:', error);
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error creating order'
    };
  }
}

// ─── Create Payment Link ──────────────────────────────────

export async function createPaymentLink(
  credentials: RazorpayCredentials,
  params: CreatePaymentLinkParams
): Promise<{ success: boolean; link?: RazorpayPaymentLink; error?: string }> {
  try {
    const response = await fetch(`${getBaseUrl()}/payment_links`, {
      method: 'POST',
      headers: {
        'Authorization': getAuthHeader(credentials),
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        amount: params.amount,
        currency: params.currency,
        description: params.description,
        customer: params.customer,
        notify: params.notify || { sms: false, email: false }, // we handle via JTD
        reminder_enable: params.reminder_enable ?? false,
        callback_url: params.callback_url,
        callback_method: params.callback_method,
        expire_by: params.expire_by,
        notes: params.notes || {}
      })
    });

    const data = await response.json();

    if (!response.ok) {
      console.error('[Razorpay] Create payment link failed:', JSON.stringify(data));
      return {
        success: false,
        error: data.error?.description || `Razorpay API error: ${response.status}`
      };
    }

    console.log(`[Razorpay] Payment link created: ${data.id}, URL: ${data.short_url}`);
    return { success: true, link: data };

  } catch (error) {
    console.error('[Razorpay] Create payment link exception:', error);
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error creating payment link'
    };
  }
}

// ─── Fetch Payment ────────────────────────────────────────

export async function fetchPayment(
  credentials: RazorpayCredentials,
  paymentId: string
): Promise<{ success: boolean; payment?: any; error?: string }> {
  try {
    const response = await fetch(`${getBaseUrl()}/payments/${paymentId}`, {
      method: 'GET',
      headers: {
        'Authorization': getAuthHeader(credentials)
      }
    });

    const data = await response.json();

    if (!response.ok) {
      return {
        success: false,
        error: data.error?.description || `Razorpay API error: ${response.status}`
      };
    }

    return { success: true, payment: data };

  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error fetching payment'
    };
  }
}

// ─── Verify Payment Signature ─────────────────────────────
// Used after Razorpay Standard Checkout callback

export async function verifyPaymentSignature(
  orderId: string,
  paymentId: string,
  signature: string,
  keySecret: string
): Promise<boolean> {
  try {
    const message = `${orderId}|${paymentId}`;
    const encoder = new TextEncoder();

    const key = await crypto.subtle.importKey(
      'raw',
      encoder.encode(keySecret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );

    const signatureBytes = await crypto.subtle.sign(
      'HMAC',
      key,
      encoder.encode(message)
    );

    const expectedSignature = Array.from(new Uint8Array(signatureBytes))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    return expectedSignature === signature;

  } catch (error) {
    console.error('[Razorpay] Signature verification error:', error);
    return false;
  }
}

// ─── Verify Webhook Signature ─────────────────────────────

export async function verifyWebhookSignature(
  body: string,
  signature: string,
  webhookSecret: string
): Promise<boolean> {
  try {
    const encoder = new TextEncoder();

    const key = await crypto.subtle.importKey(
      'raw',
      encoder.encode(webhookSecret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );

    const signatureBytes = await crypto.subtle.sign(
      'HMAC',
      key,
      encoder.encode(body)
    );

    const expectedSignature = Array.from(new Uint8Array(signatureBytes))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    return expectedSignature === signature;

  } catch (error) {
    console.error('[Razorpay] Webhook signature verification error:', error);
    return false;
  }
}

// ─── Extract Event Data ───────────────────────────────────
// Normalizes Razorpay webhook payload to gateway-agnostic format

export function extractEventData(webhookPayload: any): {
  eventId: string;
  eventType: string;
  paymentId: string | null;
  orderId: string | null;
  amount: number | null;
  currency: string | null;
  status: string | null;
} {
  const entity = webhookPayload?.payload?.payment?.entity || {};

  return {
    eventId: webhookPayload?.event_id || webhookPayload?.id || '',
    eventType: webhookPayload?.event || '',
    paymentId: entity.id || null,
    orderId: entity.order_id || null,
    amount: entity.amount ? entity.amount / 100 : null,  // paise → rupees
    currency: entity.currency || null,
    status: entity.status || null
  };
}
