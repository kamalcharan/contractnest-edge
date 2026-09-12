-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/008_cancel_receipt_reverses_jobs.sql
-- JTD Nucleus — the cutover build item: receipt-cancel becomes
-- job-aware (owner-queued as "next task", 2026-08-24).
--
-- THE DESYNC (audit chk10's reason to exist): cancel_invoice_receipt
-- reversed ONLY t_contract_events through the allocations join, then
-- deleted the allocations. On a jobs contract the allocations carry
-- jtd_id (contract_event_id NULL), so the events UPDATE matched
-- nothing, the DELETE erased the evidence, the invoice header
-- un-paid — and the JOB stayed 'paid' with its amount_settled intact.
-- Money screens and the schedule would permanently disagree.
--
-- FIX (additive splice, before the allocation DELETE): mirror-reverse
-- n_jtd rows via a.jtd_id = j.id with the same arithmetic the events
-- reversal uses — amount_settled decreases, status walks back
-- paid → partial_payment → scheduled, completed_at clears unless the
-- job is still fully covered by OTHER receipts, transition_note says
-- which receipt was cancelled.
--
-- LEGACY SAFETY, provable: every pre-nucleus allocation has jtd_id
-- NULL (BBB's entire book), so the new UPDATE matches zero rows there
-- — byte-identical behavior for every legacy cancel.
--
-- cancel_or_writeoff_invoice needs NO sibling change: V1 never touched
-- events or allocations there (invoice-header + history only), so job
-- contracts already get exactly the V1-parity behavior.
--
-- Method: verified-anchor prosrc substitution, marker-guarded.
-- APPLIED LIVE 2026-08-24 — this file is the source-of-record copy.
-- ═══════════════════════════════════════════════════════════════════

DO $do$
DECLARE
    v_def TEXT;
    v_anchor TEXT := 'DELETE FROM t_invoice_receipt_allocations WHERE receipt_id = p_receipt_id;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'cancel_invoice_receipt' AND pronamespace = 'public'::regnamespace;

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'cancel_invoice_receipt not found';
    END IF;

    IF position('JTD Nucleus 008' in v_def) > 0 THEN
        RAISE NOTICE 'cancel_invoice_receipt already job-aware — skipping';
        RETURN;
    END IF;

    IF (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 THEN
        RAISE EXCEPTION 'anchor not found exactly once — live function drifted; aborting';
    END IF;

    v_def := replace(v_def, v_anchor,
        '-- JTD Nucleus 008: reverse JOB rows settled by this receipt.' || E'\n' ||
        '  -- Jobs-era allocations carry jtd_id (contract_event_id NULL); every' || E'\n' ||
        '  -- legacy allocation has jtd_id NULL, so this matches zero rows on' || E'\n' ||
        '  -- pre-nucleus contracts — provably byte-identical legacy behavior.' || E'\n' ||
        '  UPDATE n_jtd j' || E'\n' ||
        '  SET amount_settled = GREATEST(0, COALESCE(j.amount_settled, 0) - a.amount),' || E'\n' ||
        '      status_code = CASE' || E'\n' ||
        '        WHEN GREATEST(0, COALESCE(j.amount_settled, 0) - a.amount) <= 0.005 THEN ''scheduled''' || E'\n' ||
        '        WHEN GREATEST(0, COALESCE(j.amount_settled, 0) - a.amount) >= COALESCE(j.amount, 0) - 0.005 THEN ''paid''' || E'\n' ||
        '        ELSE ''partial_payment''' || E'\n' ||
        '      END,' || E'\n' ||
        '      completed_at = CASE' || E'\n' ||
        '        WHEN GREATEST(0, COALESCE(j.amount_settled, 0) - a.amount) >= COALESCE(j.amount, 0) - 0.005 THEN j.completed_at' || E'\n' ||
        '        ELSE NULL' || E'\n' ||
        '      END,' || E'\n' ||
        '      transition_note = ''receipt '' || v_receipt.receipt_number || '' cancelled'' ||' || E'\n' ||
        '        CASE WHEN p_reason IS NOT NULL THEN '' — '' || p_reason ELSE '''' END,' || E'\n' ||
        '      updated_at = now()' || E'\n' ||
        '  FROM t_invoice_receipt_allocations a' || E'\n' ||
        '  WHERE a.receipt_id = p_receipt_id AND a.jtd_id = j.id;' || E'\n\n' ||
        '  ' || v_anchor);

    EXECUTE v_def;

    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'cancel_invoice_receipt' AND pronamespace = 'public'::regnamespace;
    IF position('JTD Nucleus 008' in v_def) = 0 THEN
        RAISE EXCEPTION 'post-check FAILED: job reversal not present after apply';
    END IF;
    RAISE NOTICE 'cancel_invoice_receipt: job reversal installed and verified';
END
$do$;
