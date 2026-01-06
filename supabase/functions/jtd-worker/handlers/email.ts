// supabase/functions/jtd-worker/handlers/email.ts
// Email handler using MSG91 - based on MSG91 official documentation

interface EmailRequest {
  to: string;
  toName?: string;
  subject: string;
  body: string;
  bodyHtml?: string;
  templateId?: string;
  templateVariables?: Record<string, any>;
  metadata?: Record<string, any>;
}

interface ProcessResult {
  success: boolean;
  provider_message_id?: string;
  error?: string;
}

// MSG91 Configuration
const MSG91_AUTH_KEY = Deno.env.get('MSG91_AUTH_KEY');
const MSG91_SENDER_EMAIL = Deno.env.get('MSG91_SENDER_EMAIL');
const MSG91_SENDER_NAME = Deno.env.get('MSG91_SENDER_NAME');
const MSG91_EMAIL_DOMAIN = Deno.env.get('MSG91_EMAIL_DOMAIN');

/**
 * Send email via MSG91
 * Based on MSG91 documentation: https://docs.msg91.com/reference/send-email
 */
export async function handleEmail(request: EmailRequest): Promise<ProcessResult> {
  const { to, toName, subject, body, bodyHtml, templateId, templateVariables, metadata } = request;

  // Validation
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
    // MSG91 Email API endpoint
    const url = 'https://control.msg91.com/api/v5/email/send';

    // Build payload per MSG91 documentation
    const payload: Record<string, any> = {
      recipients: [
        {
          to: [
            {
              name: toName || to.split('@')[0],
              email: to
            }
          ],
          variables: templateVariables || {}
        }
      ],
      from: {
        name: MSG91_SENDER_NAME,
        email: MSG91_SENDER_EMAIL
      }
    };

    // Add domain if configured
    if (MSG91_EMAIL_DOMAIN) {
      payload.domain = MSG91_EMAIL_DOMAIN;
    }

    // Add template_id if provided, otherwise this won't work with MSG91
    if (templateId) {
      payload.template_id = templateId;
    } else {
      console.error('[JTD Email] No template_id provided - MSG91 requires a template');
      return {
        success: false,
        error: 'MSG91 requires a template_id for sending emails'
      };
    }

    console.log(`[JTD Email] Sending to ${to} using template: ${templateId}`);
    console.log(`[JTD Email] Variables:`, JSON.stringify(templateVariables));
    console.log(`[JTD Email] Payload:`, JSON.stringify(payload, null, 2));

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'authkey': MSG91_AUTH_KEY,
        'Content-Type': 'application/json',
        'accept': 'application/json'
      },
      body: JSON.stringify(payload)
    });

    const result = await response.json();

    console.log(`[JTD Email] MSG91 Response:`, JSON.stringify(result));

    if (result && (result.type === 'success' || result.status === 'success')) {
      console.log(`[JTD Email] Sent successfully to ${to}`);
      return {
        success: true,
        provider_message_id: result.request_id || result.data?.request_id || result.message_id
      };
    }

    console.error('[JTD Email] MSG91 error:', JSON.stringify(result));
    return {
      success: false,
      error: `MSG91: ${JSON.stringify(result)}`
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
