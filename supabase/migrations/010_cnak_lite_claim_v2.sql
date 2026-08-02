-- ============================================================================
-- 010_cnak_lite_claim_v2.sql
-- CNAK-Lite Flow 1 — secure claim: bare-CNAK claiming is no longer allowed.
--
-- WHY: claim_contract_by_cnak() accepted a bare CNAK (CNAK-XXXXXX). Anyone
-- who guessed/overheard a code could pull a contract (and the vendor
-- relationship it creates) into their own workspace. The claim rule agreed
-- for CNAK-lite is:
--   * AUTO-CLAIM  : CNAK + secret_code (the pair from the review link —
--                   used by the signup auto-claim and review-page hand-off)
--   * MANUAL CLAIM: CNAK + registered mobile number (the buyer types the
--                   mobile the seller has on file; matched on last 10 digits
--                   against the access grant's contact channels)
-- A claim with neither is rejected with code VERIFICATION_REQUIRED.
--
-- Forward-only: no backfill (existing tenants are being cleaned up anyway).
--
-- NOTE ON SIGNATURE: we ADD two defaulted params (p_secret, p_mobile) to the
-- existing 4-param function. PostgreSQL would treat CREATE OR REPLACE with new
-- params as an OVERLOAD (two functions, ambiguous PostgREST rpc() calls), so
-- the old signature is DROPPED first. Existing callers that pass only the old
-- named args still resolve to the new function — they now get
-- VERIFICATION_REQUIRED instead of a silent claim, which is the point.
--
-- p_is_live semantics: explicit true/false keeps today's strict environment
-- check. NULL (used by the trusted server-side signup auto-claim, where the
-- brand-new tenant has no environment yet) adopts the contract's own
-- environment; the response's contract.is_live tells the caller which one.
-- ============================================================================

DROP FUNCTION IF EXISTS public.claim_contract_by_cnak(text, uuid, uuid, boolean);

CREATE FUNCTION public.claim_contract_by_cnak(
    p_cnak      text,
    p_tenant_id uuid,
    p_user_id   uuid    DEFAULT NULL,
    p_is_live   boolean DEFAULT true,
    p_secret    text    DEFAULT NULL,
    p_mobile    text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_access RECORD;
    v_contract RECORD;
    v_seller_tenant RECORD;
    v_seller_profile RECORD;
    v_contact_id UUID;
    v_existing_contact_id UUID;
    v_is_live BOOLEAN;
    v_verified BOOLEAN := false;
    v_mobile_digits TEXT;
    v_mobile_on_file BOOLEAN := false;
BEGIN
    IF p_cnak IS NULL OR TRIM(p_cnak) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'CNAK is required');
    END IF;

    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    SELECT * INTO v_access
    FROM t_contract_access
    WHERE global_access_id = UPPER(TRIM(p_cnak))
      AND is_active = true
    FOR UPDATE;

    IF v_access IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid CNAK code. Please check and try again.');
    END IF;

    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = v_access.contract_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Contract not found or no longer active.');
    END IF;

    -- Environment: explicit p_is_live keeps the strict cross-environment
    -- rejection; NULL adopts the contract's environment (signup auto-claim).
    IF p_is_live IS NOT NULL AND v_contract.is_live IS DISTINCT FROM p_is_live THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format(
                'This contract belongs to your %s workspace, but you are currently in %s mode. Switch modes and try again.',
                CASE WHEN v_contract.is_live THEN 'Live' ELSE 'Test' END,
                CASE WHEN p_is_live THEN 'Live' ELSE 'Test' END
            ),
            'code', 'ENVIRONMENT_MISMATCH'
        );
    END IF;
    v_is_live := COALESCE(p_is_live, v_contract.is_live);

    -- Already claimed by THIS tenant: no re-verification needed — the grant
    -- already belongs to them. (Also self-heals buyer_tenant_id, as before.)
    IF v_access.accessor_tenant_id IS NOT NULL AND v_access.accessor_tenant_id = p_tenant_id THEN
        UPDATE t_contracts
        SET buyer_tenant_id = p_tenant_id
        WHERE id = v_access.contract_id
          AND buyer_tenant_id IS NULL;

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
                'currency', v_contract.currency,
                'is_live', v_contract.is_live
            )
        );
    END IF;

    -- ═══════════════════════════════════════════════════════════════════
    -- VERIFICATION GATE (new): secret_code match OR registered-mobile match.
    -- Sits BEFORE any state change (including the auto-accept below) so an
    -- unverified caller cannot mutate anything or learn claim status.
    -- ═══════════════════════════════════════════════════════════════════
    IF p_secret IS NOT NULL AND TRIM(p_secret) <> ''
       AND v_access.secret_code IS NOT NULL
       AND UPPER(TRIM(p_secret)) = UPPER(TRIM(v_access.secret_code)) THEN
        v_verified := true;
    END IF;

    IF NOT v_verified AND p_mobile IS NOT NULL THEN
        v_mobile_digits := regexp_replace(p_mobile, '\D', '', 'g');
        IF length(v_mobile_digits) >= 10 AND v_access.accessor_contact_id IS NOT NULL THEN
            SELECT EXISTS (
                SELECT 1
                FROM t_contact_channels cc
                WHERE cc.contact_id = v_access.accessor_contact_id
                  AND cc.channel_type = 'mobile'
                  AND regexp_replace(COALESCE(cc.value, ''), '\D', '', 'g') <> ''
                  AND RIGHT(regexp_replace(cc.value, '\D', '', 'g'), 10) = RIGHT(v_mobile_digits, 10)
            ) INTO v_mobile_on_file;
            v_verified := v_mobile_on_file;
        END IF;
    END IF;

    IF NOT v_verified THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'We could not verify this claim. Use the full link you received (it carries a secret), or enter the mobile number this contract was shared with.',
            'code', 'VERIFICATION_REQUIRED'
        );
    END IF;

    -- Claimed by a DIFFERENT tenant (checked only after verification).
    IF v_access.accessor_tenant_id IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'This contract has already been claimed by another workspace.');
    END IF;

    IF v_access.status = 'accepted' THEN
        NULL;
    ELSIF v_contract.acceptance_method = 'auto' AND v_contract.status = 'active' THEN
        UPDATE t_contract_access
        SET status = 'accepted', responded_at = NOW(), updated_at = NOW()
        WHERE id = v_access.id;
    ELSE
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

    IF v_access.tenant_id = p_tenant_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'You cannot claim your own contract. This contract is already in your ContractHub.');
    END IF;

    SELECT * INTO v_seller_tenant FROM t_tenants WHERE id = v_access.tenant_id;
    SELECT * INTO v_seller_profile FROM t_tenant_profiles WHERE tenant_id = v_access.tenant_id LIMIT 1;

    SELECT id INTO v_existing_contact_id
    FROM t_contacts
    WHERE tenant_id = p_tenant_id
      AND source_tenant_id = v_access.tenant_id
      AND is_active = true
    LIMIT 1;

    IF v_existing_contact_id IS NULL THEN
        INSERT INTO t_contacts (
            tenant_id, type, status, name, company_name, classifications,
            source, source_tenant_id, source_cnak, notes, created_by, is_live, is_active
        )
        VALUES (
            p_tenant_id, 'corporate', 'active', NULL,
            COALESCE(v_seller_profile.business_name, v_seller_tenant.name, 'Unknown Vendor'),
            '[{"classification_value": "vendor", "classification_label": "Vendor"}]'::jsonb,
            'cnak_claim', v_access.tenant_id, p_cnak,
            'Auto-created from CNAK contract claim (vendor relationship)',
            p_user_id, v_is_live, true
        )
        RETURNING id INTO v_contact_id;
    ELSE
        v_contact_id := v_existing_contact_id;
    END IF;

    UPDATE t_contract_access
    SET accessor_tenant_id = p_tenant_id,
        accessor_contact_id = v_contact_id,
        claimed_at = NOW(),
        claimed_by = p_user_id,
        updated_at = NOW()
    WHERE id = v_access.id;

    UPDATE t_contracts
    SET buyer_tenant_id = p_tenant_id
    WHERE id = v_access.contract_id;

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
            'global_access_id', v_contract.global_access_id,
            'is_live', v_contract.is_live
        ),
        'seller', jsonb_build_object(
            'contact_id', v_contact_id,
            'name', COALESCE(v_seller_profile.business_name, v_seller_tenant.name),
            'is_new_contact', v_existing_contact_id IS NULL
        ),
        'claimed_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'Failed to claim contract: ' || SQLERRM);
END;
$function$;

COMMENT ON FUNCTION public.claim_contract_by_cnak(text, uuid, uuid, boolean, text, text) IS
'Claims a CNAK-shared contract into a buyer tenant. v2 (CNAK-lite): requires secret_code (auto-claim) or registered mobile (manual claim); bare-CNAK claims return VERIFICATION_REQUIRED. p_is_live NULL adopts the contract''s environment (server-side signup auto-claim).';
