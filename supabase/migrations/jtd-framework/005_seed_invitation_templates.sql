-- 005_seed_invitation_templates.sql
-- Seed JTD templates for user invitation notifications
-- Part of JTD Framework

-- ============================================================
-- USER INVITATION TEMPLATES
-- ============================================================

-- Email template for user invitation
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
    'user_invitation_email',
    'User Invitation Email',
    'Email template for inviting users to a workspace',
    'email',
    'user_invite',
    'You''re invited to join {{workspace_name}}',
    'Hi {{recipient_name}}, {{inviter_name}} has invited you to join {{workspace_name}}. Accept here: {{invitation_link}}',
    '<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Invitation to {{workspace_name}}</title>
</head>
<body style="font-family: -apple-system, BlinkMacSystemFont, ''Segoe UI'', Roboto, sans-serif; line-height: 1.6; color: #333; margin: 0; padding: 0; background-color: #f5f5f5;">
    <div style="max-width: 600px; margin: 0 auto; background-color: #ffffff;">
        <div style="background-color: #4F46E5; color: white; padding: 30px; text-align: center;">
            <h1 style="margin: 0;">You''re Invited!</h1>
        </div>
        <div style="padding: 40px;">
            <p>Hi {{recipient_name}},</p>
            <p><strong>{{inviter_name}}</strong> has invited you to join <strong>{{workspace_name}}</strong>.</p>
            <div style="text-align: center; margin: 40px 0;">
                <a href="{{invitation_link}}" style="background-color: #4F46E5; color: white; padding: 14px 30px; text-decoration: none; border-radius: 6px; display: inline-block;">Accept Invitation</a>
            </div>
            <p style="font-size: 14px; color: #666;">This invitation expires in 48 hours.</p>
            <p style="font-size: 14px; color: #666;">If you can''t click the button, copy this link: {{invitation_link}}</p>
        </div>
        <div style="background-color: #f9fafb; padding: 20px; text-align: center; font-size: 12px; color: #666;">
            <p style="margin: 0;">Powered by ContractNest</p>
        </div>
    </div>
</body>
</html>',
    '["recipient_name", "inviter_name", "workspace_name", "invitation_link", "custom_message"]'::jsonb,
    NULL, -- NULL is_live for system templates
    true,
    '00000000-0000-0000-0000-000000000001', -- VaNi
    '00000000-0000-0000-0000-000000000001'
) ON CONFLICT (tenant_id, template_key, channel_code, is_live)
DO UPDATE SET
    content = EXCLUDED.content,
    content_html = EXCLUDED.content_html,
    subject = EXCLUDED.subject,
    variables = EXCLUDED.variables,
    updated_at = now();

-- SMS template for user invitation
INSERT INTO public.n_jtd_templates (
    tenant_id,
    template_key,
    name,
    description,
    channel_code,
    source_type_code,
    subject,
    content,
    variables,
    is_live,
    is_active,
    created_by,
    updated_by
) VALUES (
    NULL,
    'user_invitation_sms',
    'User Invitation SMS',
    'SMS template for inviting users to a workspace',
    'sms',
    'user_invite',
    NULL, -- No subject for SMS
    '{{inviter_name}} invited you to join {{workspace_name}}. Accept here: {{invitation_link}}',
    '["inviter_name", "workspace_name", "invitation_link"]'::jsonb,
    NULL, -- NULL is_live for system templates
    true,
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001'
) ON CONFLICT (tenant_id, template_key, channel_code, is_live)
DO UPDATE SET
    content = EXCLUDED.content,
    variables = EXCLUDED.variables,
    updated_at = now();

-- WhatsApp template for user invitation
-- Note: content contains the MSG91/WhatsApp approved template NAME
-- The actual template is configured on MSG91 dashboard
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
    'user_invitation_whatsapp',
    'User Invitation WhatsApp',
    'WhatsApp template for inviting users - uses MSG91 approved template',
    'whatsapp',
    'user_invite',
    NULL,
    '{{inviter_name}} invited you to join {{workspace_name}}. Accept here: {{invitation_link}}',
    'user_invitation', -- This is the template NAME on MSG91
    '["inviter_name", "workspace_name", "invitation_link"]'::jsonb,
    NULL, -- NULL is_live for system templates
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
-- SEED TENANT SOURCE CONFIG FOR USER INVITE
-- Enable all channels for user_invite by default for test tenants
-- ============================================================

-- For tenant 1: Enable email, sms, whatsapp for user_invite
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
    'user_invite',
    ARRAY['email', 'sms', 'whatsapp'],
    true,
    true, -- VaNi auto-executes
    true, -- Live mode
    true,
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001'
) ON CONFLICT (tenant_id, source_type_code, is_live)
DO UPDATE SET
    channels_enabled = EXCLUDED.channels_enabled,
    is_enabled = EXCLUDED.is_enabled,
    updated_at = now();

-- For tenant 2: Enable email, sms, whatsapp for user_invite
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
    'user_invite',
    ARRAY['email', 'sms', 'whatsapp'],
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
    WHERE template_key LIKE 'user_invitation%';

    SELECT COUNT(*) INTO config_count
    FROM public.n_jtd_tenant_source_config
    WHERE source_type_code = 'user_invite';

    RAISE NOTICE 'User invitation templates seeded: %', template_count;
    RAISE NOTICE 'Tenant source configs for user_invite: %', config_count;
END $$;
