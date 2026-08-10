-- =====================================================================
-- 018_tenant_context_plan_aware.sql
--
-- Make get_tenant_context tell the whole truth, so /tenants/subscription
-- can be a real statement instead of a mock.
--
-- What was missing, and why each gap mattered:
--
--   · limits/usage had users, contracts, storage — but NOT rfqs, contacts
--     or templates. A buyer plan caps RFQs; the page could not show it.
--   · credits had whatsapp/sms/email/pooled but NOT inapp.
--   · billing_mode and credit_grant_rates were absent entirely, so the
--     page could not say "you are on a plan" vs "you are on wallet", nor
--     "each contract grants you 15 WhatsApp".
--   · subscription{} was read from the OLD t_bm_subscription columns and
--     came back all NULL. The plan now lives as a real CONTRACT under the
--     platform tenant, so it is resolved from there instead — the same
--     source_tenant_id link subscribe_tenant_to_plan and /plans both use,
--     so all three agree on which plan a tenant is on.
--
-- Backwards compatible: every key the previous version returned is still
-- returned, with the same name and shape. Only additions and a populated
-- subscription block.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.get_tenant_context(p_product_code text, p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_context     RECORD;
    v_platform_id UUID;
    v_plan        RECORD;
BEGIN
    IF p_product_code IS NULL OR p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'product_code and tenant_id are required'
        );
    END IF;

    SELECT * INTO v_context
    FROM t_tenant_context
    WHERE product_code = p_product_code
      AND tenant_id = p_tenant_id;

    IF v_context IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Tenant context not found',
            'product_code', p_product_code,
            'tenant_id', p_tenant_id
        );
    END IF;

    -- ── the plan, resolved from the actual contract ────────────────────
    -- Always live: ContractNest's own commercial model exists once, so a
    -- tenant in its test environment is still on the same real plan.
    SELECT id INTO v_platform_id FROM t_tenants WHERE is_admin = TRUE LIMIT 1;

    IF v_platform_id IS NOT NULL THEN
        SELECT c.id, c.contract_number, c.name, c.status,
               c.start_date, c.end_date, c.grand_total, c.currency,
               c.metadata->>'plan_template_id' AS plan_template_id
        INTO v_plan
        FROM t_contracts c
        JOIN t_contacts ct ON ct.id = c.buyer_id
        WHERE c.tenant_id = v_platform_id
          AND c.is_live = TRUE
          AND c.record_type = 'contract'
          AND c.status IN ('active', 'pending_acceptance')
          AND ct.source_tenant_id = p_tenant_id
        ORDER BY c.created_at DESC
        LIMIT 1;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'product_code', v_context.product_code,
        'tenant_id', v_context.tenant_id,

        'profile', jsonb_build_object(
            'business_name', v_context.business_name,
            'logo_url', v_context.logo_url,
            'primary_color', v_context.primary_color,
            'secondary_color', v_context.secondary_color
        ),

        -- How this tenant is billed: 'plan', 'wallet', 'freemium' or
        -- 'exempt' (the platform tenant itself).
        'billing_mode', v_context.billing_mode,

        -- Credits granted on each contract/RFQ creation, keyed by channel.
        -- Configuration authored in catalog-studio, never a constant.
        'credit_grant_rates', v_context.credit_grant_rates,

        -- The plan as a CONTRACT. id/contract_number are NULL when the
        -- tenant has not subscribed — that is the "no plan yet" state, not
        -- an error.
        'subscription', jsonb_build_object(
            'id', v_plan.id,
            'contract_id', v_plan.id,
            'contract_number', v_plan.contract_number,
            'plan_template_id', v_plan.plan_template_id,
            'plan_name', v_plan.name,
            'status', v_plan.status,
            'period_start', v_plan.start_date,
            'period_end', v_plan.end_date,
            'amount', v_plan.grand_total,
            'currency', v_plan.currency,
            -- kept so existing callers do not break
            'billing_cycle', v_context.billing_cycle,
            'trial_end', v_context.trial_end_date,
            'grace_end', v_context.grace_end_date,
            'next_billing_date', COALESCE(v_plan.end_date, v_context.next_billing_date)
        ),

        'credits', jsonb_build_object(
            'whatsapp', v_context.credits_whatsapp,
            'sms', v_context.credits_sms,
            'email', v_context.credits_email,
            'inapp', v_context.credits_inapp,
            'pooled', v_context.credits_pooled
        ),

        -- NULL means unlimited ONLY for the exempt platform tenant. For a
        -- subscribing tenant a plan always states a number, and 0 means
        -- zero — a seller plan leaves rfqs at 0 deliberately.
        'limits', jsonb_build_object(
            'users', v_context.limit_users,
            'contracts', v_context.limit_contracts,
            'rfqs', v_context.limit_rfqs,
            'contacts', v_context.limit_contacts,
            'templates', v_context.limit_templates,
            'storage_mb', v_context.limit_storage_mb
        ),

        'usage', jsonb_build_object(
            'users', v_context.usage_users,
            'contracts', v_context.usage_contracts,
            'rfqs', v_context.usage_rfqs,
            'contacts', v_context.usage_contacts,
            'templates', v_context.usage_templates,
            'storage_mb', v_context.usage_storage_mb
        ),

        'addons', jsonb_build_object(
            'vani_ai', v_context.addon_vani_ai,
            'rfp', v_context.addon_rfp
        ),

        'flags', jsonb_build_object(
            'can_access', v_context.flag_can_access,
            'can_send_whatsapp', v_context.flag_can_send_whatsapp,
            'can_send_sms', v_context.flag_can_send_sms,
            'can_send_email', v_context.flag_can_send_email,
            'can_send_inapp', v_context.flag_can_send_inapp,
            'credits_low', v_context.flag_credits_low,
            'near_limit', v_context.flag_near_limit
        ),

        'retrieved_at', NOW()
    );
END;
$function$;

COMMENT ON FUNCTION public.get_tenant_context IS
'Tenant context read model. The subscription block is resolved from the plan CONTRACT under the platform tenant (via the buyer contact''s source_tenant_id), not from the legacy t_bm_subscription columns.';

-- Verify:
--   select jsonb_pretty(get_tenant_context('contractnest','<tenant_id>'));
