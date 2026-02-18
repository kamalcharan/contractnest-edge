-- =============================================================
-- FIX: respond_to_contract() missing invoice generation + accepted_at
-- Migration: contracts/046_fix_respond_invoice_generation.sql
--
-- Problem:  respond_to_contract() (migration 010) directly UPDATEs
--           t_contracts.status = 'active' without calling
--           generate_contract_invoices(). Any buyer-accepted contract
--           ends up Active with ZERO invoices.
--
-- Fix:
--   1. Re-create respond_to_contract() with:
--      a) accepted_at = NOW() on activation
--      b) PERFORM generate_contract_invoices() after activation
--      c) JTD event queue (contract_accepted) for downstream automation
--   2. Re-create record_invoice_payment() to reject payments on
--      'bad_debt' invoices (was missing alongside 'paid'/'cancelled')
--   3. One-time backfill: generate invoices for any existing active
--      contracts that have zero invoices.
-- =============================================================


-- ─────────────────────────────────────────────────────────────
-- 1. FIX respond_to_contract
--    Accept or reject a contract via CNAK + secret_code
--    NOW includes: invoice generation, accepted_at, JTD event
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION respond_to_contract(
    p_cnak             VARCHAR,
    p_secret_code      VARCHAR,
    p_action           VARCHAR,          -- 'accept' | 'reject'
    p_responded_by     UUID DEFAULT NULL, -- user ID if logged in
    p_responder_name   VARCHAR DEFAULT NULL,
    p_responder_email  VARCHAR DEFAULT NULL,
    p_rejection_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_access   RECORD;
    v_contract RECORD;
    v_new_status VARCHAR(20);
    v_invoice_result JSONB;
BEGIN
    -- ── Step 1: Validate inputs ──
    IF p_cnak IS NULL OR p_secret_code IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'CNAK and secret code are required'
        );
    END IF;

    IF p_action NOT IN ('accept', 'reject') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Action must be accept or reject'
        );
    END IF;

    -- ── Step 2: Look up and lock access grant ──
    SELECT *
    INTO v_access
    FROM t_contract_access
    WHERE global_access_id = p_cnak
      AND secret_code      = p_secret_code
      AND is_active         = true
    FOR UPDATE;

    IF v_access IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invalid access code'
        );
    END IF;

    -- ── Step 3: Check if already responded ──
    IF v_access.status IN ('accepted', 'rejected') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'This contract has already been ' || v_access.status,
            'status', v_access.status
        );
    END IF;

    -- ── Step 4: Check expiry ──
    IF v_access.expires_at IS NOT NULL AND v_access.expires_at < NOW() THEN
        -- Mark as expired
        UPDATE t_contract_access
        SET status = 'expired', updated_at = NOW()
        WHERE id = v_access.id;

        RETURN jsonb_build_object(
            'success', false,
            'error', 'This access link has expired'
        );
    END IF;

    -- ── Step 5: Get contract ──
    SELECT *
    INTO v_contract
    FROM t_contracts
    WHERE id = v_access.contract_id
      AND is_active = true
    FOR UPDATE;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found'
        );
    END IF;

    -- ── Step 6: Determine new status ──
    v_new_status := CASE p_action
        WHEN 'accept' THEN 'accepted'
        WHEN 'reject' THEN 'rejected'
    END;

    -- ── Step 7: Update access record ──
    UPDATE t_contract_access
    SET status           = v_new_status,
        responded_by     = p_responded_by,
        responded_at     = NOW(),
        rejection_reason = CASE WHEN p_action = 'reject' THEN p_rejection_reason ELSE NULL END,
        updated_at       = NOW()
    WHERE id = v_access.id;

    -- ── Step 8: Update contract status if accepted ──
    IF p_action = 'accept' THEN
        -- Move contract from pending_acceptance → active
        IF v_contract.status = 'pending_acceptance' THEN
            UPDATE t_contracts
            SET status      = 'active',
                accepted_at = COALESCE(accepted_at, NOW()),   -- FIX: set accepted_at
                version     = version + 1,
                updated_at  = NOW()
            WHERE id = v_contract.id;

            -- Log status change in history
            INSERT INTO t_contract_history (
                contract_id, tenant_id,
                action, from_status, to_status,
                changes,
                performed_by_type, performed_by_id, performed_by_name,
                note
            ) VALUES (
                v_contract.id,
                v_access.tenant_id,
                'status_change',
                'pending_acceptance',
                'active',
                jsonb_build_object(
                    'record_type', v_contract.record_type,
                    'acceptance_method', v_contract.acceptance_method,
                    'accepted_via', 'sign_off_link'
                ),
                'external',
                p_responded_by,
                COALESCE(p_responder_name, v_access.accessor_name, 'External party'),
                'Contract accepted via sign-off link'
            );

            -- ═══════════════════════════════════════════
            -- FIX: Generate invoices on activation
            --   generate_contract_invoices is idempotent — skips if invoices exist.
            -- ═══════════════════════════════════════════
            IF v_contract.record_type = 'contract' THEN
                v_invoice_result := generate_contract_invoices(
                    v_contract.id,
                    v_access.tenant_id,
                    p_responded_by
                );
            END IF;

            -- ═══════════════════════════════════════════
            -- FIX: Queue JTD event (contract_accepted)
            --   Matches behavior in update_contract_status()
            -- ═══════════════════════════════════════════
            BEGIN
                PERFORM pgmq.send('jtd_queue', jsonb_build_object(
                    'source_type_code', 'contract_accepted',
                    'tenant_id', v_access.tenant_id,
                    'contract_id', v_contract.id,
                    'contract_name', v_contract.name,
                    'from_status', 'pending_acceptance',
                    'to_status', 'active',
                    'record_type', v_contract.record_type,
                    'performed_by_id', p_responded_by,
                    'performed_by_name', COALESCE(p_responder_name, v_access.accessor_name, 'External party')
                ));
            EXCEPTION WHEN OTHERS THEN
                -- PGMQ failure should not block the acceptance
                RAISE NOTICE 'JTD queue failed for contract % (public accept): %', v_contract.id, SQLERRM;
            END;
        END IF;
    END IF;

    -- ── Step 9: Return result ──
    RETURN jsonb_build_object(
        'success', true,
        'action', p_action,
        'status', v_new_status,
        'contract_id', v_contract.id,
        'contract_number', v_contract.contract_number,
        'invoices_generated', COALESCE((v_invoice_result->>'success')::BOOLEAN, false),
        'message', CASE p_action
            WHEN 'accept' THEN 'Contract accepted successfully'
            WHEN 'reject' THEN 'Contract rejected'
        END
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to respond to contract: ' || SQLERRM
    );
END;
$$;

-- Grants (same signature as original)
GRANT EXECUTE ON FUNCTION respond_to_contract(VARCHAR, VARCHAR, VARCHAR, UUID, VARCHAR, VARCHAR, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION respond_to_contract(VARCHAR, VARCHAR, VARCHAR, UUID, VARCHAR, VARCHAR, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION respond_to_contract(VARCHAR, VARCHAR, VARCHAR, UUID, VARCHAR, VARCHAR, TEXT) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 2. FIX record_invoice_payment: reject payments on bad_debt invoices
--    Was: status IN ('paid', 'cancelled')
--    Now: status IN ('paid', 'cancelled', 'bad_debt')
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

    -- STEP 4.5: auto-activate contract on full payment
    v_contract RECORD;
    v_unpaid_count INTEGER;
    v_activation_result JSONB;
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

    -- Can't pay a fully paid, cancelled, or bad_debt invoice
    -- FIX: added 'bad_debt' to rejection list
    IF v_invoice.status IN ('paid', 'cancelled', 'bad_debt') THEN
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
    -- STEP 4.5: Auto-activate contract on full payment
    --   When acceptance_method = 'manual' (payment acceptance) and the
    --   contract is at pending_acceptance, check if ALL invoices are
    --   now paid. If so, transition the contract to 'active'.
    --   update_contract_status handles audit trail + event triggers.
    -- ═══════════════════════════════════════════
    IF v_new_status = 'paid' AND v_contract_id IS NOT NULL THEN
        SELECT id, status, acceptance_method, record_type, tenant_id
        INTO v_contract
        FROM t_contracts
        WHERE id = v_contract_id
          AND tenant_id = v_tenant_id
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
              AND tenant_id = v_tenant_id
              AND is_active = true
              AND status NOT IN ('paid', 'cancelled');

            IF v_unpaid_count = 0 THEN
                -- All invoices paid — activate the contract
                v_activation_result := update_contract_status(
                    p_contract_id      := v_contract_id,
                    p_tenant_id        := v_tenant_id,
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


-- ─────────────────────────────────────────────────────────────
-- 3. BACKFILL: Generate invoices for existing active contracts
--    that have zero invoices (caused by the bug above).
--    Uses generate_contract_invoices() which is idempotent.
-- ─────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_row RECORD;
    v_result JSONB;
    v_count INTEGER := 0;
BEGIN
    FOR v_row IN
        SELECT c.id AS contract_id, c.tenant_id, c.created_by,
               c.contract_number, c.status
        FROM t_contracts c
        WHERE c.status = 'active'
          AND c.record_type = 'contract'
          AND c.is_active = true
          AND NOT EXISTS (
              SELECT 1 FROM t_invoices i
              WHERE i.contract_id = c.id AND i.is_active = true
          )
    LOOP
        v_result := generate_contract_invoices(
            v_row.contract_id,
            v_row.tenant_id,
            v_row.created_by
        );
        v_count := v_count + 1;
        RAISE NOTICE 'Backfill invoice for % (%) — result: %',
            v_row.contract_number, v_row.contract_id, v_result->>'success';
    END LOOP;

    RAISE NOTICE 'Backfill complete: % contracts processed', v_count;
END;
$$;
