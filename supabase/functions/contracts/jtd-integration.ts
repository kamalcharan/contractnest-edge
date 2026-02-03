// supabase/functions/contracts/jtd-integration.ts
// JTD Integration for Contract Sign-off Notifications
// Creates JTD entries for email/WhatsApp delivery via JTD worker
// Pattern follows: user-invitations/jtd-integration.ts

// NOTE: We use `any` for supabase client type to avoid importing
// a second version of @supabase/supabase-js. The client instance
// is created and passed in from index.ts (which uses @2.7.1).
type SupabaseClient = any;

// ─── Interfaces ───────────────────────────────────────────────

interface ContractSignoffJTDParams {
  tenantId: string;
  contractId: string;
  // Recipient (buyer)
  recipientName: string;
  recipientEmail?: string;
  recipientMobile?: string;
  recipientCountryCode?: string;
  // Sender (tenant)
  senderName: string;
  // Contract details
  contractTitle: string;
  contractNumber: string;
  contractValue: string; // Pre-formatted with currency symbol
  // Access
  cnak: string;
  secretCode: string;
  reviewLink: string;
  // Config
  isLive?: boolean;
}

interface JTDResult {
  success: boolean;
  jtdId?: string;
  error?: string;
  skipped?: boolean;
}

interface MultiChannelResult {
  success: boolean;
  channels: {
    channel: string;
    success: boolean;
    jtdId?: string;
    skipped?: boolean;
    error?: string;
  }[];
  anySuccess: boolean;
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
      // No config found — default to enabled
      return true;
    }

    if (!config.is_active) return false;

    const channelsEnabled: Record<string, boolean> = config.channels_enabled || {};
    return channelsEnabled[channel] === true;
  } catch {
    return true; // Default to enabled on error
  }
}

// ─── Create single JTD entry ──────────────────────────────────

async function createContractSignoffJTD(
  supabase: SupabaseClient,
  params: ContractSignoffJTDParams,
  channel: 'email' | 'whatsapp'
): Promise<JTDResult> {
  try {
    const recipientContact = channel === 'email'
      ? params.recipientEmail || ''
      : params.recipientMobile || '';

    // Build template data per channel:
    // - Email: named variables ({{recipient_name}}, {{sender_name}}, etc.)
    // - WhatsApp: 4 positional variables (MSG91 limits; combined contract_info)
    let templateData: Record<string, string>;

    if (channel === 'email') {
      templateData = {
        recipient_name: params.recipientName,
        sender_name: params.senderName,
        contract_title: params.contractTitle,
        contract_number: params.contractNumber,
        contract_value: params.contractValue,
        review_link: params.reviewLink,
        cnak: params.cnak
      };
    } else {
      // WhatsApp template: 3 body vars + CTA button URL suffix
      // Body: {{1}}=recipient_name, {{2}}=sender_name, {{3}}=contract_info
      // Button "Review Contract": base URL + {{1}} suffix
      // e.g. template URL = https://app.contractnest.in/review/{{1}}
      //      suffix = contractId?cnak=CNAK_VALUE
      const reviewSuffix = params.reviewLink.replace(/^.*\/review\//, '');
      templateData = {
        recipient_name: params.recipientName,
        sender_name: params.senderName,
        contract_info: `${params.contractTitle} (${params.contractNumber}) - ${params.contractValue}`,
        review_link_suffix: reviewSuffix
      };
    }

    const payload = {
      recipient_data: {
        email: params.recipientEmail,
        mobile: params.recipientMobile,
        country_code: params.recipientCountryCode,
        name: params.recipientName
      },
      template_data: templateData
    };

    const { data: jtd, error } = await supabase
      .from('n_jtd')
      .insert({
        tenant_id: params.tenantId,
        event_type_code: 'notification',
        channel_code: channel,
        source_type_code: 'contract_signoff',
        source_id: params.contractId,
        status_code: 'created',
        priority: 5,
        recipient_name: params.recipientName,
        recipient_contact: recipientContact,
        payload,
        template_key: `contract_signoff_${channel}`,
        template_variables: templateData,
        metadata: {
          contract_id: params.contractId,
          contract_number: params.contractNumber,
          cnak: params.cnak,
          review_link: params.reviewLink
        },
        is_live: params.isLive ?? false,
        performed_by_type: 'system',
        performed_by_id: '00000000-0000-0000-0000-000000000001',
        performed_by_name: 'VaNi',
        created_by: '00000000-0000-0000-0000-000000000001',
        updated_by: '00000000-0000-0000-0000-000000000001'
      })
      .select('id')
      .single();

    if (error) {
      console.error(`[Contract JTD] Error creating ${channel} JTD:`, error);
      return { success: false, error: error.message };
    }

    console.log(`[Contract JTD] Created ${channel} JTD ${jtd.id} for contract ${params.contractId}`);
    return { success: true, jtdId: jtd.id };

  } catch (error) {
    console.error(`[Contract JTD] Error:`, error);
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    };
  }
}

// ─── Multi-channel send ───────────────────────────────────────

/**
 * Send contract sign-off notification via email and/or WhatsApp.
 * Channel selection is automatic based on available buyer contact info.
 *
 * - If buyer email provided → create email JTD
 * - If buyer phone provided → create WhatsApp JTD
 * - If both → create JTDs for all enabled channels
 */
export async function sendContractSignoffNotification(
  supabase: SupabaseClient,
  params: ContractSignoffJTDParams
): Promise<MultiChannelResult> {
  const results: MultiChannelResult['channels'] = [];

  console.log(`[Contract JTD] Starting multi-channel for contract ${params.contractId}`);
  console.log(`[Contract JTD] Email: ${params.recipientEmail ? 'YES' : 'NO'}, Mobile: ${params.recipientMobile ? 'YES' : 'NO'}`);

  // Determine channels based on available contact info
  const channelsToSend: Array<{ channel: 'email' | 'whatsapp'; contact: string }> = [];

  if (params.recipientEmail) {
    channelsToSend.push({ channel: 'email', contact: params.recipientEmail });
  }

  if (params.recipientMobile) {
    channelsToSend.push({ channel: 'whatsapp', contact: params.recipientMobile });
  }

  if (channelsToSend.length === 0) {
    console.warn('[Contract JTD] No contact info provided — cannot send notification');
    return { success: false, channels: [], anySuccess: false };
  }

  // Process each channel
  for (const { channel } of channelsToSend) {
    const channelEnabled = await isChannelEnabled(supabase, params.tenantId, channel);

    if (!channelEnabled) {
      console.log(`[Contract JTD] Channel ${channel} disabled for tenant ${params.tenantId}`);
      results.push({
        channel,
        success: true,
        skipped: true,
        error: `Channel ${channel} is disabled for this tenant`
      });
      continue;
    }

    const jtdResult = await createContractSignoffJTD(supabase, params, channel);

    results.push({
      channel,
      success: jtdResult.success,
      jtdId: jtdResult.jtdId,
      skipped: jtdResult.skipped,
      error: jtdResult.error
    });
  }

  const anySuccess = results.some(r => r.success && !r.skipped);

  console.log(`[Contract JTD] Complete. Any success: ${anySuccess}, Results:`,
    results.map(r => `${r.channel}:${r.success ? (r.skipped ? 'skipped' : 'ok') : 'failed'}`).join(', ')
  );

  return { success: anySuccess, channels: results, anySuccess };
}
