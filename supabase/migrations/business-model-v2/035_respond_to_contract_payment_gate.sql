-- Migration 035: payment gate in respond_to_contract
-- Already applied live. Source-of-record copy — do not re-run.
--
-- acceptance_method = 'payment' means acceptance IS the payment: a buyer must
-- not be able to plain-accept a payment-gated contract while money is
-- outstanding. Adds Step 5.5 — before the access record is marked accepted —
-- returning {success:false, error_code:'PAYMENT_REQUIRED'} when the contract
-- is payment-gated, pending_acceptance, priced, and not fully paid (unpaid
-- invoices exist, or none were ever generated). The payment flows (public
-- Razorpay verify / offline-UPI declaration confirm) auto-activate via
-- record_invoice_payment (migration 033), so a fully-paid contract never sits
-- at pending_acceptance to hit this branch.
--
-- Coverage: the contracts edge function's /public/respond handler calls this
-- RPC (single RPC, confirmed), so both the API route and any direct edge call
-- are gated. Everything else in the function body is byte-identical to the
-- live definition it replaced.

CREATE OR REPLACE FUNCTION public.respond_to_contract(p_cnak character varying, p_secret_code character varying, p_action character varying, p_responded_by uuid DEFAULT NULL::uuid, p_responder_name character varying DEFAULT NULL::character varying, p_responder_email character varying DEFAULT NULL::character varying, p_rejection_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

    -- ── Step 5.5: Payment gate (migration 035) ──
    --   acceptance_method = 'payment' means acceptance IS the payment: the
    --   buyer cannot plain-accept while money is outstanding. The payment
    --   flows (public Razorpay verify / offline-UPI declaration confirm)
    --   auto-activate the contract via record_invoice_payment once all
    --   invoices are paid, so a fully-paid contract never sits at
    --   pending_acceptance to hit this branch. Blocks BEFORE the access
    --   record is marked accepted (Step 7).
    IF p_action = 'accept'
       AND v_contract.acceptance_method = 'payment'
       AND v_contract.status = 'pending_acceptance'
       AND COALESCE(v_contract.grand_total, 0) > 0
       AND (
           EXISTS (
               SELECT 1 FROM t_invoices
               WHERE contract_id = v_contract.id
                 AND is_active = true
                 AND status NOT IN ('paid', 'cancelled')
           )
           OR NOT EXISTS (
               SELECT 1 FROM t_invoices
               WHERE contract_id = v_contract.id
                 AND is_active = true
           )
       )
    THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'This contract requires payment before it can be accepted. Complete the payment and it will activate automatically.',
            'error_code', 'PAYMENT_REQUIRED'
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
                'status_changed',
                'pending_acceptance',
                'active',
                jsonb_build_object(
                    'record_type', v_contract.record_type,
                    'acceptance_method', v_contract.acceptance_method,
                    'accepted_via', 'sign_off_link'
                ),
                'system',
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
$function$;
