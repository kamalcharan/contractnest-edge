-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/007_step5fix_job_completion_stamp.sql
-- JTD Nucleus — Step 5 fix (owner-approved "fix it", 2026-08-20)
--
-- FOUND while walking CN-1005's raw n_jtd rows with the owner:
--   · a payment job that reached 'paid' kept completed_at = NULL —
--     but paid IS the job's completion; the timestamp belongs on it.
--   · transition_note on the two paid rows still read "JTD Nucleus
--     005: repaired — dispatch sweeper..." — the stale note from the
--     sweeper repair. The payment flipped the status but never
--     refreshed the note, leaving a misleading trail.
--
-- FIX (CREATE OR REPLACE record_invoice_payment_v2, same body as
-- migration 006 plus exactly this):
--   · job flips to 'paid'            → completed_at = now(),
--     transition_note = 'settled by receipt <number>'
--   · job flips to 'partial_payment' → transition_note =
--     'partially settled by receipt <number>' (not completed)
--   The receipt number comes from the V1 core's own response
--   (fallback: receipt id). Nothing else in the function changes.
--
-- REPAIR (one-time): any already-paid job with completed_at NULL gets
-- completed_at = its status_changed_at (the actual settlement moment)
-- and an honest note. Today that is exactly CN-1005's two rows.
--
-- Deliberately NOT touched (owner-visible decision, not an oversight):
--   · jtd_number / status_id — dormant on ALL 522 n_jtd rows since
--     the December seed (verified live: zero rows populated, no
--     generator exists). Adopt-or-drop is a Step 6 cutover decision.
--   · executed_at on payment jobs — nothing "dispatches" a payment
--     job; money arriving completes it. Stays NULL by design.
--
-- APPLIED LIVE 2026-08-20 — this file is the source-of-record copy.
-- ═══════════════════════════════════════════════════════════════════

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
    v_receipt_no  text;
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
    v_receipt_no := COALESCE(v_result->'data'->>'receipt_number', v_receipt_id::text);

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
                    -- paid IS the job's completion — stamp it (007)
                    completed_at = CASE
                        WHEN COALESCE(amount, 0) > 0
                         AND COALESCE(amount_settled, 0) + (v_alloc->>'amount')::numeric
                             >= COALESCE(amount, 0) - 0.005 THEN now()
                        ELSE completed_at
                    END,
                    transition_note = CASE
                        WHEN COALESCE(amount, 0) <= 0 THEN transition_note
                        WHEN COALESCE(amount_settled, 0) + (v_alloc->>'amount')::numeric
                             >= COALESCE(amount, 0) - 0.005
                            THEN 'settled by receipt ' || v_receipt_no
                        ELSE 'partially settled by receipt ' || v_receipt_no
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
                    -- paid IS the job's completion — stamp it (007)
                    completed_at = CASE
                        WHEN COALESCE(amount_settled, 0) + v_take >= COALESCE(amount, 0) - 0.005 THEN now()
                        ELSE completed_at
                    END,
                    transition_note = CASE
                        WHEN COALESCE(amount_settled, 0) + v_take >= COALESCE(amount, 0) - 0.005
                            THEN 'settled by receipt ' || v_receipt_no
                        ELSE 'partially settled by receipt ' || v_receipt_no
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
'JTD Nucleus Step 4 (+007 completion stamp): V2 payment — consumes computed_events into jobs first (pay-before-activate safe); contracts WITHOUT job rows delegate wholesale to the untouched V1 record_invoice_payment_with_allocations (settlement_path=legacy); contracts WITH jobs run the untouched V1 record_invoice_payment core then settle JOB rows: allocations carry jtd_id, job status → paid (stamps completed_at + settled-by-receipt note) / partial_payment (note only), mirroring V1 status strings. Client event_allocations honored (job ids) or FIFO across open payment jobs.';

-- ── one-time repair: already-paid jobs missing their completion stamp.
-- completed_at = the row's own status_changed_at (the real settlement
-- moment, 2026-08-20 08:18 IST+ for CN-1005's two rows), note made
-- honest. Idempotent: the WHERE excludes already-stamped rows.
UPDATE public.n_jtd j
SET completed_at    = j.status_changed_at,
    transition_note = 'settled by receipt ' || COALESCE(
        (SELECT r.receipt_number
         FROM t_invoice_receipt_allocations a
         JOIN t_invoice_receipts r ON r.id = a.receipt_id
         WHERE a.jtd_id = j.id
         ORDER BY r.created_at DESC
         LIMIT 1),
        '(unknown)')
WHERE j.channel_code IS NULL
  AND j.contract_id IS NOT NULL
  AND j.status_code = 'paid'
  AND j.completed_at IS NULL;
