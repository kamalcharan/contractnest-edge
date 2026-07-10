-- Migration: bbb-foundation/008_billing_status_money_driven.sql
-- ============================================================================
-- Money-driven billing event status.
--
-- Problem: a billing event's lifecycle `status` column was decoupled from the
-- money. Recording a receipt bumped `amount_settled` but never advanced the
-- status, so fully-paid billing events kept showing "Due" on the timeline card.
--
-- Fix: when a receipt is allocated to billing events, advance each event's
-- status from the settlement:
--   * fully settled  (amount_settled >= amount)  -> 'paid'
--   * partly settled (0 < amount_settled < amount) -> 'partial_payment'
-- Events with no amount are left untouched.
--
-- Safe against the scanner: run_contract_event_scanner's ->due / ->overdue
-- steps are guarded to `status IN ('scheduled','due')`, so they never overwrite
-- a paid / partial_payment event.
--
-- Also backfills any already-fully-settled billing event whose status is still
-- stale (e.g. events settled before this change shipped).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.record_invoice_payment_with_allocations(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_result     jsonb;
  v_receipt_id uuid;
  v_tenant_id  uuid := (p_payload->>'tenant_id')::uuid;
  v_alloc      jsonb;
  v_alloc_sum  numeric := 0;
  v_pay_amount numeric := (p_payload->>'amount')::numeric;
  v_has_alloc  boolean := (p_payload ? 'event_allocations'
                           AND jsonb_typeof(p_payload->'event_allocations') = 'array'
                           AND jsonb_array_length(p_payload->'event_allocations') > 0);
BEGIN
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

  v_result := public.record_invoice_payment(p_payload);
  IF COALESCE((v_result->>'success')::boolean, false) IS NOT TRUE THEN
    RETURN v_result;
  END IF;

  v_receipt_id := (v_result->'data'->>'receipt_id')::uuid;

  IF v_receipt_id IS NOT NULL AND v_has_alloc THEN
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_payload->'event_allocations')
    LOOP
      INSERT INTO public.t_invoice_receipt_allocations
        (receipt_id, contract_event_id, invoice_id, contract_id, tenant_id, amount, is_live)
      VALUES (
        v_receipt_id,
        (v_alloc->>'event_id')::uuid,
        (p_payload->>'invoice_id')::uuid,
        (SELECT contract_id FROM public.t_contract_events WHERE id = (v_alloc->>'event_id')::uuid),
        v_tenant_id,
        (v_alloc->>'amount')::numeric,
        COALESCE((p_payload->>'is_live')::boolean, true)
      );

      -- Bump settlement and advance the billing event's lifecycle status to
      -- reflect the money received (money-driven status). Fully settled -> paid,
      -- partially settled -> partial_payment. Events with no amount are left as-is.
      UPDATE public.t_contract_events
      SET amount_settled = COALESCE(amount_settled, 0) + (v_alloc->>'amount')::numeric,
          status = CASE
            WHEN COALESCE(amount, 0) <= 0 THEN status
            WHEN COALESCE(amount_settled, 0) + (v_alloc->>'amount')::numeric
                 >= COALESCE(amount, 0) - 0.005 THEN 'paid'
            ELSE 'partial_payment'
          END,
          version = version + 1,
          updated_at = now()
      WHERE id = (v_alloc->>'event_id')::uuid;
    END LOOP;
  END IF;

  RETURN v_result;
END;
$function$;

-- One-time backfill: fully-settled billing events whose status is still stale.
UPDATE t_contract_events
SET status = 'paid', version = version + 1, updated_at = now()
WHERE event_type = 'billing' AND is_active = true
  AND COALESCE(amount, 0) > 0
  AND COALESCE(amount_settled, 0) >= COALESCE(amount, 0) - 0.005
  AND status NOT IN ('paid', 'cancelled', 'waived');

-- Partially-settled billing events whose status is still stale.
UPDATE t_contract_events
SET status = 'partial_payment', version = version + 1, updated_at = now()
WHERE event_type = 'billing' AND is_active = true
  AND COALESCE(amount_settled, 0) > 0.005
  AND COALESCE(amount_settled, 0) < COALESCE(amount, 0) - 0.005
  AND status NOT IN ('partial_payment', 'paid', 'cancelled', 'waived');
