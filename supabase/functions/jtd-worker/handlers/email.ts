// supabase/functions/jtd-worker/handlers/email.ts
// Email handler using MSG91 - matches contractnest-api/src/services/email.service.ts

interface EmailRequest {
  to: string;
  subject: string;
  body: string;
  bodyHtml?: string;
  metadata?: Record<string, any>;
}

interface ProcessResult {
  success: boolean;
  provider_message_id?: string;
  error?: string;
}

// MSG91 Configuration (same as email.service.ts)
const MSG91_AUTH_KEY = Deno.env.get('MSG91_AUTH_KEY');
const MSG91_SENDER_EMAIL = Deno.env.get('MSG91_SENDER_EMAIL');
const MSG91_SENDER_NAME = Deno.env.get('MSG91_SENDER_NAME');

/**
 * Send email via MSG91
 * Matches: contractnest-api/src/services/email.service.ts
 */
export async function handleEmail(request: EmailRequest): Promise<ProcessResult> {
  const { to, subject, body, bodyHtml, metadata } = request;

  // Validation (same as email.service.ts)
  if (!MSG91_AUTH_KEY) {
    console.error('MSG91_AUTH_KEY is not configured');
    return {
      success: false,
      error: 'MSG91_AUTH_KEY is not configured'
    };
  }

  if (!MSG91_SENDER_EMAIL) {
    console.error('MSG91_SENDER_EMAIL is not configured');
    return {
      success: false,
      error: 'MSG91_SENDER_EMAIL is not configured'
    };
  }

  if (!MSG91_SENDER_NAME) {
    console.error('MSG91_SENDER_NAME is not configured');
    return {
      success: false,
      error: 'MSG91_SENDER_NAME is not configured'
    };
  }

  if (!to) {
    return {
      success: false,
      error: 'Recipient email is required'
    };
  }

  try {
    // MSG91 Email API endpoint (same as email.service.ts)
    const url = 'https://control.msg91.com/api/v5/email/send';

    // Payload format matches email.service.ts
    const payload: Record<string, any> = {
      from: {
        email: MSG91_SENDER_EMAIL,
        name: MSG91_SENDER_NAME
      },
      to: [{ email: to }],
      subject: subject,
      body: bodyHtml || body // Use HTML if available
    };

    console.log(`[JTD Email] Sending to ${to}: ${subject}`);

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
      console.log(`[JTD Email] Sent successfully to ${to}, request_id: ${result.request_id || result.data?.request_id}`);
      return {
        success: true,
        provider_message_id: result.request_id || result.data?.request_id
      };
    }

    console.error('[JTD Email] MSG91 error:', result);
    return {
      success: false,
      error: result.message || 'Failed to send email'
    };

  } catch (error) {
    console.error('[JTD Email] Send error:', error);
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error sending email'
    };
  }
}

/**
 * Handle MSG91 email webhook callback
 */
export interface MSG91EmailWebhook {
  request_id: string;
  event: 'sent' | 'delivered' | 'opened' | 'clicked' | 'bounced' | 'dropped' | 'spam';
  email: string;
  timestamp: string;
  description?: string;
}

export function mapMSG91EmailStatus(event: string): string {
  const statusMap: Record<string, string> = {
    'sent': 'sent',
    'delivered': 'delivered',
    'opened': 'read',
    'clicked': 'read',
    'bounced': 'failed',
    'dropped': 'failed',
    'spam': 'failed'
  };
  return statusMap[event?.toLowerCase()] || 'sent';
}
