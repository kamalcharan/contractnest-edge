-- =============================================================
-- CONTRACT RPC FUNCTIONS (Batch 2 of 2)
-- Migration: contracts/003_contract_rpc_functions_batch2.sql
-- Functions: update_contract_transaction, update_contract_status,
--            soft_delete_contract, get_contract_stats
-- =============================================================


-- ─────────────────────────────────────────────────────────────
-- 4. update_contract_transaction
--    Atomic update with optimistic concurrency (version check),
--    idempotency, block replacement, vendor sync, history
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_contract_transaction(
    p_contract_id UUID,
    p_payload JSONB,
    p_idempotency_key VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tenant_id UUID;
    v_updated_by UUID;
    v_expected_version INTEGER;
    v_current RECORD;
    v_blocks JSONB;
    v_vendors JSONB;
    v_block JSONB;
    v_vendor JSONB;
    v_changes JSONB := '{}'::JSONB;
    v_idempotency RECORD;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    v_tenant_id := (p_payload->>'tenant_id')::UUID;
    v_updated_by := (p_payload->>'updated_by')::UUID;
    v_expected_version := (p_payload->>'version')::INTEGER;

    IF p_contract_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'contract_id is required'
        );
    END IF;

    IF v_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    IF v_expected_version IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'version is required for optimistic concurrency'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Idempotency check
    -- ═══════════════════════════════════════════
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_idempotency
        FROM check_idempotency(
            p_idempotency_key,
            v_tenant_id,
            'update_contract_transaction'
        );

        IF v_idempotency.found THEN
            RETURN v_idempotency.response_body;
        END IF;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Lock row + version check (optimistic concurrency)
    -- ═══════════════════════════════════════════
    SELECT * INTO v_current
    FROM t_contracts
    WHERE id = p_contract_id
      AND tenant_id = v_tenant_id
      AND is_active = true
    FOR UPDATE;

    IF v_current IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found',
            'contract_id', p_contract_id
        );
    END IF;

    IF v_current.version <> v_expected_version THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Version conflict — contract was modified by another user',
            'error_code', 'VERSION_CONFLICT',
            'current_version', v_current.version,
            'expected_version', v_expected_version
        );
    END IF;

    -- Only allow updates on editable statuses
    IF v_current.status NOT IN ('draft') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract can only be edited in draft status',
            'current_status', v_current.status
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Track field changes for audit
    -- ═══════════════════════════════════════════
    IF p_payload ? 'name' AND p_payload->>'name' IS DISTINCT FROM v_current.name THEN
        v_changes := v_changes || jsonb_build_object('name', jsonb_build_object('from', v_current.name, 'to', p_payload->>'name'));
    END IF;
    IF p_payload ? 'description' AND p_payload->>'description' IS DISTINCT FROM v_current.description THEN
        v_changes := v_changes || jsonb_build_object('description', jsonb_build_object('from', v_current.description, 'to', p_payload->>'description'));
    END IF;
    IF p_payload ? 'buyer_name' AND p_payload->>'buyer_name' IS DISTINCT FROM v_current.buyer_name THEN
        v_changes := v_changes || jsonb_build_object('buyer_name', jsonb_build_object('from', v_current.buyer_name, 'to', p_payload->>'buyer_name'));
    END IF;
    IF p_payload ? 'acceptance_method' AND p_payload->>'acceptance_method' IS DISTINCT FROM v_current.acceptance_method THEN
        v_changes := v_changes || jsonb_build_object('acceptance_method', jsonb_build_object('from', v_current.acceptance_method, 'to', p_payload->>'acceptance_method'));
    END IF;
    IF p_payload ? 'total_value' AND (p_payload->>'total_value')::NUMERIC IS DISTINCT FROM v_current.total_value THEN
        v_changes := v_changes || jsonb_build_object('total_value', jsonb_build_object('from', v_current.total_value, 'to', (p_payload->>'total_value')::NUMERIC));
    END IF;
    IF p_payload ? 'grand_total' AND (p_payload->>'grand_total')::NUMERIC IS DISTINCT FROM v_current.grand_total THEN
        v_changes := v_changes || jsonb_build_object('grand_total', jsonb_build_object('from', v_current.grand_total, 'to', (p_payload->>'grand_total')::NUMERIC));
    END IF;
    IF p_payload ? 'tax_total' AND (p_payload->>'tax_total')::NUMERIC IS DISTINCT FROM v_current.tax_total THEN
        v_changes := v_changes || jsonb_build_object('tax_total', jsonb_build_object('from', v_current.tax_total, 'to', (p_payload->>'tax_total')::NUMERIC));
    END IF;
    IF p_payload ? 'tax_breakdown' AND p_payload->'tax_breakdown' IS DISTINCT FROM v_current.tax_breakdown THEN
        v_changes := v_changes || jsonb_build_object('tax_breakdown', jsonb_build_object('from', v_current.tax_breakdown, 'to', p_payload->'tax_breakdown'));
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 4: Update contract fields + increment version
    -- ═══════════════════════════════════════════
    UPDATE t_contracts SET
        name               = COALESCE(NULLIF(TRIM(p_payload->>'name'), ''), v_current.name),
        description        = CASE WHEN p_payload ? 'description' THEN p_payload->>'description' ELSE v_current.description END,
        path               = CASE WHEN p_payload ? 'path' THEN p_payload->>'path' ELSE v_current.path END,
        template_id        = CASE WHEN p_payload ? 'template_id' THEN (p_payload->>'template_id')::UUID ELSE v_current.template_id END,

        -- Counterparty
        buyer_id                = CASE WHEN p_payload ? 'buyer_id' THEN (p_payload->>'buyer_id')::UUID ELSE v_current.buyer_id END,
        buyer_name              = CASE WHEN p_payload ? 'buyer_name' THEN p_payload->>'buyer_name' ELSE v_current.buyer_name END,
        buyer_company           = CASE WHEN p_payload ? 'buyer_company' THEN p_payload->>'buyer_company' ELSE v_current.buyer_company END,
        buyer_email             = CASE WHEN p_payload ? 'buyer_email' THEN p_payload->>'buyer_email' ELSE v_current.buyer_email END,
        buyer_phone             = CASE WHEN p_payload ? 'buyer_phone' THEN p_payload->>'buyer_phone' ELSE v_current.buyer_phone END,
        buyer_contact_person_id = CASE WHEN p_payload ? 'buyer_contact_person_id' THEN (p_payload->>'buyer_contact_person_id')::UUID ELSE v_current.buyer_contact_person_id END,
        buyer_contact_person_name = CASE WHEN p_payload ? 'buyer_contact_person_name' THEN p_payload->>'buyer_contact_person_name' ELSE v_current.buyer_contact_person_name END,

        -- Acceptance & Duration
        acceptance_method  = CASE WHEN p_payload ? 'acceptance_method' THEN p_payload->>'acceptance_method' ELSE v_current.acceptance_method END,
        duration_value     = CASE WHEN p_payload ? 'duration_value' THEN (p_payload->>'duration_value')::INTEGER ELSE v_current.duration_value END,
        duration_unit      = CASE WHEN p_payload ? 'duration_unit' THEN p_payload->>'duration_unit' ELSE v_current.duration_unit END,
        grace_period_value = CASE WHEN p_payload ? 'grace_period_value' THEN (p_payload->>'grace_period_value')::INTEGER ELSE v_current.grace_period_value END,
        grace_period_unit  = CASE WHEN p_payload ? 'grace_period_unit' THEN p_payload->>'grace_period_unit' ELSE v_current.grace_period_unit END,

        -- Billing
        currency           = CASE WHEN p_payload ? 'currency' THEN p_payload->>'currency' ELSE v_current.currency END,
        billing_cycle_type = CASE WHEN p_payload ? 'billing_cycle_type' THEN p_payload->>'billing_cycle_type' ELSE v_current.billing_cycle_type END,
        payment_mode       = CASE WHEN p_payload ? 'payment_mode' THEN p_payload->>'payment_mode' ELSE v_current.payment_mode END,
        emi_months         = CASE WHEN p_payload ? 'emi_months' THEN (p_payload->>'emi_months')::INTEGER ELSE v_current.emi_months END,
        per_block_payment_type = CASE WHEN p_payload ? 'per_block_payment_type' THEN p_payload->>'per_block_payment_type' ELSE v_current.per_block_payment_type END,

        -- Financials
        total_value        = CASE WHEN p_payload ? 'total_value' THEN (p_payload->>'total_value')::NUMERIC ELSE v_current.total_value END,
        tax_total          = CASE WHEN p_payload ? 'tax_total' THEN (p_payload->>'tax_total')::NUMERIC ELSE v_current.tax_total END,
        grand_total        = CASE WHEN p_payload ? 'grand_total' THEN (p_payload->>'grand_total')::NUMERIC ELSE v_current.grand_total END,
        selected_tax_rate_ids = CASE WHEN p_payload ? 'selected_tax_rate_ids' THEN p_payload->'selected_tax_rate_ids' ELSE v_current.selected_tax_rate_ids END,
        tax_breakdown      = CASE WHEN p_payload ? 'tax_breakdown' THEN p_payload->'tax_breakdown' ELSE v_current.tax_breakdown END,

        -- Version + Audit
        version    = v_current.version + 1,
        updated_by = v_updated_by
    WHERE id = p_contract_id
      AND tenant_id = v_tenant_id;

    -- ═══════════════════════════════════════════
    -- STEP 5: Replace blocks (delete + re-insert)
    --   Only if blocks array is provided in payload
    -- ═══════════════════════════════════════════
    IF p_payload ? 'blocks' THEN
        -- Delete existing blocks
        DELETE FROM t_contract_blocks
        WHERE contract_id = p_contract_id;

        -- Insert new blocks
        v_blocks := p_payload->'blocks';

        FOR v_block IN SELECT * FROM jsonb_array_elements(v_blocks)
        LOOP
            INSERT INTO t_contract_blocks (
                contract_id, tenant_id, position,
                source_type, source_block_id,
                block_name, block_description,
                category_id, category_name,
                unit_price, quantity, billing_cycle, total_price,
                flyby_type, custom_fields
            )
            VALUES (
                p_contract_id, v_tenant_id,
                COALESCE((v_block->>'position')::INTEGER, 0),
                COALESCE(v_block->>'source_type', 'flyby'),
                (v_block->>'source_block_id')::UUID,
                COALESCE(v_block->>'block_name', 'Untitled Block'),
                v_block->>'block_description',
                v_block->>'category_id',
                v_block->>'category_name',
                (v_block->>'unit_price')::NUMERIC,
                (v_block->>'quantity')::INTEGER,
                v_block->>'billing_cycle',
                (v_block->>'total_price')::NUMERIC,
                v_block->>'flyby_type',
                COALESCE(v_block->'custom_fields', '{}'::JSONB)
            );
        END LOOP;

        v_changes := v_changes || jsonb_build_object('blocks_replaced', true, 'blocks_count', jsonb_array_length(v_blocks));
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 6: Replace vendors (RFQ only, if provided)
    -- ═══════════════════════════════════════════
    IF p_payload ? 'vendors' AND v_current.record_type = 'rfq' THEN
        DELETE FROM t_contract_vendors
        WHERE contract_id = p_contract_id;

        v_vendors := p_payload->'vendors';

        FOR v_vendor IN SELECT * FROM jsonb_array_elements(v_vendors)
        LOOP
            INSERT INTO t_contract_vendors (
                contract_id, tenant_id,
                vendor_id, vendor_name, vendor_company, vendor_email,
                response_status
            )
            VALUES (
                p_contract_id, v_tenant_id,
                (v_vendor->>'vendor_id')::UUID,
                v_vendor->>'vendor_name',
                v_vendor->>'vendor_company',
                v_vendor->>'vendor_email',
                'pending'
            );
        END LOOP;

        v_changes := v_changes || jsonb_build_object('vendors_replaced', true, 'vendors_count', jsonb_array_length(v_vendors));
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 7: Audit trail — history entry
    -- ═══════════════════════════════════════════
    INSERT INTO t_contract_history (
        contract_id, tenant_id,
        action, from_status, to_status,
        changes,
        performed_by_type, performed_by_id, performed_by_name,
        note
    )
    VALUES (
        p_contract_id, v_tenant_id,
        'updated', v_current.status, v_current.status,
        v_changes,
        COALESCE(p_payload->>'performed_by_type', 'user'),
        v_updated_by,
        p_payload->>'performed_by_name',
        COALESCE(p_payload->>'note', 'Contract updated')
    );

    -- ═══════════════════════════════════════════
    -- STEP 8: Build + return response
    -- ═══════════════════════════════════════════
    DECLARE
        v_response JSONB;
    BEGIN
        v_response := jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'id', p_contract_id,
                'tenant_id', v_tenant_id,
                'version', v_current.version + 1,
                'status', v_current.status,
                'changes', v_changes
            ),
            'updated_at', NOW()
        );

        IF p_idempotency_key IS NOT NULL THEN
            PERFORM store_idempotency(
                p_idempotency_key,
                v_tenant_id,
                'update_contract_transaction',
                'PUT',
                NULL,
                200,
                v_response,
                24
            );
        END IF;

        RETURN v_response;
    END;

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to update contract',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION update_contract_transaction(UUID, JSONB, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION update_contract_transaction(UUID, JSONB, VARCHAR) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 5. update_contract_status
--    Status transition with flow validation, timestamp updates,
--    auto-accept rule, JTD event queueing, audit trail
--
--    Contract flow: draft → pending_review → pending_acceptance → active → completed / cancelled / expired
--    RFQ flow:      draft → sent → quotes_received → awarded → converted_to_contract / cancelled
--    Auto-accept:   if acceptance_method = 'auto', pending_acceptance → active is skipped
-- ─────────────────────────────────────────────────────────────
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
    -- STEP 6: Return response
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', p_contract_id,
            'tenant_id', p_tenant_id,
            'from_status', v_current.status,
            'to_status', p_new_status,
            'version', v_current.version + 1,
            'jtd_queued', v_jtd_source_code IS NOT NULL
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


-- ─────────────────────────────────────────────────────────────
-- 6. soft_delete_contract
--    Sets is_active = false. Only from draft or cancelled status.
--    Version check for concurrency. Audit trail.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION soft_delete_contract(
    p_contract_id UUID,
    p_tenant_id UUID,
    p_performed_by_id UUID DEFAULT NULL,
    p_performed_by_name VARCHAR DEFAULT NULL,
    p_version INTEGER DEFAULT NULL,
    p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current RECORD;
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

    -- ═══════════════════════════════════════════
    -- STEP 1: Lock row + fetch
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
            'error', 'Contract not found or already deleted',
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

    -- ═══════════════════════════════════════════
    -- STEP 2: Business rule — only draft/cancelled can be deleted
    -- ═══════════════════════════════════════════
    IF v_current.status NOT IN ('draft', 'cancelled') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('Cannot delete contract in %s status. Only draft or cancelled contracts can be deleted.', v_current.status),
            'error_code', 'DELETE_NOT_ALLOWED',
            'current_status', v_current.status
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Soft delete
    -- ═══════════════════════════════════════════
    UPDATE t_contracts SET
        is_active  = false,
        version    = version + 1,
        updated_by = p_performed_by_id
    WHERE id = p_contract_id
      AND tenant_id = p_tenant_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Audit trail
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
        'cancelled',
        v_current.status,
        v_current.status,
        jsonb_build_object(
            'action', 'soft_delete',
            'record_type', v_current.record_type,
            'contract_number', v_current.contract_number,
            'rfq_number', v_current.rfq_number,
            'name', v_current.name
        ),
        'user',
        p_performed_by_id,
        p_performed_by_name,
        COALESCE(p_note, 'Contract deleted')
    );

    -- ═══════════════════════════════════════════
    -- STEP 5: Return response
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', p_contract_id,
            'tenant_id', p_tenant_id,
            'record_type', v_current.record_type,
            'name', v_current.name,
            'deleted', true
        ),
        'deleted_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to delete contract',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION soft_delete_contract(UUID, UUID, UUID, VARCHAR, INTEGER, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION soft_delete_contract(UUID, UUID, UUID, VARCHAR, INTEGER, TEXT) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 7. get_contract_stats
--    Dashboard aggregates: count by status, record_type, contract_type,
--    total values. SECURITY DEFINER for hot-path read.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_contract_stats(
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_by_status JSONB;
    v_by_record_type JSONB;
    v_by_contract_type JSONB;
    v_totals RECORD;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Counts by status
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_object_agg(status, cnt),
        '{}'::JSONB
    )
    INTO v_by_status
    FROM (
        SELECT status, COUNT(*) AS cnt
        FROM t_contracts
        WHERE tenant_id = p_tenant_id
          AND is_live = p_is_live
          AND is_active = true
        GROUP BY status
    ) sub;

    -- ═══════════════════════════════════════════
    -- STEP 2: Counts by record_type
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_object_agg(record_type, cnt),
        '{}'::JSONB
    )
    INTO v_by_record_type
    FROM (
        SELECT record_type, COUNT(*) AS cnt
        FROM t_contracts
        WHERE tenant_id = p_tenant_id
          AND is_live = p_is_live
          AND is_active = true
        GROUP BY record_type
    ) sub;

    -- ═══════════════════════════════════════════
    -- STEP 3: Counts by contract_type
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_object_agg(contract_type, cnt),
        '{}'::JSONB
    )
    INTO v_by_contract_type
    FROM (
        SELECT contract_type, COUNT(*) AS cnt
        FROM t_contracts
        WHERE tenant_id = p_tenant_id
          AND is_live = p_is_live
          AND is_active = true
        GROUP BY contract_type
    ) sub;

    -- ═══════════════════════════════════════════
    -- STEP 4: Financial totals
    -- ═══════════════════════════════════════════
    SELECT
        COUNT(*) AS total_count,
        COALESCE(SUM(total_value), 0) AS sum_total_value,
        COALESCE(SUM(grand_total), 0) AS sum_grand_total,
        COALESCE(SUM(CASE WHEN status = 'active' THEN grand_total ELSE 0 END), 0) AS active_value,
        COALESCE(SUM(CASE WHEN status = 'draft' THEN grand_total ELSE 0 END), 0) AS draft_value
    INTO v_totals
    FROM t_contracts
    WHERE tenant_id = p_tenant_id
      AND is_live = p_is_live
      AND is_active = true;

    -- ═══════════════════════════════════════════
    -- STEP 5: Return response
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'total_count', v_totals.total_count,
            'by_status', v_by_status,
            'by_record_type', v_by_record_type,
            'by_contract_type', v_by_contract_type,
            'financials', jsonb_build_object(
                'total_value', v_totals.sum_total_value,
                'grand_total', v_totals.sum_grand_total,
                'active_value', v_totals.active_value,
                'draft_value', v_totals.draft_value
            )
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch contract stats',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_contract_stats(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contract_stats(UUID, BOOLEAN) TO service_role;
