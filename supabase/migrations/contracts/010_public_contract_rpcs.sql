-- ═══════════════════════════════════════════════════════════════
-- Migration 010: Public Contract RPCs for sign-off workflow
-- ═══════════════════════════════════════════════════════════════
-- Functions:
--   validate_contract_access  — public validate via CNAK + secret_code
--   respond_to_contract       — accept / reject a contract
-- Pattern follows user-invitations validate + accept
-- ═══════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────
-- 1. validate_contract_access
--    Public: validates CNAK + secret_code, returns contract data
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION validate_contract_access(
    p_cnak         VARCHAR,
    p_secret_code  VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_access          RECORD;
    v_contract        RECORD;
    v_tenant          RECORD;
    v_tenant_profile  RECORD;
    v_blocks          JSONB;
BEGIN
    -- ── Step 1: Validate inputs ──
    IF p_cnak IS NULL OR p_secret_code IS NULL THEN
        RETURN jsonb_build_object(
            'valid', false,
            'error', 'CNAK and secret code are required'
        );
    END IF;

    -- ── Step 2: Look up access grant ──
    SELECT *
    INTO v_access
    FROM t_contract_access
    WHERE global_access_id = p_cnak
      AND secret_code      = p_secret_code
      AND is_active         = true
    LIMIT 1;

    IF v_access IS NULL THEN
        RETURN jsonb_build_object(
            'valid', false,
            'error', 'Invalid access code'
        );
    END IF;

    -- ── Step 3: Check expiry ──
    IF v_access.expires_at IS NOT NULL AND v_access.expires_at < NOW() THEN
        RETURN jsonb_build_object(
            'valid', false,
            'error', 'This access link has expired'
        );
    END IF;

    -- ── Step 4: Check status ──
    IF v_access.status IN ('accepted', 'rejected') THEN
        RETURN jsonb_build_object(
            'valid', false,
            'error', 'This contract has already been ' || v_access.status,
            'status', v_access.status
        );
    END IF;

    IF v_access.status = 'expired' THEN
        RETURN jsonb_build_object(
            'valid', false,
            'error', 'This access link has expired'
        );
    END IF;

    -- ── Step 5: Get contract ──
    SELECT *
    INTO v_contract
    FROM t_contracts
    WHERE id = v_access.contract_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'valid', false,
            'error', 'Contract not found'
        );
    END IF;

    -- ── Step 6: Get tenant info + profile ──
    SELECT id, name
    INTO v_tenant
    FROM t_tenants
    WHERE id = v_access.tenant_id;

    SELECT *
    INTO v_tenant_profile
    FROM t_tenant_profiles
    WHERE tenant_id = v_access.tenant_id
    LIMIT 1;

    -- ── Step 7: Get service blocks ──
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',                cb.id,
            'block_name',        cb.block_name,
            'block_description', cb.block_description,
            'quantity',          cb.quantity,
            'unit_price',        cb.unit_price,
            'total_price',       cb.total_price,
            'billing_cycle',     cb.billing_cycle,
            'category_name',     cb.category_name
        ) ORDER BY cb.position ASC
    ), '[]'::jsonb)
    INTO v_blocks
    FROM t_contract_blocks cb
    WHERE cb.contract_id = v_contract.id;

    -- ── Step 8: Record link click ──
    UPDATE t_contract_access
    SET link_clicked_at = COALESCE(link_clicked_at, NOW()),
        status = CASE WHEN status = 'pending' THEN 'viewed'
                      WHEN status = 'sent'    THEN 'viewed'
                      ELSE status END,
        updated_at = NOW()
    WHERE id = v_access.id;

    -- ── Step 9: Return contract data ──
    RETURN jsonb_build_object(
        'valid', true,
        'access', jsonb_build_object(
            'id',             v_access.id,
            'status',         CASE WHEN v_access.status IN ('pending','sent') THEN 'viewed' ELSE v_access.status END,
            'accessor_role',  v_access.accessor_role,
            'accessor_name',  v_access.accessor_name,
            'accessor_email', v_access.accessor_email
        ),
        'contract', jsonb_build_object(
            'id',                  v_contract.id,
            'name',                v_contract.name,
            'contract_number',     v_contract.contract_number,
            'record_type',         v_contract.record_type,
            'contract_type',       v_contract.contract_type,
            'status',              v_contract.status,
            'description',         v_contract.description,
            'total_value',         v_contract.total_value,
            'grand_total',         v_contract.grand_total,
            'tax_total',           v_contract.tax_total,
            'tax_breakdown',       COALESCE(v_contract.tax_breakdown, '[]'::JSONB),
            'currency',            v_contract.currency,
            'acceptance_method',   v_contract.acceptance_method,
            'duration_value',      v_contract.duration_value,
            'duration_unit',       v_contract.duration_unit,
            'billing_cycle_type',  v_contract.billing_cycle_type,
            'payment_mode',        v_contract.payment_mode,
            'buyer_name',          v_contract.buyer_name,
            'buyer_email',         v_contract.buyer_email,
            'service_blocks',      v_blocks
        ),
        'tenant', jsonb_build_object(
            'id',   v_tenant.id,
            'name', v_tenant.name,
            'profile', CASE WHEN v_tenant_profile IS NOT NULL THEN jsonb_build_object(
                'business_name',              v_tenant_profile.business_name,
                'business_email',             v_tenant_profile.business_email,
                'business_phone_country_code', v_tenant_profile.business_phone_country_code,
                'business_phone',             v_tenant_profile.business_phone,
                'logo_url',                   v_tenant_profile.logo_url,
                'primary_color',              v_tenant_profile.primary_color,
                'secondary_color',            v_tenant_profile.secondary_color,
                'address_line1',              v_tenant_profile.address_line1,
                'address_line2',              v_tenant_profile.address_line2,
                'city',                       v_tenant_profile.city,
                'state_code',                 v_tenant_profile.state_code,
                'postal_code',                v_tenant_profile.postal_code,
                'website_url',                v_tenant_profile.website_url
            ) ELSE NULL END
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'valid', false,
        'error', 'Failed to validate contract access: ' || SQLERRM
    );
END;
$$;

-- Grants
GRANT EXECUTE ON FUNCTION validate_contract_access(VARCHAR, VARCHAR) TO service_role;
GRANT EXECUTE ON FUNCTION validate_contract_access(VARCHAR, VARCHAR) TO anon;
GRANT EXECUTE ON FUNCTION validate_contract_access(VARCHAR, VARCHAR) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 2. respond_to_contract
--    Accept or reject a contract via CNAK + secret_code
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION respond_to_contract(
    p_cnak             VARCHAR,
    p_secret_code      VARCHAR,
    p_action           VARCHAR,          -- 'accept' | 'reject'
    p_responded_by     UUID DEFAULT NULL, -- user ID if logged in
    p_responder_name   VARCHAR DEFAULT NULL,
    p_responder_email  VARCHAR DEFAULT NULL,
    p_rejection_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_access   RECORD;
    v_contract RECORD;
    v_new_status VARCHAR(20);
BEGIN
    -- ── Step 1: Validate inputs ──
    IF p_cnak IS NULL OR p_secret_code IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'CNAK and secret code are required'
        );
    END IF;

    IF p_action NOT IN ('accept', 'reject') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Action must be accept or reject'
        );
    END IF;

    -- ── Step 2: Look up and lock access grant ──
    SELECT *
    INTO v_access
    FROM t_contract_access
    WHERE global_access_id = p_cnak
      AND secret_code      = p_secret_code
      AND is_active         = true
    FOR UPDATE;

    IF v_access IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invalid access code'
        );
    END IF;

    -- ── Step 3: Check if already responded ──
    IF v_access.status IN ('accepted', 'rejected') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'This contract has already been ' || v_access.status,
            'status', v_access.status
        );
    END IF;

    -- ── Step 4: Check expiry ──
    IF v_access.expires_at IS NOT NULL AND v_access.expires_at < NOW() THEN
        -- Mark as expired
        UPDATE t_contract_access
        SET status = 'expired', updated_at = NOW()
        WHERE id = v_access.id;

        RETURN jsonb_build_object(
            'success', false,
            'error', 'This access link has expired'
        );
    END IF;

    -- ── Step 5: Get contract ──
    SELECT *
    INTO v_contract
    FROM t_contracts
    WHERE id = v_access.contract_id
      AND is_active = true
    FOR UPDATE;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found'
        );
    END IF;

    -- ── Step 6: Determine new status ──
    v_new_status := CASE p_action
        WHEN 'accept' THEN 'accepted'
        WHEN 'reject' THEN 'rejected'
    END;

    -- ── Step 7: Update access record ──
    UPDATE t_contract_access
    SET status           = v_new_status,
        responded_by     = p_responded_by,
        responded_at     = NOW(),
        rejection_reason = CASE WHEN p_action = 'reject' THEN p_rejection_reason ELSE NULL END,
        updated_at       = NOW()
    WHERE id = v_access.id;

    -- ── Step 8: Update contract status if accepted ──
    IF p_action = 'accept' THEN
        -- Move contract from pending_acceptance → active
        IF v_contract.status = 'pending_acceptance' THEN
            UPDATE t_contracts
            SET status     = 'active',
                version    = version + 1,
                updated_at = NOW()
            WHERE id = v_contract.id;

            -- Log status change in history
            INSERT INTO t_contract_history (
                contract_id, tenant_id,
                action, from_status, to_status,
                changes,
                performed_by_type, performed_by_id, performed_by_name,
                note
            ) VALUES (
                v_contract.id,
                v_access.tenant_id,
                'status_change',
                'pending_acceptance',
                'active',
                NULL,
                'external',
                p_responded_by,
                COALESCE(p_responder_name, v_access.accessor_name, 'External party'),
                'Contract accepted via sign-off link'
            );
        END IF;
    END IF;

    -- ── Step 9: Return result ──
    RETURN jsonb_build_object(
        'success', true,
        'action', p_action,
        'status', v_new_status,
        'contract_id', v_contract.id,
        'contract_number', v_contract.contract_number,
        'message', CASE p_action
            WHEN 'accept' THEN 'Contract accepted successfully'
            WHEN 'reject' THEN 'Contract rejected'
        END
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to respond to contract: ' || SQLERRM
    );
END;
$$;

-- Grants
GRANT EXECUTE ON FUNCTION respond_to_contract(VARCHAR, VARCHAR, VARCHAR, UUID, VARCHAR, VARCHAR, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION respond_to_contract(VARCHAR, VARCHAR, VARCHAR, UUID, VARCHAR, VARCHAR, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION respond_to_contract(VARCHAR, VARCHAR, VARCHAR, UUID, VARCHAR, VARCHAR, TEXT) TO authenticated;
