-- Migration: bbb-foundation/006_event_level_receipt_allocations.sql
-- ============================================================================
-- P1 (backend) for the "close the loop" AR model:
--   ONE invoice per contract (already set up by the 5b fix) whose balance stays
--   the single source of truth for AR/AP, PLUS an event-level settlement
--   sub-ledger so a receipt can settle one or more specific billing events
--   (e.g. "member paid months 1-3") and the rest stay open.
--
-- This is ADDITIVE and does NOT alter any existing AR/AP logic:
--   * record_invoice_payment (the money RPC) is untouched and still owns the
--     invoice balance. AR/AP RPCs (get_tenant_receivables/payables) are
--     unchanged and keep summing invoice balances.
--   * We add: a per-event settled amount, a receipt<->event allocation table,
--     and a thin WRAPPER RPC that calls record_invoice_payment as-is, then
--     records which events the receipt covered.
--
-- Invariant to preserve: invoice.amount_paid = SUM(receipts) = SUM(event settled).
-- ============================================================================

-- 1. Per-event settled amount (event is settled when amount_settled >= amount)
ALTER TABLE public.t_contract_events
  ADD COLUMN IF NOT EXISTS amount_settled numeric NOT NULL DEFAULT 0;

-- 2. Receipt <-> billing-event allocation (one receipt can cover many events)
CREATE TABLE IF NOT EXISTS public.t_invoice_receipt_allocations (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id        UUID NOT NULL,
  contract_event_id UUID NOT NULL,
  invoice_id        UUID,
  contract_id       UUID,
  tenant_id         UUID NOT NULL,
  amount            NUMERIC NOT NULL,
  is_live           BOOLEAN DEFAULT true,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT fk_alloc_receipt FOREIGN KEY (receipt_id)
    REFERENCES public.t_invoice_receipts(id) ON DELETE CASCADE,
  CONSTRAINT fk_alloc_event FOREIGN KEY (contract_event_id)
    REFERENCES public.t_contract_events(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_alloc_event   ON public.t_invoice_receipt_allocations(contract_event_id);
CREATE INDEX IF NOT EXISTS idx_alloc_receipt ON public.t_invoice_receipt_allocations(receipt_id);
CREATE INDEX IF NOT EXISTS idx_alloc_tenant  ON public.t_invoice_receipt_allocations(tenant_id);

-- 3. Wrapper RPC — record a payment and (optionally) allocate it to events.
--    Backward compatible: with no 'event_allocations' it is exactly a
--    whole-invoice receipt (identical to record_invoice_payment).
CREATE OR REPLACE FUNCTION public.record_invoice_payment_with_allocations(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
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
  -- Allocations, if given, must sum exactly to the payment amount.
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

  -- Record the payment via the existing, unchanged money RPC (creates the
  -- receipt and updates the invoice balance).
  v_result := public.record_invoice_payment(p_payload);
  IF COALESCE((v_result->>'success')::boolean, false) IS NOT TRUE THEN
    RETURN v_result;
  END IF;

  v_receipt_id := (v_result->'data'->>'receipt_id')::uuid;

  -- Record the event allocations + advance each event's settled amount.
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

      UPDATE public.t_contract_events
      SET amount_settled = COALESCE(amount_settled, 0) + (v_alloc->>'amount')::numeric
      WHERE id = (v_alloc->>'event_id')::uuid;
    END LOOP;
  END IF;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_invoice_payment_with_allocations(jsonb) TO authenticated, service_role;
