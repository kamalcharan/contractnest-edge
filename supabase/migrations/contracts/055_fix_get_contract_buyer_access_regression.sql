-- ============================================================================
-- FIX: get_contract_by_id — restore buyer access via tenant_id
-- Migration: contracts/055_fix_get_contract_buyer_access_regression.sql
--
-- REGRESSION: Migration 052 rewrote get_contract_by_id with a 4-param
-- signature (p_contract_id, p_tenant_id, p_access_key, p_access_secret)
-- but DROPPED the buyer access fallback that migration 031 had added.
--
-- 031 had:  "If tenant_id doesn't match contract owner, check
--            t_contract_access for an active accessor grant."
--
-- 052 only checks: tenant_id = p_tenant_id (owner match).
-- Result: buyer gets "Contract not found" after claiming via CNAK,
-- because the UI fetches with buyer's tenant_id, which doesn't match
-- the contract's tenant_id (seller's).
--
-- FIX: Restore the t_contract_access fallback + also check
-- buyer_tenant_id on t_contracts as an additional path.
-- Everything else (blocks, vendors, response shape) stays identical.
-- ============================================================================

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
    v_access_role TEXT;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 1: Determine access method
    -- ═══════════════════════════════════════════
    IF p_access_key IS NOT NULL AND p_access_secret IS NOT NULL THEN
        -- CNAK-based access (buyer/external via link)
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
        -- Direct tenant access — could be seller OR buyer
        v_tenant_id := p_tenant_id;
    ELSE
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Either tenant_id or access credentials required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Fetch contract
    --   Path A: requesting tenant is the owner (seller)
    --   Path B: requesting tenant has an active access grant (buyer who claimed)
    --   Path C: requesting tenant matches buyer_tenant_id on the contract
    -- ═══════════════════════════════════════════

    -- Path A: Owner (seller) — tenant_id matches directly
    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND tenant_id = v_tenant_id
      AND is_active = true;

    -- Path B & C: Only needed when Path A fails AND we're using tenant_id (not CNAK)
    IF v_contract IS NULL AND NOT v_is_buyer_access THEN

        -- Path B: Check t_contract_access for active accessor grant
        SELECT ca.accessor_role INTO v_access_role
        FROM t_contract_access ca
        WHERE ca.contract_id = p_contract_id
          AND ca.accessor_tenant_id = p_tenant_id
          AND ca.is_active = true
          AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
        LIMIT 1;

        IF v_access_role IS NOT NULL THEN
            -- Buyer has a valid access grant — fetch using contract's own data
            SELECT * INTO v_contract
            FROM t_contracts
            WHERE id = p_contract_id
              AND is_active = true;

            v_is_buyer_access := true;
        END IF;

        -- Path C: Check buyer_tenant_id on the contract itself
        IF v_contract IS NULL THEN
            SELECT * INTO v_contract
            FROM t_contracts
            WHERE id = p_contract_id
              AND buyer_tenant_id = p_tenant_id
              AND is_active = true;

            IF v_contract IS NOT NULL THEN
                v_is_buyer_access := true;
            END IF;
        END IF;
    END IF;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found',
            'contract_id', p_contract_id
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
            'responded_at', v.responded_at,
            'quoted_amount', v.quoted_amount,
            'quote_notes', v.quote_notes,
            'created_at', v.created_at
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
                    ''block_id'', a.block_id,
                    ''file_name'', a.file_name,
                    ''file_path'', a.file_path,
                    ''file_size'', a.file_size,
                    ''file_type'', a.file_type,
                    ''mime_type'', a.mime_type,
                    ''download_url'', a.download_url,
                    ''file_category'', a.file_category,
                    ''metadata'', a.metadata,
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
    -- NOTE: Split into jsonb_build_object calls merged with ||
    --       to stay under PostgreSQL's 100-argument limit.
    -- ═══════════════════════════════════════════
    v_result := jsonb_build_object(
        'success', true,
        'data', (
            -- Part A: core + counterparty + terms (25 pairs = 50 args)
            jsonb_build_object(
                'id', v_contract.id,
                'tenant_id', v_contract.tenant_id,
                'seller_id', v_contract.seller_id,
                'buyer_tenant_id', v_contract.buyer_tenant_id,
                'contract_number', v_contract.contract_number,
                'rfq_number', v_contract.rfq_number,
                'record_type', v_contract.record_type,
                'contract_type', v_contract.contract_type,
                'path', v_contract.path,
                'template_id', v_contract.template_id,
                'name', v_contract.name,
                'description', v_contract.description,
                'status', v_contract.status,
                'buyer_id', v_contract.buyer_id,
                'buyer_name', v_contract.buyer_name,
                'buyer_company', v_contract.buyer_company,
                'buyer_email', v_contract.buyer_email,
                'buyer_phone', v_contract.buyer_phone,
                'buyer_contact_person_id', v_contract.buyer_contact_person_id,
                'buyer_contact_person_name', v_contract.buyer_contact_person_name,
                'global_access_id', v_contract.global_access_id,
                'acceptance_method', v_contract.acceptance_method,
                'start_date', v_contract.start_date,
                'duration_value', v_contract.duration_value,
                'duration_unit', v_contract.duration_unit
            )
            ||
            -- Part B: billing + financials + evidence + nomenclature + equipment + metadata + relations + audit (30 pairs = 60 args)
            jsonb_build_object(
                'grace_period_value', v_contract.grace_period_value,
                'grace_period_unit', v_contract.grace_period_unit,
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
                'computed_events', v_contract.computed_events,
                'evidence_policy_type', COALESCE(v_contract.evidence_policy_type, 'none'),
                'evidence_selected_forms', COALESCE(v_contract.evidence_selected_forms, '[]'::JSONB),
                'nomenclature_id', v_contract.nomenclature_id,
                'nomenclature_code', v_contract.nomenclature_code,
                'nomenclature_name', v_contract.nomenclature_name,
                'equipment_details', COALESCE(v_contract.equipment_details, '[]'::JSONB),
                'allow_buyer_to_add_equipment', v_contract.allow_buyer_to_add_equipment,
                'coverage_types', COALESCE(v_contract.coverage_types, '[]'::JSONB),
                'metadata', COALESCE(v_contract.metadata, '{}'::JSONB),
                'blocks', v_blocks,
                'vendors', v_vendors,
                'attachments', v_attachments,
                'history', v_history,
                'evidence_forms', v_evidence_forms,
                'blocks_count', jsonb_array_length(v_blocks),
                'vendors_count', jsonb_array_length(v_vendors),
                'attachments_count', jsonb_array_length(v_attachments)
            )
            ||
            -- Part C: version + audit (8 pairs = 16 args)
            jsonb_build_object(
                'version', v_contract.version,
                'is_live', v_contract.is_live,
                'created_by', v_contract.created_by,
                'updated_by', v_contract.updated_by,
                'created_at', v_contract.created_at,
                'updated_at', v_contract.updated_at,
                'sent_at', v_contract.sent_at,
                'accepted_at', v_contract.accepted_at,
                'completed_at', v_contract.completed_at,
                'access_role', CASE WHEN v_is_buyer_access THEN 'buyer' ELSE 'owner' END
            )
        ),
        'is_buyer_access', v_is_buyer_access
    );

    RETURN v_result;

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

-- Grants (match existing)
GRANT EXECUTE ON FUNCTION get_contract_by_id(UUID, UUID, VARCHAR, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contract_by_id(UUID, UUID, VARCHAR, VARCHAR) TO service_role;
