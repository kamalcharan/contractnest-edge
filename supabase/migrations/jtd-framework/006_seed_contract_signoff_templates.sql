-- 006_seed_contract_signoff_templates.sql
-- Seed JTD templates for contract sign-off notifications
-- Follows same pattern as 005_seed_invitation_templates.sql

-- ============================================================
-- CONTRACT SIGN-OFF TEMPLATES
-- ============================================================

-- Email template for contract sign-off notification
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
    'contract_signoff_email',
    'Contract Sign-off Email',
    'Email template for sending contract for buyer sign-off / acceptance',
    'email',
    'contract_signoff',
    '{{sender_name}} has shared a contract for your review — {{contract_title}}',
    'Hi {{recipient_name}}, {{sender_name}} has shared the contract "{{contract_title}}" ({{contract_number}}) worth {{contract_value}} for your review. Review here: {{review_link}}',
    '<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Contract Review — {{contract_title}}</title>
</head>
<body style="font-family: -apple-system, BlinkMacSystemFont, ''Segoe UI'', Roboto, sans-serif; line-height: 1.6; color: #333; margin: 0; padding: 0; background-color: #f5f5f5;">
    <div style="max-width: 600px; margin: 0 auto; background-color: #ffffff;">
        <!-- Header -->
        <div style="background: linear-gradient(135deg, #4F46E5, #7C3AED); color: white; padding: 30px; text-align: center;">
            <h1 style="margin: 0; font-size: 22px;">Contract Review</h1>
            <p style="margin: 8px 0 0; opacity: 0.9; font-size: 14px;">{{sender_name}}</p>
        </div>

        <!-- Body -->
        <div style="padding: 36px 40px;">
            <p style="margin: 0 0 20px;">Hi <strong>{{recipient_name}}</strong>,</p>
            <p style="margin: 0 0 24px;"><strong>{{sender_name}}</strong> has shared a contract for your review and acceptance.</p>

            <!-- Contract Summary Card -->
            <div style="border: 1px solid #e5e7eb; border-radius: 8px; overflow: hidden; margin: 0 0 28px;">
                <div style="background-color: #f9fafb; padding: 14px 20px; border-bottom: 1px solid #e5e7eb;">
                    <strong style="color: #111; font-size: 16px;">{{contract_title}}</strong>
                </div>
                <div style="padding: 16px 20px;">
                    <table style="width: 100%; border-collapse: collapse; font-size: 14px;">
                        <tr>
                            <td style="padding: 6px 0; color: #6b7280;">Contract #</td>
                            <td style="padding: 6px 0; text-align: right; font-weight: 600;">{{contract_number}}</td>
                        </tr>
                        <tr>
                            <td style="padding: 6px 0; color: #6b7280;">Value</td>
                            <td style="padding: 6px 0; text-align: right; font-weight: 600; color: #059669;">{{contract_value}}</td>
                        </tr>
                        <tr>
                            <td style="padding: 6px 0; color: #6b7280;">Reference</td>
                            <td style="padding: 6px 0; text-align: right; font-family: monospace; font-size: 12px; color: #4F46E5;">{{cnak}}</td>
                        </tr>
                    </table>
                </div>
            </div>

            <!-- CTA Button -->
            <div style="text-align: center; margin: 32px 0;">
                <a href="{{review_link}}" style="background: linear-gradient(135deg, #4F46E5, #7C3AED); color: white; padding: 14px 36px; text-decoration: none; border-radius: 8px; display: inline-block; font-weight: 600; font-size: 15px;">
                    Review Contract
                </a>
            </div>

            <p style="font-size: 13px; color: #6b7280; margin: 0 0 8px;">You can review, download as PDF, and accept or reject this contract using the link above.</p>
            <p style="font-size: 12px; color: #9ca3af; margin: 0 0 4px;">If the button doesn''t work, copy this link:</p>
            <p style="font-size: 12px; color: #4F46E5; word-break: break-all; margin: 0;">{{review_link}}</p>
        </div>

        <!-- Footer -->
        <div style="background-color: #f9fafb; padding: 20px; text-align: center; border-top: 1px solid #e5e7eb;">
            <p style="margin: 0 0 4px; font-size: 11px; color: #9ca3af;">Powered by ContractNest</p>
            <p style="margin: 0; font-size: 11px; color: #9ca3af;">Ref: {{cnak}}</p>
        </div>
    </div>
</body>
</html>',
    '["recipient_name", "sender_name", "contract_title", "contract_number", "contract_value", "review_link", "cnak"]'::jsonb,
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


-- WhatsApp template for contract sign-off
-- Note: Template must be created and approved on MSG91 dashboard first
-- Template name on MSG91: 'contract_signoff'
-- Placeholders: {{1}}=recipient_name, {{2}}=sender_name, {{3}}=contract_title,
--               {{4}}=contract_number, {{5}}=contract_value, {{6}}=review_link, {{7}}=cnak
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
    'contract_signoff_whatsapp',
    'Contract Sign-off WhatsApp',
    'WhatsApp template for sending contract for sign-off - uses MSG91 approved template',
    'whatsapp',
    'contract_signoff',
    NULL,
    'Hi {{recipient_name}}, {{sender_name}} has shared "{{contract_title}}" ({{contract_number}}) worth {{contract_value}} for your review. Review here: {{review_link}} | Ref: {{cnak}}',
    'contract_signoff', -- Template NAME on MSG91 (must be pre-approved)
    '["recipient_name", "sender_name", "contract_title", "contract_number", "contract_value", "review_link", "cnak"]'::jsonb,
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
-- ADD 'contract_signoff' to n_jtd_source_types if not exists
-- ============================================================
INSERT INTO public.n_jtd_source_types (code, name, description, is_active)
VALUES ('contract_signoff', 'Contract Sign-off', 'Contract sent for buyer review and acceptance', true)
ON CONFLICT (code) DO NOTHING;


-- ============================================================
-- SEED TENANT SOURCE CONFIG FOR CONTRACT SIGN-OFF
-- Enable email + whatsapp for contract_signoff for test tenants
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
    'contract_signoff',
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
    'contract_signoff',
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
    WHERE template_key LIKE 'contract_signoff%';

    SELECT COUNT(*) INTO config_count
    FROM public.n_jtd_tenant_source_config
    WHERE source_type_code = 'contract_signoff';

    RAISE NOTICE 'Contract signoff templates seeded: %', template_count;
    RAISE NOTICE 'Tenant source configs for contract_signoff: %', config_count;
END $$;
