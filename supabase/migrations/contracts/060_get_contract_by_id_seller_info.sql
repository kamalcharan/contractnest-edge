-- ═══════════════════════════════════════════════════════════════
-- Migration 060: get_contract_by_id(UUID, UUID) — add seller info
-- ═══════════════════════════════════════════════════════════════
-- Problem:  The edge function calls the 2-param overload of
--           get_contract_by_id. On expense (buyer) view, there's
--           no seller/vendor name in the response.
--
-- Fix:     Update the 2-param overload to:
--          1. Track whether access is via buyer (accessor) path
--          2. Look up seller contact in buyer's workspace
--          3. Return seller_name, seller_company, seller_contact_id
--
-- Safety:  CREATE OR REPLACE on exact (UUID, UUID) signature
--          Adds 3 new nullable fields — non-breaking for clients
--          No schema changes, no downtime
-- ═══════════════════════════════════════════════════════════════

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
    v_is_buyer_access BOOLEAN := false;
    -- Seller contact info (new in 060)
    v_seller_name TEXT;
    v_seller_company TEXT;
    v_seller_contact_id UUID;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_contract_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'contract_id is required'
        );
    END IF;

    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Fetch contract -- owner OR accessor
    -- First try: requesting tenant is the owner
    -- Second try: requesting tenant has active access grant
    -- Third try: requesting tenant matches buyer_tenant_id
    -- ═══════════════════════════════════════════
    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND tenant_id = p_tenant_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        -- Check if requesting tenant has an active access grant (buyer/vendor/partner)
        SELECT ca.accessor_role INTO v_access_role
        FROM t_contract_access ca
        WHERE ca.contract_id = p_contract_id
          AND ca.accessor_tenant_id = p_tenant_id
          AND ca.is_active = true
          AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
        LIMIT 1;

        IF v_access_role IS NOT NULL THEN
            -- Accessor has a valid grant -- fetch the contract using the contract's own tenant
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
    -- STEP 1b (NEW - 060): Look up seller contact in buyer's workspace
    -- Only when the requesting tenant is a buyer, find the seller's
    -- contact record (created during CNAK claim) to get seller name.
    -- ═══════════════════════════════════════════
    IF v_is_buyer_access THEN
        SELECT c.id, c.name, c.company_name
        INTO v_seller_contact_id, v_seller_name, v_seller_company
        FROM t_contacts c
        WHERE c.tenant_id = p_tenant_id
          AND c.source_tenant_id = v_contract.tenant_id
          AND c.is_active = true
        LIMIT 1;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Fetch blocks (ordered by position)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', cb.id,
                'position', cb.position,
                'source_type', cb.source_type,
                'source_block_id', cb.source_block_id,
                'block_name', cb.block_name,
                'block_description', cb.block_description,
                'category_id', cb.category_id,
                'category_name', cb.category_name,
                'unit_price', cb.unit_price,
                'quantity', cb.quantity,
                'billing_cycle', cb.billing_cycle,
                'total_price', cb.total_price,
                'flyby_type', cb.flyby_type,
                'custom_fields', cb.custom_fields,
                'created_at', cb.created_at
            )
            ORDER BY cb.position ASC
        ),
        '[]'::JSONB
    )
    INTO v_blocks
    FROM t_contract_blocks cb
    WHERE cb.contract_id = p_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 3: Fetch vendors (RFQ only)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', cv.id,
                'vendor_id', cv.vendor_id,
                'vendor_name', cv.vendor_name,
                'vendor_company', cv.vendor_company,
                'vendor_email', cv.vendor_email,
                'response_status', cv.response_status,
                'responded_at', cv.responded_at,
                'quoted_amount', cv.quoted_amount,
                'quote_notes', cv.quote_notes,
                'created_at', cv.created_at
            )
        ),
        '[]'::JSONB
    )
    INTO v_vendors
    FROM t_contract_vendors cv
    WHERE cv.contract_id = p_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Fetch attachments
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', ca.id,
                'block_id', ca.block_id,
                'file_name', ca.file_name,
                'file_path', ca.file_path,
                'file_size', ca.file_size,
                'file_type', ca.file_type,
                'mime_type', ca.mime_type,
                'download_url', ca.download_url,
                'file_category', ca.file_category,
                'metadata', ca.metadata,
                'uploaded_by', ca.uploaded_by,
                'created_at', ca.created_at
            )
        ),
        '[]'::JSONB
    )
    INTO v_attachments
    FROM t_contract_attachments ca
    WHERE ca.contract_id = p_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 5: Fetch recent history (last 20 entries)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', ch.id,
                'action', ch.action,
                'from_status', ch.from_status,
                'to_status', ch.to_status,
                'changes', ch.changes,
                'performed_by_type', ch.performed_by_type,
                'performed_by_name', ch.performed_by_name,
                'note', ch.note,
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
    -- NOTE: Split into jsonb_build_object calls merged with ||
    --       to stay under the 100-argument PG limit.
    -- Updated (060): Added seller_name, seller_company, seller_contact_id
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', (
            -- Part A: core fields + counterparty + terms (28 pairs = 56 args)
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
                'duration_value', v_contract.duration_value,
                'duration_unit', v_contract.duration_unit,
                'grace_period_value', v_contract.grace_period_value,
                'grace_period_unit', v_contract.grace_period_unit,
                'currency', v_contract.currency,
                'billing_cycle_type', v_contract.billing_cycle_type
            )
            ||
            -- Part B: financials + dates + audit + relations (28 pairs = 56 args)
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
            -- Part C (NEW - 060): seller contact info (3 pairs = 6 args)
            jsonb_build_object(
                'seller_name', v_seller_name,
                'seller_company', v_seller_company,
                'seller_contact_id', v_seller_contact_id
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

-- Grants (match existing for 2-param version)
GRANT EXECUTE ON FUNCTION get_contract_by_id(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contract_by_id(UUID, UUID) TO service_role;
