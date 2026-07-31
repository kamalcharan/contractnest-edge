-- 009_seed_bbb_group_session_templates.sql
-- BBB tenant mapping for the two Sprint 2 (immediate) Group Session WhatsApp
-- triggers, now that both MSG91 templates are approved.
--
-- provider_template_id matches the approved MSG91 template name exactly
-- (same as the source_type_code — MSG91 assigned no separate name).
-- Variable order in `content` (documentation only, not what's actually
-- sent) matches the payload_mapping order already seeded in
-- 008_seed_group_session_source_types.sql, and must match the order
-- template_data is built in when the Sprint 2 trigger code enqueues these
-- (jtd-worker fills WhatsApp template placeholders positionally, not by
-- name, regardless of what MSG91's template-authoring UI calls them).

INSERT INTO public.n_jtd_templates (
    tenant_id, template_key, name, description, channel_code, source_type_code,
    content, provider_template_id, is_live, is_active
) VALUES
    (
        'dd194710-92b4-4110-80eb-0b492a0d2c1f',
        'group_session_attendance_ack',
        'Group Session Attendance Acknowledgement (BBB)',
        'Sent immediately after a member scans and marks attendance',
        'whatsapp',
        'group_session_attendance_ack',
        'Hi {{member_name}}, your attendance for {{session_name}} on {{occurrence_date}} has been recorded. Thank you!',
        'group_session_attendance_ack',
        true,
        true
    ),
    (
        'dd194710-92b4-4110-80eb-0b492a0d2c1f',
        'group_session_payment_thankyou',
        'Group Session Payment Thank-You (BBB)',
        'Sent when a member''s payment declaration is confirmed',
        'whatsapp',
        'group_session_payment_thankyou',
        'Hi {{member_name}}, we''ve received your payment of {{amount}} for {{session_name}}. Thank you!',
        'group_session_payment_thankyou',
        true,
        true
    )
ON CONFLICT (tenant_id, template_key, channel_code, is_live) DO UPDATE SET
    provider_template_id = EXCLUDED.provider_template_id,
    content = EXCLUDED.content,
    is_active = EXCLUDED.is_active,
    updated_at = NOW();
