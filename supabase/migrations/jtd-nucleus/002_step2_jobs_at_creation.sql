-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/002_step2_jobs_at_creation.sql
-- JTD Nucleus — Step 2 of 6 (owner-approved 2026-08-18)
--
-- PURPOSE (Framework §1, Sprint 2 exit criterion, verbatim): jobs are
-- born WITH the contract, in the same transaction —
--   "When a contract is created with 12 monthly services, JTD
--    automatically creates 12 service_visit records."
--
-- WHAT THIS DOES:
--  A) Seeds n_jtd_statuses with the job lifecycles for event types
--     'service_visit' and 'payment' — vocabulary taken from the REAL
--     statuses the 1,840 live t_contract_events rows use (queried
--     2026-08-18: scheduled/paid/completed/due/overdue/bad_debt), not
--     invented. Guarded inserts (NOT EXISTS) — re-runnable.
--  B) Splices ONE block into the live create_contract_transaction_v2
--     (verified-anchor prosrc substitution — never retyped; aborts if
--     the live function drifted; post-check confirms it landed):
--       · one n_jtd job row per computed event —
--           service leg → event_type 'service_visit' / source 'service_scheduled'
--           billing leg → event_type 'payment'       / source 'payment_scheduled'
--         channel_code NULL (a job, not a message), contract_id set,
--         status 'scheduled', chk_performer-safe performer fields
--       · computed_events CONSUMED (set NULL on the contract row) —
--         the V1 activation materializer then no-ops benignly
--         ("No computed_events", zero side effects), so a V2 contract
--         never grows t_contract_events rows. Single truth.
--
-- WHAT IT DOES NOT TOUCH: any V1 function, trigger, reader, screen.
-- Dispatch triggers ignore job rows structurally (they act only on
-- status_code='created'; jobs are born 'scheduled').
--
-- GOLDEN RULE: create_contract_transaction_v2 is the V2 workbench —
-- nothing deployed calls it; production paths unchanged.
-- APPLIED LIVE 2026-08-18 — this file is the source-of-record copy.
-- Idempotent: skips if the Step-2 marker is already present.
-- ═══════════════════════════════════════════════════════════════════

-- ── A: job lifecycles into the statuses master ──────────────────────
DO $seed$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            -- event_type_code, code, name, status_type, is_initial, is_terminal, is_success, is_failure, display_order
            ('service_visit', 'scheduled', 'Scheduled', 'initial',  true,  false, false, false, 1),
            ('service_visit', 'due',       'Due',       'progress', false, false, false, false, 2),
            ('service_visit', 'completed', 'Completed', 'success',  false, true,  true,  false, 3),
            ('service_visit', 'overdue',   'Overdue',   'progress', false, false, false, false, 4),
            ('service_visit', 'cancelled', 'Cancelled', 'terminal', false, true,  false, false, 5),
            ('payment',       'scheduled', 'Scheduled', 'initial',  true,  false, false, false, 1),
            ('payment',       'due',       'Due',       'progress', false, false, false, false, 2),
            ('payment',       'paid',      'Paid',      'success',  false, true,  true,  false, 3),
            ('payment',       'overdue',   'Overdue',   'progress', false, false, false, false, 4),
            ('payment',       'bad_debt',  'Bad Debt',  'failure',  false, true,  false, true,  5),
            ('payment',       'cancelled', 'Cancelled', 'terminal', false, true,  false, false, 6)
        ) AS v(event_type_code, code, name, status_type, is_initial, is_terminal, is_success, is_failure, display_order)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM public.n_jtd_statuses s
            WHERE s.event_type_code = r.event_type_code AND s.code = r.code
        ) THEN
            INSERT INTO public.n_jtd_statuses
                (id, event_type_code, code, name, status_type,
                 is_initial, is_terminal, is_success, is_failure,
                 display_order, is_active)
            VALUES
                (gen_random_uuid(), r.event_type_code, r.code, r.name, r.status_type,
                 r.is_initial, r.is_terminal, r.is_success, r.is_failure,
                 r.display_order, true);
        END IF;
    END LOOP;
END
$seed$;

-- ── B: splice the job-writing block into the live V2 function ───────
DO $do$
DECLARE
    v_def    TEXT;
    v_anchor TEXT;
    v_insert TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'create_contract_transaction_v2'
      AND pronamespace = 'public'::regnamespace;

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'create_contract_transaction_v2 not found — nothing to modify';
    END IF;

    IF position('JTD Nucleus Step 2' in v_def) > 0 THEN
        RAISE NOTICE 'Step 2 block already present — skipping';
        RETURN;
    END IF;

    -- Unique anchor: the invoice-generation branch (its twin block for
    -- events shares the IF line; the PERFORM continuation disambiguates)
    v_anchor := 'IF v_initial_status = ''active'' AND v_record_type = ''contract'' THEN' || E'\n' ||
                '        PERFORM generate_contract_invoices';

    IF (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 THEN
        RAISE EXCEPTION 'anchor not found exactly once — live function has drifted; aborting (nothing changed)';
    END IF;

    v_insert := $ins$-- ═══ JTD Nucleus Step 2 (2026-08-18): jobs born WITH the contract ═══
    -- Framework §1: one job row per commitment, in THIS transaction.
    -- channel_code NULL = a job, not a message. computed_events is
    -- CONSUMED here, so the V1 activation materializer no-ops benignly
    -- and a V2 contract never grows t_contract_events rows.
    IF v_record_type = 'contract'
       AND p_payload ? 'computed_events'
       AND jsonb_typeof(p_payload->'computed_events') = 'array'
       AND jsonb_array_length(p_payload->'computed_events') > 0 THEN

        INSERT INTO n_jtd (
            tenant_id, event_type_code, source_type_code, channel_code,
            source_id, source_ref,
            contract_id, block_id, block_name, category_id,
            billing_sub_type, billing_cycle_label,
            sequence_number, total_occurrences,
            scheduled_at, original_date,
            amount, currency, assigned_to, assigned_to_name, audience,
            status_code, performed_by_type, performed_by_id,
            is_live, created_by, updated_by
        )
        SELECT
            p_tenant_id,
            CASE WHEN ev->>'event_type' = 'service' THEN 'service_visit' ELSE 'payment' END,
            CASE WHEN ev->>'event_type' = 'service' THEN 'service_scheduled' ELSE 'payment_scheduled' END,
            NULL,
            v_contract_id,
            (SELECT c2.contract_number FROM t_contracts c2 WHERE c2.id = v_contract_id),
            v_contract_id,
            ev->>'block_id', ev->>'block_name', ev->>'category_id',
            ev->>'billing_sub_type', ev->>'billing_cycle_label',
            NULLIF(ev->>'sequence_number','')::INTEGER,
            NULLIF(ev->>'total_occurrences','')::INTEGER,
            (ev->>'scheduled_date')::TIMESTAMPTZ,
            (ev->>'scheduled_date')::TIMESTAMPTZ,
            NULLIF(ev->>'amount','')::NUMERIC,
            COALESCE(ev->>'currency', 'INR'),
            NULLIF(ev->>'assigned_to','')::UUID,
            ev->>'assigned_to_name',
            ev->>'audience',
            'scheduled',
            CASE WHEN v_created_by IS NOT NULL THEN 'user' ELSE 'system' END,
            v_created_by,
            p_is_live, v_created_by, v_created_by
        FROM jsonb_array_elements(p_payload->'computed_events') ev;

        UPDATE t_contracts
        SET computed_events = NULL
        WHERE id = v_contract_id AND tenant_id = p_tenant_id;
    END IF;

    $ins$;

    v_def := replace(v_def, v_anchor, v_insert || v_anchor);
    EXECUTE v_def;

    -- Post-apply verification (a silent no-op is this technique's failure mode)
    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'create_contract_transaction_v2'
      AND pronamespace = 'public'::regnamespace;

    IF position('JTD Nucleus Step 2' in v_def) = 0 THEN
        RAISE EXCEPTION 'post-check FAILED: Step 2 block not present after apply';
    END IF;

    RAISE NOTICE 'Step 2 job-writing block installed and verified';
END
$do$;

COMMENT ON FUNCTION public.create_contract_transaction_v2 IS
'V2 contract creation (JTD Nucleus): explicit seller/buyer, unconditional CNAK grant, idempotency, cadence backstop, and (Step 2, 2026-08-18) job rows born in the create transaction — one n_jtd service_visit/payment row per commitment, channel NULL, computed_events consumed. Framework §1.';
