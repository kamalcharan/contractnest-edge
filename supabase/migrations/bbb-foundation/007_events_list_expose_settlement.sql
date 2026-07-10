-- Migration: bbb-foundation/007_events_list_expose_settlement.sql
-- ============================================================================
-- Expose amount_settled and invoice_id in the contract-events list RPC so the
-- Record Payment dialog can show which billing events are already settled and
-- which invoice they belong to (event-level receipts, P1/P2).
--
-- get_contract_events_list builds each row via a dynamic jsonb_build_object with
-- an explicit field list; add the two new fields right after 'amount'. Applied
-- drift-proof (rewrites the deployed function with the fields inserted).
-- ============================================================================

DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def
  FROM pg_proc WHERE proname = 'get_contract_events_list';
  IF v_def IS NULL THEN
    RAISE EXCEPTION 'get_contract_events_list not found';
  END IF;

  IF v_def LIKE '%amount_settled%' THEN
    RETURN; -- already patched
  END IF;

  v_def := replace(
    v_def,
    '''''amount'''', ce.amount,',
    '''''amount'''', ce.amount, ''''amount_settled'''', ce.amount_settled, ''''invoice_id'''', ce.invoice_id,'
  );

  EXECUTE v_def;
END $$;
