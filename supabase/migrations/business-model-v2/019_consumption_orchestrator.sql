-- =====================================================================
-- 019_consumption_orchestrator.sql
--
-- The consumption side. Creating a contract or an RFQ must MOVE the meter.
--
-- Until this, t_tenant_context was written only when a tenant subscribed.
-- Creating a contract changed nothing — usage stayed at 0 and no credits
-- were granted — so a plan was a decoration. Trinity created CN-1017 and
-- usage_contracts was still 0.
--
-- WHY A TRIGGER rather than a step in an API path: contracts are created
-- from several places — the contract wizard, subscribe_tenant_to_plan,
-- imports, and whatever comes next. A trigger cannot be bypassed by adding
-- a new path, and metering that can be bypassed is not metering.
-- =====================================================================

-- The platform-wide grant rate, read from the Credit Pack block authored in
-- catalog-studio (mode = per_creation). Never a constant in code: change 15
-- to 20 in the block and every tenant follows on their next creation.
CREATE OR REPLACE FUNCTION public.fn_platform_creation_rates()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
    SELECT COALESCE(
        (SELECT b.config->'metering'->'grants'
         FROM m_cat_blocks b
         JOIN t_tenants t ON t.id = b.tenant_id AND t.is_admin
         WHERE b.config->'metering'->>'mode' = 'per_creation'
           AND b.is_active AND b.is_live
         ORDER BY b.updated_at DESC
         LIMIT 1),
        '{}'::JSONB);
$function$;


CREATE OR REPLACE FUNCTION public.trg_fn_contract_consumption()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_ctx     RECORD;
    v_rates   JSONB;
    v_channel TEXT;
    v_qty     INTEGER;
BEGIN
    SELECT * INTO v_ctx
    FROM t_tenant_context
    WHERE product_code = 'contractnest' AND tenant_id = NEW.tenant_id;

    -- No context, or the platform tenant itself: nothing to meter. Vikuna is
    -- billing_mode='exempt', so its own plan contracts do not consume anything.
    IF v_ctx IS NULL OR v_ctx.billing_mode = 'exempt' THEN
        RETURN NEW;
    END IF;

    -- ── 1. move the meter ──────────────────────────────────────────────
    -- record_type decides which counter moves: a seller creates contracts,
    -- a buyer raises RFQs, and each is capped separately.
    IF NEW.record_type = 'rfq' THEN
        UPDATE t_tenant_context
        SET usage_rfqs = usage_rfqs + 1, updated_at = now()
        WHERE product_code = 'contractnest' AND tenant_id = NEW.tenant_id;
    ELSE
        UPDATE t_tenant_context
        SET usage_contracts = usage_contracts + 1, updated_at = now()
        WHERE product_code = 'contractnest' AND tenant_id = NEW.tenant_id;
    END IF;

    -- ── 2. grant notification credits ──────────────────────────────────
    -- The settled rule: EVERY creation event — contract or RFQ — tops up the
    -- tenant's pools. Pools are tenant-level, accumulate (9 + 15 = 24), and
    -- are spent only when a notification is actually sent.
    --
    -- A plan may carry its own rate via a metering block
    -- (t_tenant_context.credit_grant_rates); otherwise the platform rate.
    v_rates := CASE
        WHEN v_ctx.credit_grant_rates IS NOT NULL
             AND v_ctx.credit_grant_rates <> '{}'::JSONB
        THEN v_ctx.credit_grant_rates
        ELSE fn_platform_creation_rates()
    END;

    FOR v_channel, v_qty IN SELECT key, value::INTEGER FROM jsonb_each_text(v_rates)
    LOOP
        CONTINUE WHEN v_qty IS NULL OR v_qty <= 0;

        -- add_credits writes the balance AND the journal row, so every
        -- granted credit is auditable back to the contract that earned it.
        PERFORM add_credits(
            NEW.tenant_id,
            'notification',
            v_qty,
            v_channel,
            'plan_grant',
            NEW.id::TEXT,
            'Granted on ' || COALESCE(NEW.contract_number, NEW.rfq_number, 'creation'),
            'contract'
        );
    END LOOP;

    RETURN NEW;

EXCEPTION WHEN OTHERS THEN
    -- Metering must NEVER block a contract being created. A tenant losing a
    -- credit grant is recoverable; a failed contract create is not.
    RAISE WARNING 'contract consumption metering failed for % (%): %',
        NEW.id, NEW.tenant_id, SQLERRM;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_contract_consumption ON public.t_contracts;
CREATE TRIGGER trg_contract_consumption
    AFTER INSERT ON public.t_contracts
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_fn_contract_consumption();

COMMENT ON FUNCTION public.trg_fn_contract_consumption IS
'Moves the tenant meter on contract/RFQ creation: increments usage_contracts or usage_rfqs and grants notification credits at the plan rate (or the platform-wide rate). Never blocks the insert.';


-- ── top-up packs: give them a channel ─────────────────────────────────
-- The channel column was added in 010 but never populated; the channel only
-- ever existed inside the pack NAME. That is why packs could not be rendered
-- against the pool they refill.
UPDATE t_bm_topup_pack
SET channel = CASE
      WHEN name ILIKE '%whatsapp%' THEN 'whatsapp'
      WHEN name ILIKE '%email%'    THEN 'email'
      WHEN name ILIKE '%sms%'      THEN 'sms'
      WHEN name ILIKE '%in-app%' OR name ILIKE '%inapp%' THEN 'inapp'
      ELSE channel
    END,
    updated_at = now()
WHERE channel IS NULL;

-- The 5 "AI Report" packs are intentionally left with a NULL channel: they
-- are not notification credits and do not belong against a channel pool.

-- Verify:
--   select channel, count(*) from t_bm_topup_pack where is_active group by channel;
--   -- create a contract for a metered tenant, then:
--   select usage_contracts, credits_whatsapp, credits_email
--   from t_tenant_context where tenant_id = '<tenant>';


-- ─────────────────────────────────────────────────────────────────────
-- THE OTHER HALF: the ledger was writing, the read model was not reading.
--
-- add_credits works — it writes t_bm_credit_balance and the journal. But
-- t_tenant_context.credits_* stayed at 0, because the sync trigger
-- (trg_fn_update_context_on_credit_change) opened with:
--
--     SELECT product_code, status ... FROM t_bm_tenant_subscription
--     WHERE tenant_id = ... AND status IN ('active','trial','grace_period')
--     IF v_product_code IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;
--
-- A tenant's plan is a CONTRACT now, so t_bm_tenant_subscription is empty
-- for every plan tenant. v_product_code came back NULL and the trigger
-- returned before syncing anything. Migration 012 noted this early return
-- as "latent" — it stopped being latent the moment plans moved to
-- contracts.
--
-- Product code now comes from t_tenant_context itself. The subscription
-- status is still consulted for the credit flags, falling back to the
-- billing mode when there is no legacy row.
-- ─────────────────────────────────────────────────────────────────────

-- (applied in place against the deployed function; reproduced here so the
--  file matches production)
DO $do$
DECLARE v_src TEXT; v_old TEXT; v_new TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='trg_fn_update_context_on_credit_change';

  v_old := '    SELECT product_code, status INTO v_product_code, v_sub_status
    FROM t_bm_tenant_subscription
    WHERE tenant_id = v_tenant_id
      AND status IN (''active'', ''trial'', ''grace_period'')
    ORDER BY created_at DESC LIMIT 1;

    IF v_product_code IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;';

  v_new := '    SELECT product_code INTO v_product_code
    FROM t_tenant_context
    WHERE tenant_id = v_tenant_id
    ORDER BY (product_code = ''contractnest'') DESC
    LIMIT 1;

    IF v_product_code IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    SELECT status INTO v_sub_status
    FROM t_bm_tenant_subscription
    WHERE tenant_id = v_tenant_id
      AND status IN (''active'', ''trial'', ''grace_period'')
    ORDER BY created_at DESC LIMIT 1;

    IF v_sub_status IS NULL THEN
        SELECT CASE WHEN billing_mode IN (''plan'', ''wallet'') THEN ''active'' END
        INTO v_sub_status
        FROM t_tenant_context
        WHERE tenant_id = v_tenant_id AND product_code = v_product_code;
    END IF;';

  IF position(v_old in v_src) = 0 THEN
    RAISE NOTICE 'sync-trigger anchor not found — already patched, skipping';
    RETURN;
  END IF;

  EXECUTE replace(v_src, v_old, v_new);
END $do$;
