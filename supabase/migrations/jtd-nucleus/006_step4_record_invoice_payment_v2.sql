-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/006_step4_record_invoice_payment_v2.sql
-- JTD Nucleus — Step 4 of 6 (owner-approved 2026-08-18)
--
-- V2 payment path: money settles AGAINST JOB ROWS.
--
-- V1 anatomy (read live before writing):
--   · record_invoice_payment(p_payload)            — receipt (self-healing
--     number), invoice header, STEP 4.5 auto-activate. Writes NO allocations.
--   · record_invoice_payment_with_allocations      — wraps the core, then
--     writes t_invoice_receipt_allocations rows against t_contract_events
--     and bumps event amount_settled / status (paid | partial_payment).
--     This is what the record-payment route actually calls.
--
-- V2 mirrors that shape onto jobs, by composition (V1 untouched):
--   1. PRE: jtd_materialize_jobs_from_computed — for payment-acceptance
--      contracts, STEP 4.5's auto-activation fires INSIDE the V1 core;
--      consuming computed_events first means the V1 events trigger skips
--      by its own guard → no legacy rows even on pay-before-activate.
--      (Idempotent no-op for already-materialized contracts.)
--   1b. LEGACY DELEGATION: if after materialization the contract has NO
--      job rows (pre-nucleus contract living on t_contract_events), the
--      whole call delegates to the untouched V1 wrapper
--      record_invoice_payment_with_allocations — byte-identical legacy
--      behavior, event-level settlement included. Same decision rule as
--      the Step 3 aggregate's events.source = 'jtd' | 'legacy', and the
--      response says which path ran (settlement_path) so nothing is
--      silently deceptive. This matters because the UI's record-payment
--      hook defaults ALL contracts to the V2 route.
--   2. CALL the untouched V1 core (receipt / invoice header / activate).
--   3. SETTLE jobs:
--      · client-sent event_allocations (ids are JOB ids on V2 contracts,
--        validated to sum to the payment, same rule as V1) — or
--      · FIFO by scheduled_at across open payment jobs when none sent.
--      Allocations rows carry jtd_id; job amount_settled bumps; status →
--      'paid' (covered) / 'partial_payment' (mirrors V1's exact strings
--      so every screen renders identically through the aggregate).
--
-- SCHEMA (prerequisite): t_invoice_receipt_allocations.contract_event_id
-- drops NOT NULL, replaced by CHECK (event OR jtd reference present).
-- Zero impact on V1 writers — they always supply contract_event_id.
--
-- Master: 'partial_payment' seeded for the payment event type (guarded)
-- so JTD's own vocabulary stays authoritative.
--
-- APPLIED LIVE 2026-08-18; re-applied 2026-08-19 with the legacy
-- delegation (1b) + settlement_path flag — this file is the
-- source-of-record copy of what is live.
-- ═══════════════════════════════════════════════════════════════════

-- ── A: allocations may reference a job instead of a legacy event ────
ALTER TABLE public.t_invoice_receipt_allocations
  ALTER COLUMN contract_event_id DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_alloc_target'
      AND conrelid = 'public.t_invoice_receipt_allocations'::regclass
  ) THEN
    ALTER TABLE public.t_invoice_receipt_allocations
      ADD CONSTRAINT chk_alloc_target
      CHECK (contract_event_id IS NOT NULL OR jtd_id IS NOT NULL);
  END IF;
END $$;

-- ── B: vocabulary — partial settlement state for payment jobs ───────
INSERT INTO public.n_jtd_statuses
  (id, event_type_code, code, name, status_type,
   is_initial, is_terminal, is_success, is_failure, display_order, is_active)
SELECT gen_random_uuid(), 'payment', 'partial_payment', 'Partially Paid', 'progress',
       false, false, false, false, 7, true
WHERE NOT EXISTS (
  SELECT 1 FROM public.n_jtd_statuses
  WHERE event_type_code = 'payment' AND code = 'partial_payment'
);

-- ── C: the V2 payment function ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_invoice_payment_v2(
    p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_tenant_id   uuid := (p_payload->>'tenant_id')::uuid;
    v_invoice_id  uuid := (p_payload->>'invoice_id')::uuid;
    v_contract_id uuid := (p_payload->>'contract_id')::uuid;
    v_is_live     boolean := COALESCE((p_payload->>'is_live')::boolean, true);
    v_pay_amount  numeric := (p_payload->>'amount')::numeric;

    v_has_alloc   boolean := (p_payload ? 'event_allocations'
                              AND jsonb_typeof(p_payload->'event_allocations') = 'array'
                              AND jsonb_array_length(p_payload->'event_allocations') > 0);
    v_alloc_sum   numeric := 0;
    v_alloc       jsonb;

    v_result      jsonb;
    v_receipt_id  uuid;
    v_mat         jsonb;

    v_job         RECORD;
    v_remaining   numeric;
    v_take        numeric;
    v_settled     numeric := 0;
    v_jobs_hit    integer := 0;
    v_has_jobs    boolean := false;
BEGIN
    IF v_contract_id IS NULL AND v_invoice_id IS NOT NULL THEN
        SELECT contract_id INTO v_contract_id
        FROM t_invoices WHERE id = v_invoice_id AND tenant_id = v_tenant_id;
    END IF;

    -- Same validation rule as V1's _with_allocations wrapper
    IF v_has_alloc THEN
        SELECT COALESCE(SUM((e->>'amount')::numeric), 0)
        INTO v_alloc_sum
        FROM jsonb_array_elements(p_payload->'event_allocations') e;
        IF round(v_alloc_sum, 2) <> round(v_pay_amount, 2) THEN
            RETURN jsonb_build_object('success', false,
                'error', format('Event allocations (%s) must sum to the payment amount (%s)',
                                v_alloc_sum, v_pay_amount));
        END IF;
    END IF;

    -- 1 ── PRE: consume computed_events into jobs BEFORE the V1 core can
    --     auto-activate (pay-before-activate path). Idempotent no-op when
    --     jobs already exist or there is nothing to consume.
    IF v_contract_id IS NOT NULL THEN
        v_mat := jtd_materialize_jobs_from_computed(v_contract_id, v_tenant_id);
        IF COALESCE((v_mat->>'success')::boolean, false) IS DISTINCT FROM true THEN
            RETURN v_mat;
        END IF;

        SELECT EXISTS (
            SELECT 1 FROM n_jtd
            WHERE contract_id = v_contract_id
              AND tenant_id = v_tenant_id
              AND channel_code IS NULL
        ) INTO v_has_jobs;
    END IF;

    -- 1b ── LEGACY DELEGATION: no job rows = pre-nucleus contract. The
    --     untouched V1 wrapper handles everything (receipt, invoice,
    --     auto-activate, t_contract_events settlement) exactly as the V1
    --     route would — client event_allocation ids are legacy event ids
    --     there and land on contract_event_id, never jtd_id. Same decision
    --     rule as the Step 3 aggregate's events.source flag.
    IF NOT v_has_jobs THEN
        v_result := record_invoice_payment_with_allocations(p_payload);
        RETURN v_result || jsonb_build_object('settlement_path', 'legacy');
    END IF;

    -- 2 ── the UNTOUCHED V1 core: receipt, invoice header, auto-activate
    v_result := record_invoice_payment(p_payload);
    IF COALESCE((v_result->>'success')::boolean, false) IS NOT TRUE THEN
        RETURN v_result;
    END IF;

    v_receipt_id := (v_result->'data'->>'receipt_id')::uuid;

    -- 3 ── settle JOB rows
    IF v_receipt_id IS NOT NULL AND v_contract_id IS NOT NULL THEN
        IF v_has_alloc THEN
            -- Client-directed: ids are JOB ids on a V2 contract
            FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_payload->'event_allocations')
            LOOP
                INSERT INTO t_invoice_receipt_allocations
                    (receipt_id, jtd_id, contract_event_id, invoice_id, contract_id, tenant_id, amount, is_live)
                VALUES (
                    v_receipt_id,
                    (v_alloc->>'event_id')::uuid,
                    NULL,
                    v_invoice_id,
                    v_contract_id,
                    v_tenant_id,
                    (v_alloc->>'amount')::numeric,
                    v_is_live
                );

                UPDATE n_jtd
                SET amount_settled = COALESCE(amount_settled, 0) + (v_alloc->>'amount')::numeric,
                    status_code = CASE
                        WHEN COALESCE(amount, 0) <= 0 THEN status_code
                        WHEN COALESCE(amount_settled, 0) + (v_alloc->>'amount')::numeric
                             >= COALESCE(amount, 0) - 0.005 THEN 'paid'
                        ELSE 'partial_payment'
                    END,
                    invoice_id = COALESCE(invoice_id, v_invoice_id)
                WHERE id = (v_alloc->>'event_id')::uuid
                  AND tenant_id = v_tenant_id
                  AND channel_code IS NULL;

                GET DIAGNOSTICS v_jobs_hit = ROW_COUNT;
                v_settled := v_settled + (v_alloc->>'amount')::numeric;
            END LOOP;
        ELSE
            -- FIFO: oldest open payment jobs first
            v_remaining := v_pay_amount;
            FOR v_job IN
                SELECT id, amount, COALESCE(amount_settled, 0) AS settled
                FROM n_jtd
                WHERE contract_id = v_contract_id
                  AND tenant_id = v_tenant_id
                  AND channel_code IS NULL
                  AND event_type_code = 'payment'
                  AND COALESCE(is_active, true)
                  AND amount IS NOT NULL
                  AND (amount - COALESCE(amount_settled, 0)) > 0.005
                ORDER BY scheduled_at, sequence_number, id
                FOR UPDATE
            LOOP
                EXIT WHEN v_remaining <= 0.005;
                v_take := LEAST(v_job.amount - v_job.settled, v_remaining);

                INSERT INTO t_invoice_receipt_allocations
                    (receipt_id, jtd_id, contract_event_id, invoice_id, contract_id, tenant_id, amount, is_live)
                VALUES (v_receipt_id, v_job.id, NULL, v_invoice_id, v_contract_id, v_tenant_id, v_take, v_is_live);

                UPDATE n_jtd
                SET amount_settled = COALESCE(amount_settled, 0) + v_take,
                    status_code = CASE
                        WHEN COALESCE(amount_settled, 0) + v_take >= COALESCE(amount, 0) - 0.005 THEN 'paid'
                        ELSE 'partial_payment'
                    END,
                    invoice_id = COALESCE(invoice_id, v_invoice_id)
                WHERE id = v_job.id;

                v_remaining := v_remaining - v_take;
                v_settled   := v_settled + v_take;
                v_jobs_hit  := v_jobs_hit + 1;
            END LOOP;
        END IF;
    END IF;

    RETURN v_result || jsonb_build_object(
        'settlement_path', 'jtd',
        'jobs_settled_amount', v_settled,
        'jobs_settled_count', v_jobs_hit
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to record payment (V2)',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$function$;

COMMENT ON FUNCTION public.record_invoice_payment_v2 IS
'JTD Nucleus Step 4: V2 payment — consumes computed_events into jobs first (pay-before-activate safe); contracts WITHOUT job rows delegate wholesale to the untouched V1 record_invoice_payment_with_allocations (legacy path, settlement_path=legacy); contracts WITH jobs run the untouched V1 record_invoice_payment core then settle JOB rows (allocations carry jtd_id; job status → paid / partial_payment, mirroring V1 strings; settlement_path=jtd). Client event_allocations honored (job ids) or FIFO across open payment jobs.';
