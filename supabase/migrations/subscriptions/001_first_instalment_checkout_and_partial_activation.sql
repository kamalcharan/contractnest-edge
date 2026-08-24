-- ═══════════════════════════════════════════════════════════════════
-- subscriptions/001_first_instalment_checkout_and_partial_activation.sql
-- Plan-subscription payment fixes (owner-approved "go ahead fix",
-- 2026-08-20). Companion to payment-gateway edge v10 (the isLive
-- threading fix — without it no gateway payment verifies at all).
--
-- TWO CHANGES, both verified-anchor prosrc substitutions (abort if the
-- live function drifted; post-check that each edit landed):
--
-- B ── subscribe_tenant_to_plan returns due_now
--   The buy flow charged the response's invoice_amount — the single
--   full-term invoice (₹23,996 on the quarterly plan) — even though the
--   contract itself stores the 4 × ₹5,999 schedule and the Subscription
--   resume page already asks for one quarter. due_now = the FIRST
--   billing event's amount from that same schedule. The invoice remains
--   the full term (platform pattern: one invoice, paid down over time —
--   BBB works identically); only the amount COLLECTED at checkout
--   changes. UI companion: pricing-plans charges due_now ?? invoice_amount.
--
-- C ── record_invoice_payment activates on FIRST payment
--   STEP 4.5 required the invoice status to reach 'paid' AND zero unpaid
--   invoices — so an instalment against a full-term invoice could NEVER
--   activate the plan (invoice lands 'partially_paid', gate never fires).
--   Owner rule (verbatim, 2026-08-20): "in any of the contract …
--   contract is still valid on partial payments." The gate becomes: a
--   pending_acceptance contract with acceptance_method payment/manual
--   activates on its FIRST successful payment, partial included.
--   Platform-wide for every payment-acceptance contract (plan
--   subscriptions, CNAK public payments, EMI) — that is the point of the
--   rule. BBB unaffected: all its contracts are already active.
--
-- APPLIED LIVE 2026-08-20 — this file is the source-of-record copy.
-- ═══════════════════════════════════════════════════════════════════

-- ── B: subscribe_tenant_to_plan gains due_now ───────────────────────
DO $do$
DECLARE
    v_def TEXT;
    v_anchor_decl   TEXT := 'v_invoice_currency TEXT;';
    v_anchor_select TEXT := 'ORDER BY created_at ASC' || E'\n' || '    LIMIT 1;';
    v_anchor_return TEXT := '''requires_payment'', COALESCE(v_template.total, 0) > 0';
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'subscribe_tenant_to_plan' AND pronamespace = 'public'::regnamespace;

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'subscribe_tenant_to_plan not found';
    END IF;

    IF position('due_now' in v_def) > 0 THEN
        RAISE NOTICE 'subscribe_tenant_to_plan already returns due_now — skipping';
        RETURN;
    END IF;

    IF (length(v_def) - length(replace(v_def, v_anchor_decl, ''))) / length(v_anchor_decl) <> 1 THEN
        RAISE EXCEPTION 'declare anchor not found exactly once — live function drifted; aborting';
    END IF;
    IF (length(v_def) - length(replace(v_def, v_anchor_select, ''))) / length(v_anchor_select) <> 1 THEN
        RAISE EXCEPTION 'invoice-select anchor not found exactly once — live function drifted; aborting';
    END IF;
    IF (length(v_def) - length(replace(v_def, v_anchor_return, ''))) / length(v_anchor_return) <> 1 THEN
        RAISE EXCEPTION 'return anchor not found exactly once — live function drifted; aborting';
    END IF;

    v_def := replace(v_def, v_anchor_decl,
        v_anchor_decl || E'\n' || '    v_due_now          NUMERIC;');

    v_def := replace(v_def, v_anchor_select,
        v_anchor_select || E'\n\n' ||
        '    -- Owner rule (2026-08-20): checkout collects the FIRST INSTALMENT,' || E'\n' ||
        '    -- not the whole term. The invoice stays the full amount; due_now is' || E'\n' ||
        '    -- what the buy flow charges — from the same schedule the contract' || E'\n' ||
        '    -- stores (the resume page''s billing-overview already behaves this way).' || E'\n' ||
        '    SELECT (e->>''amount'')::NUMERIC INTO v_due_now' || E'\n' ||
        '    FROM jsonb_array_elements(COALESCE(v_events, ''[]''::jsonb)) e' || E'\n' ||
        '    WHERE COALESCE(e->>''event_type'', ''billing'') = ''billing''' || E'\n' ||
        '    ORDER BY (e->>''scheduled_date'')::timestamptz ASC NULLS LAST' || E'\n' ||
        '    LIMIT 1;');

    v_def := replace(v_def, v_anchor_return,
        '''due_now'',          COALESCE(v_due_now, v_invoice_amount),' || E'\n' ||
        '        ' || v_anchor_return);

    EXECUTE v_def;

    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'subscribe_tenant_to_plan' AND pronamespace = 'public'::regnamespace;
    IF position('due_now' in v_def) = 0 THEN
        RAISE EXCEPTION 'post-check FAILED: due_now not present after apply';
    END IF;
    RAISE NOTICE 'subscribe_tenant_to_plan: due_now installed and verified';
END
$do$;

-- ── C: record_invoice_payment activates on first payment ────────────
DO $do$
DECLARE
    v_def TEXT;
    v_anchor_hdr  TEXT := 'STEP 4.5: Auto-activate contract on full payment';
    v_anchor_if   TEXT := 'IF v_new_status = ''paid'' AND v_contract_id IS NOT NULL THEN';
    v_anchor_gate TEXT := 'IF v_unpaid_count = 0 THEN';
    v_anchor_note TEXT := '''Auto-activated: all invoices paid''';
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'record_invoice_payment' AND pronamespace = 'public'::regnamespace;

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'record_invoice_payment not found';
    END IF;

    IF position('partial included' in v_def) > 0 THEN
        RAISE NOTICE 'record_invoice_payment already activates on first payment — skipping';
        RETURN;
    END IF;

    IF (length(v_def) - length(replace(v_def, v_anchor_hdr, ''))) / length(v_anchor_hdr) <> 1 THEN
        RAISE EXCEPTION 'header anchor not found exactly once — live function drifted; aborting';
    END IF;
    IF (length(v_def) - length(replace(v_def, v_anchor_if, ''))) / length(v_anchor_if) <> 1 THEN
        RAISE EXCEPTION 'IF anchor not found exactly once — live function drifted; aborting';
    END IF;
    IF (length(v_def) - length(replace(v_def, v_anchor_gate, ''))) / length(v_anchor_gate) <> 1 THEN
        RAISE EXCEPTION 'gate anchor not found exactly once — live function drifted; aborting';
    END IF;
    IF (length(v_def) - length(replace(v_def, v_anchor_note, ''))) / length(v_anchor_note) <> 1 THEN
        RAISE EXCEPTION 'note anchor not found exactly once — live function drifted; aborting';
    END IF;

    v_def := replace(v_def, v_anchor_hdr,
        'STEP 4.5: Auto-activate contract on FIRST payment, partial included' || E'\n' ||
        '    --   (owner rule 2026-08-20: "a contract is still valid on partial' || E'\n' ||
        '    --   payments" — an instalment against a full-term invoice activates;' || E'\n' ||
        '    --   previously the gate required the invoice fully paid, so a' || E'\n' ||
        '    --   quarterly plan instalment could never activate the plan)');

    v_def := replace(v_def, v_anchor_if,
        'IF v_new_status IN (''paid'', ''partially_paid'') AND v_contract_id IS NOT NULL THEN');

    v_def := replace(v_def, v_anchor_gate,
        'IF TRUE THEN  -- was: v_unpaid_count = 0 (full-payment gate, removed per owner rule)');

    v_def := replace(v_def, v_anchor_note,
        '''Auto-activated: payment received''');

    EXECUTE v_def;

    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'record_invoice_payment' AND pronamespace = 'public'::regnamespace;
    IF position('partial included' in v_def) = 0
       OR position('IN (''paid'', ''partially_paid'')' in v_def) = 0 THEN
        RAISE EXCEPTION 'post-check FAILED: first-payment activation not present after apply';
    END IF;
    RAISE NOTICE 'record_invoice_payment: first-payment activation installed and verified';
END
$do$;
