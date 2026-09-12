-- ═══════════════════════════════════════════════════════════════════
-- jtd-cutover/005_bbb_fk_swap.sql — Phase 2 for tenant BBB
-- APPLIED LIVE 2026-09-11. Source-of-record copy.
--
-- Identical body to 002_signia_fk_swap.sql: the swap is keyed on the
-- provenance tag, not the tenant, so re-running it after the BBB copy
-- (004) picks up BBB's allocation rows; signia's 3 already-swapped rows
-- are skipped by the jtd_id IS NULL guard. t_invoices.jtd_id DDL already
-- exists (from 002) — the guard makes it a no-op.
--
-- Pre-flight expectation (2026-09-11 audit): 141 BBB allocation rows
-- with contract_event_id set and jtd_id NULL; 0 invoice backfills
-- (BBB invoices are contract-level, contract_event_id NULL — linkage
-- runs the other direction via events.invoice_id, which the bridge
-- mirrors). Rollback: SET jtd_id = NULL on the swapped rows.
--
-- FIRST ATTEMPT ABORTED (by design): 002's verification predicate
-- (contract_event_id IS DISTINCT FROM jtd_id) also catches allocations
-- born on the V2 path — jtd_id set, contract_event_id legitimately NULL.
-- Three such rows exist since 2 Sep (Signia CN-1003's ₹250 + ₹350 V2
-- payments + the known ₹0 cosmetic allocation). They are correct data,
-- not mismatches; the check below now flags only rows where BOTH ids
-- are set and disagree. Nothing was written by the aborted attempt.
-- ═══════════════════════════════════════════════════════════════════

DO $do$
DECLARE
    v_swapped int;
    v_bad     int;
BEGIN
    UPDATE t_invoice_receipt_allocations a
    SET jtd_id = a.contract_event_id
    WHERE a.jtd_id IS NULL
      AND a.contract_event_id IN (
          SELECT id FROM n_jtd WHERE business_context->>'migration' = 'jtd-cutover/001');
    GET DIAGNOSTICS v_swapped = ROW_COUNT;

    SELECT count(*) INTO v_bad
    FROM t_invoice_receipt_allocations a
    JOIN n_jtd j ON j.id = a.jtd_id
    WHERE j.business_context->>'migration' = 'jtd-cutover/001'
      AND a.contract_event_id IS NOT NULL
      AND a.contract_event_id <> a.jtd_id;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'Phase 2a (BBB) verification FAILED: % rows with mismatched ids', v_bad;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 't_invoices' AND column_name = 'jtd_id') THEN
        ALTER TABLE t_invoices ADD COLUMN jtd_id uuid NULL;
        COMMENT ON COLUMN t_invoices.jtd_id IS
          'Job (n_jtd) this invoice originated from; mirrors contract_event_id post-cutover (jtd-cutover/002).';
    END IF;

    UPDATE t_invoices i
    SET jtd_id = i.contract_event_id
    WHERE i.jtd_id IS NULL
      AND i.contract_event_id IN (
          SELECT id FROM n_jtd WHERE business_context->>'migration' = 'jtd-cutover/001');

    RAISE NOTICE 'Phase 2 (BBB) OK: % allocation rows swapped to jtd_id', v_swapped;
END
$do$;
