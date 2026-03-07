// supabase/functions/jtd-worker/handlers/sms.ts
// SMS handler using MSG91 - matches contractnest-api/src/services/sms.service.ts

interface SMSRequest {
  to: string;
  countryCode?: string;
  body: string;
  templateId?: string;
  variables?: Record<string, string>;
  metadata?: Record<string, any>;
}

interface ProcessResult {
  success: boolean;
  provider_message_id?: string;
  error?: string;
}

// MSG91 Configuration (same as sms.service.ts)
const MSG91_AUTH_KEY = Deno.env.get('MSG91_AUTH_KEY');
const MSG91_SENDER_ID = Deno.env.get('MSG91_SENDER_ID');
const MSG91_ROUTE = Deno.env.get('MSG91_ROUTE') || '4'; // Default: Transactional
const MSG91_COUNTRY_CODE = Deno.env.get('MSG91_COUNTRY_CODE') || '91';

/**
 * Format mobile number using the recipient's country code when available,
 * falling back to MSG91_COUNTRY_CODE env var (default '91').
 */
function formatMobile(num: string, countryCode?: string): string {
  const cleaned = num.replace(/\D/g, '');
  const code = countryCode?.replace(/\D/g, '') || MSG91_COUNTRY_CODE;
  if (cleaned.startsWith(code)) {
    return cleaned;
  }
  return `${code}${cleaned}`;
}

/**
 * Send SMS via MSG91
 * Matches: contractnest-api/src/services/sms.service.ts
 */
export async function handleSMS(request: SMSRequest): Promise<ProcessResult> {
  const { to, countryCode, body, templateId, variables, metadata } = request;

  // Validation (same as sms.service.ts)
  if (!MSG91_AUTH_KEY) {
    console.error('MSG91_AUTH_KEY is not configured');
    return {
      success: false,
      error: 'MSG91_AUTH_KEY is not configured'
    };
  }

  if (!MSG91_SENDER_ID) {
    console.error('MSG91_SENDER_ID is not configured');
    return {
      success: false,
      error: 'MSG91_SENDER_ID is not configured'
    };
  }

  if (!to) {
    return {
      success: false,
      error: 'Mobile number is required'
    };
  }

  try {
    const formattedMobile = formatMobile(to, countryCode);

    // MSG91 SMS API endpoint (same as sms.service.ts)
    const url = 'https://control.msg91.com/api/v5/flow/';

    // Payload format matches sms.service.ts
    const payload: Record<string, any> = {
      sender: MSG91_SENDER_ID,
      route: MSG91_ROUTE,
      country: countryCode?.replace(/\D/g, '') || MSG91_COUNTRY_CODE,
      sms: [{
        message: body,
        to: [formattedMobile]
      }]
    };

    // Add template fields if provided
    if (templateId || metadata?.template_id) {
      payload.template_id = templateId || metadata?.template_id;
      if (variables || metadata?.variables) {
        payload.sms[0].variables = variables || metadata?.variables;
      }
    }

    console.log(`[JTD SMS] Sending to ${formattedMobile}`);

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'authkey': MSG91_AUTH_KEY,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payload)
    });

    const result = await response.json();

    if (result && result.type === 'success') {
      console.log(`[JTD SMS] Sent successfully to ${formattedMobile}, request_id: ${result.request_id}`);
      return {
        success: true,
        provider_message_id: result.request_id
      };
    }

    console.error('[JTD SMS] MSG91 error:', result);
    return {
      success: false,
      error: result.message || 'Failed to send SMS'
    };

  } catch (error) {
    console.error('[JTD SMS] Send error:', error);
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error sending SMS'
    };
  }
}

/**
 * Handle MSG91 SMS delivery webhook
 */
export interface MSG91SMSWebhook {
  request_id: string;
  status: 'DELIVRD' | 'FAILED' | 'EXPIRED' | 'UNDELIV' | 'REJECTD';
  mobile: string;
  timestamp: string;
  description?: string;
}

export function mapMSG91SMSStatus(status: string): string {
  const statusMap: Record<string, string> = {
    'DELIVRD': 'delivered',
    'FAILED': 'failed',
    'EXPIRED': 'failed',
    'UNDELIV': 'failed',
    'REJECTD': 'failed'
  };
  return statusMap[status] || status.toLowerCase();
}
