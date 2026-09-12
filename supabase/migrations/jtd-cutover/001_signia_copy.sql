-- ═══════════════════════════════════════════════════════════════════
-- jtd-cutover/001_signia_copy.sql — Phase 1 for tenant signia
-- APPLIED LIVE 2026-09-01 (owner: "ok migrate signia to V2 (jtd)").
-- This file is the source-of-record copy — DO NOT RE-RUN blindly;
-- it is idempotent (row-level NOT EXISTS) but Phase status is tracked
-- in the session/POA, not by re-running.
--
-- What it does: id-preserving copy of every legacy t_contract_events
-- row (23 signia contracts, 356 rows) into n_jtd as JOB rows
-- (channel_code NULL), n_jtd.id = t_contract_events.id. Additive —
-- t_contract_events untouched. Vocabulary matches born-V2 jobs:
--   service → event_type_code 'service_visit' / source 'service_scheduled'
--   billing → 'payment' / 'payment_scheduled'
--   status_code = event status verbatim (Step 2 seeded lifecycles from
--   the real statuses); paid/completed rows get completed_at stamped
--   (mirrors jtd-nucleus/007's repair rule).
-- Provenance: business_context = {migrated_from, migration:'jtd-cutover/001',
-- migrated_at} — also the rollback handle:
--   DELETE FROM n_jtd WHERE business_context->>'migration'='jtd-cutover/001';
--
-- Trigger safety (verified before run): jtd_enqueue_on_insert and
-- trg_fn_jtd_credit_gate act only on status_code='created' — copied rows
-- arrive scheduled/overdue/paid/due, so nothing enqueues and no credits
-- gate. jtd_log_creation writes history rows — desirable provenance.
--
-- Verification (inside the same transaction, aborts + rolls back on fail):
-- per contract, row count, Σamount, Σamount_settled MUST match between
-- t_contract_events and n_jtd job rows. Result on live run:
--   Phase 1 OK: 23 contracts, 356 rows copied, all counts/sums match.
-- Independent post-check: signia_events_without_twin = 0,
-- settled_in_jobs = 21300 (CN-1003 15800 + CN-1004 5500).
-- ═══════════════════════════════════════════════════════════════════

DO $do$
DECLARE
    v_tenant  uuid := '80e3b843-525e-4368-b418-b1250d1d1d63';
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
        RAISE EXCEPTION 'Phase 1 verification FAILED on % contract(s) — transaction rolled back', v_bad;
    END IF;

    RAISE NOTICE 'Phase 1 OK: % contracts in scope, % event rows copied id-preserving, all counts/sums match', v_scope, v_copied;
END
$do$;
