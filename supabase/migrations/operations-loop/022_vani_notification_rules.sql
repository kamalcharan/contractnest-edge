-- 022_vani_notification_rules.sql
-- VaNi Rules — notification domain (Phase 1)
--
-- Adds one rule per tenant-controllable JTD source type so the tenant's
-- "when does this message fire / does it fire at all" knob lives in the SAME
-- store as the existing service/finance automation rules
-- (017_vani_rules_v1.sql), instead of the parallel n_jtd_tenant_source_config
-- schema (dead, being retired — see cleanup notes in the accompanying
-- COPY_INSTRUCTIONS.txt for the Phase 1 bundle).
--
-- Separation of concerns:
--   • m_vani_rule_templates / t_vani_rules  — WHEN + on/off (this file)
--   • n_jtd_templates                       — WHAT text goes out (unchanged;
--                                             admin-managed via
--                                             /admin/jtd/template-mapping)
--   • n_jtd                                 — queued job (unchanged)
--
-- Identity/access source types (user_invite, user_created, contract_signoff)
-- deliberately DO NOT get a rule here. They stay always-on via jtd-worker's
-- GATE_EXEMPT_SOURCE_TYPES — blocking them isn't "saving spend," it breaks
-- login/signup/contract-signing outright. A tenant can't restrict them.
--
-- Config shape uses JSONB arrays for timing fields even where Phase 1 UI
-- will only surface a single value. Reason (owner call 2026-08-01): the
-- background AI service coming later reads multiple offsets per rule
-- (e.g. "remind 2 days before AND 1 day before"). Locking the schema to a
-- scalar today would force a migration + resolver rewrite the moment that
-- service arrives.
--
-- Phase 1 is view-only for tenants. update_vani_rule (017_vani_rules_v1.sql,
-- line 200) currently rejects array config values — INVALID_TYPE — which
-- means these rules can't be edited via the standard tenant PUT path yet.
-- That's intentional for Phase 1: admin edits happen out-of-band. Widening
-- update_vani_rule to accept array/bounded-array fields is Phase 2 work,
-- paired with turning the UI cards editable.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Seed notification-domain rule templates
-- ---------------------------------------------------------------------------
-- ON CONFLICT DO NOTHING so re-running is safe and existing rules (with
-- possibly-live tenant overrides) never get their default_config replaced.

INSERT INTO m_vani_rule_templates
    (rule_key, name, description, domain, default_config, constraints, sort_order)
VALUES
    -- Group session — scheduled (need timing)
    ('notif_group_session_looking_forward',
     'Group session — looking forward',
     'Reminder sent to members before an upcoming group session. The array holds one offset per reminder; the automation fires one message per entry.',
     'notifications',
     '{"days_before": [2, 1]}'::jsonb,
     '{"days_before": {"min": 0, "max": 30, "minLength": 1, "maxLength": 5}}'::jsonb,
     100),

    ('notif_group_session_absentee_reminder',
     'Group session — absentee reminder',
     'Nudge sent to members who have not checked in some minutes after the session starts.',
     'notifications',
     '{"minutes_after_start": [15]}'::jsonb,
     '{"minutes_after_start": {"min": 0, "max": 240, "minLength": 1, "maxLength": 3}}'::jsonb,
     110),

    ('notif_group_session_noshow_regret',
     'Group session — no-show regret',
     'Post-session note to members who did not attend, sent some hours after the session ends.',
     'notifications',
     '{"hours_after_end": [2]}'::jsonb,
     '{"hours_after_end": {"min": 0, "max": 168, "minLength": 1, "maxLength": 3}}'::jsonb,
     120),

    -- Group session — event-driven (on/off only)
    ('notif_group_session_attendance_ack',
     'Group session — attendance acknowledgement',
     'Confirmation sent to a member the moment they check in to a session.',
     'notifications', '{}'::jsonb, '{}'::jsonb, 130),

    ('notif_group_session_payment_thankyou',
     'Group session — payment thank-you',
     'Thank-you sent to a member the moment their session payment is confirmed.',
     'notifications', '{}'::jsonb, '{}'::jsonb, 140),

    -- Payments (event-driven — timing already lives on the existing
    -- automation-domain payment_reminder rule; here we control on/off only)
    ('notif_payment_due',        'Payment due',        'Notice sent when a payment becomes due.',                       'notifications', '{}'::jsonb, '{}'::jsonb, 200),
    ('notif_payment_overdue',    'Payment overdue',    'Notice sent when a payment crosses its due date without receipt.','notifications', '{}'::jsonb, '{}'::jsonb, 210),
    ('notif_payment_received',   'Payment received',   'Acknowledgement sent when a payment is received.',              'notifications', '{}'::jsonb, '{}'::jsonb, 220),
    ('notif_payment_request',    'Payment request',    'Standalone payment request sent to a customer.',                'notifications', '{}'::jsonb, '{}'::jsonb, 230),

    -- Service lifecycle (event-driven)
    ('notif_service_scheduled',  'Service scheduled',  'Notice sent when a service visit is scheduled.',                'notifications', '{}'::jsonb, '{}'::jsonb, 300),
    ('notif_service_reminder',   'Service reminder',   'Reminder sent ahead of a scheduled service visit.',             'notifications', '{}'::jsonb, '{}'::jsonb, 310),
    ('notif_service_completed',  'Service completed',  'Notice sent when a service visit is marked complete.',          'notifications', '{}'::jsonb, '{}'::jsonb, 320),

    -- Appointments (event-driven)
    ('notif_appointment_created',  'Appointment created',  'Notice sent when an appointment is created.',       'notifications', '{}'::jsonb, '{}'::jsonb, 400),
    ('notif_appointment_reminder', 'Appointment reminder', 'Reminder sent ahead of an upcoming appointment.',   'notifications', '{}'::jsonb, '{}'::jsonb, 410),

    -- Contract lifecycle (event-driven)
    ('notif_contract_created',   'Contract created',   'Notice sent to counterparty when a contract is created.', 'notifications', '{}'::jsonb, '{}'::jsonb, 500),
    ('notif_contract_sent',      'Contract sent',      'Notice sent when a contract is dispatched.',              'notifications', '{}'::jsonb, '{}'::jsonb, 510),
    ('notif_contract_signed',    'Contract signed',    'Notice sent when a contract is signed.',                  'notifications', '{}'::jsonb, '{}'::jsonb, 520),
    ('notif_contract_accepted',  'Contract accepted',  'Notice sent when a contract is accepted.',                'notifications', '{}'::jsonb, '{}'::jsonb, 530),
    ('notif_contract_expired',   'Contract expired',   'Notice sent when a contract expires.',                    'notifications', '{}'::jsonb, '{}'::jsonb, 540),

    -- RFQ (event-driven)
    ('notif_rfq_sent',           'RFQ sent to vendors',    'Notice sent to vendors when an RFQ goes out.',        'notifications', '{}'::jsonb, '{}'::jsonb, 600),
    ('notif_rfq_quote_received', 'Vendor quote received',  'Notice sent to the buyer when a vendor quote lands.', 'notifications', '{}'::jsonb, '{}'::jsonb, 610)
ON CONFLICT (rule_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Array-value resolver — for the Phase 2 scheduler
-- ---------------------------------------------------------------------------
-- Companion to vani_rule_int(). Reads an INT[] field with the same precedence
-- (tenant rule config → template default → caller fallback). Present now,
-- unused today; the scheduler that reads days_before / minutes_after_start
-- / hours_after_end will call this once it exists.

CREATE OR REPLACE FUNCTION vani_rule_int_array(
    p_tenant_id UUID,
    p_rule_key  TEXT,
    p_field     TEXT,
    p_fallback  INT[]
)
RETURNS INT[]
LANGUAGE sql STABLE
SET search_path = public
AS $$
    SELECT COALESCE((
        SELECT ARRAY(
            SELECT (value)::int
            FROM jsonb_array_elements_text(
                COALESCE(tr.config -> p_field, mt.default_config -> p_field)
            )
        )
        FROM m_vani_rule_templates mt
        LEFT JOIN t_vani_rules tr
               ON tr.tenant_id = p_tenant_id AND tr.rule_key = mt.rule_key
        WHERE mt.rule_key = p_rule_key
          AND mt.is_active = true
          AND jsonb_typeof(COALESCE(tr.config -> p_field, mt.default_config -> p_field)) = 'array'
    ), p_fallback);
$$;

COMMENT ON FUNCTION vani_rule_int_array IS
'INT[] companion to vani_rule_int. Returns the tenant''s override if present, template default otherwise, or p_fallback if neither is an array field.';

COMMIT;
