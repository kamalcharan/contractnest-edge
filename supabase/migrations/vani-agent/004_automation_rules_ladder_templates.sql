-- ============================================================================
-- 004_automation_rules_ladder_templates.sql — Automation Rules: truthful
-- templates + the payment ladder lives in the Payment reminders rule
-- ============================================================================
-- Context (review 2026-09-16, specs/OPS-JTD-TOOLS-SPEC.md §3.2/§6):
--   · The per-tenant collections ladder is stored in t_vani_rules (NOT in
--     n_jtd_tenant_source_config as first drafted) — update_vani_rule already
--     validates integer arrays with min/max/min_items/max_items and
--     vani_rule_int_array() already reads them. Zero RPC change.
--   · Owner: fold the ladder into the existing "Payment reminders" card, one
--     card = the whole payment schedule. Rungs stored as three day arrays
--     (email / WhatsApp / call task), presets are UI sugar.
--   · Group-session rule values were decorative: gs_run_session_notifications
--     never reads them (fires 3d + 1d out, absentee 3d out to members who
--     missed the last two, no-show +2h). Only the worker's on/off gate is
--     honoured. Templates now SAY so and default to what the engine does.
--   · Bug: templates spelled array-length bounds minLength/maxLength while
--     update_vani_rule checks min_items/max_items → never enforced. Fixed.
--
-- Data hygiene: tenant rows that were verbatim copies of the OLD defaults
-- (seed_vani_rules copies default_config into config) collapse to {} =
-- "use defaults", so they do not read as "customized" just because the
-- default moved. Genuinely customized rows (e.g. tenant 'setup' with
-- days_before [3,2,1]) are untouched.
--
-- Scanner impact: run_contract_event_scanner reads ONLY payment_reminder.
-- lead_days (unchanged, still default 3) — its behaviour is identical.
--
-- APPLIED LIVE 2026-09-16 after a guarded BEGIN…ROLLBACK run (array save +
-- out-of-bounds reject both exercised through update_vani_rule). Idempotent.
-- ============================================================================

UPDATE m_vani_rule_templates SET
  name = 'Payment reminders',
  description = 'Your payment reminder schedule. Before due: one email this many days ahead (runs today). After due: the collections ladder — email, WhatsApp, and a call task for your team on the given days past due. Configure the ladder now; it is dispatched by the collections tools as they ship.',
  default_config = '{"lead_days":3,"email_days_after_due":[0,3,7],"whatsapp_days_after_due":[7],"call_days_after_due":[14]}'::jsonb,
  constraints = '{"lead_days":{"min":0,"max":30},"email_days_after_due":{"min":0,"max":365,"min_items":0,"max_items":12},"whatsapp_days_after_due":{"min":0,"max":365,"min_items":0,"max_items":12},"call_days_after_due":{"min":0,"max":365,"min_items":0,"max_items":12}}'::jsonb
WHERE rule_key = 'payment_reminder';

UPDATE m_vani_rule_templates SET
  description = 'Reminder sent to members before an upcoming group session, 3 days and 1 day ahead. The on/off switch is honoured today; the day offsets are fixed by the engine and not yet read from here.',
  default_config = '{"days_before":[3,1]}'::jsonb,
  constraints = '{"days_before":{"min":0,"max":30,"min_items":1,"max_items":5}}'::jsonb
WHERE rule_key = 'notif_group_session_looking_forward';

UPDATE m_vani_rule_templates SET
  description = 'Nudge sent 3 days before a session to members who missed the last two. The on/off switch is honoured today; the offset is fixed by the engine and not yet read from here.',
  default_config = '{"days_before":[3]}'::jsonb,
  constraints = '{"days_before":{"min":0,"max":30,"min_items":1,"max_items":3}}'::jsonb
WHERE rule_key = 'notif_group_session_absentee_reminder';

UPDATE m_vani_rule_templates SET
  description = 'Post-session note to members who did not attend, sent 2 hours after the session ends. The on/off switch is honoured today; the offset is fixed by the engine and not yet read from here.',
  constraints = '{"hours_after_end":{"min":0,"max":168,"min_items":1,"max_items":3}}'::jsonb
WHERE rule_key = 'notif_group_session_noshow_regret';

UPDATE t_vani_rules SET config = '{}'::jsonb
WHERE (rule_key = 'payment_reminder' AND config = '{"lead_days":3}'::jsonb)
   OR (rule_key = 'notif_group_session_looking_forward' AND config = '{"days_before":[2,1]}'::jsonb)
   OR (rule_key = 'notif_group_session_absentee_reminder' AND config = '{"minutes_after_start":[15]}'::jsonb)
   OR (rule_key = 'notif_group_session_noshow_regret' AND config = '{"hours_after_end":[2]}'::jsonb);

DO $chk$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM m_vani_rule_templates WHERE constraints::text ILIKE '%minLength%' OR constraints::text ILIKE '%maxLength%';
  IF v_n <> 0 THEN RAISE EXCEPTION 'post-check: % templates still carry minLength/maxLength', v_n; END IF;
  SELECT count(*) INTO v_n FROM m_vani_rule_templates WHERE rule_key='payment_reminder' AND default_config ? 'email_days_after_due' AND default_config ? 'whatsapp_days_after_due' AND default_config ? 'call_days_after_due' AND default_config ? 'lead_days';
  IF v_n <> 1 THEN RAISE EXCEPTION 'post-check: payment_reminder template not upgraded'; END IF;
  SELECT count(*) INTO v_n FROM t_vani_rules WHERE rule_key='payment_reminder' AND config = '{"lead_days":3}'::jsonb;
  IF v_n <> 0 THEN RAISE EXCEPTION 'post-check: % payment_reminder rows still hold the old verbatim default', v_n; END IF;
END $chk$;
