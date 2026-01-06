// supabase/functions/jtd-worker/handlers/whatsapp.ts
// WhatsApp handler using MSG91 - based on MSG91 official documentation

interface WhatsAppRequest {
  to: string;
  templateName: string;
  templateData: Record<string, any>;
  mediaUrl?: string;
  metadata?: Record<string, any>;
}

interface ProcessResult {
  success: boolean;
  provider_message_id?: string;
  error?: string;
}

// MSG91 WhatsApp Configuration
const MSG91_AUTH_KEY = Deno.env.get('MSG91_AUTH_KEY');
const MSG91_WHATSAPP_NUMBER = Deno.env.get('MSG91_WHATSAPP_NUMBER');
const MSG91_COUNTRY_CODE = Deno.env.get('MSG91_COUNTRY_CODE') || '91';

/**
 * Format mobile number
 */
function formatMobile(num: string): string {
  const cleaned = num.replace(/\D/g, '');
  if (cleaned.startsWith(MSG91_COUNTRY_CODE)) {
    return cleaned;
  }
  return `${MSG91_COUNTRY_CODE}${cleaned}`;
}

/**
 * Send WhatsApp message via MSG91
 * Based on MSG91 documentation: https://docs.msg91.com/reference/send-whatsapp-message
 */
export async function handleWhatsApp(request: WhatsAppRequest): Promise<ProcessResult> {
  const { to, templateName, templateData, mediaUrl, metadata } = request;

  // Validation
  if (!MSG91_AUTH_KEY) {
    console.error('MSG91_AUTH_KEY is not configured');
    return {
      success: false,
      error: 'MSG91_AUTH_KEY is not configured'
    };
  }

  if (!MSG91_WHATSAPP_NUMBER) {
    console.error('MSG91_WHATSAPP_NUMBER is not configured');
    return {
      success: false,
      error: 'MSG91_WHATSAPP_NUMBER is not configured'
    };
  }

  if (!to) {
    return {
      success: false,
      error: 'Mobile number is required'
    };
  }

  try {
    const formattedMobile = formatMobile(to);

    // MSG91 WhatsApp API endpoint (bulk endpoint for templates)
    const url = 'https://control.msg91.com/api/v5/whatsapp/whatsapp-outbound-message/bulk/';

    // Build components object based on template variables
    // MSG91 uses body_1, body_2, etc. for template placeholders
    const components: Record<string, { type: string; value: string }> = {};

    if (templateData && Object.keys(templateData).length > 0) {
      let orderedValues: string[];

      if (templateName === 'user_invitation') {
        // user_invitation template: {{1}}=recipient_name, {{2}}=inviter_name, {{3}}=workspace_name, {{4}}=invitation_link
        orderedValues = [
          String(templateData.recipient_name || ''),
          String(templateData.inviter_name || ''),
          String(templateData.workspace_name || ''),
          String(templateData.invitation_link || '')
        ];
        console.log(`[JTD WhatsApp] user_invitation variables:`, orderedValues);
      } else {
        // For other templates, use Object.values
        orderedValues = Object.values(templateData).map(v => String(v));
      }

      // Convert to MSG91 format: body_1, body_2, etc.
      orderedValues.forEach((value, index) => {
        components[`body_${index + 1}`] = {
          type: 'text',
          value: value
        };
      });
    }

    // Add header component if media URL provided
    if (mediaUrl) {
      components['header_1'] = {
        type: 'image',
        value: mediaUrl
      };
    }

    // Build payload per MSG91 documentation
    const payload = {
      integrated_number: MSG91_WHATSAPP_NUMBER,
      content_type: 'template',
      payload: {
        type: 'template',
        template: {
          name: templateName,
          language: {
            code: 'en',
            policy: 'deterministic'
          },
          to_and_components: [
            {
              to: [formattedMobile],
              components: components
            }
          ]
        },
        messaging_product: 'whatsapp'  // REQUIRED by MSG91/WhatsApp
      }
    };

    console.log(`[JTD WhatsApp] Sending to ${formattedMobile}, template: ${templateName}`);
    console.log(`[JTD WhatsApp] Payload:`, JSON.stringify(payload, null, 2));

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

    console.log(`[JTD WhatsApp] MSG91 Response:`, JSON.stringify(result));

    if (result && (result.type === 'success' || result.status === 'success')) {
      console.log(`[JTD WhatsApp] Sent successfully to ${formattedMobile}`);
      return {
        success: true,
        provider_message_id: result.data?.id || result.request_id || result.message_id
      };
    }

    console.error('[JTD WhatsApp] MSG91 error:', JSON.stringify(result));
    return {
      success: false,
      error: `MSG91: ${JSON.stringify(result)}`
    };

  } catch (error) {
    console.error('[JTD WhatsApp] Send error:', error);
    return {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error sending WhatsApp'
    };
  }
}

/**
 * Handle MSG91 WhatsApp webhook callback
 */
export interface MSG91WhatsAppWebhook {
  message_id: string;
  status: 'sent' | 'delivered' | 'read' | 'failed';
  mobile: string;
  timestamp: string;
  error_code?: string;
  error_message?: string;
}

export function mapMSG91WhatsAppStatus(status: string): string {
  const statusMap: Record<string, string> = {
    'sent': 'sent',
    'delivered': 'delivered',
    'read': 'read',
    'failed': 'failed'
  };
  return statusMap[status] || status.toLowerCase();
}
