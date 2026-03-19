-- ═══════════════════════════════════════════════════════════════════
-- 058_fix_cnak_in_status_response.sql
-- Adds global_access_id to update_contract_status response so the
-- frontend success screen can display CNAK after draft → active
-- (or draft → pending_acceptance) transitions.
--
-- Root cause:
--   update_contract_status generates CNAK when transitioning from
--   draft, but never returns it in the response JSON. The frontend
--   still holds the stale contractResult with global_access_id=null.
--
-- Fix:
--   Include global_access_id (and the generated v_cnak if applicable)
--   in the STEP 6 response object.
--
-- Dependencies:
--   053_fix_cnak_draft_workflow.sql
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION update_contract_status(
    p_contract_id UUID,
    p_tenant_id UUID,
    p_new_status VARCHAR,
    p_performed_by_id UUID DEFAULT NULL,
    p_performed_by_name VARCHAR DEFAULT NULL,
    p_performed_by_type VARCHAR DEFAULT 'user',
    p_note TEXT DEFAULT NULL,
    p_version INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current RECORD;
    v_is_valid_transition BOOLEAN := false;
    v_jtd_source_code VARCHAR;
    -- CNAK generation (for draft → non-draft)
    v_cnak VARCHAR(12);
    v_access_secret VARCHAR(32);
    v_final_cnak VARCHAR(12);
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_contract_id IS NULL OR p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'contract_id and tenant_id are required'
        );
    END IF;

    IF p_new_status IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'new_status is required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Lock row + fetch current state
    -- ═══════════════════════════════════════════
    SELECT * INTO v_current
    FROM t_contracts
    WHERE id = p_contract_id
      AND tenant_id = p_tenant_id
      AND is_active = true
    FOR UPDATE;

    IF v_current IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found',
            'contract_id', p_contract_id
        );
    END IF;

    -- Version check (if provided)
    IF p_version IS NOT NULL AND v_current.version <> p_version THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Version conflict — contract was modified by another user',
            'error_code', 'VERSION_CONFLICT',
            'current_version', v_current.version,
            'expected_version', p_version
        );
    END IF;

    -- Same status — no-op
    IF v_current.status = p_new_status THEN
        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'id', p_contract_id,
                'status', v_current.status,
                'message', 'Status unchanged'
            )
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Validate status transition
    -- ═══════════════════════════════════════════
    IF v_current.record_type = 'contract' THEN
        -- Contract status flow
        v_is_valid_transition := CASE
            -- Forward flow
            WHEN v_current.status = 'draft'              AND p_new_status = 'pending_review'      THEN true
            WHEN v_current.status = 'draft'              AND p_new_status = 'pending_acceptance'  THEN true -- wizard send (skip review)
            WHEN v_current.status = 'draft'              AND p_new_status = 'active'
                 AND v_current.acceptance_method = 'auto'                                         THEN true -- auto-accept draft finalization
            WHEN v_current.status = 'pending_review'     AND p_new_status = 'pending_acceptance'  THEN true
            WHEN v_current.status = 'pending_acceptance' AND p_new_status = 'active'              THEN true
            WHEN v_current.status = 'active'             AND p_new_status = 'completed'           THEN true
            WHEN v_current.status = 'active'             AND p_new_status = 'expired'             THEN true
            -- Auto-accept: skip pending_acceptance
            WHEN v_current.status = 'pending_review'     AND p_new_status = 'active'
                 AND v_current.acceptance_method = 'auto'                                         THEN true
            -- Cancellation from any pre-active status
            WHEN v_current.status IN ('draft', 'pending_review', 'pending_acceptance')
                 AND p_new_status = 'cancelled'                                                   THEN true
            -- Also allow cancellation from active
            WHEN v_current.status = 'active'             AND p_new_status = 'cancelled'           THEN true
            ELSE false
        END;

    ELSIF v_current.record_type = 'rfq' THEN
        -- RFQ status flow
        v_is_valid_transition := CASE
            WHEN v_current.status = 'draft'               AND p_new_status = 'sent'                  THEN true
            WHEN v_current.status = 'sent'                AND p_new_status = 'quotes_received'       THEN true
            WHEN v_current.status = 'quotes_received'     AND p_new_status = 'awarded'               THEN true
            WHEN v_current.status = 'awarded'             AND p_new_status = 'converted_to_contract' THEN true
            -- Cancellation from any pre-converted status
            WHEN v_current.status IN ('draft', 'sent', 'quotes_received', 'awarded')
                 AND p_new_status = 'cancelled'                                                      THEN true
            ELSE false
        END;
    END IF;

    IF NOT v_is_valid_transition THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('Invalid status transition: %s → %s', v_current.status, p_new_status),
            'error_code', 'INVALID_TRANSITION',
            'current_status', v_current.status,
            'requested_status', p_new_status,
            'record_type', v_current.record_type
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2.5: Generate CNAK if transitioning from draft
    --   and contract has no CNAK yet (NULL global_access_id)
    -- ═══════════════════════════════════════════
    IF v_current.status = 'draft'
       AND p_new_status != 'cancelled'
       AND v_current.global_access_id IS NULL THEN

        v_access_secret := md5(random()::text || clock_timestamp()::text);

        FOR i IN 1..10 LOOP
            v_cnak := 'CNAK-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));

            IF NOT EXISTS (
                SELECT 1 FROM t_contracts
                WHERE tenant_id = p_tenant_id AND global_access_id = v_cnak
            ) THEN
                EXIT;
            END IF;
        END LOOP;

        -- Update the contract with the generated CNAK
        UPDATE t_contracts
        SET global_access_id = v_cnak
        WHERE id = p_contract_id
          AND tenant_id = p_tenant_id;

        -- Create contract_access row
        IF v_current.buyer_id IS NOT NULL THEN
            INSERT INTO t_contract_access (
                contract_id,
                global_access_id,
                secret_code,
                tenant_id,
                creator_tenant_id,
                accessor_tenant_id,
                accessor_role,
                accessor_contact_id,
                accessor_email,
                accessor_name,
                status,
                is_active,
                created_by
            )
            VALUES (
                p_contract_id,
                v_cnak,
                v_access_secret,
                p_tenant_id,
                p_tenant_id,
                NULL,
                COALESCE(v_current.contract_type, 'client'),
                v_current.buyer_id,
                v_current.buyer_email,
                v_current.buyer_name,
                'pending',
                true,
                p_performed_by_id
            );
        END IF;
    END IF;

    -- Resolve final CNAK: either newly generated or pre-existing
    v_final_cnak := COALESCE(v_cnak, v_current.global_access_id);

    -- ═══════════════════════════════════════════
    -- STEP 3: Update status + relevant timestamps
    -- ═══════════════════════════════════════════
    UPDATE t_contracts SET
        status     = p_new_status,
        version    = version + 1,
        updated_by = p_performed_by_id,
        -- Set timestamps based on transition
        sent_at      = CASE
            WHEN p_new_status IN ('pending_review', 'sent') AND sent_at IS NULL THEN NOW()
            ELSE sent_at
        END,
        accepted_at  = CASE
            WHEN p_new_status = 'active' AND accepted_at IS NULL THEN NOW()
            ELSE accepted_at
        END,
        completed_at = CASE
            WHEN p_new_status IN ('completed', 'expired', 'cancelled', 'converted_to_contract') AND completed_at IS NULL THEN NOW()
            ELSE completed_at
        END
    WHERE id = p_contract_id
      AND tenant_id = p_tenant_id;

    -- ═══════════════════════════════════════════
    -- STEP 3.5: Auto-generate invoices on activation
    --   When any contract transitions to 'active', generate invoices
    --   based on payment_mode (prepaid/emi/defined).
    --   generate_contract_invoices is idempotent — skips if invoices exist.
    -- ═══════════════════════════════════════════
    IF p_new_status = 'active' AND v_current.record_type = 'contract' THEN
        PERFORM generate_contract_invoices(p_contract_id, p_tenant_id, p_performed_by_id);
    END IF;
    IF p_new_status = 'pending_acceptance'
       AND v_current.acceptance_method = 'manual'
       AND v_current.record_type = 'contract' THEN
        PERFORM generate_contract_invoices(p_contract_id, p_tenant_id, p_performed_by_id);
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 4: Audit trail — history entry
    -- ═══════════════════════════════════════════
    INSERT INTO t_contract_history (
        contract_id, tenant_id,
        action, from_status, to_status,
        changes,
        performed_by_type, performed_by_id, performed_by_name,
        note
    )
    VALUES (
        p_contract_id, p_tenant_id,
        'status_changed',
        v_current.status,
        p_new_status,
        jsonb_build_object(
            'record_type', v_current.record_type,
            'acceptance_method', v_current.acceptance_method
        ),
        p_performed_by_type,
        p_performed_by_id,
        p_performed_by_name,
        COALESCE(p_note, format('Status changed from %s to %s', v_current.status, p_new_status))
    );

    -- ═══════════════════════════════════════════
    -- STEP 5: Queue JTD event via PGMQ (async)
    -- ═══════════════════════════════════════════
    v_jtd_source_code := CASE
        WHEN v_current.record_type = 'contract' AND p_new_status IN ('pending_review', 'pending_acceptance') THEN 'contract_sent'
        WHEN v_current.record_type = 'contract' AND p_new_status = 'active'    THEN 'contract_accepted'
        WHEN v_current.record_type = 'contract' AND p_new_status = 'expired'   THEN 'contract_expired'
        WHEN v_current.record_type = 'rfq'      AND p_new_status = 'sent'      THEN 'rfq_sent'
        ELSE NULL
    END;

    IF v_jtd_source_code IS NOT NULL THEN
        BEGIN
            PERFORM pgmq.send('jtd_queue', jsonb_build_object(
                'source_type_code', v_jtd_source_code,
                'tenant_id', p_tenant_id,
                'contract_id', p_contract_id,
                'contract_name', v_current.name,
                'from_status', v_current.status,
                'to_status', p_new_status,
                'record_type', v_current.record_type,
                'performed_by_id', p_performed_by_id,
                'performed_by_name', p_performed_by_name
            ));
        EXCEPTION WHEN OTHERS THEN
            -- PGMQ failure should not block the status update
            RAISE NOTICE 'JTD queue failed for contract %: %', p_contract_id, SQLERRM;
        END;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 6: Return response (now includes global_access_id)
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', p_contract_id,
            'tenant_id', p_tenant_id,
            'from_status', v_current.status,
            'to_status', p_new_status,
            'version', v_current.version + 1,
            'jtd_queued', v_jtd_source_code IS NOT NULL,
            'cnak_generated', v_cnak IS NOT NULL,
            'global_access_id', v_final_cnak
        ),
        'updated_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to update contract status',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION update_contract_status(UUID, UUID, VARCHAR, UUID, VARCHAR, VARCHAR, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION update_contract_status(UUID, UUID, VARCHAR, UUID, VARCHAR, VARCHAR, TEXT, INTEGER) TO service_role;

COMMENT ON FUNCTION update_contract_status IS 'Updates contract status with validation, history, JTD events, and auto-invoice generation. Generates CNAK when transitioning from draft. Returns global_access_id in response.';
