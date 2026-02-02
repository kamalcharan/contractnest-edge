-- =============================================================
-- INVOICE PAYMENT RPC FUNCTIONS
-- Migration: contracts/007_invoice_payment_rpc.sql
-- Functions: record_invoice_payment
-- =============================================================


-- ─────────────────────────────────────────────────────────────
-- 1. record_invoice_payment
--    Records a receipt against an invoice.
--    Updates invoice balance, amount_paid, and status.
--
--    For EMI contracts: each receipt represents an installment.
--    emi_sequence on the receipt tracks which installment (1 of 6, etc.)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION record_invoice_payment(
    p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_invoice_id UUID;
    v_contract_id UUID;
    v_tenant_id UUID;
    v_recorded_by UUID;
    v_is_live BOOLEAN;

    v_invoice RECORD;
    v_amount NUMERIC;
    v_payment_method VARCHAR(30);
    v_payment_date DATE;
    v_reference_number TEXT;
    v_notes TEXT;
    v_emi_sequence INTEGER;

    v_seq_result JSONB;
    v_receipt_number VARCHAR(30);
    v_receipt_id UUID;

    v_new_amount_paid NUMERIC;
    v_new_balance NUMERIC;
    v_new_status VARCHAR(20);
    v_receipts_count INTEGER;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Extract and validate inputs
    -- ═══════════════════════════════════════════
    v_invoice_id := (p_payload->>'invoice_id')::UUID;
    v_contract_id := (p_payload->>'contract_id')::UUID;
    v_tenant_id := (p_payload->>'tenant_id')::UUID;
    v_recorded_by := (p_payload->>'recorded_by')::UUID;
    v_is_live := COALESCE((p_payload->>'is_live')::BOOLEAN, true);

    v_amount := (p_payload->>'amount')::NUMERIC;
    v_payment_method := COALESCE(p_payload->>'payment_method', 'bank_transfer');
    v_payment_date := COALESCE((p_payload->>'payment_date')::DATE, CURRENT_DATE);
    v_reference_number := p_payload->>'reference_number';
    v_notes := p_payload->>'notes';
    v_emi_sequence := (p_payload->>'emi_sequence')::INTEGER;

    IF v_invoice_id IS NULL OR v_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'invoice_id and tenant_id are required'
        );
    END IF;

    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'amount must be a positive number'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Fetch and lock the invoice
    -- ═══════════════════════════════════════════
    SELECT * INTO v_invoice
    FROM t_invoices
    WHERE id = v_invoice_id
      AND tenant_id = v_tenant_id
      AND is_active = true
    FOR UPDATE;

    IF v_invoice IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoice not found'
        );
    END IF;

    -- Can't pay a fully paid or cancelled invoice
    IF v_invoice.status IN ('paid', 'cancelled') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoice is already ' || v_invoice.status
        );
    END IF;

    -- Validate amount doesn't exceed balance
    IF v_amount > v_invoice.balance THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Payment amount exceeds invoice balance',
            'balance', v_invoice.balance,
            'attempted', v_amount
        );
    END IF;

    -- Use contract_id from invoice if not provided
    IF v_contract_id IS NULL THEN
        v_contract_id := v_invoice.contract_id;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Generate receipt number
    -- ═══════════════════════════════════════════
    v_seq_result := get_next_formatted_sequence('RECEIPT', v_tenant_id, v_is_live);
    v_receipt_number := v_seq_result->>'formatted';

    -- ═══════════════════════════════════════════
    -- STEP 3: Create receipt record
    -- ═══════════════════════════════════════════
    INSERT INTO t_invoice_receipts (
        invoice_id,
        contract_id,
        tenant_id,
        receipt_number,
        amount,
        currency,
        payment_date,
        payment_method,
        reference_number,
        notes,
        is_offline,
        recorded_by
    ) VALUES (
        v_invoice_id,
        v_contract_id,
        v_tenant_id,
        v_receipt_number,
        v_amount,
        v_invoice.currency,
        v_payment_date,
        v_payment_method,
        v_reference_number,
        v_notes,
        true,  -- manually recorded = offline
        v_recorded_by
    )
    RETURNING id INTO v_receipt_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Update invoice totals and status
    -- ═══════════════════════════════════════════
    v_new_amount_paid := v_invoice.amount_paid + v_amount;
    v_new_balance := v_invoice.total_amount - v_new_amount_paid;

    -- Determine new status
    IF v_new_balance <= 0 THEN
        v_new_status := 'paid';
    ELSE
        v_new_status := 'partially_paid';
    END IF;

    UPDATE t_invoices
    SET amount_paid = v_new_amount_paid,
        balance = v_new_balance,
        status = v_new_status,
        paid_at = CASE WHEN v_new_status = 'paid' THEN NOW() ELSE paid_at END,
        updated_at = NOW()
    WHERE id = v_invoice_id;

    -- Count total receipts for this invoice
    SELECT COUNT(*) INTO v_receipts_count
    FROM t_invoice_receipts
    WHERE invoice_id = v_invoice_id AND is_active = true;

    -- ═══════════════════════════════════════════
    -- STEP 5: Return receipt details
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'receipt_id', v_receipt_id,
            'receipt_number', v_receipt_number,
            'amount', v_amount,
            'currency', v_invoice.currency,
            'payment_method', v_payment_method,
            'payment_date', v_payment_date,
            'emi_sequence', v_emi_sequence,
            'invoice_id', v_invoice_id,
            'invoice_number', v_invoice.invoice_number,
            'invoice_status', v_new_status,
            'amount_paid', v_new_amount_paid,
            'balance', v_new_balance,
            'receipts_count', v_receipts_count
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to record payment',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION record_invoice_payment(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION record_invoice_payment(JSONB) TO service_role;
