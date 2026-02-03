-- 007_seed_payment_request_templates.sql
-- Seed JTD templates for payment request notifications (payment link delivery).
-- These are used when a seller sends a payment link to a buyer via email or WhatsApp.
-- Follows pattern from 006_seed_contract_signoff_templates.sql

-- ============================================================
-- ADD 'payment_request' to n_jtd_source_types FIRST (FK dependency)
-- ============================================================
INSERT INTO public.n_jtd_source_types (code, name, description, is_active)
VALUES ('payment_request', 'Payment Request', 'Payment link sent to buyer for online collection', true)
ON CONFLICT (code) DO NOTHING;

-- ============================================================
-- PAYMENT REQUEST TEMPLATES
-- ============================================================

-- ─── Email Template ──────────────────────────────────────────

INSERT INTO public.n_jtd_templates (
    tenant_id,
    template_key,
    name,
    description,
    channel_code,
    source_type_code,
    subject,
    content,
    content_html,
    variables,
    is_live,
    is_active,
    created_by,
    updated_by
) VALUES (
    NULL, -- System template (applies to all tenants)
    'payment_request_email',
    'Payment Request Email',
    'Email template for sending payment collection link to buyer',
    'email',
    'payment_request',
    'Payment request from {{tenant_name}} — {{currency}} {{amount}} for Invoice {{invoice_number}}',
    'Hi {{customer_name}}, {{tenant_name}} has sent you a payment request of {{currency}} {{amount}} for Invoice {{invoice_number}}. Pay securely here: {{payment_link}}. This link expires in {{expire_hours}} hours.',
    '<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Payment Request — {{invoice_number}}</title>
</head>
<body style="font-family: -apple-system, BlinkMacSystemFont, ''Segoe UI'', Roboto, sans-serif; line-height: 1.6; color: #333; margin: 0; padding: 0; background-color: #f5f5f5;">
    <div style="max-width: 600px; margin: 0 auto; background-color: #ffffff;">
        <!-- Header -->
        <div style="background: linear-gradient(135deg, #059669, #10B981); color: white; padding: 30px; text-align: center;">
            <h1 style="margin: 0; font-size: 22px;">Payment Request</h1>
            <p style="margin: 8px 0 0; opacity: 0.9; font-size: 14px;">from {{tenant_name}}</p>
        </div>

        <!-- Body -->
        <div style="padding: 36px 40px;">
            <p style="margin: 0 0 20px;">Hi <strong>{{customer_name}}</strong>,</p>
            <p style="margin: 0 0 24px;"><strong>{{tenant_name}}</strong> has requested a payment from you.</p>

            <!-- Payment Summary Card -->
            <div style="border: 1px solid #e5e7eb; border-radius: 8px; overflow: hidden; margin: 0 0 28px;">
                <div style="background-color: #f0fdf4; padding: 14px 20px; border-bottom: 1px solid #e5e7eb;">
                    <strong style="color: #111; font-size: 16px;">Payment Details</strong>
                </div>
                <div style="padding: 16px 20px;">
                    <table style="width: 100%; border-collapse: collapse; font-size: 14px;">
                        <tr>
                            <td style="padding: 6px 0; color: #6b7280;">Invoice</td>
                            <td style="padding: 6px 0; text-align: right; font-weight: 600;">{{invoice_number}}</td>
                        </tr>
                        <tr>
                            <td style="padding: 6px 0; color: #6b7280;">Amount</td>
                            <td style="padding: 6px 0; text-align: right; font-weight: 600; color: #059669; font-size: 18px;">{{currency}} {{amount}}</td>
                        </tr>
                        <tr>
                            <td style="padding: 6px 0; color: #6b7280;">Expires</td>
                            <td style="padding: 6px 0; text-align: right; font-size: 13px; color: #9ca3af;">{{expire_hours}} hours from now</td>
                        </tr>
                    </table>
                </div>
            </div>

            <!-- CTA Button -->
            <div style="text-align: center; margin: 32px 0;">
                <a href="{{payment_link}}" style="background: linear-gradient(135deg, #059669, #10B981); color: white; padding: 14px 40px; text-decoration: none; border-radius: 8px; display: inline-block; font-weight: 600; font-size: 16px;">
                    Pay {{currency}} {{amount}}
                </a>
            </div>

            <p style="font-size: 13px; color: #6b7280; margin: 0 0 8px;">Click the button above to pay securely via our payment partner.</p>
            <p style="font-size: 12px; color: #9ca3af; margin: 0 0 4px;">If the button doesn''t work, copy this link:</p>
            <p style="font-size: 12px; color: #059669; word-break: break-all; margin: 0;">{{payment_link}}</p>
        </div>

        <!-- Footer -->
        <div style="background-color: #f9fafb; padding: 20px; text-align: center; border-top: 1px solid #e5e7eb;">
            <p style="margin: 0 0 4px; font-size: 11px; color: #9ca3af;">Powered by ContractNest</p>
            <p style="margin: 0; font-size: 11px; color: #9ca3af;">This is an automated payment request. Do not reply to this email.</p>
        </div>
    </div>
</body>
</html>',
    '["customer_name", "tenant_name", "invoice_number", "amount", "currency", "payment_link", "expire_hours"]'::jsonb,
    NULL, -- NULL is_live for system templates
    true,
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001'
) ON CONFLICT (tenant_id, template_key, channel_code, is_live)
DO UPDATE SET
    content = EXCLUDED.content,
    content_html = EXCLUDED.content_html,
    subject = EXCLUDED.subject,
    variables = EXCLUDED.variables,
    updated_at = now();


-- ─── WhatsApp Template ───────────────────────────────────────
-- Template must be created and approved on MSG91 dashboard first
-- Template name on MSG91: 'payment_request'
-- Placeholders: {{1}}=customer_name, {{2}}=tenant_name, {{3}}=invoice_number,
--               {{4}}=amount, {{5}}=currency, {{6}}=payment_link, {{7}}=expire_hours

INSERT INTO public.n_jtd_templates (
    tenant_id,
    template_key,
    name,
    description,
    channel_code,
    source_type_code,
    subject,
    content,
    provider_template_id,
    variables,
    is_live,
    is_active,
    created_by,
    updated_by
) VALUES (
    NULL,
    'payment_request_whatsapp',
    'Payment Request WhatsApp',
    'WhatsApp template for sending payment collection link - uses MSG91 approved template',
    'whatsapp',
    'payment_request',
    NULL,
    'Hi {{customer_name}}, {{tenant_name}} has sent you a payment request of {{currency}} {{amount}} for Invoice {{invoice_number}}. Pay securely here: {{payment_link}}. Link expires in {{expire_hours}} hours.',
    'payment_request', -- Template NAME on MSG91 (must be pre-approved)
    '["customer_name", "tenant_name", "invoice_number", "amount", "currency", "payment_link", "expire_hours"]'::jsonb,
    NULL,
    true,
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001'
) ON CONFLICT (tenant_id, template_key, channel_code, is_live)
DO UPDATE SET
    content = EXCLUDED.content,
    provider_template_id = EXCLUDED.provider_template_id,
    variables = EXCLUDED.variables,
    updated_at = now();


-- ============================================================
-- SEED TENANT SOURCE CONFIG FOR PAYMENT REQUEST
-- Enable email + whatsapp for payment_request for test tenants
-- ============================================================

INSERT INTO public.n_jtd_tenant_source_config (
    tenant_id,
    source_type_code,
    channels_enabled,
    is_enabled,
    auto_execute,
    is_live,
    is_active,
    created_by,
    updated_by
) VALUES (
    '70f8eb69-9ccf-4a0c-8177-cb6131934344',
    'payment_request',
    ARRAY['email', 'whatsapp'],
    true,
    true,
    true,
    true,
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001'
) ON CONFLICT (tenant_id, source_type_code, is_live)
DO UPDATE SET
    channels_enabled = EXCLUDED.channels_enabled,
    is_enabled = EXCLUDED.is_enabled,
    updated_at = now();

INSERT INTO public.n_jtd_tenant_source_config (
    tenant_id,
    source_type_code,
    channels_enabled,
    is_enabled,
    auto_execute,
    is_live,
    is_active,
    created_by,
    updated_by
) VALUES (
    'a58ca91a-7832-4b4c-b67c-a210032f26b8',
    'payment_request',
    ARRAY['email', 'whatsapp'],
    true,
    true,
    true,
    true,
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001'
) ON CONFLICT (tenant_id, source_type_code, is_live)
DO UPDATE SET
    channels_enabled = EXCLUDED.channels_enabled,
    is_enabled = EXCLUDED.is_enabled,
    updated_at = now();


-- ============================================================
-- VERIFICATION
-- ============================================================
DO $$
DECLARE
    template_count INTEGER;
    config_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO template_count
    FROM public.n_jtd_templates
    WHERE template_key LIKE 'payment_request%';

    SELECT COUNT(*) INTO config_count
    FROM public.n_jtd_tenant_source_config
    WHERE source_type_code = 'payment_request';

    RAISE NOTICE 'Payment request templates seeded: %', template_count;
    RAISE NOTICE 'Tenant source configs for payment_request: %', config_count;
END $$;
