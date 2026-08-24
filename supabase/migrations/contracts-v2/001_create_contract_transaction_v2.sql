-- ═══════════════════════════════════════════════════════════════════
-- contracts-v2/001_create_contract_transaction_v2.sql
-- JTD Nucleus initiative — Milestone 1, Sprint 2
--
-- New, versioned RPC alongside (not replacing) create_contract_transaction.
-- Nothing in migrations/contracts/*.sql is modified by this file, and
-- nothing currently running calls this function yet.
--
-- Changes vs. V1 (contracts/053_fix_cnak_draft_workflow.sql):
--   1. p_tenant_id, p_seller_id, p_buyer_id are explicit, required
--      parameters — not optional keys buried inside p_payload. A call
--      missing any of the three fails immediately, instead of silently
--      producing a contract with no CNAK access grant (the traced root
--      cause of the 62/190-contracts-with-no-grant-row finding).
--   2. t_contract_access insert is unconditional on buyer presence
--      (still conditional on non-draft status, same as V1) — buyer_id
--      is now guaranteed by the parameter list itself, not hoped for
--      inside a JSONB blob.
--   3. Seller is no longer hardcoded to tenant_id — p_seller_id is
--      independent, per the confirmed rule that either side of a
--      contract may be a non-tenant identity.
--   4. Inserts a JTD commitment row (source_type_code='contract_created',
--      0 rows ever as of this session's audit) in the same transaction.
--      is_live is set explicitly from p_is_live — never left to the
--      column default. No manual pgmq.send() call is written here:
--      trg_jtd_enqueue (BEFORE INSERT on n_jtd) already writes the
--      queue message atomically as part of the same INSERT statement,
--      inside this function's transaction — confirmed live via
--      pg_trigger. (Side finding, not fixed here: update_contract_status's
--      hand-rolled pgmq.send for contract_sent/accepted/expired/rfq_sent
--      skips the n_jtd insert entirely and sends a message with no
--      jtd_id, which jtd-worker cannot resolve — the likely reason
--      those source types show 0 rows despite firing on every relevant
--      transition. Out of scope for this migration.)
--
-- Everything else (contract number sequencing, nomenclature lookup,
-- CNAK generation for non-drafts, block/vendor insert, history entry,
-- idempotency) is carried over unchanged from V1.
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION create_contract_transaction_v2(
    p_tenant_id UUID,
    p_seller_id UUID,
    p_buyer_id UUID,
    p_payload JSONB,
    p_is_live BOOLEAN DEFAULT true,
    p_idempotency_key VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_record_type VARCHAR(10);
    v_contract_type VARCHAR(20);
    v_created_by UUID;
    v_seq_result JSONB;
    v_contract_number VARCHAR(30);
    v_rfq_number VARCHAR(30);
    v_acceptance_method VARCHAR(20);
    v_initial_status VARCHAR(30);
    v_nomenclature_id UUID;
    v_nomenclature_code TEXT;
    v_nomenclature_name TEXT;
    v_contract_id UUID;
    v_contract RECORD;
    v_blocks JSONB;
    v_vendors JSONB;
    v_block JSONB;
    v_vendor JSONB;
    v_cnak VARCHAR(12);
    v_access_secret VARCHAR(32);
    v_idempotency RECORD;
    v_jtd_id UUID;
BEGIN
    -- STEP 0: Required-identity validation — the reason this sprint exists.
    -- A contract can never be created without a seller and a buyer, even
    -- when neither is the creating tenant itself.
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;
    IF p_seller_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'seller_id is required');
    END IF;
    IF p_buyer_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'buyer_id is required');
    END IF;
    IF p_payload->>'name' IS NULL OR TRIM(p_payload->>'name') = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Contract name is required');
    END IF;

    v_record_type := COALESCE(p_payload->>'record_type', 'contract');
    v_contract_type := COALESCE(p_payload->>'contract_type', 'client');
    v_created_by := (p_payload->>'created_by')::UUID;

    -- STEP 1: Idempotency check (reused pattern from V1)
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_idempotency
        FROM check_idempotency(p_idempotency_key, p_tenant_id, 'create_contract_transaction_v2');
        IF v_idempotency.found THEN
            RETURN v_idempotency.response_body;
        END IF;
    END IF;

    -- STEP 2: Generate contract number (reused pattern from V1)
    IF v_record_type = 'rfq' THEN
        v_seq_result := get_next_formatted_sequence('PROJECT', p_tenant_id, p_is_live);
        v_rfq_number := v_seq_result->>'formatted';
    ELSE
        v_seq_result := get_next_formatted_sequence('CONTRACT', p_tenant_id, p_is_live);
        v_contract_number := v_seq_result->>'formatted';
    END IF;

    -- STEP 2.5: Resolve acceptance method + initial status (reused from V1)
    v_acceptance_method := COALESCE(p_payload->>'acceptance_method', 'manual');
    IF v_acceptance_method = 'auto' AND v_record_type = 'contract' THEN
        v_initial_status := 'active';
    ELSIF v_record_type = 'rfq' THEN
        v_initial_status := 'draft';
    ELSE
        v_initial_status := 'draft';
    END IF;

    -- STEP 2.6: Nomenclature denormalization (reused from V1)
    IF (p_payload->>'nomenclature_id') IS NOT NULL THEN
        v_nomenclature_id := (p_payload->>'nomenclature_id')::UUID;

        SELECT cd.sub_cat_name, cd.display_name
        INTO v_nomenclature_code, v_nomenclature_name
        FROM m_category_details cd
        JOIN m_category_master cm ON cd.category_id = cm.id
        WHERE cd.id = v_nomenclature_id
          AND cm.category_name = 'cat_contract_nomenclature';

        IF v_nomenclature_code IS NULL THEN
            v_nomenclature_id := NULL;
        END IF;
    END IF;

    -- STEP 3: Generate CNAK (only for non-draft) — reused from V1
    IF v_initial_status != 'draft' THEN
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
    ELSE
        v_cnak := NULL;
        v_access_secret := NULL;
    END IF;

    -- STEP 4: Insert contract — seller_id and buyer_id come from the
    -- explicit required params now, not from p_payload extraction.
    INSERT INTO t_contracts (
        tenant_id, seller_id, contract_number, rfq_number,
        record_type, contract_type, path, template_id,
        name, description, status,
        buyer_id, buyer_name, buyer_company, buyer_email, buyer_phone,
        buyer_contact_person_id, buyer_contact_person_name,
        acceptance_method, start_date,
        duration_value, duration_unit,
        grace_period_value, grace_period_unit,
        currency, billing_cycle_type, payment_mode, emi_months,
        per_block_payment_type,
        total_value, tax_total, grand_total,
        selected_tax_rate_ids, tax_breakdown, computed_events,
        nomenclature_id, nomenclature_code, nomenclature_name,
        equipment_details, allow_buyer_to_add_equipment,
        coverage_types, metadata,
        global_access_id, version, is_live, is_active,
        created_by, updated_by
    )
    VALUES (
        p_tenant_id, p_seller_id,
        v_contract_number, v_rfq_number,
        v_record_type, v_contract_type,
        p_payload->>'path', (p_payload->>'template_id')::UUID,
        TRIM(p_payload->>'name'), p_payload->>'description',
        v_initial_status,
        p_buyer_id, p_payload->>'buyer_name',
        p_payload->>'buyer_company', p_payload->>'buyer_email', p_payload->>'buyer_phone',
        (p_payload->>'buyer_contact_person_id')::UUID, p_payload->>'buyer_contact_person_name',
        v_acceptance_method,
        COALESCE((p_payload->>'start_date')::TIMESTAMPTZ, NOW()),
        (p_payload->>'duration_value')::INTEGER, p_payload->>'duration_unit',
        COALESCE((p_payload->>'grace_period_value')::INTEGER, 0), p_payload->>'grace_period_unit',
        COALESCE(p_payload->>'currency', 'INR'),
        p_payload->>'billing_cycle_type', p_payload->>'payment_mode',
        (p_payload->>'emi_months')::INTEGER, p_payload->>'per_block_payment_type',
        COALESCE((p_payload->>'total_value')::NUMERIC, 0),
        COALESCE((p_payload->>'tax_total')::NUMERIC, 0),
        COALESCE((p_payload->>'grand_total')::NUMERIC, 0),
        COALESCE(p_payload->'selected_tax_rate_ids', '[]'::JSONB),
        COALESCE(p_payload->'tax_breakdown', '[]'::JSONB),
        p_payload->'computed_events',
        v_nomenclature_id, v_nomenclature_code, v_nomenclature_name,
        COALESCE(p_payload->'equipment_details', '[]'::JSONB),
        COALESCE((p_payload->>'allow_buyer_to_add_equipment')::BOOLEAN, false),
        COALESCE(p_payload->'coverage_types', '[]'::JSONB),
        COALESCE(p_payload->'metadata', '{}'::JSONB),
        v_cnak, 1, p_is_live, true,
        v_created_by, v_created_by
    )
    RETURNING id INTO v_contract_id;

    -- STEP 5: Bulk insert blocks (reused from V1)
    v_blocks := COALESCE(p_payload->'blocks', '[]'::JSONB);
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
            v_contract_id, p_tenant_id,
            COALESCE((v_block->>'position')::INTEGER, 0),
            COALESCE(v_block->>'source_type', 'flyby'),
            (v_block->>'source_block_id')::UUID,
            COALESCE(v_block->>'block_name', 'Untitled Block'),
            v_block->>'block_description',
            v_block->>'category_id', v_block->>'category_name',
            (v_block->>'unit_price')::NUMERIC,
            (v_block->>'quantity')::INTEGER,
            v_block->>'billing_cycle',
            (v_block->>'total_price')::NUMERIC,
            v_block->>'flyby_type',
            COALESCE(v_block->'custom_fields', '{}'::JSONB)
        );
    END LOOP;

    -- STEP 6: Bulk insert vendors (RFQ only) — reused from V1
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
                v_contract_id, p_tenant_id,
                (v_vendor->>'vendor_id')::UUID,
                v_vendor->>'vendor_name', v_vendor->>'vendor_company',
                v_vendor->>'vendor_email', 'pending'
            );
        END LOOP;
    END IF;

    -- STEP 7: Create history entry (reused from V1)
    INSERT INTO t_contract_history (
        contract_id, tenant_id,
        action, from_status, to_status,
        performed_by_type, performed_by_id, performed_by_name, note
    )
    VALUES (
        v_contract_id, p_tenant_id,
        'created', NULL, v_initial_status,
        COALESCE(p_payload->>'performed_by_type', 'user'),
        v_created_by, p_payload->>'performed_by_name',
        COALESCE(p_payload->>'note', v_record_type || ' created')
    );

    -- STEP 7.5: Create contract_access row (only for non-draft) — now
    -- UNCONDITIONAL on buyer presence, since buyer_id is guaranteed by
    -- the parameter list. Fixes the 62/190-contracts finding: V1 skipped
    -- this insert whenever p_payload->>'buyer_id' was absent from the
    -- JSONB blob, even though a buyer always exists for a real contract.
    IF v_cnak IS NOT NULL THEN
        INSERT INTO t_contract_access (
            contract_id, global_access_id, secret_code,
            tenant_id, creator_tenant_id, accessor_tenant_id,
            accessor_role, accessor_contact_id,
            accessor_email, accessor_name,
            status, is_active, created_by
        )
        VALUES (
            v_contract_id, v_cnak, v_access_secret,
            p_tenant_id, p_tenant_id, NULL,
            COALESCE(v_contract_type, 'client'),
            p_buyer_id,
            p_payload->>'buyer_email', p_payload->>'buyer_name',
            'pending', true, v_created_by
        );
    END IF;

    -- STEP 7.6: Auto-generate invoices (auto-accept only) — reused from V1
    IF v_initial_status = 'active' AND v_record_type = 'contract' THEN
        PERFORM generate_contract_invoices(v_contract_id, p_tenant_id, v_created_by);
    END IF;

    -- STEP 7.7: Auto-create events (auto-accept only) — reused from V1
    IF v_initial_status = 'active' AND v_record_type = 'contract' THEN
        PERFORM process_contract_events_from_computed(v_contract_id, p_tenant_id);
    END IF;

    -- STEP 7.8: JTD commitment — NEW. source_type_code='contract_created'
    -- has 0 rows ever, confirmed live this session. A plain INSERT is
    -- sufficient: trg_jtd_enqueue (BEFORE INSERT on n_jtd) writes the
    -- pgmq message atomically as part of this same statement, inside
    -- this function's transaction — no manual pgmq.send() needed.
    -- is_live is explicit from p_is_live, never left to the column
    -- default (which is `true` — silently wrong for a test-mode call).
    INSERT INTO n_jtd (
        tenant_id, event_type_code, channel_code, source_type_code,
        source_id, source_ref,
        recipient_type, recipient_id, recipient_name, recipient_contact,
        status_code, priority,
        payload, is_live,
        performed_by_type, performed_by_id, performed_by_name,
        created_by, updated_by
    )
    VALUES (
        p_tenant_id, 'notification', 'email', 'contract_created',
        v_contract_id, v_contract_number,
        'contact', p_buyer_id, p_payload->>'buyer_name', p_payload->>'buyer_email',
        'created', 5,
        jsonb_build_object(
            'contract_id', v_contract_id,
            'contract_number', v_contract_number,
            'contract_name', TRIM(p_payload->>'name'),
            'record_type', v_record_type,
            'status', v_initial_status
        ),
        p_is_live,
        -- chk_performer on n_jtd requires performed_by_id whenever
        -- performed_by_type='user'. Don't just trust the caller's claim —
        -- subscribe_tenant_to_plan_v2 (and V1's own payload, unexercised
        -- until this insert existed) hardcodes 'user' regardless of
        -- whether created_by is actually present. Override to 'system'
        -- whenever created_by is null, regardless of what was sent.
        CASE WHEN v_created_by IS NOT NULL THEN COALESCE(p_payload->>'performed_by_type', 'user') ELSE 'system' END,
        v_created_by, p_payload->>'performed_by_name',
        v_created_by, v_created_by
    )
    RETURNING id INTO v_jtd_id;

    -- STEP 8: Fetch the created contract for response
    SELECT * INTO v_contract FROM t_contracts WHERE id = v_contract_id;

    -- STEP 9: Build success response
    DECLARE
        v_response JSONB;
    BEGIN
        v_response := jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'id', v_contract.id,
                'tenant_id', v_contract.tenant_id,
                'seller_id', v_contract.seller_id,
                'buyer_id', v_contract.buyer_id,
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
                'created_at', v_contract.created_at,
                'jtd_id', v_jtd_id
            ),
            'created_at', NOW()
        );

        IF p_idempotency_key IS NOT NULL THEN
            PERFORM store_idempotency(
                p_idempotency_key, p_tenant_id,
                'create_contract_transaction_v2', 'POST', NULL,
                200, v_response, 24
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

COMMENT ON FUNCTION create_contract_transaction_v2 IS
'V2 of create_contract_transaction — JTD Nucleus initiative, Milestone 1 Sprint 2. Requires explicit tenant/seller/buyer ids (fixes the silent-CNAK-skip gap), inserts a contract_created JTD commitment atomically. Not called by any live pathway yet.';

GRANT EXECUTE ON FUNCTION create_contract_transaction_v2(UUID, UUID, UUID, JSONB, BOOLEAN, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION create_contract_transaction_v2(UUID, UUID, UUID, JSONB, BOOLEAN, VARCHAR) TO service_role;
