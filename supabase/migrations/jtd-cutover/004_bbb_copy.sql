-- ═══════════════════════════════════════════════════════════════════
-- jtd-cutover/004_bbb_copy.sql — Phase 1 for tenant BBB
-- APPLIED LIVE 2026-09-11 (owner: "i guess we should go forward";
-- physical DB backup taken 2026-09-10 22:14:03 UTC as disaster net —
-- surgical rollback stays the provenance-tag delete below).
-- Identical mechanics to 001_signia_copy.sql, tenant swapped.
--
-- Pre-flight audit (2026-09-11, in-session) established:
--   LIVE:  52 active contracts, 389 billing events (203 scheduled ₹4,99,500
--          / 132 paid ₹3,42,000 / 54 overdue ₹1,17,000), 0 service events.
--   TEST:  18 active + 6 draft contracts, 88 billing + 13 service events.
--   Attendance (t_session_attendance, 348 rows) references the SCHEDULE,
--   never events — structurally unaffected.
--   Money-in writers (gs_confirm_declaration, scanner, record_invoice_
--   payment) all write t_contract_events → mirrored by the already-live
--   global bridge (003) the moment twins exist.
--   n_jtd for BBB = 515 message rows only (channel_code set); id
--   collisions with event ids = 0.
--   is_live is carried VERBATIM — both environments copied, both keep
--   working identically.
--
-- Rollback (surgical, holds through Phase 5):
--   DELETE FROM n_jtd WHERE business_context->>'migration'='jtd-cutover/001'
--     AND tenant_id='dd194710-92b4-4110-80eb-0b492a0d2c1f';
-- (Provenance tag kept as 'jtd-cutover/001' ON PURPOSE — 002/005, the
--  bridge drift check and audit_dual_read_check all key on that one tag.)
-- ═══════════════════════════════════════════════════════════════════

DO $do$
DECLARE
    v_tenant  uuid := 'dd194710-92b4-4110-80eb-0b492a0d2c1f';
    v_copied  int;
    v_bad     int;
    v_scope   int;
BEGIN
    CREATE TEMP TABLE tmp_cutover_scope ON COMMIT DROP AS
    SELECT c.id AS contract_id
    FROM t_contracts c
    WHERE c.tenant_id = v_tenant
      AND EXISTS (SELECT 1 FROM t_contract_events e WHERE e.contract_id = c.id)
      AND NOT EXISTS (
          SELECT 1 FROM n_jtd j
          WHERE j.contract_id = c.id AND j.channel_code IS NULL
            AND COALESCE(j.business_context->>'migration','') <> 'jtd-cutover/001');
    SELECT count(*) INTO v_scope FROM tmp_cutover_scope;

    INSERT INTO n_jtd (id, tenant_id, contract_id, block_id, block_name, category_id,
        event_type_code, source_type_code, source_id, source_ref,
        scheduled_at, original_date, sequence_number, total_occurrences,
        billing_sub_type, billing_cycle_label, amount, amount_settled, currency,
        invoice_id, status_code, status_changed_at, completed_at,
        task_id, reminder_jtd_id, reminder_dispatched_at,
        assigned_to, assigned_to_name, notes, version, is_active, is_live, audience,
        performed_by_type, priority, business_context,
        created_at, updated_at, created_by, updated_by)
    SELECT e.id, e.tenant_id, e.contract_id, e.block_id, e.block_name, e.category_id,
        CASE e.event_type WHEN 'service' THEN 'service_visit' ELSE 'payment' END,
        CASE e.event_type WHEN 'service' THEN 'service_scheduled' ELSE 'payment_scheduled' END,
        e.contract_id, c.contract_number,
        e.scheduled_date, e.original_date, e.sequence_number, e.total_occurrences,
        e.billing_sub_type, e.billing_cycle_label, e.amount, e.amount_settled, e.currency,
        e.invoice_id, e.status, e.updated_at,
        CASE WHEN e.status IN ('paid','completed') THEN e.updated_at ELSE NULL END,
        e.task_id, e.reminder_jtd_id, e.reminder_dispatched_at,
        e.assigned_to, e.assigned_to_name, e.notes, e.version, e.is_active, e.is_live, e.audience,
        'system', 5,
        jsonb_build_object('migrated_from','t_contract_events',
                           'migration','jtd-cutover/001','migrated_at', now()),
        e.created_at, e.updated_at, e.created_by, e.updated_by
    FROM t_contract_events e
    JOIN t_contracts c ON c.id = e.contract_id
    WHERE e.contract_id IN (SELECT contract_id FROM tmp_cutover_scope)
      AND NOT EXISTS (SELECT 1 FROM n_jtd j2 WHERE j2.id = e.id);
    GET DIAGNOSTICS v_copied = ROW_COUNT;

    SELECT count(*) INTO v_bad FROM (
        SELECT s.contract_id,
            (SELECT count(*) FROM t_contract_events e WHERE e.contract_id = s.contract_id) AS ec,
            (SELECT COALESCE(SUM(e.amount),0) FROM t_contract_events e WHERE e.contract_id = s.contract_id) AS ea,
            (SELECT COALESCE(SUM(e.amount_settled),0) FROM t_contract_events e WHERE e.contract_id = s.contract_id) AS es,
            (SELECT count(*) FROM n_jtd j WHERE j.contract_id = s.contract_id AND j.channel_code IS NULL) AS jc,
            (SELECT COALESCE(SUM(j.amount),0) FROM n_jtd j WHERE j.contract_id = s.contract_id AND j.channel_code IS NULL) AS ja,
            (SELECT COALESCE(SUM(j.amount_settled),0) FROM n_jtd j WHERE j.contract_id = s.contract_id AND j.channel_code IS NULL) AS js
        FROM tmp_cutover_scope s) t
    WHERE t.ec <> t.jc OR t.ea <> t.ja OR t.es <> t.js;

    IF v_bad > 0 THEN
        RAISE EXCEPTION 'Phase 1 (BBB) verification FAILED on % contract(s) — transaction rolled back', v_bad;
    END IF;

    RAISE NOTICE 'Phase 1 (BBB) OK: % contracts in scope, % event rows copied id-preserving, all counts/sums match', v_scope, v_copied;
END
$do$;
