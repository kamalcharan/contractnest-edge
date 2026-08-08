-- =====================================================================
-- 022_soft_limits.sql   —   BUSINESS MODEL V4, PHASE C
--
-- Limits become visible. They do NOT become enforced. (Decision D3.)
--
-- Nothing in the product reads limit_contracts or limit_rfqs — verified
-- by grep across all five submodules, zero application call sites.
-- Trinity has been sitting at 17 contracts against a limit of 3 and
-- nothing has ever said a word about it.
--
-- The owner's ruling is SOFT: no block in create_contract_transaction,
-- no failed request, no half-filled wizard thrown away. A tenant who
-- goes over is told, clearly, with the upgrade one click away. Hard
-- blocking is a decision to take later with real usage in hand; silently
-- metering nothing is what produced the current state.
--
-- Three things here:
--
--   1. flag_over_limit, computed on the context row itself. The existing
--      flag_near_limit was only ever written by trg_fn_update_context_on_usage,
--      which fires on t_bm_subscription_usage — a table with ZERO rows.
--      So near_limit has never been true for anybody either. Both flags
--      now recalculate wherever limits or usage change, which is the same
--      pattern Phase A used for the credit flags: a BEFORE trigger on the
--      row itself catches every writer, not just one blessed path.
--
--   2. The plan-expiry guard. auto_expire_contracts (nightly cron) flips
--      a contract active → expired, and a plan IS a contract, so plan
--      contracts already expire. Without this, get_tenant_context would
--      stop showing the plan while t_tenant_context happily kept the
--      limits it granted. Now expiry lapses the allowances —
--      and DELIBERATELY LEAVES CREDITS ALONE (decision D2): the contract
--      expires, the credits it granted are the tenant's to keep.
--
--   3. Nothing is blocked. This migration adds no constraint, no RAISE,
--      no rejected insert.
-- =====================================================================


-- ── 1. the flag ───────────────────────────────────────────────────────
ALTER TABLE public.t_tenant_context
    ADD COLUMN IF NOT EXISTS flag_over_limit BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.t_tenant_context.flag_over_limit IS
'Tenant has reached or passed a metered allowance (contracts, rfqs). Advisory only — nothing blocks on it (V4 decision D3). Recomputed by trg_context_limit_flags whenever a limit or usage changes.';


-- ── 2. recompute near/over wherever limits or usage move ──────────────
-- Only the two METERED allowances count. Contacts, users and templates
-- are uncapped in every plan authored so far, and storage is not metered
-- by anything that writes usage — including them would produce a warning
-- nobody can act on.
CREATE OR REPLACE FUNCTION public.trg_fn_context_limit_flags()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS
$function$
DECLARE
    v_over BOOLEAN := FALSE;
    v_near BOOLEAN := FALSE;
BEGIN
    -- NULL limit means unlimited, which in practice only the exempt
    -- platform tenant ever sees.
    --
    -- A limit of 0 with usage of 0 is "not included in this plan", NOT
    -- "over". A seller plan sets limit_rfqs = 0 deliberately; reading
    -- 0 >= 0 as over-limit would nag every seller-plan tenant forever
    -- about an allowance they never wanted. Zero only counts as over once
    -- something has actually been created against it.
    IF NEW.limit_contracts IS NOT NULL THEN
        v_over := v_over
               OR (NEW.limit_contracts =  0 AND COALESCE(NEW.usage_contracts, 0) >  0)
               OR (NEW.limit_contracts >  0 AND COALESCE(NEW.usage_contracts, 0) >= NEW.limit_contracts);
        v_near := v_near
               OR (NEW.limit_contracts >  0 AND COALESCE(NEW.usage_contracts, 0) >= NEW.limit_contracts * 0.8);
    END IF;

    IF NEW.limit_rfqs IS NOT NULL THEN
        v_over := v_over
               OR (NEW.limit_rfqs =  0 AND COALESCE(NEW.usage_rfqs, 0) >  0)
               OR (NEW.limit_rfqs >  0 AND COALESCE(NEW.usage_rfqs, 0) >= NEW.limit_rfqs);
        v_near := v_near
               OR (NEW.limit_rfqs >  0 AND COALESCE(NEW.usage_rfqs, 0) >= NEW.limit_rfqs * 0.8);
    END IF;

    -- The platform tenant is not on a plan and should never be nagged.
    IF NEW.billing_mode = 'exempt' THEN
        v_over := FALSE;
        v_near := FALSE;
    END IF;

    NEW.flag_over_limit := v_over;
    -- "Near" stops being interesting once you are over — one message at a
    -- time, and the over-limit one is the one worth reading.
    NEW.flag_near_limit := v_near AND NOT v_over;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_context_limit_flags ON public.t_tenant_context;
CREATE TRIGGER trg_context_limit_flags
    BEFORE INSERT OR UPDATE OF limit_contracts, limit_rfqs,
                               usage_contracts, usage_rfqs, billing_mode
    ON public.t_tenant_context
    FOR EACH ROW EXECUTE FUNCTION public.trg_fn_context_limit_flags();


-- The old writer fired on t_bm_subscription_usage, which has never had a
-- row. Removing it now so two things are not competing to own the flag.
DROP TRIGGER IF EXISTS trg_usage_update_context ON public.t_bm_subscription_usage;
DROP FUNCTION IF EXISTS public.trg_fn_update_context_on_usage();


-- ── 3. when the plan contract ends, the allowances end with it ────────
-- Credits do NOT (decision D2). A tenant who earned 270 WhatsApp credits
-- under a plan keeps all 270 after it lapses; what they lose is the right
-- to create more contracts under that plan.
CREATE OR REPLACE FUNCTION public.trg_fn_plan_contract_lapsed()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$function$
DECLARE
    v_platform_id  UUID;
    v_subscriber   UUID;
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NULL;
    END IF;

    IF NEW.status NOT IN ('expired', 'cancelled', 'terminated') THEN
        RETURN NULL;
    END IF;

    SELECT id INTO v_platform_id FROM t_tenants WHERE is_admin = TRUE LIMIT 1;

    -- Only plan contracts: raised BY the platform tenant, FOR a tenant.
    -- The buyer contact's source_tenant_id is the only link between a
    -- contact and a tenant account, and it is the same link
    -- subscribe_tenant_to_plan and get_tenant_context use.
    IF v_platform_id IS NULL OR NEW.tenant_id <> v_platform_id THEN
        RETURN NULL;
    END IF;

    SELECT ct.source_tenant_id INTO v_subscriber
    FROM t_contacts ct WHERE ct.id = NEW.buyer_id;

    IF v_subscriber IS NULL THEN
        RETURN NULL;
    END IF;

    -- Only the two metered allowances. Everything else on the row —
    -- credits, grant rates, add-ons — is left exactly as it was.
    UPDATE t_tenant_context
    SET limit_contracts = 0,
        limit_rfqs      = 0,
        updated_at      = NOW()
    WHERE tenant_id = v_subscriber
      AND product_code = 'contractnest';

    RAISE NOTICE 'plan contract % lapsed (%): allowances zeroed for tenant %, credits untouched',
        NEW.contract_number, NEW.status, v_subscriber;

    RETURN NULL;

EXCEPTION WHEN OTHERS THEN
    -- Never fail a contract status change because the meter misbehaved.
    RAISE WARNING 'plan lapse handling failed for contract %: %', NEW.id, SQLERRM;
    RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_plan_contract_lapsed ON public.t_contracts;
CREATE TRIGGER trg_plan_contract_lapsed
    AFTER UPDATE OF status ON public.t_contracts
    FOR EACH ROW EXECUTE FUNCTION public.trg_fn_plan_contract_lapsed();


-- ── 4. backfill the flags for rows that already exist ─────────────────
-- A no-op UPDATE would not fire the trigger (the column list would not
-- match), so touch a listed column with its own value.
UPDATE public.t_tenant_context SET usage_contracts = usage_contracts;


-- ── 5. surface it ─────────────────────────────────────────────────────
-- flags.over_limit joins the existing flags block. Everything else about
-- get_tenant_context is unchanged from Phase A.
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
    v_res         JSONB;
BEGIN
    IF p_product_code IS NULL OR p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false,
            'error', 'product_code and tenant_id are required');
    END IF;

    SELECT * INTO v_context
    FROM t_tenant_context
    WHERE product_code = p_product_code AND tenant_id = p_tenant_id;

    IF v_context IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Tenant context not found',
            'product_code', p_product_code, 'tenant_id', p_tenant_id);
    END IF;

    v_res := COALESCE(v_context.credits_reserved, '{}'::JSONB);

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

        'billing_mode', v_context.billing_mode,
        'credit_grant_rates', v_context.credit_grant_rates,

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
            'billing_cycle', v_context.billing_cycle,
            'trial_end', v_context.trial_end_date,
            'grace_end', v_context.grace_end_date,
            'next_billing_date', COALESCE(v_plan.end_date, v_context.next_billing_date)
        ),

        'credits', jsonb_build_object(
            'whatsapp', GREATEST(0, COALESCE(v_context.credits_whatsapp,0)
                          - COALESCE((v_res->>'notification:whatsapp')::INT, 0)),
            'sms',      GREATEST(0, COALESCE(v_context.credits_sms,0)
                          - COALESCE((v_res->>'notification:sms')::INT, 0)),
            'email',    GREATEST(0, COALESCE(v_context.credits_email,0)
                          - COALESCE((v_res->>'notification:email')::INT, 0)),
            'inapp',    GREATEST(0, COALESCE(v_context.credits_inapp,0)
                          - COALESCE((v_res->>'notification:inapp')::INT, 0)),
            'pooled',   GREATEST(0, COALESCE(v_context.credits_pooled,0)
                          - COALESCE((v_res->>'notification:_')::INT, 0))
        ),

        'credits_gross', jsonb_build_object(
            'whatsapp', COALESCE(v_context.credits_whatsapp,0),
            'sms',      COALESCE(v_context.credits_sms,0),
            'email',    COALESCE(v_context.credits_email,0),
            'inapp',    COALESCE(v_context.credits_inapp,0),
            'pooled',   COALESCE(v_context.credits_pooled,0)
        ),
        'credits_reserved', v_res,
        'credits_other', COALESCE(v_context.credits_other, '{}'::JSONB),

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
            'near_limit', v_context.flag_near_limit,
            -- Advisory. Nothing blocks on this (D3).
            'over_limit', v_context.flag_over_limit
        ),

        'retrieved_at', NOW()
    );
END;
$function$;


-- =====================================================================
-- Verify:
--   select tenant_id, limit_contracts, usage_contracts,
--          flag_near_limit, flag_over_limit
--   from t_tenant_context;
--
--   -- nothing is blocked: this must still succeed for an over-limit tenant
--   -- (create a contract through the wizard and watch usage_contracts move)
--
--   -- lapse: expiring a plan contract zeroes allowances, not credits
--   select limit_contracts, limit_rfqs, credits_whatsapp
--   from t_tenant_context where tenant_id = '<subscriber>';
-- =====================================================================
