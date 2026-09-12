-- ═══════════════════════════════════════════════════════════════════
-- jtd-cutover/003_bidirectional_sync.sql — Phase 3 (drift-kill bridge)
-- APPLIED LIVE 2026-09-02. Source-of-record copy — do not re-run blindly
-- (CREATE OR REPLACE + DROP/CREATE TRIGGER are idempotent regardless).
--
-- Execution-time design decision (paper allowed finalization at
-- execution): instead of editing the 10 V1 writer functions
-- (run_contract_event_scanner, update_contract_event, update_appointment,
-- approve_draft_invoice, cancel_invoice_receipt, gs_mark_due_paid,
-- insert_contract_events_batch, process_contract_events_from_computed,
-- admin_reset_*), Phase 3 installs a BIDIRECTIONAL SYNC BRIDGE:
--   trg_zz_cutover_sync_e2j  AFTER UPDATE ON t_contract_events
--       V1 writers move an event → the twin job follows
--   trg_zz_cutover_sync_j2e  AFTER UPDATE ON n_jtd
--       V2 writers settle a job → the twin event follows
-- Twin = same id in both tables (the id-preserving copy). Rows without a
-- twin (BBB, un-migrated tenants) miss the PK match and nothing happens —
-- V1 behavior byte-identical there. pg_trigger_depth() > 1 guard breaks
-- the mirror cycle; IS DISTINCT FROM guards make no-op updates free.
-- ZERO V1 function edits — golden rule fully respected.
--
-- One-time reconcile (ran first, same migration):
--   money truth = jobs  → 4 event rows took job money-state (CN-1003-test
--                          ₹600: 250 paid + 350 paid + invoice_id refs)
--   status truth = events → 3 job rows took event scheduler-status
--                          (CN-1019 due→overdue flips made post-copy)
--
-- Verified live 2026-09-02:
--   in-migration check: drift = 0 across all 23 migrated contracts
--   forced-rollback harness: event→'overdue' mirrored to job; job settled
--   123.45/'partial_payment' mirrored to event; transaction rolled back
--   post-harness dual check: 0 drifted
--
-- DELETE mirroring deliberately NOT installed: only admin_reset_* delete
-- events (test-data resets); their n_jtd sweep is a Phase 5 item.
-- Bridge lifetime: until Phase 5 flip (writers all-V2), then triggers drop.
-- Rollback: DROP TRIGGER trg_zz_cutover_sync_e2j ON t_contract_events;
--           DROP TRIGGER trg_zz_cutover_sync_j2e ON n_jtd;
-- ═══════════════════════════════════════════════════════════════════

DO $do$
DECLARE
    v_money int; v_status int;
BEGIN
    UPDATE t_contract_events e
    SET amount_settled = j.amount_settled,
        status         = j.status_code,
        invoice_id     = COALESCE(j.invoice_id, e.invoice_id),
        updated_at     = now()
    FROM n_jtd j
    WHERE j.id = e.id AND j.channel_code IS NULL
      AND COALESCE(j.amount_settled,0) > COALESCE(e.amount_settled,0);
    GET DIAGNOSTICS v_money = ROW_COUNT;

    UPDATE n_jtd j
    SET status_code = e.status, status_changed_at = now(), updated_at = now()
    FROM t_contract_events e
    WHERE e.id = j.id AND j.channel_code IS NULL
      AND COALESCE(j.amount_settled,0) = COALESCE(e.amount_settled,0)
      AND j.status_code IS DISTINCT FROM e.status;
    GET DIAGNOSTICS v_status = ROW_COUNT;

    RAISE NOTICE 'reconcile: % event rows took job money-state, % job rows took event status', v_money, v_status;
END
$do$;

CREATE OR REPLACE FUNCTION trg_fn_cutover_sync_e2j() RETURNS trigger AS $fn$
BEGIN
    -- jtd-cutover/003: mirror V1 writer changes into the twin job row
    IF pg_trigger_depth() > 1 THEN RETURN NULL; END IF;
    IF NEW.status IS NOT DISTINCT FROM OLD.status
       AND NEW.amount_settled IS NOT DISTINCT FROM OLD.amount_settled
       AND NEW.scheduled_date IS NOT DISTINCT FROM OLD.scheduled_date
       AND NEW.invoice_id IS NOT DISTINCT FROM OLD.invoice_id THEN
        RETURN NULL;
    END IF;
    UPDATE n_jtd j
    SET status_code       = NEW.status,
        amount_settled    = NEW.amount_settled,
        scheduled_at      = NEW.scheduled_date,
        invoice_id        = NEW.invoice_id,
        status_changed_at = CASE WHEN j.status_code IS DISTINCT FROM NEW.status THEN now() ELSE j.status_changed_at END,
        completed_at      = CASE WHEN NEW.status IN ('paid','completed')
                                 THEN COALESCE(j.completed_at, now()) ELSE NULL END
    WHERE j.id = NEW.id AND j.channel_code IS NULL
      AND (j.status_code IS DISTINCT FROM NEW.status
        OR j.amount_settled IS DISTINCT FROM NEW.amount_settled
        OR j.scheduled_at IS DISTINCT FROM NEW.scheduled_date
        OR j.invoice_id IS DISTINCT FROM NEW.invoice_id);
    RETURN NULL;
END
$fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_fn_cutover_sync_j2e() RETURNS trigger AS $fn$
BEGIN
    -- jtd-cutover/003: mirror V2 writer changes into the twin event row
    IF pg_trigger_depth() > 1 THEN RETURN NULL; END IF;
    IF NEW.channel_code IS NOT NULL THEN RETURN NULL; END IF;
    IF NEW.status_code IS NOT DISTINCT FROM OLD.status_code
       AND NEW.amount_settled IS NOT DISTINCT FROM OLD.amount_settled
       AND NEW.scheduled_at IS NOT DISTINCT FROM OLD.scheduled_at
       AND NEW.invoice_id IS NOT DISTINCT FROM OLD.invoice_id THEN
        RETURN NULL;
    END IF;
    UPDATE t_contract_events e
    SET status         = NEW.status_code,
        amount_settled = NEW.amount_settled,
        scheduled_date = NEW.scheduled_at,
        invoice_id     = NEW.invoice_id,
        updated_at     = now()
    WHERE e.id = NEW.id
      AND (e.status IS DISTINCT FROM NEW.status_code
        OR e.amount_settled IS DISTINCT FROM NEW.amount_settled
        OR e.scheduled_date IS DISTINCT FROM NEW.scheduled_at
        OR e.invoice_id IS DISTINCT FROM NEW.invoice_id);
    RETURN NULL;
END
$fn$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_zz_cutover_sync_e2j ON t_contract_events;
CREATE TRIGGER trg_zz_cutover_sync_e2j
AFTER UPDATE ON t_contract_events
FOR EACH ROW EXECUTE FUNCTION trg_fn_cutover_sync_e2j();

DROP TRIGGER IF EXISTS trg_zz_cutover_sync_j2e ON n_jtd;
CREATE TRIGGER trg_zz_cutover_sync_j2e
AFTER UPDATE ON n_jtd
FOR EACH ROW EXECUTE FUNCTION trg_fn_cutover_sync_j2e();

DO $do$
DECLARE v_drift int;
BEGIN
    SELECT count(*) INTO v_drift
    FROM t_contracts c
    JOIN LATERAL (SELECT COALESCE(SUM(e.amount_settled),0) s, count(*) n,
            string_agg(e.status||':1', ',' ORDER BY e.status) st
            FROM t_contract_events e WHERE e.contract_id=c.id) ev ON true
    JOIN LATERAL (SELECT COALESCE(SUM(j.amount_settled),0) s, count(*) n,
            string_agg(j.status_code||':1', ',' ORDER BY j.status_code) st
            FROM n_jtd j WHERE j.contract_id=c.id AND j.channel_code IS NULL) jb ON true
    WHERE EXISTS (SELECT 1 FROM n_jtd j WHERE j.contract_id=c.id
            AND j.business_context->>'migration'='jtd-cutover/001')
      AND (ev.s <> jb.s OR ev.n <> jb.n OR ev.st <> jb.st);
    IF v_drift > 0 THEN
        RAISE EXCEPTION 'Phase 3 verification FAILED: % contracts still drifted', v_drift;
    END IF;
    RAISE NOTICE 'Phase 3 OK: sync bridge installed, drift = 0 across all migrated contracts';
END
$do$;
