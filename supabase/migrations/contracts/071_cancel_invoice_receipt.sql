-- Cancel a single receipt (payment record) with a captured reason.
-- Mirrors cancel_or_writeoff_invoice's structure (062_adjustment_billing_status.sql)
-- but operates one level down: a receipt, not a whole invoice. Reverses whatever
-- t_invoice_receipt_allocations rows this receipt created (un-settling the
-- contract_events it paid toward, same money-driven status logic
-- record_invoice_payment_with_allocations uses going forward), deletes those
-- allocation rows, deactivates the receipt, and recomputes the parent invoice's
-- amount_paid/balance/status. Whole-receipt only — no partial cancellation.

ALTER TABLE public.t_invoice_receipts
  ADD COLUMN IF NOT EXISTS cancellation_reason text,
  ADD COLUMN IF NOT EXISTS cancelled_at timestamptz,
  ADD COLUMN IF NOT EXISTS cancelled_by uuid;

CREATE OR REPLACE FUNCTION public.cancel_invoice_receipt(
  p_receipt_id uuid,
  p_tenant_id uuid,
  p_reason text DEFAULT NULL,
  p_performed_by uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_receipt RECORD;
  v_invoice RECORD;
  v_contract RECORD;
  v_new_amount_paid NUMERIC;
  v_new_balance NUMERIC;
  v_new_invoice_status VARCHAR(20);
BEGIN
  -- ═══════════════════════════════════════════
  -- STEP 0: Validate inputs
  -- ═══════════════════════════════════════════
  IF p_receipt_id IS NULL OR p_tenant_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'receipt_id and tenant_id are required');
  END IF;

  -- ═══════════════════════════════════════════
  -- STEP 1: Fetch and lock the receipt
  -- ═══════════════════════════════════════════
  SELECT * INTO v_receipt
  FROM t_invoice_receipts
  WHERE id = p_receipt_id AND tenant_id = p_tenant_id AND is_active = true
  FOR UPDATE;

  IF v_receipt IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Receipt not found or already cancelled');
  END IF;

  -- ═══════════════════════════════════════════
  -- STEP 2: Seller-only access check
  --   Only the contract OWNER can cancel a receipt.
  -- ═══════════════════════════════════════════
  SELECT id, tenant_id, status INTO v_contract
  FROM t_contracts
  WHERE id = v_receipt.contract_id AND is_active = true;

  IF v_contract IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Contract not found');
  END IF;

  IF v_contract.tenant_id != p_tenant_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only the contract owner can cancel receipts');
  END IF;

  -- ═══════════════════════════════════════════
  -- STEP 3: Fetch and lock the parent invoice
  -- ═══════════════════════════════════════════
  SELECT * INTO v_invoice
  FROM t_invoices
  WHERE id = v_receipt.invoice_id AND is_active = true
  FOR UPDATE;

  IF v_invoice IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
  END IF;

  -- ═══════════════════════════════════════════
  -- STEP 4: Reverse event-level settlement for whatever this receipt
  --   allocated (no-op if it was recorded via the non-allocations path).
  --   Dropping to 0 resets the event to 'scheduled' — same as fresh
  --   derivation — and the scanner's due/overdue pass (guarded to
  --   'scheduled'/'due' sources) will re-date it on its next run.
  -- ═══════════════════════════════════════════
  UPDATE t_contract_events ce
  SET amount_settled = GREATEST(0, COALESCE(ce.amount_settled, 0) - a.amount),
      status = CASE
        WHEN GREATEST(0, COALESCE(ce.amount_settled, 0) - a.amount) <= 0 THEN 'scheduled'
        WHEN GREATEST(0, COALESCE(ce.amount_settled, 0) - a.amount) >= COALESCE(ce.amount, 0) - 0.005 THEN 'paid'
        ELSE 'partial_payment'
      END,
      version = ce.version + 1,
      updated_at = now()
  FROM t_invoice_receipt_allocations a
  WHERE a.receipt_id = p_receipt_id AND a.contract_event_id = ce.id;

  -- ═══════════════════════════════════════════
  -- STEP 5: Remove the allocation records
  -- ═══════════════════════════════════════════
  DELETE FROM t_invoice_receipt_allocations WHERE receipt_id = p_receipt_id;

  -- ═══════════════════════════════════════════
  -- STEP 6: Deactivate the receipt, capture the reason
  -- ═══════════════════════════════════════════
  UPDATE t_invoice_receipts
  SET is_active = false,
      cancellation_reason = p_reason,
      cancelled_at = now(),
      cancelled_by = p_performed_by,
      updated_at = now()
  WHERE id = p_receipt_id;

  -- ═══════════════════════════════════════════
  -- STEP 7: Recompute the invoice
  --   A terminal invoice (cancelled/bad_debt/adjustment) stays terminal —
  --   removing a receipt from it doesn't resurrect it.
  -- ═══════════════════════════════════════════
  v_new_amount_paid := GREATEST(0, v_invoice.amount_paid - v_receipt.amount);
  v_new_balance := v_invoice.total_amount - v_new_amount_paid;
  v_new_invoice_status := CASE
    WHEN v_invoice.status IN ('cancelled', 'bad_debt', 'adjustment') THEN v_invoice.status
    WHEN v_new_balance <= 0 THEN 'paid'
    WHEN v_new_amount_paid > 0 THEN 'partially_paid'
    ELSE 'unpaid'
  END;

  UPDATE t_invoices
  SET amount_paid = v_new_amount_paid,
      balance = v_new_balance,
      status = v_new_invoice_status,
      paid_at = CASE WHEN v_new_invoice_status != 'paid' THEN NULL ELSE paid_at END,
      updated_at = now()
  WHERE id = v_invoice.id;

  -- ═══════════════════════════════════════════
  -- STEP 8: Record in contract history (audit trail)
  -- ═══════════════════════════════════════════
  INSERT INTO t_contract_history (
    contract_id, tenant_id, action, from_status, to_status,
    performed_by_id, performed_by_type, note, changes
  ) VALUES (
    v_contract.id, p_tenant_id, 'status_changed', v_invoice.status, v_new_invoice_status,
    p_performed_by, 'user',
    'Receipt ' || v_receipt.receipt_number || ' cancelled' ||
      CASE WHEN p_reason IS NOT NULL THEN ' — ' || p_reason ELSE '' END,
    jsonb_build_object(
      'receipt_id', p_receipt_id,
      'receipt_number', v_receipt.receipt_number,
      'amount', v_receipt.amount,
      'reason', p_reason,
      'invoice_id', v_invoice.id,
      'previous_amount_paid', v_invoice.amount_paid,
      'new_amount_paid', v_new_amount_paid
    )
  );

  -- ═══════════════════════════════════════════
  -- STEP 9: Return result
  -- ═══════════════════════════════════════════
  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'receipt_id', p_receipt_id,
      'receipt_number', v_receipt.receipt_number,
      'cancelled_amount', v_receipt.amount,
      'invoice_id', v_invoice.id,
      'invoice_status', v_new_invoice_status,
      'amount_paid', v_new_amount_paid,
      'balance', v_new_balance
    )
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', 'Failed to cancel receipt',
    'details', SQLERRM,
    'error_code', SQLSTATE
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.cancel_invoice_receipt(uuid, uuid, text, uuid) TO authenticated, service_role;
