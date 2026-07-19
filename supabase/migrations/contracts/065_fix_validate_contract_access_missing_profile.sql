-- ═══════════════════════════════════════════════════════════════
-- Migration 065: Fix validate_contract_access missing tenant profile
-- ═══════════════════════════════════════════════════════════════
-- STATUS: Already applied directly to the Supabase project (2026-07-19)
-- via MCP, verified live. This file tracks that same SQL in source
-- control immediately (not after the fact — see the note in migration
-- 064 about why that matters).
--
-- ROOT CAUSE: the tracked migration file (contracts/010_public_contract_rpcs.sql)
-- built a full `profile` object from t_tenant_profiles into the
-- function's `tenant` response key; the LIVE deployed function (pulled
-- via pg_get_functiondef and verified byte-for-byte before this edit)
-- never did — its `tenant` object only returned {id, name}. The two
-- drifted at some point after the migration file was written, same
-- untracked-drift pattern as migration 064's tax-settings RPCs.
--
-- IMPACT: every buyer opening a contract via the public CNAK review
-- link (contractnest-ui/src/pages/contracts/review/index.tsx) has been
-- reading `tenant?.profile?.*` as undefined in production — no seller
-- logo, business name, address, phone, email, or (as of this session's
-- earlier work) tax registration number ever rendered on the letterhead.
--
-- FIX: reproduced the live function VERBATIM (every line above and
-- below the change is byte-identical to the pre-fix live definition),
-- adding one `t_tenant_profiles` lookup and one `profile` key in the
-- response. Nothing else in the access-validation, contract, or blocks
-- logic is touched.
--
-- SECURITY NOTE (considered, not a new exposure): this is a
-- SECURITY DEFINER function on a public/unauthenticated path (cnak +
-- secret_code only). The fields now exposed — business name, email,
-- phone, logo, address, website, tax registration number — are exactly
-- the seller's own letterhead information, i.e. what the seller already
-- intends the buyer to see on the contract document. Nothing internal
-- or buyer-identifying is added.
--
-- VERIFIED LIVE (2026-07-19):
--   - Error path (invalid cnak/secret) unchanged: still returns
--     {valid: false, error: 'Invalid access code'}.
--   - Did NOT invoke the function against a real pending access record
--     to test the happy path — it has a side effect (marks the link
--     `viewed`), which would have corrupted real buyer-tracking data.
--     Instead verified the new profile-lookup + jsonb_build_object
--     logic directly via a read-only SELECT against a real tenant_id,
--     confirmed correct shape/values.
--   - Confirmed via pg_get_functiondef that the deployed function
--     contains the new v_tenant_profile variable, the gst_number field,
--     and that the pre-existing service_blocks logic is untouched.
-- ═══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.validate_contract_access(p_cnak character varying, p_secret_code character varying)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_access   RECORD;
    v_contract RECORD;
    v_tenant   RECORD;
    v_tenant_profile RECORD;
    v_blocks   JSONB;
BEGIN
    IF p_cnak IS NULL OR p_secret_code IS NULL THEN
        RETURN jsonb_build_object('valid', false, 'error', 'CNAK and secret code are required');
    END IF;

    SELECT * INTO v_access
    FROM t_contract_access
    WHERE global_access_id = p_cnak AND secret_code = p_secret_code AND is_active = true
    LIMIT 1;

    IF v_access IS NULL THEN
        RETURN jsonb_build_object('valid', false, 'error', 'Invalid access code');
    END IF;

    IF v_access.expires_at IS NOT NULL AND v_access.expires_at < NOW() THEN
        RETURN jsonb_build_object('valid', false, 'error', 'This access link has expired');
    END IF;

    IF v_access.status IN ('accepted', 'rejected') THEN
        RETURN jsonb_build_object('valid', false, 'error', 'This contract has already been ' || v_access.status, 'status', v_access.status);
    END IF;

    IF v_access.status = 'expired' THEN
        RETURN jsonb_build_object('valid', false, 'error', 'This access link has expired');
    END IF;

    SELECT * INTO v_contract FROM t_contracts WHERE id = v_access.contract_id AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object('valid', false, 'error', 'Contract not found');
    END IF;

    SELECT id, name INTO v_tenant FROM t_tenants WHERE id = v_access.tenant_id;

    SELECT * INTO v_tenant_profile FROM t_tenant_profiles WHERE tenant_id = v_access.tenant_id;

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
    FROM t_contract_blocks cb WHERE cb.contract_id = v_contract.id;

    UPDATE t_contract_access
    SET link_clicked_at = COALESCE(link_clicked_at, NOW()),
        status = CASE WHEN status = 'pending' THEN 'viewed' WHEN status = 'sent' THEN 'viewed' ELSE status END,
        updated_at = NOW()
    WHERE id = v_access.id;

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
                'website_url',                v_tenant_profile.website_url,
                'country_code',               v_tenant_profile.country_code,
                'gst_number',                 v_tenant_profile.gst_number
            ) ELSE NULL END
        )
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('valid', false, 'error', 'Failed to validate contract access: ' || SQLERRM);
END;
$function$;
