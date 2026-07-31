-- 008_seed_group_session_source_types.sql
-- Group Session WhatsApp notification triggers — new n_jtd_source_types.
--
-- Deliberately NOT seeding any n_jtd_templates rows here (no tenant_id=NULL
-- system template for these 5 codes). getTemplate() in jtd-worker/index.ts
-- falls back to a NULL-tenant row only when one exists — omitting it means a
-- tenant with no explicit (tenant_id, source_type_code, channel_code) row of
-- their own simply gets no template match, and the job fails cleanly
-- (status='failed' + DLQ, see jtd-worker/index.ts "No template found for
-- X/Y") rather than silently defaulting to shared content. This is
-- intentional: it makes onboarding a tenant onto these triggers (inserting
-- their n_jtd_templates row with a real MSG91 provider_template_id) the only
-- way they start receiving them — a natural rollout gate (e.g. BBB piloting
-- while every other tenant stays untouched) with no separate feature flag.
--
-- Channel is WhatsApp-only for all 5 — these are the triggers scoped in the
-- Group Session WhatsApp notifications work.

INSERT INTO public.n_jtd_source_types (
    code, name, description, default_event_type, source_table, source_id_field, default_channels, payload_mapping, is_active
) VALUES
    ('group_session_attendance_ack', 'Group Session Attendance Acknowledgement',
     'Immediate acknowledgement sent to a member right after they scan and mark attendance', 'notification',
     't_session_attendance', 'id', ARRAY['whatsapp'],
     '{"member_name": "$.member.name", "session_name": "$.block.name", "occurrence_date": "$.occurrence_date", "checked_in_at": "$.checked_in_at"}'::jsonb, true),

    ('group_session_noshow_regret', 'Group Session No-Show Regret',
     'Sent to a member who did not check in, after the session has concluded', 'reminder',
     't_group_session_schedule', 'id', ARRAY['whatsapp'],
     '{"member_name": "$.member.name", "session_name": "$.block.name", "occurrence_date": "$.occurrence_date"}'::jsonb, true),

    ('group_session_looking_forward', 'Group Session Looking Forward',
     'Sent to all active roster members ahead of an upcoming session occurrence', 'reminder',
     't_group_session_schedule', 'id', ARRAY['whatsapp'],
     '{"member_name": "$.member.name", "session_name": "$.block.name", "occurrence_date": "$.occurrence_date", "start_time": "$.block.groupSession.timing.startTime"}'::jsonb, true),

    ('group_session_payment_thankyou', 'Group Session Payment Thank-You',
     'Sent to a member when their payment declaration is confirmed', 'notification',
     't_session_payment_declarations', 'id', ARRAY['whatsapp'],
     '{"member_name": "$.member.name", "session_name": "$.block.name", "amount": "$.amount", "confirmed_at": "$.confirmed_at"}'::jsonb, true),

    ('group_session_absentee_reminder', 'Group Session Absentee Reminder',
     'Sent ahead of an upcoming occurrence to members who missed the previous two', 'reminder',
     't_group_session_schedule', 'id', ARRAY['whatsapp'],
     '{"member_name": "$.member.name", "session_name": "$.block.name", "occurrence_date": "$.occurrence_date"}'::jsonb, true)
ON CONFLICT (code) DO NOTHING;
