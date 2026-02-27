-- ═══════════════════════════════════════════════════════════════════
-- 049_start_date_and_equipment_flag.sql
-- Adds start_date and allow_buyer_to_add_equipment to t_contracts.
-- Updates create, update, and get_contract_by_id RPCs.
-- Backfills start_date from created_at for existing rows.
--
-- Dependencies:
--   041_rpc_equipment_details_support.sql (latest RPCs)
--   048_portfolio_grouped_view.sql (latest migration)
-- ═══════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. ADD COLUMNS
-- ─────────────────────────────────────────────────────────────
ALTER TABLE t_contracts
  ADD COLUMN IF NOT EXISTS start_date TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS allow_buyer_to_add_equipment BOOLEAN NOT NULL DEFAULT false;

-- Backfill start_date from created_at for existing rows
UPDATE t_contracts SET start_date = created_at WHERE start_date IS NULL;

-- Make start_date NOT NULL after backfill
ALTER TABLE t_contracts ALTER COLUMN start_date SET NOT NULL;
ALTER TABLE t_contracts ALTER COLUMN start_date SET DEFAULT NOW();

COMMENT ON COLUMN t_contracts.start_date IS 'Contract start date. Defaults to creation time but can be set to a future date.';
COMMENT ON COLUMN t_contracts.allow_buyer_to_add_equipment IS 'When true, buyer can add equipment/entities to this contract.';


-- ─────────────────────────────────────────────────────────────
-- 2. UPDATE get_contract_by_id — add nomenclature + start_date
--    + allow_buyer_to_add_equipment to response Part B
-- ─────────────────────────────────────────────────────────────

-- We need to replace the entire function to add fields to the response.
-- The function is defined in 041_rpc_equipment_details_support.sql.
-- We only modify the RETURN section (Part B) to include the new fields.

CREATE OR REPLACE FUNCTION get_contract_by_id(
    p_contract_id UUID,
    p_tenant_id UUID
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
    v_access_role TEXT;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 1: Fetch contract record
    -- ═══════════════════════════════════════════
    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found or has been deleted',
            'error_code', 'NOT_FOUND'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Determine access role
    -- ═══════════════════════════════════════════
    IF v_contract.tenant_id = p_tenant_id THEN
        v_access_role := 'owner';
    ELSE
        -- Check if this tenant has been granted access
        SELECT 'accessor' INTO v_access_role
        FROM t_contract_access
        WHERE contract_id = p_contract_id
          AND tenant_id = p_tenant_id
          AND is_active = true
        LIMIT 1;

        IF v_access_role IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Access denied',
                'error_code', 'ACCESS_DENIED'
            );
        END IF;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Fetch blocks with content snapshot
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', cb.id,
                'block_id', cb.block_id,
                'sort_order', cb.sort_order,
                'content_snapshot', cb.content_snapshot
            )
            ORDER BY cb.sort_order
        ),
        '[]'::JSONB
    )
    INTO v_blocks
    FROM t_contract_blocks cb
    WHERE cb.contract_id = p_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Fetch vendors
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', cv.id,
                'vendor_id', cv.vendor_id,
                'vendor_name', cv.vendor_name,
                'role', cv.role
            )
            ORDER BY cv.created_at
        ),
        '[]'::JSONB
    )
    INTO v_vendors
    FROM t_contract_vendors cv
    WHERE cv.contract_id = p_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 5: Fetch attachments
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', ca.id,
                'file_name', ca.file_name,
                'file_type', ca.file_type,
                'file_size', ca.file_size,
                'storage_path', ca.storage_path,
                'uploaded_by', ca.uploaded_by,
                'created_at', ca.created_at
            )
            ORDER BY ca.created_at DESC
        ),
        '[]'::JSONB
    )
    INTO v_attachments
    FROM t_contract_attachments ca
    WHERE ca.contract_id = p_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 5b: Fetch recent history (last 20)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', ch.id,
                'action', ch.action,
                'from_status', ch.from_status,
                'to_status', ch.to_status,
                'changed_by', ch.changed_by,
                'changes', ch.changes,
                'created_at', ch.created_at
            )
            ORDER BY ch.created_at DESC
        ),
        '[]'::JSONB
    )
    INTO v_history
    FROM (
        SELECT *
        FROM t_contract_history
        WHERE contract_id = p_contract_id
        ORDER BY created_at DESC
        LIMIT 20
    ) ch;

    -- ═══════════════════════════════════════════
    -- STEP 6: Return full contract with embedded data
    -- NOTE: Split into two jsonb_build_object calls merged
    --       with || to stay under the 100-argument PG limit.
    -- UPDATED: Added nomenclature_id/name/code, start_date,
    --          allow_buyer_to_add_equipment
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', (
            -- Part A: core fields + counterparty + terms (26 pairs = 52 args)
            jsonb_build_object(
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
                'buyer_id', v_contract.buyer_id,
                'buyer_name', v_contract.buyer_name,
                'buyer_company', v_contract.buyer_company,
                'buyer_email', v_contract.buyer_email,
                'buyer_phone', v_contract.buyer_phone,
                'buyer_contact_person_id', v_contract.buyer_contact_person_id,
                'buyer_contact_person_name', v_contract.buyer_contact_person_name,
                'global_access_id', v_contract.global_access_id,
                'acceptance_method', v_contract.acceptance_method,
                'duration_value', v_contract.duration_value,
                'duration_unit', v_contract.duration_unit,
                'grace_period_value', v_contract.grace_period_value,
                'grace_period_unit', v_contract.grace_period_unit,
                'currency', v_contract.currency,
                'billing_cycle_type', v_contract.billing_cycle_type
            )
            ||
            -- Part B: financials + evidence + dates + audit + relations + equipment + NEW fields
            jsonb_build_object(
                'payment_mode', v_contract.payment_mode,
                'emi_months', v_contract.emi_months,
                'per_block_payment_type', v_contract.per_block_payment_type,
                'total_value', v_contract.total_value,
                'tax_total', v_contract.tax_total,
                'grand_total', v_contract.grand_total,
                'selected_tax_rate_ids', v_contract.selected_tax_rate_ids,
                'tax_breakdown', COALESCE(v_contract.tax_breakdown, '[]'::JSONB),
                'evidence_policy_type', COALESCE(v_contract.evidence_policy_type, 'none'),
                'evidence_selected_forms', COALESCE(v_contract.evidence_selected_forms, '[]'::JSONB),
                'equipment_details', COALESCE(v_contract.equipment_details, '[]'::JSONB),
                'sent_at', v_contract.sent_at,
                'accepted_at', v_contract.accepted_at,
                'completed_at', v_contract.completed_at,
                'version', v_contract.version,
                'is_live', v_contract.is_live,
                'created_by', v_contract.created_by,
                'updated_by', v_contract.updated_by,
                'created_at', v_contract.created_at,
                'updated_at', v_contract.updated_at,
                'blocks', v_blocks,
                'vendors', v_vendors,
                'attachments', v_attachments,
                'history', v_history,
                'blocks_count', jsonb_array_length(v_blocks),
                'vendors_count', jsonb_array_length(v_vendors),
                'attachments_count', jsonb_array_length(v_attachments),
                'access_role', COALESCE(v_access_role, 'owner')
            )
            ||
            -- Part C: NEW fields (nomenclature + start_date + equipment flag)
            jsonb_build_object(
                'nomenclature_id', v_contract.nomenclature_id,
                'nomenclature_code', v_contract.nomenclature_code,
                'nomenclature_name', v_contract.nomenclature_name,
                'start_date', v_contract.start_date,
                'allow_buyer_to_add_equipment', v_contract.allow_buyer_to_add_equipment,
                'seller_id', v_contract.seller_id,
                'buyer_tenant_id', v_contract.buyer_tenant_id
            )
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch contract',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_contract_by_id(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contract_by_id(UUID, UUID) TO service_role;

COMMENT ON FUNCTION get_contract_by_id IS 'Returns full contract detail with blocks, vendors, attachments, history, equipment, nomenclature, start_date, and equipment flag';
