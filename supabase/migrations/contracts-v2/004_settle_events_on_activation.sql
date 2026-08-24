-- ═══════════════════════════════════════════════════════════════════
-- contracts-v2/004_settle_events_on_activation.sql
-- JTD Nucleus initiative — owner-approved live-function fix (2026-08-15)
--
-- BUG (found on CN-1003): payment-acceptance contracts pay BEFORE
-- activation. record_invoice_payment records the receipt, marks the
-- invoice paid, then auto-activates — and the activation trigger
-- materializes billing events AFTER the money already landed. The
-- events are born with amount_settled=0 and no receipt allocations,
-- so the event layer says "outstanding" while the invoice says "paid"
-- (two contradictory payment truths; UI shows RECORD PAYMENT on money
-- already collected).
--
-- FIX: after materialization succeeds, settle the newly-born billing
-- events against money already received on this contract — FIFO by
-- receipt date across events by scheduled date, writing REAL
-- t_invoice_receipt_allocations rows (the per-commitment payment
-- truth), updating amount_settled, and flipping fully-covered events
-- to 'paid'. Placed here (materialization) rather than in
-- record_invoice_payment so EVERY pay-first path is covered: auto-
-- activate, manual activation after payment, public CNAK payment.
--
-- Safety: no-op when there are no receipts (normal activations) or no
-- unallocated money. Already-active contracts (BBB) never re-enter
-- this function. Base source: live prosrc pulled 2026-08-15 (not
-- retyped from migration files).
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.process_contract_events_from_computed(p_contract_id uuid, p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_contract      RECORD;
    v_result        JSONB;
    v_existing      INT;
    -- STEP 2.5 (settlement of pre-received money)
    v_receipt       RECORD;
    v_event         RECORD;
    v_remaining     NUMERIC;
    v_take          NUMERIC;
    v_settled_total NUMERIC := 0;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Fetch contract + computed_events
    -- ═══════════════════════════════════════════
    SELECT id, tenant_id, computed_events, created_by, is_live
    INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND tenant_id = p_tenant_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found',
            'contract_id', p_contract_id
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Idempotency — skip if no computed_events
    -- ═══════════════════════════════════════════
    IF v_contract.computed_events IS NULL OR jsonb_array_length(v_contract.computed_events) = 0 THEN
        -- Check if events already exist (previously processed)
        SELECT COUNT(*) INTO v_existing
        FROM t_contract_events
        WHERE contract_id = p_contract_id
          AND tenant_id = p_tenant_id
          AND is_active = true;

        IF v_existing > 0 THEN
            RETURN jsonb_build_object(
                'success', true,
                'data', jsonb_build_object(
                    'contract_id', p_contract_id,
                    'message', 'Events already exist — skipped',
                    'existing_count', v_existing
                )
            );
        ELSE
            RETURN jsonb_build_object(
                'success', false,
                'error', 'No computed_events found on contract',
                'contract_id', p_contract_id
            );
        END IF;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Delegate to insert_contract_events_batch
    -- ═══════════════════════════════════════════
    v_result := insert_contract_events_batch(
        p_tenant_id     := v_contract.tenant_id,
        p_contract_id   := p_contract_id,
        p_events        := v_contract.computed_events,
        p_created_by    := v_contract.created_by,
        p_is_live       := v_contract.is_live,
        p_idempotency_key := 'pgmq_events_' || p_contract_id::TEXT
    );

    IF (v_result->>'success')::BOOLEAN THEN
        -- ═══════════════════════════════════════════
        -- STEP 2.5: Settle newly-born billing events against money
        -- already received on this contract (pay-before-activate flows).
        -- FIFO: receipts by created_at, events by scheduled_date. Each
        -- allocation is a real t_invoice_receipt_allocations row — the
        -- per-commitment payment truth — never exceeding either the
        -- receipt's unallocated remainder or the event's open amount.
        -- ═══════════════════════════════════════════
        FOR v_receipt IN
            SELECT r.id, r.invoice_id,
                   r.amount - COALESCE((
                       SELECT SUM(a.amount) FROM t_invoice_receipt_allocations a
                       WHERE a.receipt_id = r.id
                   ), 0) AS unallocated
            FROM t_invoice_receipts r
            WHERE r.contract_id = p_contract_id
              AND r.tenant_id = p_tenant_id
              AND r.is_active = true
            ORDER BY r.created_at, r.id
        LOOP
            CONTINUE WHEN v_receipt.unallocated <= 0;
            v_remaining := v_receipt.unallocated;

            FOR v_event IN
                SELECT e.id, e.amount, COALESCE(e.amount_settled, 0) AS settled, e.invoice_id
                FROM t_contract_events e
                WHERE e.contract_id = p_contract_id
                  AND e.tenant_id = p_tenant_id
                  AND e.event_type = 'billing'
                  AND e.is_active = true
                  AND e.amount IS NOT NULL
                  AND (e.amount - COALESCE(e.amount_settled, 0)) > 0
                ORDER BY e.scheduled_date, e.created_at, e.id
                FOR UPDATE
            LOOP
                EXIT WHEN v_remaining <= 0;
                v_take := LEAST(v_event.amount - v_event.settled, v_remaining);
                CONTINUE WHEN v_take <= 0;

                INSERT INTO t_invoice_receipt_allocations (
                    receipt_id, contract_event_id, invoice_id,
                    contract_id, tenant_id, amount, is_live
                ) VALUES (
                    v_receipt.id, v_event.id,
                    COALESCE(v_event.invoice_id, v_receipt.invoice_id),
                    p_contract_id, p_tenant_id, v_take, v_contract.is_live
                );

                UPDATE t_contract_events
                SET amount_settled = COALESCE(amount_settled, 0) + v_take,
                    status = CASE WHEN COALESCE(amount_settled, 0) + v_take >= amount
                                  THEN 'paid' ELSE status END,
                    invoice_id = COALESCE(invoice_id, v_receipt.invoice_id)
                WHERE id = v_event.id;

                v_remaining := v_remaining - v_take;
                v_settled_total := v_settled_total + v_take;
            END LOOP;
        END LOOP;

        -- ═══════════════════════════════════════════
        -- STEP 3: Clean up — NULL out computed_events
        -- ═══════════════════════════════════════════
        UPDATE t_contracts
        SET computed_events = NULL
        WHERE id = p_contract_id
          AND tenant_id = p_tenant_id;

        IF v_settled_total > 0 THEN
            v_result := v_result || jsonb_build_object('settled_from_prior_receipts', v_settled_total);
        END IF;
    END IF;

    RETURN v_result;

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to process computed events',
        'details', SQLERRM,
        'error_code', SQLSTATE,
        'contract_id', p_contract_id
    );
END;
$function$;

COMMENT ON FUNCTION public.process_contract_events_from_computed IS
'Materializes computed_events into t_contract_events at activation, then settles newly-born billing events against receipts already received on the contract (pay-before-activate flows) via real t_invoice_receipt_allocations rows. Modified 2026-08-15 (owner-approved): STEP 2.5 settlement added.';
