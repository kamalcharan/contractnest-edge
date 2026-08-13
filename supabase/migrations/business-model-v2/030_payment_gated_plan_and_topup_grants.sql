-- ============================================================================
-- Business Model V5 — payment-gated plan subscribe/switch + topup purchase,
-- plus flag-mode grants for topup packs (Website/WhatsApp Extend touchpoints).
--
-- Already applied live — this file is the source-of-record copy, not to be
-- re-run. See the migration header inside for the full rationale.
--
-- Problem: subscribe_tenant_to_plan and purchase_topup_template both hardcode
-- acceptance_method 'auto', so every plan/pack contract goes 'active' the
-- instant it's created — and fn_apply_contract_entitlements fires purely off
-- contract status, with zero connection to whether the invoice was ever
-- paid. A tenant "switching" to Yearly (₹19,999) got the full 200-contract
-- limit and 20+20 credits granted instantly, with no payment ever collected.
--
-- purchase_topup_template already half-solves this for CREDIT/WALLET grants:
-- fn_apply_topup_grants only fires immediately for free (₹0) packs; a paid
-- pack's grants wait for trg_topup_credits_on_payment on t_invoices. This
-- migration:
--   1. Extends that exact pattern to plan_subscription contracts, so Free
--      stays instant (unchanged) but any priced plan only grants once its
--      first invoice is marked paid.
--   2. Extends purchase_topup_template + fn_apply_topup_grants to also
--      collect/apply 'flag' mode metering (until now only 'one_time'
--      numeric grants were handled) — needed for the two touchpoint packs
--      seeded below, which grant a boolean addon, not a credit count.
--   3. Surfaces invoice_id/amount on both RPCs' response so the frontend can
--      open Razorpay checkout against the right invoice immediately after
--      create.
--
-- Also applied live in this pass, not part of this SQL file:
--   - Quarterly plan template's settings.defaults.duration_value/unit fixed
--     from "1 year" to "3 months" — a live-data authoring bug, not code.
--   - Two new topup_pack templates seeded under the platform tenant:
--     "Website Touchpoint" and "WhatsApp Touchpoint", ₹700 each, each with a
--     flag-mode metering block (addon_extend_website / addon_extend_whatsapp)
--     — see t_cat_templates rows 54a42ec0.../1868b804... .
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. purchase_topup_template — collect flag-mode blocks, surface invoice info
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.purchase_topup_template(p_template_id uuid, p_buyer_tenant_id uuid, p_user_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_platform_id UUID;
    v_template    RECORD;
    v_buyer       RECORD;
    v_contact_id  UUID;
    v_seq         JSONB;
    v_blocks      JSONB := '[]'::JSONB;
    v_block       JSONB;
    v_meter       JSONB;
    v_grants      JSONB := '{}'::JSONB;
    v_flags       TEXT[] := ARRAY[]::TEXT[];
    v_wallet_paise BIGINT := NULL;
    v_events      JSONB := '[]'::JSONB;
    v_payload     JSONB;
    v_result      JSONB;
    v_contract_id UUID;
    v_dur_value   INTEGER;
    v_dur_unit    TEXT;
    v_invoice_id       UUID;
    v_invoice_amount   NUMERIC;
    v_invoice_currency TEXT;
BEGIN
    SELECT id INTO v_platform_id FROM t_tenants WHERE is_admin = TRUE LIMIT 1;
    IF v_platform_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No platform tenant configured',
                                  'error_code', 'NO_PLATFORM_TENANT');
    END IF;

    IF p_buyer_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'buyer tenant is required',
                                  'error_code', 'VALIDATION_ERROR');
    END IF;

    IF p_buyer_tenant_id = v_platform_id THEN
        RETURN jsonb_build_object('success', false,
            'error', 'The platform tenant cannot buy its own credit pack',
            'error_code', 'SELF_PURCHASE');
    END IF;

    SELECT * INTO v_template
    FROM t_cat_templates
    WHERE id = p_template_id
      AND tenant_id = v_platform_id
      AND is_active = TRUE
      AND is_live = TRUE
      AND is_public = TRUE
      AND settings->>'lifecycle' = 'signed_off';

    IF v_template.id IS NULL THEN
        RETURN jsonb_build_object('success', false,
            'error', 'Pack not found, not published, or not listed for sale',
            'error_code', 'PACK_NOT_AVAILABLE');
    END IF;

    IF v_template.category = 'wallet_topup' THEN
        v_wallet_paise := ROUND(COALESCE(v_template.total, 0) * 100)::BIGINT;
    ELSE
        FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_template.blocks, '[]'::JSONB))
        LOOP
            v_meter := v_block->'config_overrides'->'config'->'metering';
            CONTINUE WHEN v_meter IS NULL;
            IF v_meter->>'mode' = 'one_time' AND v_meter->'grants' IS NOT NULL THEN
                v_grants := v_grants || v_meter->'grants';
            ELSIF v_meter->>'mode' = 'flag' AND v_meter->>'flag' IS NOT NULL THEN
                v_flags := array_append(v_flags, v_meter->>'flag');
            END IF;
        END LOOP;
    END IF;

    IF v_grants = '{}'::JSONB AND (v_wallet_paise IS NULL OR v_wallet_paise <= 0)
       AND COALESCE(array_length(v_flags, 1), 0) = 0 THEN
        RETURN jsonb_build_object('success', false,
            'error', 'This template grants nothing once and tops up no wallet - it is a plan, not a credit pack',
            'error_code', 'NOT_A_TOPUP_PACK');
    END IF;

    SELECT id, name INTO v_buyer FROM t_tenants WHERE id = p_buyer_tenant_id;
    IF v_buyer.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Buyer tenant not found',
                                  'error_code', 'TENANT_NOT_FOUND');
    END IF;

    SELECT id INTO v_contact_id
    FROM t_contacts
    WHERE tenant_id = v_platform_id AND is_live = TRUE
      AND source_tenant_id = p_buyer_tenant_id
    LIMIT 1;

    IF v_contact_id IS NULL THEN
        v_seq := get_next_formatted_sequence('CONTACT', v_platform_id, TRUE);
        INSERT INTO t_contacts (
            tenant_id, is_live, type, name, company_name, contact_number,
            classifications, status, is_active, is_seed,
            source, source_tenant_id, created_by
        ) VALUES (
            v_platform_id, TRUE, 'corporate',
            NULL, v_buyer.name, v_seq->>'formatted',
            '["client"]'::JSONB, 'active', TRUE, FALSE,
            'topup_purchase', p_buyer_tenant_id, p_user_id
        )
        RETURNING id INTO v_contact_id;
    END IF;

    FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_template.blocks, '[]'::JSONB))
    LOOP
        v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
            'position',        COALESCE((v_block->>'order')::INT, 0),
            'source_type',     'catalog',
            'source_block_id', v_block->>'block_id',
            'block_name',      v_block->'config_overrides'->>'name',
            'category_id',     v_block->'config_overrides'->>'category_id',
            'category_name',   v_block->'config_overrides'->>'category_name',
            'unit_price',      COALESCE((v_block->'config_overrides'->>'unit_price')::NUMERIC, 0),
            'quantity',        COALESCE((v_block->'config_overrides'->>'quantity')::INT, 1),
            'billing_cycle',   'prepaid',
            'total_price',     COALESCE((v_block->'config_overrides'->>'total_price')::NUMERIC, 0),
            'custom_fields',   jsonb_build_object(
                                  'config',   COALESCE(v_block->'config_overrides'->'config', '{}'::JSONB),
                                  'currency', COALESCE(v_template.currency, 'INR'),
                                  'notes',    'Credit pack: ' || COALESCE(v_template.display_name, v_template.name)
                               )
        ));
    END LOOP;

    IF COALESCE(v_template.total, 0) > 0 THEN
        v_events := jsonb_build_array(jsonb_build_object(
            'id', 'billing-1',
            'event_type', 'billing',
            'category_id', '',
            'block_name', COALESCE(v_template.display_name, v_template.name),
            'scheduled_date', now(),
            'amount', v_template.total,
            'status', 'pending'
        ));
    END IF;

    v_dur_value := COALESCE((v_template.settings->'defaults'->>'duration_value')::INT, 1);
    v_dur_unit  := COALESCE(v_template.settings->'defaults'->>'duration_unit', 'months');

    v_payload := jsonb_build_object(
        'tenant_id',         v_platform_id,
        'is_live',           TRUE,
        'record_type',       'contract',
        'contract_type',     'client',
        'name',              COALESCE(v_template.display_name, v_template.name),
        'buyer_id',          v_contact_id,
        'buyer_company',     v_buyer.name,
        'currency',          COALESCE(v_template.currency, 'INR'),
        'duration_value',    v_dur_value,
        'duration_unit',     v_dur_unit,
        'start_date',        now(),
        'acceptance_method', 'auto',
        'nomenclature_id',   v_template.settings->'defaults'->>'nomenclature_id',
        'billing_cycle_type','unified',
        'grand_total',       COALESCE(v_template.total, 0),
        'total_value',       COALESCE(v_template.total, 0),
        'tax_total',         0,
        'discount_total',    0,
        'blocks',            v_blocks,
        'computed_events',   v_events,
        'created_by',        p_user_id,
        'performed_by_type', 'user',
        'metadata',          jsonb_build_object(
                                'source',            'topup_purchase',
                                'pack_template_id',  v_template.id,
                                'buyer_tenant_id',   p_buyer_tenant_id,
                                'topup_grants',      v_grants,
                                'topup_flags',       to_jsonb(v_flags),
                                'wallet_topup_paise', v_wallet_paise
                             )
    );

    v_result := create_contract_transaction(v_payload, NULL);

    IF NOT COALESCE((v_result->>'success')::BOOLEAN, FALSE) THEN
        RETURN jsonb_build_object('success', false,
            'error', COALESCE(v_result->>'error', 'Contract creation failed'),
            'error_code', 'CONTRACT_CREATE_FAILED', 'detail', v_result);
    END IF;

    v_contract_id := (v_result->'data'->>'id')::UUID;

    SELECT id, total_amount, currency INTO v_invoice_id, v_invoice_amount, v_invoice_currency
    FROM t_invoices
    WHERE contract_id = v_contract_id
    ORDER BY created_at ASC
    LIMIT 1;

    IF COALESCE(v_template.total, 0) <= 0 THEN
        PERFORM fn_apply_topup_grants(v_contract_id);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'contract_id',     v_contract_id,
        'contract_number', v_result->'data'->>'contract_number',
        'contact_id',      v_contact_id,
        'pack_name',       COALESCE(v_template.display_name, v_template.name),
        'amount',          COALESCE(v_template.total, 0),
        'currency',        COALESCE(v_template.currency, 'INR'),
        'grants',          v_grants,
        'flags',           to_jsonb(v_flags),
        'wallet_paise',    v_wallet_paise,
        'credits_pending', COALESCE(v_template.total, 0) > 0,
        'invoice_id',       v_invoice_id,
        'invoice_amount',   v_invoice_amount,
        'invoice_currency', COALESCE(v_invoice_currency, v_template.currency, 'INR')
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. fn_apply_topup_grants — apply flag-mode grants too
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_apply_topup_grants(p_contract_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_c           RECORD;
    v_buyer       UUID;
    v_grants      JSONB;
    v_flags       TEXT[];
    v_wallet_paise BIGINT;
    v_key         TEXT;
    v_val         INTEGER;
    v_n           INTEGER := 0;
    v_before      BIGINT;
    v_after       BIGINT;
BEGIN
    SELECT id, name, contract_number, metadata INTO v_c
    FROM t_contracts WHERE id = p_contract_id;

    IF NOT FOUND OR COALESCE(v_c.metadata->>'source', '') <> 'topup_purchase' THEN
        RETURN jsonb_build_object('success', true, 'granted', false, 'reason', 'not_a_topup');
    END IF;

    IF EXISTS (SELECT 1 FROM t_credit_journal
               WHERE reference_type = 'topup_contract' AND reference_id = p_contract_id) THEN
        RETURN jsonb_build_object('success', true, 'granted', false, 'reason', 'already_granted');
    END IF;

    v_buyer        := (v_c.metadata->>'buyer_tenant_id')::UUID;
    v_grants       := COALESCE(v_c.metadata->'topup_grants', '{}'::JSONB);
    v_flags        := ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_c.metadata->'topup_flags', '[]'::JSONB)));
    v_wallet_paise := (v_c.metadata->>'wallet_topup_paise')::BIGINT;

    IF v_buyer IS NULL THEN
        RETURN jsonb_build_object('success', true, 'granted', false, 'reason', 'nothing_to_grant');
    END IF;

    FOR v_key, v_val IN SELECT key, value::INTEGER FROM jsonb_each_text(v_grants)
    LOOP
        CONTINUE WHEN v_val IS NULL OR v_val <= 0;

        PERFORM add_credits(
            v_buyer,
            CASE WHEN v_key IN ('whatsapp','sms','email','inapp')
                 THEN 'notification' ELSE v_key END,
            v_val,
            CASE WHEN v_key IN ('whatsapp','sms','email','inapp')
                 THEN v_key ELSE NULL END,
            'topup',
            p_contract_id::TEXT,
            'Credit pack ' || COALESCE(v_c.contract_number, '') || ': ' || COALESCE(v_c.name, ''),
            'topup_contract'
        );
        v_n := v_n + 1;
    END LOOP;

    IF v_wallet_paise IS NOT NULL AND v_wallet_paise > 0 THEN
        INSERT INTO t_tenant_context (product_code, tenant_id, billing_mode)
        VALUES ('contractnest', v_buyer, 'per_contract')
        ON CONFLICT (product_code, tenant_id) DO NOTHING;

        SELECT wallet_balance_paise INTO v_before
        FROM t_tenant_context
        WHERE product_code = 'contractnest' AND tenant_id = v_buyer
        FOR UPDATE;

        v_before := COALESCE(v_before, 0);
        v_after  := v_before + v_wallet_paise;

        UPDATE t_tenant_context
        SET billing_mode       = 'per_contract',
            limit_contracts    = NULL,
            limit_rfqs         = NULL,
            credit_grant_rates = jsonb_build_object('whatsapp', 15, 'email', 15),
            wallet_balance_paise = v_after,
            flag_can_access    = TRUE,
            updated_at         = now()
        WHERE product_code = 'contractnest' AND tenant_id = v_buyer;

        INSERT INTO t_credit_journal (
            tenant_id, credit_type, channel, transaction_type, quantity,
            balance_before, balance_after, reference_type, reference_id, description
        ) VALUES (
            v_buyer, 'wallet', NULL, 'topup', v_wallet_paise,
            v_before, v_after, 'topup_contract', p_contract_id,
            'Wallet top-up ' || COALESCE(v_c.contract_number, '') || ': ' || COALESCE(v_c.name, '')
        );

        v_n := v_n + 1;
    END IF;

    -- flag grants (e.g. Extend touchpoint unlocks) — no dedicated credit
    -- pool, so no t_credit_journal row; mirrors how fn_apply_contract_
    -- entitlements grants plan flags with no ledger entry either.
    IF COALESCE(array_length(v_flags, 1), 0) > 0 THEN
        INSERT INTO t_tenant_context (product_code, tenant_id)
        VALUES ('contractnest', v_buyer)
        ON CONFLICT (product_code, tenant_id) DO NOTHING;

        UPDATE t_tenant_context
        SET addon_vani_ai   = ('addon_vani_ai' = ANY(v_flags)) OR addon_vani_ai,
            addon_rfp       = ('addon_rfp' = ANY(v_flags)) OR addon_rfp,
            addons_extra    = COALESCE(addons_extra, '{}'::JSONB) ||
                               COALESCE((SELECT jsonb_object_agg(f, TRUE)
                                         FROM unnest(v_flags) f
                                         WHERE f NOT IN ('addon_vani_ai', 'addon_rfp')), '{}'::JSONB),
            flag_can_access = TRUE,
            updated_at      = now()
        WHERE product_code = 'contractnest' AND tenant_id = v_buyer;

        v_n := v_n + 1;
    END IF;

    IF v_n = 0 THEN
        RETURN jsonb_build_object('success', true, 'granted', false, 'reason', 'nothing_to_grant');
    END IF;

    RETURN jsonb_build_object('success', true, 'granted', TRUE,
        'contract_id', p_contract_id, 'pools', v_n);

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'topup grant failed for contract %: %', p_contract_id, SQLERRM;
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;

-- ----------------------------------------------------------------------------
-- 3. fn_apply_contract_entitlements — defer priced plan subscriptions until paid
-- ----------------------------------------------------------------------------
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

  -- paid plan subscriptions defer entitlements until the first invoice
  -- clears — mirrors fn_apply_topup_grants' existing pack behavior. Closes
  -- the gap where subscribe_tenant_to_plan hardcodes acceptance_method
  -- 'auto': without this, a plan's full limits/credits were granted the
  -- instant the contract was created, with zero payment ever collected or
  -- verified (e.g. a ₹19,999 Yearly switch granted 200 contracts free).
  IF COALESCE(v_contract.metadata->>'source','') = 'plan_subscription'
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

-- ----------------------------------------------------------------------------
-- 4. trg_fn_topup_credits_on_payment — also settle plan entitlements on payment
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_fn_topup_credits_on_payment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF NEW.status <> 'paid' OR COALESCE(OLD.status, '') = 'paid' THEN
        RETURN NULL;
    END IF;

    IF NEW.contract_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Two independent settlement paths, each self-guarded by the contract's
    -- own metadata.source — safe to call both unconditionally on every
    -- invoice that turns 'paid', regardless of which kind of contract it
    -- belongs to (topup_purchase vs plan_subscription vs neither).
    PERFORM fn_apply_topup_grants(NEW.contract_id);
    PERFORM fn_apply_contract_entitlements(NEW.contract_id);
    RETURN NULL;

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'settlement on payment failed for invoice %: %', NEW.id, SQLERRM;
    RETURN NULL;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 5. subscribe_tenant_to_plan — surface invoice info for checkout
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.subscribe_tenant_to_plan(p_template_id uuid, p_subscriber_tenant_id uuid, p_user_id uuid DEFAULT NULL::uuid, p_computed_events jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_platform_id     UUID;
    v_template        RECORD;
    v_subscriber      RECORD;
    v_contact_id      UUID;
    v_seq             JSONB;
    v_existing        RECORD;
    v_is_switch       BOOLEAN := FALSE;
    v_previous_contract_id UUID;
    v_cancel_result   JSONB;
    v_blocks          JSONB := '[]'::JSONB;
    v_block           JSONB;
    v_payload         JSONB;
    v_result          JSONB;
    v_meter           JSONB;
    v_limits          JSONB := '{}'::JSONB;
    v_grants          JSONB := '{}'::JSONB;
    v_flags           TEXT[] := ARRAY[]::TEXT[];
    v_duration_value  INTEGER;
    v_duration_unit   TEXT;
    v_events          JSONB;
    v_invoice_id       UUID;
    v_invoice_amount   NUMERIC;
    v_invoice_currency TEXT;
BEGIN
    SELECT id INTO v_platform_id FROM t_tenants WHERE is_admin = TRUE LIMIT 1;
    IF v_platform_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No platform tenant configured',
                                  'error_code', 'NO_PLATFORM_TENANT');
    END IF;

    IF p_subscriber_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'subscriber tenant is required',
                                  'error_code', 'VALIDATION_ERROR');
    END IF;

    IF p_subscriber_tenant_id = v_platform_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'The platform tenant cannot subscribe to its own plan',
                                  'error_code', 'SELF_SUBSCRIPTION');
    END IF;

    SELECT * INTO v_template
    FROM t_cat_templates
    WHERE id = p_template_id
      AND tenant_id = v_platform_id
      AND is_active = TRUE
      AND is_live = TRUE
      AND is_public = TRUE
      AND settings->>'lifecycle' = 'signed_off';

    IF v_template.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Plan not found, not published, or not listed for sale',
                                  'error_code', 'PLAN_NOT_AVAILABLE');
    END IF;

    SELECT id, name INTO v_subscriber FROM t_tenants WHERE id = p_subscriber_tenant_id;
    IF v_subscriber.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Subscriber tenant not found',
                                  'error_code', 'TENANT_NOT_FOUND');
    END IF;

    SELECT c.id, c.contract_number, c.metadata->>'plan_template_id' AS plan_template_id INTO v_existing
    FROM t_contracts c
    JOIN t_contacts ct ON ct.id = c.buyer_id
    WHERE c.tenant_id = v_platform_id
      AND c.is_live = TRUE
      AND c.record_type = 'contract'
      AND c.status IN ('active', 'pending_acceptance')
      AND COALESCE(c.metadata->>'source', '') <> 'topup_purchase'
      AND ct.source_tenant_id = p_subscriber_tenant_id
    LIMIT 1;

    IF v_existing.id IS NOT NULL THEN
        IF v_existing.plan_template_id = p_template_id::TEXT THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'This tenant already has an active plan (' || v_existing.contract_number || ')',
                'error_code', 'ALREADY_SUBSCRIBED',
                'contract_id', v_existing.id
            );
        END IF;

        v_is_switch := TRUE;
        v_previous_contract_id := v_existing.id;

        v_cancel_result := update_contract_status(
            v_existing.id, v_platform_id, 'cancelled',
            p_user_id, NULL, 'system',
            'Superseded by switch to plan: ' || COALESCE(v_template.display_name, v_template.name)
        );

        IF NOT COALESCE((v_cancel_result->>'success')::BOOLEAN, FALSE) THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', COALESCE(v_cancel_result->>'error', 'Could not end current plan'),
                'error_code', 'SWITCH_CANCEL_FAILED',
                'detail', v_cancel_result
            );
        END IF;
    END IF;

    SELECT id INTO v_contact_id
    FROM t_contacts
    WHERE tenant_id = v_platform_id
      AND is_live = TRUE
      AND source_tenant_id = p_subscriber_tenant_id
    LIMIT 1;

    IF v_contact_id IS NULL THEN
        v_seq := get_next_formatted_sequence('CONTACT', v_platform_id, TRUE);

        INSERT INTO t_contacts (
            tenant_id, is_live, type, name, company_name, contact_number,
            classifications, status, is_active, is_seed,
            source, source_tenant_id, created_by
        ) VALUES (
            v_platform_id, TRUE, 'corporate',
            NULL, v_subscriber.name, v_seq->>'formatted',
            '["client"]'::JSONB, 'active', TRUE, FALSE,
            'plan_subscription', p_subscriber_tenant_id, p_user_id
        )
        RETURNING id INTO v_contact_id;
    END IF;

    FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_template.blocks, '[]'::JSONB))
    LOOP
        v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
            'position',        COALESCE((v_block->>'order')::INT, 0),
            'source_type',     'catalog',
            'source_block_id', v_block->>'block_id',
            'block_name',      v_block->'config_overrides'->>'name',
            'category_id',     v_block->'config_overrides'->>'category_id',
            'category_name',   v_block->'config_overrides'->>'category_name',
            'unit_price',      COALESCE((v_block->'config_overrides'->>'unit_price')::NUMERIC, 0),
            'quantity',        COALESCE((v_block->'config_overrides'->>'quantity')::INT, 1),
            'billing_cycle',   COALESCE(v_block->'config_overrides'->>'billing_cycle', 'prepaid'),
            'total_price',     COALESCE((v_block->'config_overrides'->>'total_price')::NUMERIC, 0),
            'custom_fields',   jsonb_build_object(
                                  'config',   COALESCE(v_block->'config_overrides'->'config', '{}'::JSONB),
                                  'currency', COALESCE(v_template.currency, 'INR'),
                                  'notes',    'Plan: ' || COALESCE(v_template.display_name, v_template.name)
                               )
        ));
    END LOOP;

    v_duration_value := COALESCE((v_template.settings->'defaults'->>'duration_value')::INT, 1);
    v_duration_unit  := COALESCE(v_template.settings->'defaults'->>'duration_unit', 'months');

    -- Real schedule from the caller (API derives it from the template's
    -- wizard_state via the shared derivation engine). Fallback: one upfront
    -- event — the pre-030 behaviour — so older callers stay correct enough.
    IF p_computed_events IS NOT NULL AND jsonb_typeof(p_computed_events) = 'array'
       AND jsonb_array_length(p_computed_events) > 0 THEN
        v_events := p_computed_events;
    ELSIF COALESCE(v_template.total, 0) > 0 THEN
        v_events := jsonb_build_array(jsonb_build_object(
            'id', 'billing-1',
            'event_type', 'billing',
            'category_id', '',
            'block_name', COALESCE(v_template.display_name, v_template.name),
            'scheduled_date', now(),
            'amount', v_template.total,
            'status', 'pending'
        ));
    ELSE
        v_events := '[]'::JSONB;
    END IF;

    v_payload := jsonb_build_object(
        'tenant_id',         v_platform_id,
        'is_live',           TRUE,
        'record_type',       'contract',
        'contract_type',     'client',
        'name',              COALESCE(v_template.display_name, v_template.name),
        'buyer_id',          v_contact_id,
        'buyer_company',     v_subscriber.name,
        'currency',          COALESCE(v_template.currency, 'INR'),
        'duration_value',    v_duration_value,
        'duration_unit',     v_duration_unit,
        'start_date',        now(),
        'acceptance_method', 'auto',
        'nomenclature_id',   v_template.settings->'defaults'->>'nomenclature_id',
        'billing_cycle_type',COALESCE(v_template.settings->'defaults'->>'billing_cycle_type', 'unified'),
        'grand_total',       COALESCE(v_template.total, 0),
        'total_value',       COALESCE(v_template.total, 0),
        'tax_total',         0,
        'discount_total',    0,
        'blocks',            v_blocks,
        'computed_events',   v_events,
        'created_by',        p_user_id,
        'performed_by_type', 'user',
        'metadata',          jsonb_build_object(
                                'source',                 'plan_subscription',
                                'plan_template_id',       v_template.id,
                                'subscriber_tenant_id',   p_subscriber_tenant_id,
                                'switched_from_contract_id', v_previous_contract_id
                             )
    );

    v_result := create_contract_transaction(v_payload, NULL);

    IF NOT COALESCE((v_result->>'success')::BOOLEAN, FALSE) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', COALESCE(v_result->>'error', 'Contract creation failed'),
            'error_code', 'CONTRACT_CREATE_FAILED',
            'detail', v_result
        );
    END IF;

    SELECT id, total_amount, currency INTO v_invoice_id, v_invoice_amount, v_invoice_currency
    FROM t_invoices
    WHERE contract_id = (v_result->'data'->>'id')::UUID
    ORDER BY created_at ASC
    LIMIT 1;

    -- Response display only — actual application happens in
    -- fn_apply_contract_entitlements, gated on payment for priced plans (the
    -- deferred trigger fires at this transaction's COMMIT for the free case;
    -- trg_fn_topup_credits_on_payment fires it again once the invoice above
    -- is marked paid for the priced case).
    FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_template.blocks, '[]'::JSONB))
    LOOP
        v_meter := v_block->'config_overrides'->'config'->'metering';
        CONTINUE WHEN v_meter IS NULL;
        IF v_meter->>'mode' = 'limit' AND v_meter->'limits' IS NOT NULL THEN
            v_limits := v_limits || v_meter->'limits';
        ELSIF v_meter->>'mode' = 'per_creation' AND v_meter->'grants' IS NOT NULL THEN
            v_grants := v_grants || v_meter->'grants';
        ELSIF v_meter->>'mode' = 'flag' AND v_meter->>'flag' IS NOT NULL THEN
            v_flags := v_flags || (v_meter->>'flag');
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'contract_id',     v_result->'data'->>'id',
        'contract_number', v_result->'data'->>'contract_number',
        'contact_id',      v_contact_id,
        'plan_name',       COALESCE(v_template.display_name, v_template.name),
        'limits',          v_limits,
        'grants',          v_grants,
        'flags',           to_jsonb(v_flags),
        'was_switch',       v_is_switch,
        'previous_contract_id', v_previous_contract_id,
        'invoice_id',       v_invoice_id,
        'invoice_amount',   v_invoice_amount,
        'invoice_currency', COALESCE(v_invoice_currency, v_template.currency, 'INR'),
        'requires_payment', COALESCE(v_template.total, 0) > 0
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Subscription failed: ' || SQLERRM,
        'error_code', 'INTERNAL_ERROR'
    );
END;
$function$;
