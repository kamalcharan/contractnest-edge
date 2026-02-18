-- =============================================================
-- FIX: INVOICE BUYER ACCESS + RECEIPT DETAILS
-- Migration: contracts/044_fix_invoice_buyer_access_and_receipts.sql
--
-- Problems Fixed:
--   1. get_contract_invoices filtered by tenant_id, blocking buyer access
--   2. record_invoice_payment filtered by tenant_id, blocking buyer payment
--   3. get_contract_invoices returned receipts_count but no receipt details
--
-- Approach:
--   Use t_contract_access to verify either owner OR accessor can access.
--   Fetch invoices by contract_id only (after access validation).
--   Embed receipt array per invoice for full receipt reporting.
-- =============================================================


-- ─────────────────────────────────────────────────────────────
-- 1. REPLACE get_contract_invoices
--    Now supports both seller (owner) and buyer (accessor) access.
--    Returns full receipt details per invoice (not just count).
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_contract_invoices(
    p_contract_id UUID,
    p_tenant_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_invoices JSONB;
    v_summary JSONB;
    v_has_access BOOLEAN := false;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Validate inputs
    -- ═══════════════════════════════════════════
    IF p_contract_id IS NULL OR p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'contract_id and tenant_id are required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Access check — owner OR accessor
    --   Owner: contract.tenant_id = p_tenant_id
    --   Accessor: active grant in t_contract_access
    -- ═══════════════════════════════════════════
    SELECT true INTO v_has_access
    FROM t_contracts c
    WHERE c.id = p_contract_id
      AND c.is_active = true
      AND (
          c.tenant_id = p_tenant_id
          OR EXISTS (
              SELECT 1 FROM t_contract_access ca
              WHERE ca.contract_id = p_contract_id
                AND ca.accessor_tenant_id = p_tenant_id
                AND ca.is_active = true
                AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
          )
      );

    IF v_has_access IS NULL OR v_has_access = false THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Access denied: not a party to this contract'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Fetch invoices with receipt details
    --   Filter by contract_id only (access already validated)
    --   Embed full receipt array per invoice
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', i.id,
                'invoice_number', i.invoice_number,
                'invoice_type', i.invoice_type,
                'amount', i.amount,
                'tax_amount', i.tax_amount,
                'total_amount', i.total_amount,
                'currency', i.currency,
                'amount_paid', i.amount_paid,
                'balance', i.balance,
                'status', i.status,
                'payment_mode', i.payment_mode,
                'emi_sequence', i.emi_sequence,
                'emi_total', i.emi_total,
                'billing_cycle', i.billing_cycle,
                'block_ids', i.block_ids,
                'due_date', i.due_date,
                'issued_at', i.issued_at,
                'paid_at', i.paid_at,
                'notes', i.notes,
                'created_at', i.created_at,
                'receipts_count', (
                    SELECT COUNT(*)
                    FROM t_invoice_receipts r
                    WHERE r.invoice_id = i.id AND r.is_active = true
                ),
                'receipts', COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'id', r.id,
                                'receipt_number', r.receipt_number,
                                'amount', r.amount,
                                'currency', r.currency,
                                'payment_date', r.payment_date,
                                'payment_method', r.payment_method,
                                'reference_number', r.reference_number,
                                'notes', r.notes,
                                'is_offline', r.is_offline,
                                'is_verified', r.is_verified,
                                'recorded_by', r.recorded_by,
                                'created_at', r.created_at
                            )
                            ORDER BY r.payment_date ASC, r.created_at ASC
                        )
                        FROM t_invoice_receipts r
                        WHERE r.invoice_id = i.id AND r.is_active = true
                    ),
                    '[]'::JSONB
                )
            )
            ORDER BY COALESCE(i.emi_sequence, 0), i.due_date ASC
        ),
        '[]'::JSONB
    )
    INTO v_invoices
    FROM t_invoices i
    WHERE i.contract_id = p_contract_id
      AND i.is_active = true;

    -- ═══════════════════════════════════════════
    -- STEP 3: Build collection summary
    -- ═══════════════════════════════════════════
    SELECT jsonb_build_object(
        'total_invoiced', COALESCE(SUM(i.total_amount), 0),
        'total_paid', COALESCE(SUM(i.amount_paid), 0),
        'total_balance', COALESCE(SUM(i.balance), 0),
        'invoice_count', COUNT(*),
        'paid_count', COUNT(*) FILTER (WHERE i.status = 'paid'),
        'unpaid_count', COUNT(*) FILTER (WHERE i.status = 'unpaid'),
        'partial_count', COUNT(*) FILTER (WHERE i.status = 'partially_paid'),
        'overdue_count', COUNT(*) FILTER (WHERE i.status = 'overdue'),
        'cancelled_count', COUNT(*) FILTER (WHERE i.status = 'cancelled'),
        'collection_percentage', CASE
            WHEN COALESCE(SUM(i.total_amount), 0) > 0
            THEN ROUND((COALESCE(SUM(i.amount_paid), 0) / SUM(i.total_amount)) * 100, 1)
            ELSE 0
        END
    )
    INTO v_summary
    FROM t_invoices i
    WHERE i.contract_id = p_contract_id
      AND i.is_active = true;

    -- ═══════════════════════════════════════════
    -- STEP 4: Return
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'invoices', v_invoices,
            'summary', v_summary
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch invoices',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_contract_invoices(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contract_invoices(UUID, UUID) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 2. REPLACE record_invoice_payment
--    Now supports both seller (owner) and buyer (accessor).
--    Invoice lookup uses contract_id access check instead of
--    requiring tenant_id to match the invoice's tenant_id.
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

    -- auto-activate
    v_contract RECORD;
    v_unpaid_count INTEGER;
    v_activation_result JSONB;

    -- access check
    v_has_access BOOLEAN := false;
    v_invoice_tenant_id UUID;
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
    --   No longer filters by tenant_id on the invoice itself.
    --   Access is validated separately via contract ownership/access.
    -- ═══════════════════════════════════════════
    SELECT * INTO v_invoice
    FROM t_invoices
    WHERE id = v_invoice_id
      AND is_active = true
    FOR UPDATE;

    IF v_invoice IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoice not found'
        );
    END IF;

    -- Use contract_id from invoice if not provided
    IF v_contract_id IS NULL THEN
        v_contract_id := v_invoice.contract_id;
    END IF;

    -- Store the invoice's tenant_id for receipt creation
    v_invoice_tenant_id := v_invoice.tenant_id;

    -- ═══════════════════════════════════════════
    -- STEP 1.5: Access check — owner OR accessor
    -- ═══════════════════════════════════════════
    SELECT true INTO v_has_access
    FROM t_contracts c
    WHERE c.id = v_contract_id
      AND c.is_active = true
      AND (
          c.tenant_id = v_tenant_id
          OR EXISTS (
              SELECT 1 FROM t_contract_access ca
              WHERE ca.contract_id = v_contract_id
                AND ca.accessor_tenant_id = v_tenant_id
                AND ca.is_active = true
                AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
          )
      );

    IF v_has_access IS NULL OR v_has_access = false THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Access denied: not a party to this contract'
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

    -- ═══════════════════════════════════════════
    -- STEP 2: Generate receipt number
    --   Use invoice's tenant_id for sequence (seller's namespace)
    -- ═══════════════════════════════════════════
    v_seq_result := get_next_formatted_sequence('RECEIPT', v_invoice_tenant_id, v_is_live);
    v_receipt_number := v_seq_result->>'formatted';

    -- ═══════════════════════════════════════════
    -- STEP 3: Create receipt record
    --   Receipt tenant_id = invoice's tenant_id (seller's namespace)
    --   recorded_by = the user who recorded it (could be buyer or seller)
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
        v_invoice_tenant_id,
        v_receipt_number,
        v_amount,
        v_invoice.currency,
        v_payment_date,
        v_payment_method,
        v_reference_number,
        v_notes,
        true,
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
    -- STEP 4.5: Auto-activate contract on full payment
    --   When acceptance_method = 'manual' (payment acceptance) and the
    --   contract is at pending_acceptance, check if ALL invoices are
    --   now paid. If so, transition the contract to 'active'.
    -- ═══════════════════════════════════════════
    IF v_new_status = 'paid' AND v_contract_id IS NOT NULL THEN
        SELECT id, status, acceptance_method, record_type, tenant_id
        INTO v_contract
        FROM t_contracts
        WHERE id = v_contract_id
          AND is_active = true;

        IF v_contract IS NOT NULL
           AND v_contract.status = 'pending_acceptance'
           AND v_contract.acceptance_method = 'manual'
           AND v_contract.record_type = 'contract'
        THEN
            -- Check if any unpaid invoices remain
            SELECT COUNT(*) INTO v_unpaid_count
            FROM t_invoices
            WHERE contract_id = v_contract_id
              AND is_active = true
              AND status NOT IN ('paid', 'cancelled');

            IF v_unpaid_count = 0 THEN
                -- All invoices paid — activate the contract
                v_activation_result := update_contract_status(
                    p_contract_id      := v_contract_id,
                    p_tenant_id        := v_contract.tenant_id,
                    p_new_status       := 'active',
                    p_performed_by_id  := v_recorded_by,
                    p_performed_by_name := NULL,
                    p_performed_by_type := 'system',
                    p_note             := 'Auto-activated: all invoices paid'
                );
            END IF;
        END IF;
    END IF;

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
            'receipts_count', v_receipts_count,
            'contract_activated', COALESCE((v_activation_result->>'success')::BOOLEAN, false)
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
