// supabase/functions/jtd-worker/handlers/whatsapp.ts
// WhatsApp handler using MSG91 - based on MSG91 official documentation

interface WhatsAppRequest {
  to: string;
  countryCode?: string;
  templateName: string;
  templateData: Record<string, any>;
  mediaUrl?: string;
  /** The template's declared variables, in order, from n_jtd_templates. */
  templateVariableOrder?: any;
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
 * Send WhatsApp message via MSG91
 * Based on MSG91 documentation: https://docs.msg91.com/reference/send-whatsapp-message
 */
export async function handleWhatsApp(request: WhatsAppRequest): Promise<ProcessResult> {
  const { to, countryCode, templateName, templateData, mediaUrl, templateVariableOrder, metadata } = request;

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
    const formattedMobile = formatMobile(to, countryCode);

    // MSG91 WhatsApp API endpoint (bulk endpoint for templates)
    const url = 'https://control.msg91.com/api/v5/whatsapp/whatsapp-outbound-message/bulk/';

    // Build components object based on template variables.
    //
    // MSG91 supports two template variable styles, matching Meta's WhatsApp
    // Cloud API:
    //   - POSITIONAL ({{1}}, {{2}}, {{3}}): components key is "body_1", "body_2",
    //       value shape {type:'text', value:'...'}.
    //   - NAMED      ({{member_name}}, ...):  components key is "body_<name>",
    //       value shape {type:'text', value:'...', parameter_name:'<name>'}.
    // Meta added named parameters in 2024; some WABA namespaces enforce named
    // ONLY (BBB's namespace does — see MSG91 dashboard rejecting {{1}}). The
    // wrong style is silently accepted by MSG91 at request time (returns
    // success + request_id), then WhatsApp itself rejects on delivery with
    // "Parameter name is missing or empty". Reason attendance_ack /
    // payment_thankyou stayed unread on the tester's phone despite the JTD
    // showing status='sent'.
    //
    // Each template branch declares which style its MSG91 registration uses;
    // don't mix — MSG91 rejects a components object with both keys shapes.
    const components: Record<string, { type: string; value: string; sub_type?: string; parameter_name?: string }> = {};

    if (templateData && Object.keys(templateData).length > 0) {
      // orderedValues → positional, namedParams → named. Exactly one is set
      // per template branch. Emit block after the if-chain reads whichever
      // was set.
      let orderedValues: string[] | null = null;
      let namedParams: Array<{ name: string; value: string }> | null = null;

      if (templateName === 'user_invitation') {
        // Positional. {{1}}=recipient_name, {{2}}=inviter_name, {{3}}=workspace_name, {{4}}=invitation_link
        orderedValues = [
          String(templateData.recipient_name || ''),
          String(templateData.inviter_name || ''),
          String(templateData.workspace_name || ''),
          String(templateData.invitation_link || '')
        ];
        console.log(`[JTD WhatsApp] user_invitation variables:`, orderedValues);
      } else if (templateName === 'contract_signoff') {
        // Positional. Body: {{1}}=recipient_name, {{2}}=sender_name, {{3}}=contract_info + CTA button URL suffix.
        orderedValues = [
          String(templateData.recipient_name || ''),
          String(templateData.sender_name || ''),
          String(templateData.contract_info || '')
        ];

        // CTA button: pass the dynamic URL suffix for "Review Contract" button
        if (templateData.review_link_suffix) {
          components['button_1'] = {
            type: 'text',
            sub_type: 'url',
            value: String(templateData.review_link_suffix)
          };
        }

        console.log(`[JTD WhatsApp] contract_signoff body:`, orderedValues, 'button_suffix:', templateData.review_link_suffix);
      } else if (templateName === 'group_session_attendance_ack') {
        // Named. Body: Hi {{member_name}}, your attendance for {{session_name}} on {{occurrence_date}}...
        namedParams = [
          { name: 'member_name',     value: String(templateData.member_name || '') },
          { name: 'session_name',    value: String(templateData.session_name || '') },
          { name: 'occurrence_date', value: String(templateData.occurrence_date || '') }
        ];
      } else if (templateName === 'group_session_payment_thankyou') {
        // Named. Body: Hi {{member_name}}, we've received your payment of {{amount}} for {{session_name}}...
        namedParams = [
          { name: 'member_name',  value: String(templateData.member_name || '') },
          { name: 'amount',       value: String(templateData.amount || '') },
          { name: 'session_name', value: String(templateData.session_name || '') }
        ];
      } else if (templateName === 'group_session_looking_forward') {
        // Named. Body: Hi {{member_name}}, looking forward to seeing you at
        // {{session_name}} on {{occurrence_date}} at {{start_time}}...
        // Four variables — the only group-session template carrying a time.
        // The enqueue side (gs_run_session_notifications) only creates these
        // for blocks with groupSession.timing.startTime set, so start_time is
        // never blank in practice.
        namedParams = [
          { name: 'member_name',     value: String(templateData.member_name || '') },
          { name: 'session_name',    value: String(templateData.session_name || '') },
          { name: 'occurrence_date', value: String(templateData.occurrence_date || '') },
          { name: 'start_time',      value: String(templateData.start_time || '') }
        ];
      } else if (templateName === 'group_session_noshow_regret') {
        // Named. Body: Hi {{member_name}}, we missed you at {{session_name}}
        // on {{occurrence_date}}...
        namedParams = [
          { name: 'member_name',     value: String(templateData.member_name || '') },
          { name: 'session_name',    value: String(templateData.session_name || '') },
          { name: 'occurrence_date', value: String(templateData.occurrence_date || '') }
        ];
      } else {
        // GENERIC PATH — no per-template branch required.
        //
        // n_jtd_templates.variables declares each template's variables IN
        // ORDER, and always did; the worker simply never read the column. So
        // this used to be Object.values(templateData), whose order Postgres
        // does not preserve for a jsonb object — hence the old warning that
        // every new template needed hand-written code above.
        //
        // Reading the declared order removes that requirement entirely. Two
        // shapes are in use: ["name", ...] and [{name: "..."}, ...].
        const declared: string[] = Array.isArray(templateVariableOrder)
          ? templateVariableOrder
              .map((v: any) => (typeof v === 'string' ? v : v?.name))
              .filter((n: any): n is string => typeof n === 'string' && n.length > 0)
          : [];

        if (declared.length > 0) {
          orderedValues = declared.map(n => String(templateData[n] ?? ''));
        } else {
          // Template declares nothing — the old behaviour, kept so the
          // existing templates with variables:[] are unaffected. Still
          // order-unreliable, which is now a reason to populate `variables`
          // on that template rather than to add a branch here.
          orderedValues = Object.values(templateData).map(v => String(v));
        }
      }

      if (namedParams) {
        // Named: key becomes body_<param_name>, value carries parameter_name too.
        namedParams.forEach(({ name, value }) => {
          components[`body_${name}`] = {
            type: 'text',
            value: value,
            parameter_name: name
          };
        });
      } else if (orderedValues) {
        // Positional: keys become body_1, body_2, ...
        orderedValues.forEach((value, index) => {
          components[`body_${index + 1}`] = {
            type: 'text',
            value: value
          };
        });
      }
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
