-- =============================================================
-- FIX: get_contract_by_id exceeds 100 argument limit
-- Migration: contracts/030_fix_get_contract_by_id_arg_limit.sql
--
-- ISSUE: Migration 029 added evidence_policy_type and
-- evidence_selected_forms to the jsonb_build_object() call,
-- pushing it to 104 arguments (52 key-value pairs).
-- PostgreSQL hard-limits functions to 100 arguments (error 54023).
--
-- FIX: Split the inner jsonb_build_object into two halves
-- concatenated with ||, keeping each under the 100 arg limit.
-- =============================================================

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
    -- STEP 1: Fetch contract
    -- ═══════════════════════════════════════════
    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND tenant_id = p_tenant_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found',
            'contract_id', p_contract_id
        );
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
    -- NOTE: Split into two jsonb_build_object calls merged
    --       with || to stay under the 100-argument PG limit.
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
            -- Part B: financials + evidence + dates + audit + relations (26 pairs = 52 args)
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
                'attachments_count', jsonb_array_length(v_attachments)
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
