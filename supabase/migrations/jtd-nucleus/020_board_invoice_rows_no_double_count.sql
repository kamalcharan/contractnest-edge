-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/020_board_invoice_rows_no_double_count.sql  (2026-09-17)
-- A whole-invoice row appears only when the contract has NO open payment
-- job — the same money must never be on the board twice.
--
-- FOUND ON signia (owner: "I still don't see 37000"): CN-1006, CN-1008 and
-- CN-1009 (live) showed BOTH a whole-invoice row (INV-10025 ₹20,600 ·
-- INV-10052 ₹2,29,500 · INV-10051 ₹10,500) AND their instalment rows for
-- the same rupees. Those contracts were activated through the V2 path
-- (jobs, no legacy events); generate_contract_invoices links only legacy
-- events, so the jobs carry invoice_id NULL and 017's guard
-- "skip the invoice row when a job points at this invoice" never fired.
-- CN-1005's ₹6,000 balance = its ten future ₹600 instalments, same story.
-- Money In is unaffected (events + invoices only); the board's "N need
-- you" was inflated by these rows.
--
-- WHAT THIS DOES: in jtd_ops_board's invoice_rows CTE the guard becomes
-- "no open payment job on the contract at all" (channel_code IS NULL,
-- status scheduled/due/overdue/partial_payment). Since 018 every billing
-- schedule has jobs, "whole invoice with no schedule" is now exactly that.
-- Follow-up (not here): stamp invoice_id on jobs in generate_contract_
-- invoices so V2-path instalment cards show their invoice number too.
-- Applied live 2026-09-17 (batch ops-board-invoice-double-count) — source
-- of record; do not re-run. Anchor rewrite with post-check.
-- ═══════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_def    text;
  v_anchor text := $a$AND NOT EXISTS (SELECT 1 FROM public.n_jtd j WHERE j.tenant_id = p_tenant AND j.event_type_code = 'payment' AND j.invoice_id = i.id
                          AND j.status_code IN ('scheduled','due','overdue','partial_payment') AND COALESCE(j.is_active, true))$a$;
  v_new    text := $n$AND NOT EXISTS (SELECT 1 FROM public.n_jtd j WHERE j.tenant_id = p_tenant AND j.event_type_code = 'payment' AND j.channel_code IS NULL
                          AND j.contract_id = i.contract_id AND COALESCE(j.is_live, true) = p_is_live
                          AND j.status_code IN ('scheduled','due','overdue','partial_payment') AND COALESCE(j.is_active, true)) -- 020: any open job on the contract$n$;
  v_n integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'jtd_ops_board';
  IF v_def IS NULL THEN RAISE EXCEPTION '020: jtd_ops_board not found'; END IF;
  IF position('020: any open job on the contract' IN v_def) > 0 THEN RAISE NOTICE '020: already applied'; RETURN; END IF;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  IF v_n <> 1 THEN RAISE EXCEPTION '020: expected exactly one anchor, found %', v_n; END IF;
  v_def := replace(v_def, v_anchor, v_new);
  EXECUTE v_def;
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'jtd_ops_board';
  IF position('020: any open job on the contract' IN v_def) = 0 THEN RAISE EXCEPTION '020: rewrite did not land'; END IF;
END $$;
