-- ═══════════════════════════════════════════════════════════════════
-- jtd-cutover/002_signia_fk_swap.sql — Phase 2 for tenant signia
-- APPLIED LIVE 2026-09-01. Source-of-record copy.
--
-- (a) Receipt allocations: rows pointing at copied signia events get
--     jtd_id = contract_event_id (identical values by the id-preserving
--     copy). contract_event_id is KEPT until Phase 6 — rollback is
--     SET jtd_id = NULL for these rows. chk_alloc_target (jtd-nucleus/006)
--     already permits either target.
--     Live result: 3 rows swapped, Σ ₹21,300 (CN-1003 receipts 15,800;
--     CN-1004 receipt 5,500). Signia live invoice paid total unchanged
--     (₹26,900 pre and post).
-- (b) t_invoices.jtd_id added (additive, nullable, platform-wide DDL —
--     inert for other tenants) + backfill for copied events. Live result:
--     0 rows backfilled — CORRECT: all 43 event-referencing invoices
--     platform-wide belong to Hygene/Freedom/Trinity/Value Elevators
--     (they ride their own tenants' Phase 1 later); signia invoices are
--     contract-level with contract_event_id NULL.
--
-- Junction FKs (t_contract_event_assets.event_id,
-- t_service_ticket_events.event_id) deliberately UNTOUCHED: they
-- reference t_contract_events, which stays intact through Phase 5;
-- their swap belongs to Phase 6 prep after ALL tenants are copied.
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
      AND a.contract_event_id IS DISTINCT FROM a.jtd_id;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'Phase 2a verification FAILED: % rows with mismatched ids', v_bad;
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

    RAISE NOTICE 'Phase 2 OK: % allocation rows swapped to jtd_id; t_invoices.jtd_id in place and backfilled', v_swapped;
END
$do$;
