-- ═══════════════════════════════════════════════════════════════════
-- 050_coverage_types_and_rpc_fix.sql
-- 1. Adds coverage_types JSONB column to t_contracts
-- 2. Updates create_contract_transaction to include:
--    - start_date
--    - allow_buyer_to_add_equipment
--    - coverage_types
-- 3. Updates update_contract_transaction to include:
--    - start_date
--    - allow_buyer_to_add_equipment
--    - coverage_types
-- 4. Updates get_contract_by_id to return coverage_types
--
-- Dependencies:
--   049_start_date_and_equipment_flag.sql
--   041_rpc_equipment_details_support.sql
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. ADD coverage_types COLUMN
-- ─────────────────────────────────────────────────────────────
ALTER TABLE t_contracts
  ADD COLUMN IF NOT EXISTS coverage_types JSONB DEFAULT '[]'::JSONB;

COMMENT ON COLUMN t_contracts.coverage_types
  IS 'Array of coverage type items selected in the wizard. Each element: {id, sub_category, resource_id, resource_name}.';


-- ═══════════════════════════════════════════════════════════════════
-- 2. REPLACE create_contract_transaction
--    Now includes: start_date, allow_buyer_to_add_equipment, coverage_types
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
    v_seq_result := generate_next_number(v_tenant_id, v_record_type);
    v_contract_number := v_seq_result->>'contract_number';
    v_rfq_number := v_seq_result->>'rfq_number';

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
    -- STEP 3: Generate CNAK (global access key)
    -- ═══════════════════════════════════════════
    v_access_secret := encode(gen_random_bytes(16), 'hex');

    FOR i IN 1..10 LOOP
        v_cnak := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4))
               || '-'
               || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4))
               || '-'
               || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));

        IF NOT EXISTS (
            SELECT 1 FROM t_contracts
            WHERE tenant_id = v_tenant_id AND global_access_id = v_cnak
        ) THEN
            EXIT;
        END IF;
    END LOOP;

    -- ═══════════════════════════════════════════
    -- STEP 4: Insert contract (WITH start_date, allow_buyer_to_add_equipment, coverage_types)
    -- ═══════════════════════════════════════════
    INSERT INTO t_contracts (
        tenant_id,
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
        global_access_id,
        version,
        is_live,
        is_active,
        created_by,
        updated_by
    )
    VALUES (
        v_tenant_id,
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
            custom_cycle_days, service_cycle_days,
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
            (v_block->>'custom_cycle_days')::INTEGER,
            (v_block->>'service_cycle_days')::INTEGER,
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
    -- STEP 7.5: Create contract_access row (for CNAK-based access)
    -- ═══════════════════════════════════════════
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_name = 't_contract_access' AND table_schema = 'public'
    ) THEN
        INSERT INTO t_contract_access (
            contract_id,
            access_key,
            access_secret,
            owner_tenant_id,
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

COMMENT ON FUNCTION create_contract_transaction IS 'Creates a contract with blocks, vendors, history, access, computed_events, nomenclature, equipment_details, coverage_types, start_date, and allow_buyer_to_add_equipment in a single transaction';


-- ═══════════════════════════════════════════════════════════════════
-- 3. REPLACE update_contract_transaction
--    Now includes: start_date, allow_buyer_to_add_equipment, coverage_types
-- ═══════════════════════════════════════════════════════════════════

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
    IF p_payload ? 'equipment_details' AND p_payload->'equipment_details' IS DISTINCT FROM v_current.equipment_details THEN
        v_changes := v_changes || jsonb_build_object('equipment_details_updated', true,
            'equipment_details_count', jsonb_build_object(
                'from', jsonb_array_length(COALESCE(v_current.equipment_details, '[]'::JSONB)),
                'to', jsonb_array_length(COALESCE(p_payload->'equipment_details', '[]'::JSONB))
            )
        );
    END IF;
    IF p_payload ? 'coverage_types' AND p_payload->'coverage_types' IS DISTINCT FROM v_current.coverage_types THEN
        v_changes := v_changes || jsonb_build_object('coverage_types_updated', true,
            'coverage_types_count', jsonb_build_object(
                'from', jsonb_array_length(COALESCE(v_current.coverage_types, '[]'::JSONB)),
                'to', jsonb_array_length(COALESCE(p_payload->'coverage_types', '[]'::JSONB))
            )
        );
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
        start_date         = CASE WHEN p_payload ? 'start_date' THEN (p_payload->>'start_date')::TIMESTAMPTZ ELSE v_current.start_date END,
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

        -- Equipment details (denormalized JSONB array)
        equipment_details  = CASE WHEN p_payload ? 'equipment_details' THEN p_payload->'equipment_details' ELSE v_current.equipment_details END,
        allow_buyer_to_add_equipment = CASE WHEN p_payload ? 'allow_buyer_to_add_equipment' THEN (p_payload->>'allow_buyer_to_add_equipment')::BOOLEAN ELSE v_current.allow_buyer_to_add_equipment END,
        coverage_types     = CASE WHEN p_payload ? 'coverage_types' THEN p_payload->'coverage_types' ELSE v_current.coverage_types END,

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
    -- STEP 8: Fetch updated contract for response
    -- ═══════════════════════════════════════════
    SELECT * INTO v_current
    FROM t_contracts
    WHERE id = p_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 9: Build success response
    -- ═══════════════════════════════════════════
    DECLARE
        v_response JSONB;
    BEGIN
        v_response := jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'id', v_current.id,
                'tenant_id', v_current.tenant_id,
                'contract_number', v_current.contract_number,
                'record_type', v_current.record_type,
                'name', v_current.name,
                'status', v_current.status,
                'start_date', v_current.start_date,
                'equipment_details', COALESCE(v_current.equipment_details, '[]'::JSONB),
                'allow_buyer_to_add_equipment', v_current.allow_buyer_to_add_equipment,
                'coverage_types', COALESCE(v_current.coverage_types, '[]'::JSONB),
                'version', v_current.version,
                'updated_at', v_current.updated_at
            )
        );

        IF p_idempotency_key IS NOT NULL THEN
            PERFORM store_idempotency(
                p_idempotency_key,
                v_tenant_id,
                'update_contract_transaction',
                'PUT',
                p_contract_id::TEXT,
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

COMMENT ON FUNCTION update_contract_transaction IS 'Updates a contract with optimistic concurrency, audit trail, equipment_details, coverage_types, start_date, and allow_buyer_to_add_equipment';


-- ═══════════════════════════════════════════════════════════════════
-- 4. UPDATE get_contract_by_id to return coverage_types
--    (Replaces the version from 049 which missed coverage_types)
-- ═══════════════════════════════════════════════════════════════════

-- We only need to add coverage_types to the response.
-- The function from 049 already returns start_date, allow_buyer_to_add_equipment,
-- and equipment_details. We re-create it adding coverage_types.

CREATE OR REPLACE FUNCTION get_contract_by_id(
    p_contract_id UUID,
    p_tenant_id UUID DEFAULT NULL,
    p_access_key VARCHAR DEFAULT NULL,
    p_access_secret VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_contract RECORD;
    v_blocks JSONB;
    v_vendors JSONB;
    v_attachments JSONB;
    v_history JSONB;
    v_evidence_forms JSONB;
    v_result JSONB;
    v_tenant_id UUID;
    v_is_buyer_access BOOLEAN := false;
    v_access_record RECORD;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 1: Determine access method
    -- ═══════════════════════════════════════════
    IF p_access_key IS NOT NULL AND p_access_secret IS NOT NULL THEN
        -- CNAK-based access (buyer/external)
        SELECT ca.*, c.tenant_id AS contract_tenant_id
        INTO v_access_record
        FROM t_contract_access ca
        JOIN t_contracts c ON c.id = ca.contract_id
        WHERE ca.contract_id = p_contract_id
          AND ca.access_key = p_access_key
          AND ca.access_secret = p_access_secret
          AND ca.is_active = true;

        IF v_access_record IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Invalid access credentials'
            );
        END IF;

        v_tenant_id := v_access_record.contract_tenant_id;
        v_is_buyer_access := true;

    ELSIF p_tenant_id IS NOT NULL THEN
        -- Direct tenant access (seller)
        v_tenant_id := p_tenant_id;
    ELSE
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Either tenant_id or access credentials required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Fetch contract
    -- ═══════════════════════════════════════════
    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND tenant_id = v_tenant_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Fetch related blocks
    -- ═══════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', b.id,
            'position', b.position,
            'source_type', b.source_type,
            'source_block_id', b.source_block_id,
            'block_name', b.block_name,
            'block_description', b.block_description,
            'category_id', b.category_id,
            'category_name', b.category_name,
            'unit_price', b.unit_price,
            'quantity', b.quantity,
            'billing_cycle', b.billing_cycle,
            'custom_cycle_days', b.custom_cycle_days,
            'service_cycle_days', b.service_cycle_days,
            'total_price', b.total_price,
            'flyby_type', b.flyby_type,
            'custom_fields', COALESCE(b.custom_fields, '{}'::JSONB)
        ) ORDER BY b.position
    ), '[]'::JSONB)
    INTO v_blocks
    FROM t_contract_blocks b
    WHERE b.contract_id = p_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Fetch related vendors
    -- ═══════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', v.id,
            'vendor_id', v.vendor_id,
            'vendor_name', v.vendor_name,
            'vendor_company', v.vendor_company,
            'vendor_email', v.vendor_email,
            'response_status', v.response_status,
            'quoted_total', v.quoted_total,
            'quoted_blocks', COALESCE(v.quoted_blocks, '[]'::JSONB),
            'responded_at', v.responded_at
        )
    ), '[]'::JSONB)
    INTO v_vendors
    FROM t_contract_vendors v
    WHERE v.contract_id = p_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 5: Fetch attachments (if table exists)
    -- ═══════════════════════════════════════════
    v_attachments := '[]'::JSONB;
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_name = 't_contract_attachments' AND table_schema = 'public'
    ) THEN
        EXECUTE format(
            'SELECT COALESCE(jsonb_agg(
                jsonb_build_object(
                    ''id'', a.id,
                    ''file_name'', a.file_name,
                    ''file_type'', a.file_type,
                    ''file_size'', a.file_size,
                    ''storage_path'', a.storage_path,
                    ''uploaded_by'', a.uploaded_by,
                    ''created_at'', a.created_at
                )
            ), ''[]''::JSONB)
            FROM t_contract_attachments a
            WHERE a.contract_id = %L', p_contract_id
        ) INTO v_attachments;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 6: Fetch history (last 50 entries)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', h.id,
            'action', h.action,
            'from_status', h.from_status,
            'to_status', h.to_status,
            'changes', COALESCE(h.changes, '{}'::JSONB),
            'performed_by_type', h.performed_by_type,
            'performed_by_id', h.performed_by_id,
            'performed_by_name', h.performed_by_name,
            'note', h.note,
            'created_at', h.created_at
        ) ORDER BY h.created_at DESC
    ), '[]'::JSONB)
    INTO v_history
    FROM (
        SELECT * FROM t_contract_history
        WHERE contract_id = p_contract_id
        ORDER BY created_at DESC
        LIMIT 50
    ) h;

    -- ═══════════════════════════════════════════
    -- STEP 7: Fetch evidence forms (if table exists)
    -- ═══════════════════════════════════════════
    v_evidence_forms := '[]'::JSONB;
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_name = 't_contract_evidence_forms' AND table_schema = 'public'
    ) THEN
        EXECUTE format(
            'SELECT COALESCE(jsonb_agg(
                jsonb_build_object(
                    ''id'', ef.id,
                    ''form_template_id'', ef.form_template_id,
                    ''name'', ef.name,
                    ''version'', ef.version,
                    ''category'', ef.category,
                    ''sort_order'', ef.sort_order
                ) ORDER BY ef.sort_order
            ), ''[]''::JSONB)
            FROM t_contract_evidence_forms ef
            WHERE ef.contract_id = %L', p_contract_id
        ) INTO v_evidence_forms;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 8: Build full response
    -- ═══════════════════════════════════════════
    v_result := jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            -- Part A: Core contract fields
            'id', v_contract.id,
            'tenant_id', v_contract.tenant_id,
            'contract_number', v_contract.contract_number,
            'rfq_number', v_contract.rfq_number,
            'record_type', v_contract.record_type,
            'contract_type', v_contract.contract_type,
            'path', v_contract.path,
            'template_id', v_contract.template_id,
            'name', v_contract.name,
            'description', v_contract.description,
            'status', v_contract.status,

            -- Part B: Counterparty
            'buyer_id', v_contract.buyer_id,
            'buyer_name', v_contract.buyer_name,
            'buyer_company', v_contract.buyer_company,
            'buyer_email', v_contract.buyer_email,
            'buyer_phone', v_contract.buyer_phone,
            'buyer_contact_person_id', v_contract.buyer_contact_person_id,
            'buyer_contact_person_name', v_contract.buyer_contact_person_name,

            -- Part B2: Contract details
            'acceptance_method', v_contract.acceptance_method,
            'start_date', v_contract.start_date,
            'duration_value', v_contract.duration_value,
            'duration_unit', v_contract.duration_unit,
            'grace_period_value', v_contract.grace_period_value,
            'grace_period_unit', v_contract.grace_period_unit,

            -- Part B3: Billing
            'currency', v_contract.currency,
            'billing_cycle_type', v_contract.billing_cycle_type,
            'payment_mode', v_contract.payment_mode,
            'emi_months', v_contract.emi_months,
            'per_block_payment_type', v_contract.per_block_payment_type,
            'total_value', v_contract.total_value,
            'tax_total', v_contract.tax_total,
            'grand_total', v_contract.grand_total,
            'selected_tax_rate_ids', COALESCE(v_contract.selected_tax_rate_ids, '[]'::JSONB),
            'tax_breakdown', COALESCE(v_contract.tax_breakdown, '[]'::JSONB),

            -- Part B4: Computed events & Evidence
            'computed_events', v_contract.computed_events,
            'evidence_policy_type', v_contract.evidence_policy_type,

            -- Part C: Nomenclature, start_date, equipment, coverage
            'nomenclature_id', v_contract.nomenclature_id,
            'nomenclature_code', v_contract.nomenclature_code,
            'nomenclature_name', v_contract.nomenclature_name,
            'equipment_details', COALESCE(v_contract.equipment_details, '[]'::JSONB),
            'allow_buyer_to_add_equipment', v_contract.allow_buyer_to_add_equipment,
            'coverage_types', COALESCE(v_contract.coverage_types, '[]'::JSONB),

            -- Part D: Access
            'global_access_id', v_contract.global_access_id,

            -- Part E: Related entities
            'blocks', v_blocks,
            'vendors', v_vendors,
            'attachments', v_attachments,
            'history', v_history,
            'evidence_forms', v_evidence_forms,

            -- Part F: Metadata
            'version', v_contract.version,
            'is_live', v_contract.is_live,
            'created_by', v_contract.created_by,
            'updated_by', v_contract.updated_by,
            'created_at', v_contract.created_at,
            'updated_at', v_contract.updated_at
        ),
        'is_buyer_access', v_is_buyer_access
    );

    RETURN v_result;

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to retrieve contract',
        'details', SQLERRM
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_contract_by_id(UUID, UUID, VARCHAR, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contract_by_id(UUID, UUID, VARCHAR, VARCHAR) TO service_role;

COMMENT ON FUNCTION get_contract_by_id IS 'Returns full contract detail with blocks, vendors, attachments, history, equipment, nomenclature, start_date, equipment flag, and coverage_types';
