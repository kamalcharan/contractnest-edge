-- ═══════════════════════════════════════════════════════════════
-- Migration 051: claim_contract_by_cnak RPC
-- ═══════════════════════════════════════════════════════════════
-- Purpose: Allows a buyer to claim a contract using its CNAK code.
-- Creates seller as a corporate contact in buyer's workspace.
-- Supports both manual-accept (status='accepted') and
-- auto-accept (acceptance_method='auto', contract status='active').
-- ═══════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
-- 1. Add claimed_at / claimed_by columns to t_contract_access
-- ─────────────────────────────────────────────────────────────
ALTER TABLE t_contract_access
    ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ;

ALTER TABLE t_contract_access
    ADD COLUMN IF NOT EXISTS claimed_by UUID;

-- ─────────────────────────────────────────────────────────────
-- 2. Create / Replace the RPC function
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION claim_contract_by_cnak(
    p_cnak TEXT,
    p_tenant_id UUID,
    p_user_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_access RECORD;
    v_contract RECORD;
    v_seller_tenant RECORD;
    v_seller_profile RECORD;
    v_contact_id UUID;
    v_existing_contact_id UUID;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 1: Validate inputs
    -- ═══════════════════════════════════════════
    IF p_cnak IS NULL OR TRIM(p_cnak) = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'CNAK is required'
        );
    END IF;

    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Find access record by CNAK
    -- ═══════════════════════════════════════════
    SELECT * INTO v_access
    FROM t_contract_access
    WHERE global_access_id = UPPER(TRIM(p_cnak))
      AND is_active = true
    FOR UPDATE;

    IF v_access IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invalid CNAK code. Please check and try again.'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Get contract details (needed for
    --         auto-accept check in step 4)
    -- ═══════════════════════════════════════════
    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = v_access.contract_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found or no longer active.'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 4: Check claimability
    --   • Manual/signoff/payment: access status must be 'accepted'
    --   • Auto-accept: contract status must be 'active'
    --     (access stays 'pending' because there is no review step)
    -- ═══════════════════════════════════════════
    IF v_access.status = 'accepted' THEN
        -- Normal flow (signoff / payment) — already accepted, proceed
        NULL;
    ELSIF v_contract.acceptance_method = 'auto' AND v_contract.status = 'active' THEN
        -- Auto-accept contracts are immediately active, allow claim
        -- Also update the access record status to 'accepted' for consistency
        UPDATE t_contract_access
        SET status = 'accepted',
            responded_at = NOW(),
            updated_at = NOW()
        WHERE id = v_access.id;
    ELSE
        -- Not in a claimable state
        RETURN jsonb_build_object(
            'success', false,
            'error', CASE v_access.status
                WHEN 'pending' THEN 'This contract has not been accepted yet. Please accept it first using the review link.'
                WHEN 'viewed' THEN 'This contract has not been accepted yet. Please accept it first using the review link.'
                WHEN 'rejected' THEN 'This contract was rejected and cannot be claimed.'
                WHEN 'expired' THEN 'This contract access has expired.'
                ELSE 'Contract is not in a claimable state.'
            END,
            'status', v_access.status
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 5: Check if already claimed by another tenant
    -- ═══════════════════════════════════════════
    IF v_access.accessor_tenant_id IS NOT NULL THEN
        IF v_access.accessor_tenant_id = p_tenant_id THEN
            -- Already claimed by this tenant — return success with contract info
            RETURN jsonb_build_object(
                'success', true,
                'already_claimed', true,
                'message', 'This contract is already in your ContractHub.',
                'contract', jsonb_build_object(
                    'id', v_contract.id,
                    'name', v_contract.name,
                    'contract_number', v_contract.contract_number,
                    'status', v_contract.status,
                    'grand_total', v_contract.grand_total,
                    'currency', v_contract.currency
                )
            );
        ELSE
            -- Claimed by a different tenant
            RETURN jsonb_build_object(
                'success', false,
                'error', 'This contract has already been claimed by another workspace.'
            );
        END IF;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 6: Prevent self-claim (seller claiming own contract)
    -- ═══════════════════════════════════════════
    IF v_access.tenant_id = p_tenant_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'You cannot claim your own contract. This contract is already in your ContractHub.'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 7: Get seller tenant info for contact creation
    -- ═══════════════════════════════════════════
    SELECT * INTO v_seller_tenant
    FROM t_tenants
    WHERE id = v_access.tenant_id;

    SELECT * INTO v_seller_profile
    FROM t_tenant_profiles
    WHERE tenant_id = v_access.tenant_id
    LIMIT 1;

    -- ═══════════════════════════════════════════
    -- STEP 8: Check if seller contact already exists in buyer's space
    -- ═══════════════════════════════════════════
    SELECT id INTO v_existing_contact_id
    FROM t_contacts
    WHERE tenant_id = p_tenant_id
      AND source_tenant_id = v_access.tenant_id
      AND is_active = true
    LIMIT 1;

    -- ═══════════════════════════════════════════
    -- STEP 9: Create seller as CORPORATE contact (if not exists)
    -- NOTE: Using 'corporate' type (not 'vendor') due to constraint
    -- For corporate contacts, use company_name (not name)
    -- ═══════════════════════════════════════════
    IF v_existing_contact_id IS NULL THEN
        INSERT INTO t_contacts (
            tenant_id,
            type,
            status,
            name,
            company_name,
            source,
            source_tenant_id,
            source_cnak,
            notes,
            created_by,
            is_live,
            is_active
        )
        VALUES (
            p_tenant_id,
            'corporate',
            'active',
            NULL,
            COALESCE(v_seller_profile.business_name, v_seller_tenant.name, 'Unknown Vendor'),
            'cnak_claim',
            v_access.tenant_id,
            p_cnak,
            'Auto-created from CNAK contract claim (vendor relationship)',
            p_user_id,
            true,
            true
        )
        RETURNING id INTO v_contact_id;
    ELSE
        v_contact_id := v_existing_contact_id;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 10: Update access record with accessor_tenant_id
    -- ═══════════════════════════════════════════
    UPDATE t_contract_access
    SET accessor_tenant_id = p_tenant_id,
        accessor_contact_id = v_contact_id,
        claimed_at = NOW(),
        claimed_by = p_user_id,
        updated_at = NOW()
    WHERE id = v_access.id;

    -- ═══════════════════════════════════════════
    -- STEP 11: Return success with contract and seller info
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Contract claimed successfully! It is now in your ContractHub.',
        'contract', jsonb_build_object(
            'id', v_contract.id,
            'name', v_contract.name,
            'contract_number', v_contract.contract_number,
            'description', v_contract.description,
            'status', v_contract.status,
            'total_value', v_contract.total_value,
            'grand_total', v_contract.grand_total,
            'currency', v_contract.currency,
            'duration_value', v_contract.duration_value,
            'duration_unit', v_contract.duration_unit,
            'global_access_id', v_contract.global_access_id
        ),
        'seller', jsonb_build_object(
            'contact_id', v_contact_id,
            'name', COALESCE(v_seller_profile.business_name, v_seller_tenant.name),
            'is_new_contact', v_existing_contact_id IS NULL
        ),
        'claimed_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to claim contract: ' || SQLERRM
    );
END;
$$;

-- Grant execute to authenticated users
GRANT EXECUTE ON FUNCTION claim_contract_by_cnak(TEXT, UUID, UUID) TO authenticated;

COMMENT ON FUNCTION claim_contract_by_cnak IS 'Claim a contract by CNAK code. Creates seller as corporate contact in buyer workspace. Supports both manual-accept and auto-accept contracts.';
