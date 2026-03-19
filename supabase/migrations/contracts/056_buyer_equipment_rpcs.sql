-- ============================================================================
-- Buyer Equipment RPCs — add/remove equipment from the buyer side
-- Migration: contracts/056_buyer_equipment_rpcs.sql
--
-- Two new RPCs:
--   1. buyer_add_equipment_to_contract   — appends an item to equipment_details
--   2. buyer_remove_equipment_from_contract — removes a buyer-added item
--
-- Security:
--   - Validates buyer_tenant_id matches the caller
--   - Validates allow_buyer_to_add_equipment = true
--   - buyer_remove only allows removing items with matching added_by_tenant_id
-- ============================================================================

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. buyer_add_equipment_to_contract
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION buyer_add_equipment_to_contract(
    p_contract_id UUID,
    p_buyer_tenant_id UUID,
    p_equipment_item JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_contract RECORD;
    v_updated_details JSONB;
    v_item_id TEXT;
BEGIN
    -- ── Validate contract exists and caller is the buyer ──
    SELECT id, buyer_tenant_id, allow_buyer_to_add_equipment, equipment_details, status
    INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND is_active = true
    FOR UPDATE;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found',
            'code', 'NOT_FOUND'
        );
    END IF;

    -- Ensure the caller is the buyer
    IF v_contract.buyer_tenant_id IS NULL OR v_contract.buyer_tenant_id != p_buyer_tenant_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only the buyer can add equipment to this contract',
            'code', 'FORBIDDEN'
        );
    END IF;

    -- Ensure the seller has enabled buyer equipment additions
    IF v_contract.allow_buyer_to_add_equipment IS NOT TRUE THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Buyer equipment additions are not enabled for this contract',
            'code', 'NOT_ALLOWED'
        );
    END IF;

    -- ── Build the new item with enforced fields ──
    v_item_id := COALESCE(p_equipment_item->>'id', gen_random_uuid()::text);

    -- Append item to equipment_details JSONB array
    v_updated_details := COALESCE(v_contract.equipment_details, '[]'::JSONB) || jsonb_build_array(
        p_equipment_item || jsonb_build_object(
            'id', v_item_id,
            'added_by_role', 'buyer',
            'added_by_tenant_id', p_buyer_tenant_id::text,
            'quantity', 1
        )
    );

    -- ── Update the contract ──
    UPDATE t_contracts
    SET equipment_details = v_updated_details,
        updated_at = NOW()
    WHERE id = p_contract_id;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'contract_id', p_contract_id,
            'item_id', v_item_id,
            'equipment_details', v_updated_details
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'code', SQLSTATE
    );
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. buyer_remove_equipment_from_contract
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION buyer_remove_equipment_from_contract(
    p_contract_id UUID,
    p_buyer_tenant_id UUID,
    p_item_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_contract RECORD;
    v_item JSONB;
    v_updated_details JSONB;
    v_found BOOLEAN := false;
BEGIN
    -- ── Fetch contract ──
    SELECT id, buyer_tenant_id, equipment_details
    INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND is_active = true
    FOR UPDATE;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found',
            'code', 'NOT_FOUND'
        );
    END IF;

    -- Ensure the caller is the buyer
    IF v_contract.buyer_tenant_id IS NULL OR v_contract.buyer_tenant_id != p_buyer_tenant_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only the buyer can remove their equipment',
            'code', 'FORBIDDEN'
        );
    END IF;

    -- ── Find and validate the item ──
    v_updated_details := '[]'::JSONB;

    FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(v_contract.equipment_details, '[]'::JSONB))
    LOOP
        IF v_item->>'id' = p_item_id THEN
            -- Found the item — verify it was added by this buyer
            IF v_item->>'added_by_tenant_id' != p_buyer_tenant_id::text THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'Cannot remove equipment added by the seller',
                    'code', 'FORBIDDEN'
                );
            END IF;
            v_found := true;
            -- Skip this item (effectively removing it)
        ELSE
            v_updated_details := v_updated_details || jsonb_build_array(v_item);
        END IF;
    END LOOP;

    IF NOT v_found THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Equipment item not found',
            'code', 'NOT_FOUND'
        );
    END IF;

    -- ── Update the contract ──
    UPDATE t_contracts
    SET equipment_details = v_updated_details,
        updated_at = NOW()
    WHERE id = p_contract_id;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'contract_id', p_contract_id,
            'removed_item_id', p_item_id,
            'equipment_details', v_updated_details
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'code', SQLSTATE
    );
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Grants
-- ═══════════════════════════════════════════════════════════════════════════

GRANT EXECUTE ON FUNCTION buyer_add_equipment_to_contract(UUID, UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION buyer_add_equipment_to_contract(UUID, UUID, JSONB) TO service_role;

GRANT EXECUTE ON FUNCTION buyer_remove_equipment_from_contract(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION buyer_remove_equipment_from_contract(UUID, UUID, TEXT) TO service_role;
