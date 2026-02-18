-- =============================================================
-- BUYER RLS + CANCEL / BAD DEBT INVOICE SUPPORT
-- Migration: contracts/045_buyer_rls_and_invoice_cancel_writeoff.sql
--
-- 1. Buyer-aware RLS SELECT policies on t_invoices, t_invoice_receipts
-- 2. cancel_or_writeoff_invoice RPC (seller-only)
-- 3. Update get_contract_invoices summary with bad_debt_count
-- =============================================================


-- ─────────────────────────────────────────────────────────────
-- 1. BUYER-AWARE RLS POLICIES
--    Allow accessor tenants (buyers) to SELECT invoices & receipts
--    for contracts they have active access grants to.
-- ─────────────────────────────────────────────────────────────

-- Drop existing SELECT policies so we can replace them
DROP POLICY IF EXISTS "Tenant members can view invoices" ON t_invoices;
DROP POLICY IF EXISTS "Tenant members can view receipts" ON t_invoice_receipts;

-- NEW: Invoices readable by owner tenant OR buyer with active access grant
CREATE POLICY "Owner or accessor can view invoices"
    ON t_invoices FOR SELECT
    USING (
        -- Owner tenant
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
        OR
        -- Buyer/accessor: their tenant has an active access grant on this contract
        EXISTS (
            SELECT 1
            FROM t_contract_access ca
            JOIN t_user_tenants ut ON ut.tenant_id = ca.accessor_tenant_id AND ut.user_id = auth.uid()
            WHERE ca.contract_id = t_invoices.contract_id
              AND ca.is_active = true
              AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
        )
    );

-- NEW: Receipts readable by owner tenant OR buyer with active access grant
CREATE POLICY "Owner or accessor can view receipts"
    ON t_invoice_receipts FOR SELECT
    USING (
        -- Owner tenant
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
        OR
        -- Buyer/accessor
        EXISTS (
            SELECT 1
            FROM t_contract_access ca
            JOIN t_user_tenants ut ON ut.tenant_id = ca.accessor_tenant_id AND ut.user_id = auth.uid()
            WHERE ca.contract_id = t_invoice_receipts.contract_id
              AND ca.is_active = true
              AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
        )
    );


-- ─────────────────────────────────────────────────────────────
-- 2. cancel_or_writeoff_invoice RPC
--    Supports two actions: 'cancel' and 'bad_debt'
--    SELLER-ONLY: Only the contract owner tenant can invoke this.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cancel_or_writeoff_invoice(
    p_invoice_id UUID,
    p_contract_id UUID,
    p_tenant_id UUID,
    p_action VARCHAR,           -- 'cancel' | 'bad_debt'
    p_reason TEXT DEFAULT NULL,
    p_performed_by UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_invoice RECORD;
    v_contract RECORD;
    v_new_status VARCHAR(20);
    v_action_label VARCHAR(20);
    v_old_status VARCHAR(20);
    v_old_balance NUMERIC;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Validate inputs
    -- ═══════════════════════════════════════════
    IF p_invoice_id IS NULL OR p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'invoice_id and tenant_id are required'
        );
    END IF;

    IF p_action NOT IN ('cancel', 'bad_debt') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'action must be ''cancel'' or ''bad_debt'''
        );
    END IF;

    -- Map action to status
    IF p_action = 'cancel' THEN
        v_new_status := 'cancelled';
        v_action_label := 'Cancelled';
    ELSE
        v_new_status := 'bad_debt';
        v_action_label := 'Marked as Bad Debt';
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Fetch and lock the invoice
    -- ═══════════════════════════════════════════
    SELECT * INTO v_invoice
    FROM t_invoices
    WHERE id = p_invoice_id
      AND is_active = true
    FOR UPDATE;

    IF v_invoice IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoice not found'
        );
    END IF;

    -- Use contract_id from invoice if not provided
    IF p_contract_id IS NULL THEN
        p_contract_id := v_invoice.contract_id;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Seller-only access check
    --   Only the contract OWNER can cancel/write-off.
    --   Buyers cannot cancel invoices.
    -- ═══════════════════════════════════════════
    SELECT id, tenant_id, status INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found'
        );
    END IF;

    IF v_contract.tenant_id != p_tenant_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only the contract owner can cancel or write off invoices'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Validate current status allows this action
    -- ═══════════════════════════════════════════
    v_old_status := v_invoice.status;
    v_old_balance := v_invoice.balance;

    -- Cannot cancel/write-off an already paid invoice
    IF v_old_status = 'paid' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Cannot ' || p_action || ' a fully paid invoice'
        );
    END IF;

    -- Cannot re-cancel or re-write-off
    IF v_old_status IN ('cancelled', 'bad_debt') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoice is already ' || v_old_status
        );
    END IF;

    -- Allowed from: 'unpaid', 'partially_paid', 'overdue'

    -- ═══════════════════════════════════════════
    -- STEP 4: Update the invoice
    --   Set balance to 0 (written off / voided)
    --   Keep amount_paid as-is (audit trail for partial payments)
    -- ═══════════════════════════════════════════
    UPDATE t_invoices
    SET status = v_new_status,
        balance = 0,
        notes = COALESCE(notes || E'\n', '') ||
                v_action_label || ' on ' || TO_CHAR(NOW(), 'YYYY-MM-DD HH24:MI') ||
                CASE WHEN p_reason IS NOT NULL THEN ': ' || p_reason ELSE '' END,
        updated_at = NOW()
    WHERE id = p_invoice_id;

    -- ═══════════════════════════════════════════
    -- STEP 5: Record in contract history (audit trail)
    -- ═══════════════════════════════════════════
    INSERT INTO t_contract_history (
        contract_id,
        tenant_id,
        action,
        new_status,
        performed_by_id,
        performed_by_type,
        note,
        metadata
    ) VALUES (
        p_contract_id,
        p_tenant_id,
        'invoice_' || p_action,
        v_contract.status,
        p_performed_by,
        'user',
        'Invoice ' || v_invoice.invoice_number || ' ' || LOWER(v_action_label) ||
            CASE WHEN p_reason IS NOT NULL THEN ' — ' || p_reason ELSE '' END,
        jsonb_build_object(
            'invoice_id', p_invoice_id,
            'invoice_number', v_invoice.invoice_number,
            'action', p_action,
            'previous_status', v_old_status,
            'previous_balance', v_old_balance,
            'amount_paid', v_invoice.amount_paid,
            'total_amount', v_invoice.total_amount,
            'reason', p_reason
        )
    );

    -- ═══════════════════════════════════════════
    -- STEP 6: Return result
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'invoice_id', p_invoice_id,
            'invoice_number', v_invoice.invoice_number,
            'action', p_action,
            'new_status', v_new_status,
            'previous_status', v_old_status,
            'previous_balance', v_old_balance,
            'amount_paid', v_invoice.amount_paid
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to ' || COALESCE(p_action, 'process') || ' invoice',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION cancel_or_writeoff_invoice(UUID, UUID, UUID, VARCHAR, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_or_writeoff_invoice(UUID, UUID, UUID, VARCHAR, TEXT, UUID) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 3. UPDATE get_contract_invoices summary to include bad_debt_count
--    (Replaces the function from migration 044)
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
    -- STEP 0: Validate
    IF p_contract_id IS NULL OR p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'contract_id and tenant_id are required'
        );
    END IF;

    -- STEP 1: Access check — owner OR accessor
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

    -- STEP 2: Fetch invoices with receipt details
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

    -- STEP 3: Build collection summary (includes bad_debt_count)
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
        'bad_debt_count', COUNT(*) FILTER (WHERE i.status = 'bad_debt'),
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

    -- STEP 4: Return
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
