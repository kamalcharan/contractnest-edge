-- ============================================================================
-- Equipment placeholder attach — Sprint 1(b) step (c)
-- Migration: contracts/058_equipment_placeholder_attach.sql
--
-- Extends buyer_add_equipment_to_contract / seller_add_equipment_to_contract
-- (056/057) with an optional p_replaces_item_id param. When provided, the
-- matching placeholder entry (asset_registry_id null, or
-- specifications.placeholder = true) is replaced in-place instead of
-- appending a new item, and t_contract_event_assets rows generated for that
-- placeholder are unlocked via unlock_placeholder_event_assets (sql/sprint1b
-- 002_event_assets.sql). Omitting p_replaces_item_id preserves the existing
-- append behavior exactly — backward compatible with current call sites.
-- ============================================================================

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. buyer_add_equipment_to_contract
-- New param changes the signature, so CREATE OR REPLACE would otherwise
-- create a second overload alongside the old 3-arg version. Drop it first
-- so there's exactly one function.
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS buyer_add_equipment_to_contract(UUID, UUID, JSONB);

CREATE OR REPLACE FUNCTION buyer_add_equipment_to_contract(
    p_contract_id UUID,
    p_buyer_tenant_id UUID,
    p_equipment_item JSONB,
    p_replaces_item_id TEXT DEFAULT NULL
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
    v_placeholder JSONB;
    v_old_ref TEXT;
    v_new_ref TEXT;
BEGIN
    -- ── Validate contract exists and caller is the buyer ──
    SELECT id, tenant_id, buyer_tenant_id, allow_buyer_to_add_equipment, equipment_details, status
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

    -- ═══════════════════════════════════════════
    -- Placeholder-attach path
    -- ═══════════════════════════════════════════
    IF p_replaces_item_id IS NOT NULL THEN
        SELECT value INTO v_placeholder
        FROM jsonb_array_elements(COALESCE(v_contract.equipment_details, '[]'::JSONB))
        WHERE value->>'id' = p_replaces_item_id
        LIMIT 1;

        IF v_placeholder IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Placeholder equipment item not found',
                'code', 'NOT_FOUND'
            );
        END IF;

        IF NOT (
            v_placeholder->>'asset_registry_id' IS NULL
            OR COALESCE(v_placeholder->'specifications'->>'placeholder', 'false') = 'true'
        ) THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Target item is not a placeholder',
                'code', 'NOT_A_PLACEHOLDER'
            );
        END IF;

        IF (p_equipment_item->>'asset_registry_id') IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'asset_registry_id is required to attach a real asset',
                'code', 'ASSET_REQUIRED'
            );
        END IF;

        v_item_id := p_replaces_item_id;
        v_old_ref := COALESCE(v_placeholder->>'asset_registry_id', v_placeholder->>'id');
        v_new_ref := p_equipment_item->>'asset_registry_id';

        SELECT jsonb_agg(
            CASE WHEN elem->>'id' = p_replaces_item_id
                 THEN p_equipment_item || jsonb_build_object(
                    'id', v_item_id,
                    'added_by_role', 'buyer',
                    'added_by_tenant_id', p_buyer_tenant_id::text,
                    'quantity', 1
                 )
                 ELSE elem
            END
        )
        INTO v_updated_details
        FROM jsonb_array_elements(COALESCE(v_contract.equipment_details, '[]'::JSONB)) elem;

        UPDATE t_contracts
        SET equipment_details = v_updated_details,
            updated_at = NOW()
        WHERE id = p_contract_id;

        PERFORM unlock_placeholder_event_assets(p_contract_id, v_contract.tenant_id, v_old_ref, v_new_ref);

        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'contract_id', p_contract_id,
                'item_id', v_item_id,
                'replaced_placeholder_id', p_replaces_item_id,
                'equipment_details', v_updated_details
            )
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- Existing append path (unchanged)
    -- ═══════════════════════════════════════════
    v_item_id := COALESCE(p_equipment_item->>'id', gen_random_uuid()::text);

    v_updated_details := COALESCE(v_contract.equipment_details, '[]'::JSONB) || jsonb_build_array(
        p_equipment_item || jsonb_build_object(
            'id', v_item_id,
            'added_by_role', 'buyer',
            'added_by_tenant_id', p_buyer_tenant_id::text,
            'quantity', 1
        )
    );

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
-- 2. seller_add_equipment_to_contract
-- Same signature-change reasoning as above.
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS seller_add_equipment_to_contract(UUID, UUID, JSONB);

CREATE OR REPLACE FUNCTION seller_add_equipment_to_contract(
    p_contract_id UUID,
    p_seller_tenant_id UUID,
    p_equipment_item JSONB,
    p_replaces_item_id TEXT DEFAULT NULL
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
    v_placeholder JSONB;
    v_old_ref TEXT;
    v_new_ref TEXT;
BEGIN
    -- ── Validate contract exists and caller is the seller ──
    SELECT id, seller_id, tenant_id, equipment_details, status
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

    -- Ensure the caller is the seller (check both seller_id and tenant_id)
    IF COALESCE(v_contract.seller_id, v_contract.tenant_id) != p_seller_tenant_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only the seller can add equipment via this endpoint',
            'code', 'FORBIDDEN'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- Placeholder-attach path
    -- ═══════════════════════════════════════════
    IF p_replaces_item_id IS NOT NULL THEN
        SELECT value INTO v_placeholder
        FROM jsonb_array_elements(COALESCE(v_contract.equipment_details, '[]'::JSONB))
        WHERE value->>'id' = p_replaces_item_id
        LIMIT 1;

        IF v_placeholder IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Placeholder equipment item not found',
                'code', 'NOT_FOUND'
            );
        END IF;

        IF NOT (
            v_placeholder->>'asset_registry_id' IS NULL
            OR COALESCE(v_placeholder->'specifications'->>'placeholder', 'false') = 'true'
        ) THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Target item is not a placeholder',
                'code', 'NOT_A_PLACEHOLDER'
            );
        END IF;

        IF (p_equipment_item->>'asset_registry_id') IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'asset_registry_id is required to attach a real asset',
                'code', 'ASSET_REQUIRED'
            );
        END IF;

        v_item_id := p_replaces_item_id;
        v_old_ref := COALESCE(v_placeholder->>'asset_registry_id', v_placeholder->>'id');
        v_new_ref := p_equipment_item->>'asset_registry_id';

        SELECT jsonb_agg(
            CASE WHEN elem->>'id' = p_replaces_item_id
                 THEN p_equipment_item || jsonb_build_object(
                    'id', v_item_id,
                    'added_by_role', 'seller',
                    'added_by_tenant_id', p_seller_tenant_id::text,
                    'quantity', COALESCE((p_equipment_item->>'quantity')::int, (elem->>'quantity')::int, 1)
                 )
                 ELSE elem
            END
        )
        INTO v_updated_details
        FROM jsonb_array_elements(COALESCE(v_contract.equipment_details, '[]'::JSONB)) elem;

        UPDATE t_contracts
        SET equipment_details = v_updated_details,
            updated_at = NOW()
        WHERE id = p_contract_id;

        PERFORM unlock_placeholder_event_assets(p_contract_id, v_contract.tenant_id, v_old_ref, v_new_ref);

        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'contract_id', p_contract_id,
                'item_id', v_item_id,
                'replaced_placeholder_id', p_replaces_item_id,
                'equipment_details', v_updated_details
            )
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- Existing append path (unchanged)
    -- ═══════════════════════════════════════════
    v_item_id := COALESCE(p_equipment_item->>'id', gen_random_uuid()::text);

    v_updated_details := COALESCE(v_contract.equipment_details, '[]'::JSONB) || jsonb_build_array(
        p_equipment_item || jsonb_build_object(
            'id', v_item_id,
            'added_by_role', 'seller',
            'added_by_tenant_id', p_seller_tenant_id::text,
            'quantity', COALESCE((p_equipment_item->>'quantity')::int, 1)
        )
    );

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
-- Grants (re-stated for the new 4-arg signatures)
-- ═══════════════════════════════════════════════════════════════════════════

GRANT EXECUTE ON FUNCTION buyer_add_equipment_to_contract(UUID, UUID, JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION buyer_add_equipment_to_contract(UUID, UUID, JSONB, TEXT) TO service_role;

GRANT EXECUTE ON FUNCTION seller_add_equipment_to_contract(UUID, UUID, JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION seller_add_equipment_to_contract(UUID, UUID, JSONB, TEXT) TO service_role;
