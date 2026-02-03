// supabase/functions/payment-gateway/jtd-integration.ts
// JTD Integration for Payment Request Notifications
// Creates JTD entries for email/WhatsApp delivery of payment links.
// Pattern follows: contracts/jtd-integration.ts

type SupabaseClient = any;

// ─── Interfaces ───────────────────────────────────────────────

interface PaymentRequestJTDParams {
  tenantId: string;
  requestId: string;
  invoiceId: string;
  // Recipient (buyer)
  customerName: string;
  customerEmail?: string;
  customerPhone?: string;
  customerCountryCode?: string;
  // Tenant
  tenantName: string;
  // Payment details
  invoiceNumber: string;
  amount: string;         // Pre-formatted (e.g. "5000.00")
  currency: string;
  paymentLink: string;    // Razorpay short URL
  expireHours: number;
  // Collection channel — determines which notification channel to use
  collectionMode: 'email_link' | 'whatsapp_link';
  // Config
  isLive?: boolean;
}

interface JTDResult {
  success: boolean;
  jtdId?: string;
  error?: string;
  skipped?: boolean;
}

// ─── Channel check ────────────────────────────────────────────

async function isChannelEnabled(
  supabase: SupabaseClient,
  tenantId: string,
  channel: 'email' | 'whatsapp'
): Promise<boolean> {
  try {
    const { data: config, error } = await supabase
      .from('n_jtd_tenant_config')
      .select('channels_enabled, is_active')
      .eq('tenant_id', tenantId)
      .single();

    if (error || !config) {
      return true; // Default to enabled if no config
    }

    if (!config.is_active) return false;

    const channelsEnabled: Record<string, boolean> = config.channels_enabled || {};
    return channelsEnabled[channel] === true;
  } catch {
    return true;
  }
}

// ─── Resolve tenant name ──────────────────────────────────────

async function getTenantName(
  supabase: SupabaseClient,
  tenantId: string
): Promise<string> {
  try {
    const { data, error } = await supabase
      .from('t_tenants')
      .select('name')
      .eq('id', tenantId)
      .single();

    if (error || !data) return 'Your Service Provider';
    return data.name || 'Your Service Provider';
  } catch {
    return 'Your Service Provider';
  }
}

// ─── Resolve invoice number ───────────────────────────────────

async function getInvoiceNumber(
  supabase: SupabaseClient,
  invoiceId: string
): Promise<string> {
  try {
    const { data, error } = await supabase
      .from('t_contract_invoices')
      .select('invoice_number')
      .eq('id', invoiceId)
      .single();

    if (error || !data) return invoiceId;
    return data.invoice_number || invoiceId;
  } catch {
    return invoiceId;
  }
}

// ─── Create single JTD entry ──────────────────────────────────

async function createPaymentRequestJTD(
  supabase: SupabaseClient,
  params: PaymentRequestJTDParams,
  channel: 'email' | 'whatsapp'
): Promise<JTDResult> {
  try {
    const recipientContact = channel === 'email'
      ? params.customerEmail || ''
      : params.customerPhone || '';

    // Template variables — same 7 variables for both email and WhatsApp
    const templateData: Record<string, string> = {
      customer_name: params.customerName,
      tenant_name: params.tenantName,
      invoice_number: params.invoiceNumber,
      amount: params.amount,
      currency: params.currency,
      payment_link: params.paymentLink,
      expire_hours: params.expireHours.toString(),
    };

    const payload = {
      recipient_data: {
        email: params.customerEmail,
        mobile: params.customerPhone,
        country_code: params.customerCountryCode || '91',
        name: params.customerName,
      },
      template_data: templateData,
    };

    const { data: jtd, error } = await supabase
      .from('n_jtd')
      .insert({
        tenant_id: params.tenantId,
        event_type_code: 'notification',
        channel_code: channel,
        source_type_code: 'payment_request',
        source_id: params.requestId,
        status_code: 'created',
        priority: 3, // Higher priority than signoff (5) — payment links are time-sensitive
        recipient_name: params.customerName,
        recipient_contact: recipientContact,
        payload,
        template_key: `payment_request_${channel}`,
        template_variables: templateData,
        metadata: {
          request_id: params.requestId,
          invoice_id: params.invoiceId,
          invoice_number: params.invoiceNumber,
          payment_link: params.paymentLink,
          collection_mode: params.collectionMode,
          expire_hours: params.expireHours,
        },
        is_live: params.isLive ?? false,
        performed_by_type: 'system',
        performed_by_id: '00000000-0000-0000-0000-000000000001',
        performed_by_name: 'VaNi',
        created_by: '00000000-0000-0000-0000-000000000001',
        updated_by: '00000000-0000-0000-0000-000000000001',
      })
      .select('id')
      .single();

    if (error) {
      console.error(`[PaymentJTD] Error creating ${channel} JTD:`, error);
      return { success: false, error: error.message };
    }

    console.log(`[PaymentJTD] Created ${channel} JTD ${jtd.id} for request ${params.requestId}`);
    return { success: true, jtdId: jtd.id };

  } catch (error) {
    console.error(`[PaymentJTD] Error:`, error);
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error',
    };
  }
}

// ─── Send payment request notification ────────────────────────

/**
 * Send payment link notification via the appropriate channel.
 *
 * Channel is determined by collection_mode:
 * - email_link → send email notification
 * - whatsapp_link → send WhatsApp notification
 *
 * The notification is only created if:
 * - The appropriate contact info is provided (email for email_link, phone for whatsapp_link)
 * - The channel is enabled in tenant's JTD config
 */
export async function sendPaymentRequestNotification(
  supabase: SupabaseClient,
  params: {
    tenantId: string;
    requestId: string;
    invoiceId: string;
    customerName?: string;
    customerEmail?: string;
    customerPhone?: string;
    customerCountryCode?: string;
    amount: string;
    currency: string;
    paymentLink: string;
    collectionMode: 'email_link' | 'whatsapp_link';
    expireHours?: number;
    isLive?: boolean;
  }
): Promise<{ success: boolean; jtdId?: string; skipped?: boolean; error?: string }> {

  console.log(`[PaymentJTD] Sending ${params.collectionMode} notification for request ${params.requestId}`);

  // Resolve tenant name + invoice number from DB
  const [tenantName, invoiceNumber] = await Promise.all([
    getTenantName(supabase, params.tenantId),
    getInvoiceNumber(supabase, params.invoiceId),
  ]);

  // Map collection_mode → JTD channel
  const channel: 'email' | 'whatsapp' = params.collectionMode === 'email_link' ? 'email' : 'whatsapp';

  // Validate contact info for the channel
  if (channel === 'email' && !params.customerEmail) {
    console.warn('[PaymentJTD] No email provided for email_link notification');
    return { success: false, skipped: true, error: 'No email address provided' };
  }
  if (channel === 'whatsapp' && !params.customerPhone) {
    console.warn('[PaymentJTD] No phone provided for whatsapp_link notification');
    return { success: false, skipped: true, error: 'No phone number provided' };
  }

  // Check if channel is enabled for tenant
  const channelEnabled = await isChannelEnabled(supabase, params.tenantId, channel);
  if (!channelEnabled) {
    console.log(`[PaymentJTD] Channel ${channel} disabled for tenant ${params.tenantId}`);
    return { success: true, skipped: true, error: `Channel ${channel} is disabled` };
  }

  // Create JTD entry
  const jtdParams: PaymentRequestJTDParams = {
    tenantId: params.tenantId,
    requestId: params.requestId,
    invoiceId: params.invoiceId,
    customerName: params.customerName || 'Customer',
    customerEmail: params.customerEmail,
    customerPhone: params.customerPhone,
    customerCountryCode: params.customerCountryCode,
    tenantName,
    invoiceNumber,
    amount: params.amount,
    currency: params.currency,
    paymentLink: params.paymentLink,
    expireHours: params.expireHours || 72,
    collectionMode: params.collectionMode,
    isLive: params.isLive,
  };

  const result = await createPaymentRequestJTD(supabase, jtdParams, channel);
  return result;
}
