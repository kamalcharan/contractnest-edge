// supabase/functions/payment-webhook/providers/razorpay.ts
// Razorpay webhook signature verification and event extraction

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
    console.error('[Razorpay Webhook] Signature verification error:', error);
    return false;
  }
}

// ─── Extract Gateway-Agnostic Event Data ──────────────────

export function extractEventData(payload: any): {
  eventId: string;
  eventType: string;
  paymentId: string | null;
  orderId: string | null;
  linkId: string | null;
  amount: number | null;
  currency: string | null;
} {
  // Razorpay webhook structure:
  // { event: "payment.captured", payload: { payment: { entity: { ... } } } }
  const entity = payload?.payload?.payment?.entity
    || payload?.payload?.payment_link?.entity
    || payload?.payload?.order?.entity
    || {};

  const eventType = payload?.event || '';

  // For payment_link events, the payment entity is nested differently
  let paymentId = entity.id || null;
  let orderId = entity.order_id || null;
  let linkId: string | null = null;

  // payment_link.paid has payment_link entity
  if (eventType === 'payment_link.paid') {
    const plEntity = payload?.payload?.payment_link?.entity || {};
    linkId = plEntity.id || null;
    // Payment details inside payment_link.paid
    const paymentEntity = payload?.payload?.payment?.entity || {};
    paymentId = paymentEntity.id || paymentId;
    orderId = paymentEntity.order_id || orderId;
  }

  return {
    eventId: payload?.event_id || payload?.id || `${eventType}_${Date.now()}`,
    eventType,
    paymentId,
    orderId,
    linkId,
    amount: entity.amount ? entity.amount / 100 : null,  // paise → rupees
    currency: entity.currency || null
  };
}

// ─── Extract Tenant ID from Notes ─────────────────────────
// When creating orders/links, payment-gateway injects tenant_id + invoice_id
// into Razorpay's `notes` object. This lets the webhook identify the tenant
// from a single shared webhook URL (no tenant_id in URL path needed).

export function extractTenantId(payload: any): string | null {
  // payment.captured / payment.failed → payload.payment.entity.notes
  const paymentNotes = payload?.payload?.payment?.entity?.notes;
  if (paymentNotes?.tenant_id) return paymentNotes.tenant_id;

  // payment_link.paid → payload.payment_link.entity.notes
  const linkNotes = payload?.payload?.payment_link?.entity?.notes;
  if (linkNotes?.tenant_id) return linkNotes.tenant_id;

  // order.paid → payload.order.entity.notes
  const orderNotes = payload?.payload?.order?.entity?.notes;
  if (orderNotes?.tenant_id) return orderNotes.tenant_id;

  return null;
}

// ─── Relevant Event Types ─────────────────────────────────

export const PAYMENT_SUCCESS_EVENTS = [
  'payment.captured',
  'payment_link.paid',
  'order.paid'
];

export const PAYMENT_FAILURE_EVENTS = [
  'payment.failed'
];

export function isPaymentEvent(eventType: string): boolean {
  return PAYMENT_SUCCESS_EVENTS.includes(eventType)
    || PAYMENT_FAILURE_EVENTS.includes(eventType);
}
