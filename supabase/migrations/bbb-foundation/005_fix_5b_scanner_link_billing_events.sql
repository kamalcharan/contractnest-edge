-- Migration: bbb-foundation/005_fix_5b_scanner_link_billing_events.sql
-- ============================================================================
-- Purpose: Close "5b" double-billing.
--
-- The billing scanner (run_contract_event_scanner, last defined in
-- operations-loop/017_vani_rules_v1.sql) links a due billing event to the
-- contract-level lump invoice created by generate_contract_invoices ONLY when
--     i.total_amount = v_row.amount
-- i.e. only when the lump invoice equals the single event's amount. That holds
-- for a single-event contract, but for a multi-event contract (e.g. a BBB
-- membership: lump = 25,500 vs events of 1,384.62 / 7,500) it never matches, so
-- the scanner falls through and MINTS a duplicate per-event draft invoice. The
-- contract then shows the lump invoice PLUS per-event drafts, inflating the
-- balance above the contract value.
--
-- Fix: remove the amount-equality condition so ANY billing event links to the
-- existing contract-level invoice (contract_event_id IS NULL) instead of
-- duplicating. Result: one invoice per contract, with its billing events linked
-- underneath as they come due (payment-schedule model). Backward compatible:
-- contracts with no contract-level invoice still get per-event drafts as before.
--
-- Applied drift-proof: rewrites the currently-deployed function with just that
-- one condition removed, so it does not depend on any exact prior definition.
-- ============================================================================

DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE p.proname = 'run_contract_event_scanner'
    AND n.nspname = 'public';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'run_contract_event_scanner not found — nothing to patch';
  END IF;

  -- Remove the over-narrow guard line (leading whitespace + the AND clause).
  -- The condition appears exactly once, inside STEP 4's link lookup.
  v_def := regexp_replace(v_def, '\s*AND i\.total_amount = v_row\.amount', '', 'g');

  EXECUTE v_def;
END $$;
