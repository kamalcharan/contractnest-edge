-- =============================================================
-- INVOICE RPC FUNCTIONS
-- Migration: contracts/006_invoice_rpc_functions.sql
-- Functions: generate_contract_invoices, get_contract_invoices
-- =============================================================


-- ─────────────────────────────────────────────────────────────
-- 1. generate_contract_invoices
--    Auto-generates ONE invoice per contract when it becomes active.
--    Called from: create_contract_transaction (auto-accept)
--                 update_contract_status (transition → active)
--
--    Model: Always 1 invoice for grand_total, regardless of payment_mode.
--           Payments are recorded as receipts against this single invoice.
--           For EMI: emi_months receipts against 1 invoice.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION generate_contract_invoices(
    p_contract_id UUID,
    p_tenant_id UUID,
    p_created_by UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_contract RECORD;
    v_invoice_type VARCHAR(20);
    v_seq_result JSONB;
    v_invoice_number VARCHAR(30);
    v_invoice_id UUID;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Fetch contract + validate
    -- ═══════════════════════════════════════════
    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND tenant_id = p_tenant_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found'
        );
    END IF;

    -- Don't generate if not active
    IF v_contract.status <> 'active' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract must be active to generate invoices',
            'current_status', v_contract.status
        );
    END IF;

    -- Don't generate if invoices already exist
    IF EXISTS (
        SELECT 1 FROM t_invoices
        WHERE contract_id = p_contract_id AND is_active = true
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoices already generated for this contract'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Determine AR/AP from contract_type
    --   client  → client pays tenant  → Receivable (AR)
    --   vendor  → tenant pays vendor  → Payable (AP)
    --   partner → default to AR
    -- ═══════════════════════════════════════════
    v_invoice_type := CASE v_contract.contract_type
        WHEN 'vendor' THEN 'payable'
        ELSE 'receivable'
    END;

    -- ═══════════════════════════════════════════
    -- STEP 2: Generate sequence number
    -- ═══════════════════════════════════════════
    v_seq_result := get_next_formatted_sequence('INVOICE', p_tenant_id, v_contract.is_live);
    v_invoice_number := v_seq_result->>'formatted';

    -- ═══════════════════════════════════════════
    -- STEP 3: Create single invoice for grand_total
    --   Regardless of payment_mode (prepaid/emi/defined),
    --   always 1 invoice. Payments are tracked via receipts.
    -- ═══════════════════════════════════════════
    INSERT INTO t_invoices (
        contract_id, tenant_id, invoice_number, invoice_type,
        amount, tax_amount, total_amount, currency,
        balance, status, payment_mode,
        emi_total,
        due_date, issued_at,
        is_live, created_by
    ) VALUES (
        p_contract_id, p_tenant_id, v_invoice_number, v_invoice_type,
        COALESCE(v_contract.total_value, 0),
        COALESCE(v_contract.tax_total, 0),
        COALESCE(v_contract.grand_total, 0),
        COALESCE(v_contract.currency, 'INR'),
        COALESCE(v_contract.grand_total, 0),  -- balance = total at creation
        'unpaid',
        COALESCE(v_contract.payment_mode, 'prepaid'),
        CASE WHEN v_contract.payment_mode = 'emi'
             THEN v_contract.emi_months
             ELSE NULL
        END,
        CURRENT_DATE, NOW(),
        v_contract.is_live, p_created_by
    )
    RETURNING id INTO v_invoice_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Return summary
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'contract_id', p_contract_id,
            'invoice_id', v_invoice_id,
            'invoice_number', v_invoice_number,
            'invoice_type', v_invoice_type,
            'payment_mode', COALESCE(v_contract.payment_mode, 'prepaid'),
            'emi_months', v_contract.emi_months,
            'total_amount', COALESCE(v_contract.grand_total, 0),
            'currency', COALESCE(v_contract.currency, 'INR')
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to generate invoices',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION generate_contract_invoices(UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION generate_contract_invoices(UUID, UUID, UUID) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 2. get_contract_invoices
--    Returns all invoices for a contract with receipt summaries
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
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Validate
    -- ═══════════════════════════════════════════
    IF p_contract_id IS NULL OR p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'contract_id and tenant_id are required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Fetch invoices with receipt counts
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
                )
            )
            ORDER BY COALESCE(i.emi_sequence, 0), i.due_date ASC
        ),
        '[]'::JSONB
    )
    INTO v_invoices
    FROM t_invoices i
    WHERE i.contract_id = p_contract_id
      AND i.tenant_id = p_tenant_id
      AND i.is_active = true;

    -- ═══════════════════════════════════════════
    -- STEP 2: Build collection summary
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
        'collection_percentage', CASE
            WHEN COALESCE(SUM(i.total_amount), 0) > 0
            THEN ROUND((COALESCE(SUM(i.amount_paid), 0) / SUM(i.total_amount)) * 100, 1)
            ELSE 0
        END
    )
    INTO v_summary
    FROM t_invoices i
    WHERE i.contract_id = p_contract_id
      AND i.tenant_id = p_tenant_id
      AND i.is_active = true;

    -- ═══════════════════════════════════════════
    -- STEP 3: Return
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
