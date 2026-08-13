-- Migration 031: generalize payment-gated entitlement deferral
-- Already applied live. Source-of-record copy — do not re-run.
--
-- fn_apply_contract_entitlements deferred entitlements only for
-- metadata.source='plan_subscription' contracts (migration 030). This widens
-- the guard so ANY contract whose own acceptance_method is genuinely
-- 'payment' also defers — covers admin-assigned contracts (Catalog Studio
-- Assign -> VaNi composer) and any future path, since respond_to_contract's
-- accept-link handler flips pending_acceptance -> active with no payment
-- check of its own. trg_fn_topup_credits_on_payment (030) already calls this
-- unconditionally on every invoice reaching 'paid', so entitlements land
-- automatically once the deferred condition clears.

CREATE OR REPLACE FUNCTION public.fn_apply_contract_entitlements(p_contract_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contract   RECORD;
  v_subscriber UUID;
  v_meter      JSONB;
  v_limits     JSONB := '{}'::JSONB;
  v_grants     JSONB := '{}'::JSONB;
  v_once       JSONB := '{}'::JSONB;
  v_flags      TEXT[] := ARRAY[]::TEXT[];
  v_found      BOOLEAN := FALSE;
  v_is_switch  BOOLEAN := FALSE;
  v_gkey       TEXT;
  v_gval       INTEGER;
  r            RECORD;
BEGIN
  SELECT c.*, ct.source_tenant_id
  INTO v_contract
  FROM t_contracts c
  LEFT JOIN t_contacts ct ON ct.id = c.buyer_id
  WHERE c.id = p_contract_id;

  IF v_contract.id IS NULL THEN RETURN; END IF;

  -- only live, active, real contracts entitle anyone
  IF v_contract.record_type <> 'contract'
     OR v_contract.is_live IS DISTINCT FROM TRUE
     OR v_contract.status <> 'active' THEN
    RETURN;
  END IF;

  -- top-up purchases are payment-gated in fn_apply_topup_grants — not here
  IF COALESCE(v_contract.metadata->>'source','') = 'topup_purchase' THEN
    RETURN;
  END IF;

  -- Payment-gated priced contracts defer entitlements until the first
  -- invoice clears — mirrors fn_apply_topup_grants' existing pack behavior.
  -- Two independent triggers for this, covering every known path:
  --   (a) plan_subscription contracts — subscribe_tenant_to_plan hardcodes
  --       acceptance_method 'auto' (so the contract activates + invoices
  --       immediately, same as topup packs), so it needs its own metadata
  --       signal rather than relying on acceptance_method.
  --   (b) ANY contract whose own acceptance_method is genuinely 'payment' —
  --       covers admin-assigned contracts (Catalog Studio Assign -> VaNi
  --       composer) and any future path, since respond_to_contract's
  --       accept-link handler flips pending_acceptance -> active with no
  --       payment check of its own.
  IF (
       COALESCE(v_contract.metadata->>'source','') = 'plan_subscription'
       OR v_contract.acceptance_method = 'payment'
     )
     AND COALESCE(v_contract.grand_total, 0) > 0
     AND NOT EXISTS (
       SELECT 1 FROM t_invoices
       WHERE contract_id = p_contract_id AND status = 'paid'
     )
  THEN
    RETURN;
  END IF;

  -- already settled (idempotency across both triggers and re-activation)
  IF v_contract.metadata ? 'entitlements_applied_at' THEN
    RETURN;
  END IF;

  v_subscriber := v_contract.source_tenant_id;
  IF v_subscriber IS NULL THEN RETURN; END IF;   -- buyer is not a tenant

  -- collect metering off the contract's OWN block rows
  FOR r IN SELECT custom_fields->'config'->'metering' AS meter
           FROM t_contract_blocks
           WHERE contract_id = p_contract_id
             AND custom_fields->'config'->'metering' IS NOT NULL
  LOOP
    v_meter := r.meter;
    v_found := TRUE;
    IF v_meter->>'mode' = 'limit' AND v_meter->'limits' IS NOT NULL THEN
      v_limits := v_limits || v_meter->'limits';
    ELSIF v_meter->>'mode' = 'per_creation' AND v_meter->'grants' IS NOT NULL THEN
      v_grants := v_grants || v_meter->'grants';
    ELSIF v_meter->>'mode' = 'one_time' AND v_meter->'grants' IS NOT NULL THEN
      v_once := v_once || v_meter->'grants';
    ELSIF v_meter->>'mode' = 'flag' AND v_meter->>'flag' IS NOT NULL THEN
      v_flags := v_flags || (v_meter->>'flag');
    END IF;
  END LOOP;

  IF NOT v_found THEN RETURN; END IF;   -- nothing metered on this contract

  v_is_switch := (v_contract.metadata ? 'switched_from_contract_id')
                 AND (v_contract.metadata->>'switched_from_contract_id') IS NOT NULL;

  INSERT INTO t_tenant_context (product_code, tenant_id)
  VALUES ('contractnest', v_subscriber)
  ON CONFLICT (product_code, tenant_id) DO NOTHING;

  UPDATE t_tenant_context
  SET -- a LIMIT block is what makes this a plan; flag-only contracts
      -- (e.g. Extend touchpoint add-ons) must not touch billing_mode/limits
      billing_mode       = CASE WHEN v_limits <> '{}'::JSONB THEN 'plan' ELSE billing_mode END,
      limit_contracts    = CASE WHEN v_limits <> '{}'::JSONB
                                THEN COALESCE((v_limits->>'contracts')::INT, 0) ELSE limit_contracts END,
      limit_rfqs         = CASE WHEN v_limits <> '{}'::JSONB
                                THEN COALESCE((v_limits->>'rfqs')::INT, 0) ELSE limit_rfqs END,
      credit_grant_rates = CASE WHEN v_grants = '{}'::JSONB THEN credit_grant_rates ELSE v_grants END,
      addon_vani_ai      = ('addon_vani_ai' = ANY(v_flags)) OR addon_vani_ai,
      addon_rfp          = ('addon_rfp'     = ANY(v_flags)) OR addon_rfp,
      -- flags without a dedicated column land in addons_extra (added below)
      addons_extra       = (SELECT COALESCE(addons_extra, '{}'::JSONB) ||
                              COALESCE((SELECT jsonb_object_agg(f, TRUE)
                                        FROM unnest(v_flags) f
                                        WHERE f NOT IN ('addon_vani_ai','addon_rfp')), '{}'::JSONB)),
      flag_can_access    = TRUE,
      -- switching plans forfeits the old plan's unused allowance and accrued
      -- credits (owner decision 2026-08-09) — detected via metadata rather
      -- than passed in, so ANY switch-shaped contract behaves the same
      usage_contracts    = CASE WHEN v_is_switch THEN 0 ELSE usage_contracts END,
      usage_rfqs         = CASE WHEN v_is_switch THEN 0 ELSE usage_rfqs END,
      credits_whatsapp   = CASE WHEN v_is_switch THEN 0 ELSE credits_whatsapp END,
      credits_sms        = CASE WHEN v_is_switch THEN 0 ELSE credits_sms END,
      credits_email      = CASE WHEN v_is_switch THEN 0 ELSE credits_email END,
      credits_inapp      = CASE WHEN v_is_switch THEN 0 ELSE credits_inapp END,
      updated_at         = now()
  WHERE product_code = 'contractnest' AND tenant_id = v_subscriber;

  -- one-time grants on non-topup contracts (a plan bundling starter credits)
  FOR v_gkey, v_gval IN SELECT key, value::INTEGER FROM jsonb_each_text(v_once)
  LOOP
    CONTINUE WHEN v_gval IS NULL OR v_gval <= 0;
    PERFORM add_credits(
      v_subscriber,
      CASE WHEN v_gkey IN ('whatsapp','sms','email','inapp') THEN 'notification' ELSE v_gkey END,
      v_gval,
      CASE WHEN v_gkey IN ('whatsapp','sms','email','inapp') THEN v_gkey ELSE NULL END,
      'plan_grant',
      p_contract_id::TEXT,
      'Included with ' || COALESCE(v_contract.name, 'plan'),
      'contract'
    );
  END LOOP;

  -- settle marker — the idempotency anchor
  UPDATE t_contracts
  SET metadata = COALESCE(metadata, '{}'::JSONB)
                 || jsonb_build_object('entitlements_applied_at', now()::TEXT)
  WHERE id = p_contract_id;
END;
$function$;
