-- ═══════════════════════════════════════════════════════════════════
-- 053_fix_cnak_draft_workflow.sql
-- 1. Reverts CNAK format from XXXX-XXXX-XXXX (14 chars, broken) back
--    to CNAK-XXXXXX (11 chars, original working format)
-- 2. Skips CNAK + contract_access generation for draft contracts
-- 3. Adds CNAK generation to update_contract_status when transitioning
--    from draft to any non-draft status (if CNAK is missing)
--
-- Root cause:
--   Migration 050 changed CNAK from 'CNAK-' || 6-char-hex (11 chars)
--   to XXXX-XXXX-XXXX (14 chars), exceeding the VARCHAR(12) column limit.
--   Additionally, drafts don't need CNAK until they are activated/sent.
--
-- Dependencies:
--   052_add_metadata_column.sql
-- ═══════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════
-- 1. REPLACE create_contract_transaction
--    Changes:
--    a) Revert CNAK format to CNAK-XXXXXX (original)
--    b) Skip CNAK + access_secret + contract_access for drafts
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION create_contract_transaction(
    p_payload JSONB,
    p_idempotency_key VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    -- Extracted fields
    v_tenant_id UUID;
    v_record_type VARCHAR(10);
    v_contract_type VARCHAR(20);
    v_is_live BOOLEAN;
    v_created_by UUID;

    -- Sequence
    v_seq_result JSONB;
    v_contract_number VARCHAR(30);
    v_rfq_number VARCHAR(30);

    -- Auto-accept
    v_acceptance_method VARCHAR(20);
    v_initial_status VARCHAR(30);

    -- Nomenclature (denormalized lookup)
    v_nomenclature_id UUID;
    v_nomenclature_code TEXT;
    v_nomenclature_name TEXT;

    -- Result
    v_contract_id UUID;
    v_contract RECORD;

    -- Blocks & Vendors
    v_blocks JSONB;
    v_vendors JSONB;
    v_block JSONB;
    v_vendor JSONB;
    v_block_id UUID;

    -- CNAK (ContractNest Access Key)
    v_cnak VARCHAR(12);
    v_access_secret VARCHAR(32);

    -- Idempotency
    v_idempotency RECORD;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    v_tenant_id := (p_payload->>'tenant_id')::UUID;
    v_record_type := COALESCE(p_payload->>'record_type', 'contract');
    v_contract_type := COALESCE(p_payload->>'contract_type', 'client');
    v_is_live := COALESCE((p_payload->>'is_live')::BOOLEAN, true);
    v_created_by := (p_payload->>'created_by')::UUID;

    IF v_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    IF p_payload->>'name' IS NULL OR TRIM(p_payload->>'name') = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract name is required'
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
            'create_contract_transaction'
        );

        IF v_idempotency.found THEN
            RETURN v_idempotency.response_body;
        END IF;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Generate contract number
    -- ═══════════════════════════════════════════
    IF v_record_type = 'rfq' THEN
        v_seq_result := get_next_formatted_sequence('PROJECT', v_tenant_id, v_is_live);
        v_rfq_number := v_seq_result->>'formatted';
    ELSE
        v_seq_result := get_next_formatted_sequence('CONTRACT', v_tenant_id, v_is_live);
        v_contract_number := v_seq_result->>'formatted';
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2.5: Resolve acceptance method + initial status
    -- ═══════════════════════════════════════════
    v_acceptance_method := COALESCE(p_payload->>'acceptance_method', 'manual');

    IF v_acceptance_method = 'auto' AND v_record_type = 'contract' THEN
        v_initial_status := 'active';
    ELSIF v_record_type = 'rfq' THEN
        v_initial_status := 'draft';
    ELSE
        v_initial_status := 'draft';
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2.6: Nomenclature denormalization
    -- ═══════════════════════════════════════════
    IF p_payload->>'nomenclature_id' IS NOT NULL THEN
        SELECT id, code, name
        INTO v_nomenclature_id, v_nomenclature_code, v_nomenclature_name
        FROM t_nomenclatures
        WHERE id = (p_payload->>'nomenclature_id')::UUID
          AND is_active = true
        LIMIT 1;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Generate CNAK (only for non-draft)
    --   Drafts don't need CNAK — it's generated
    --   when the contract transitions out of draft.
    -- ═══════════════════════════════════════════
    IF v_initial_status != 'draft' THEN
        v_access_secret := md5(random()::text || clock_timestamp()::text);

        FOR i IN 1..10 LOOP
            v_cnak := 'CNAK-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));

            IF NOT EXISTS (
                SELECT 1 FROM t_contracts
                WHERE tenant_id = v_tenant_id AND global_access_id = v_cnak
            ) THEN
                EXIT;
            END IF;
        END LOOP;
    ELSE
        -- Draft: no CNAK, no access_secret
        v_cnak := NULL;
        v_access_secret := NULL;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 4: Insert contract (WITH metadata)
    -- ═══════════════════════════════════════════
    INSERT INTO t_contracts (
        tenant_id,
        seller_id,
        contract_number,
        rfq_number,
        record_type,
        contract_type,
        path,
        template_id,
        name,
        description,
        status,
        buyer_id,
        buyer_name,
        buyer_company,
        buyer_email,
        buyer_phone,
        buyer_contact_person_id,
        buyer_contact_person_name,
        acceptance_method,
        start_date,
        duration_value,
        duration_unit,
        grace_period_value,
        grace_period_unit,
        currency,
        billing_cycle_type,
        payment_mode,
        emi_months,
        per_block_payment_type,
        total_value,
        tax_total,
        grand_total,
        selected_tax_rate_ids,
        tax_breakdown,
        computed_events,
        nomenclature_id,
        nomenclature_code,
        nomenclature_name,
        equipment_details,
        allow_buyer_to_add_equipment,
        coverage_types,
        metadata,
        global_access_id,
        version,
        is_live,
        is_active,
        created_by,
        updated_by
    )
    VALUES (
        v_tenant_id,
        v_tenant_id,                -- seller_id = creator tenant
        v_contract_number,
        v_rfq_number,
        v_record_type,
        v_contract_type,
        p_payload->>'path',
        (p_payload->>'template_id')::UUID,
        TRIM(p_payload->>'name'),
        p_payload->>'description',
        v_initial_status,
        (p_payload->>'buyer_id')::UUID,
        p_payload->>'buyer_name',
        p_payload->>'buyer_company',
        p_payload->>'buyer_email',
        p_payload->>'buyer_phone',
        (p_payload->>'buyer_contact_person_id')::UUID,
        p_payload->>'buyer_contact_person_name',
        v_acceptance_method,
        COALESCE((p_payload->>'start_date')::TIMESTAMPTZ, NOW()),
        (p_payload->>'duration_value')::INTEGER,
        p_payload->>'duration_unit',
        COALESCE((p_payload->>'grace_period_value')::INTEGER, 0),
        p_payload->>'grace_period_unit',
        COALESCE(p_payload->>'currency', 'INR'),
        p_payload->>'billing_cycle_type',
        p_payload->>'payment_mode',
        (p_payload->>'emi_months')::INTEGER,
        p_payload->>'per_block_payment_type',
        COALESCE((p_payload->>'total_value')::NUMERIC, 0),
        COALESCE((p_payload->>'tax_total')::NUMERIC, 0),
        COALESCE((p_payload->>'grand_total')::NUMERIC, 0),
        COALESCE(p_payload->'selected_tax_rate_ids', '[]'::JSONB),
        COALESCE(p_payload->'tax_breakdown', '[]'::JSONB),
        p_payload->'computed_events',
        v_nomenclature_id,
        v_nomenclature_code,
        v_nomenclature_name,
        COALESCE(p_payload->'equipment_details', '[]'::JSONB),
        COALESCE((p_payload->>'allow_buyer_to_add_equipment')::BOOLEAN, false),
        COALESCE(p_payload->'coverage_types', '[]'::JSONB),
        COALESCE(p_payload->'metadata', '{}'::JSONB),
        v_cnak,
        1,
        v_is_live,
        true,
        v_created_by,
        v_created_by
    )
    RETURNING id INTO v_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 5: Bulk insert blocks
    -- ═══════════════════════════════════════════
    v_blocks := COALESCE(p_payload->'blocks', '[]'::JSONB);

    FOR v_block IN SELECT * FROM jsonb_array_elements(v_blocks)
    LOOP
        INSERT INTO t_contract_blocks (
            contract_id, tenant_id, position,
            source_type, source_block_id,
            block_name, block_description,
            category_id, category_name,
            unit_price, quantity, billing_cycle,
            total_price,
            flyby_type, custom_fields
        )
        VALUES (
            v_contract_id, v_tenant_id,
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

    -- ═══════════════════════════════════════════
    -- STEP 6: Bulk insert vendors (RFQ only)
    -- ═══════════════════════════════════════════
    IF v_record_type = 'rfq' THEN
        v_vendors := COALESCE(p_payload->'vendors', '[]'::JSONB);

        FOR v_vendor IN SELECT * FROM jsonb_array_elements(v_vendors)
        LOOP
            INSERT INTO t_contract_vendors (
                contract_id, tenant_id,
                vendor_id, vendor_name, vendor_company, vendor_email,
                response_status
            )
            VALUES (
                v_contract_id, v_tenant_id,
                (v_vendor->>'vendor_id')::UUID,
                v_vendor->>'vendor_name',
                v_vendor->>'vendor_company',
                v_vendor->>'vendor_email',
                'pending'
            );
        END LOOP;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 7: Create history entry
    -- ═══════════════════════════════════════════
    INSERT INTO t_contract_history (
        contract_id, tenant_id,
        action, from_status, to_status,
        performed_by_type, performed_by_id, performed_by_name,
        note
    )
    VALUES (
        v_contract_id, v_tenant_id,
        'created', NULL, v_initial_status,
        COALESCE(p_payload->>'performed_by_type', 'user'),
        v_created_by,
        p_payload->>'performed_by_name',
        COALESCE(p_payload->>'note', v_record_type || ' created')
    );

    -- ═══════════════════════════════════════════
    -- STEP 7.5: Create contract_access row (only for non-draft)
    --   Drafts skip this — CNAK is NULL, so no access row needed.
    --   Access row is created when contract transitions out of draft.
    -- ═══════════════════════════════════════════
    IF v_cnak IS NOT NULL AND (p_payload->>'buyer_id') IS NOT NULL THEN
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
            v_contract_id,
            v_cnak,
            v_access_secret,
            v_tenant_id,
            v_tenant_id,
            NULL,
            COALESCE(v_contract_type, 'client'),
            (p_payload->>'buyer_id')::UUID,
            p_payload->>'buyer_email',
            p_payload->>'buyer_name',
            'pending',
            true,
            v_created_by
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 7.6: Auto-generate invoices (auto-accept only)
    -- ═══════════════════════════════════════════
    IF v_initial_status = 'active' AND v_record_type = 'contract' THEN
        PERFORM generate_contract_invoices(v_contract_id, v_tenant_id, v_created_by);
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 7.7: Auto-create events (auto-accept only)
    -- ═══════════════════════════════════════════
    IF v_initial_status = 'active' AND v_record_type = 'contract' THEN
        PERFORM process_contract_events_from_computed(v_contract_id, v_tenant_id);
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 8: Fetch the created contract for response
    -- ═══════════════════════════════════════════
    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = v_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 9: Build success response
    -- ═══════════════════════════════════════════
    DECLARE
        v_response JSONB;
    BEGIN
        v_response := jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'id', v_contract.id,
                'tenant_id', v_contract.tenant_id,
                'seller_id', v_contract.seller_id,
                'buyer_tenant_id', v_contract.buyer_tenant_id,
                'contract_number', v_contract.contract_number,
                'rfq_number', v_contract.rfq_number,
                'record_type', v_contract.record_type,
                'contract_type', v_contract.contract_type,
                'name', v_contract.name,
                'status', v_contract.status,
                'acceptance_method', v_contract.acceptance_method,
                'start_date', v_contract.start_date,
                'buyer_name', v_contract.buyer_name,
                'buyer_email', v_contract.buyer_email,
                'total_value', v_contract.total_value,
                'tax_total', v_contract.tax_total,
                'grand_total', v_contract.grand_total,
                'tax_breakdown', COALESCE(v_contract.tax_breakdown, '[]'::JSONB),
                'currency', v_contract.currency,
                'global_access_id', v_contract.global_access_id,
                'access_secret', v_access_secret,
                'nomenclature_id', v_contract.nomenclature_id,
                'nomenclature_code', v_contract.nomenclature_code,
                'nomenclature_name', v_contract.nomenclature_name,
                'equipment_details', COALESCE(v_contract.equipment_details, '[]'::JSONB),
                'allow_buyer_to_add_equipment', v_contract.allow_buyer_to_add_equipment,
                'coverage_types', COALESCE(v_contract.coverage_types, '[]'::JSONB),
                'metadata', COALESCE(v_contract.metadata, '{}'::JSONB),
                'version', v_contract.version,
                'created_at', v_contract.created_at
            ),
            'created_at', NOW()
        );

        -- Store idempotency (if key provided)
        IF p_idempotency_key IS NOT NULL THEN
            PERFORM store_idempotency(
                p_idempotency_key,
                v_tenant_id,
                'create_contract_transaction',
                'POST',
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
        'error', 'Failed to create contract',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION create_contract_transaction(JSONB, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION create_contract_transaction(JSONB, VARCHAR) TO service_role;

COMMENT ON FUNCTION create_contract_transaction IS 'Creates a contract with blocks, vendors, history, access, computed_events, nomenclature, equipment_details, coverage_types, metadata, start_date, and allow_buyer_to_add_equipment in a single transaction. Skips CNAK generation for drafts.';


-- ═══════════════════════════════════════════════════════════════════
-- 2. REPLACE update_contract_status
--    Change: Generate CNAK when transitioning FROM draft to any
--    non-draft status, if global_access_id is NULL.
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
            'jtd_queued', v_jtd_source_code IS NOT NULL,
            'cnak_generated', v_cnak IS NOT NULL
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

COMMENT ON FUNCTION update_contract_status IS 'Updates contract status with validation, history, JTD events, and auto-invoice generation. Now generates CNAK when transitioning from draft to non-draft status.';
