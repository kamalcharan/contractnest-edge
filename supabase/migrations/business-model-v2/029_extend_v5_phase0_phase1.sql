-- ============================================================================
-- 029_extend_v5_phase0_phase1.sql — Business Model V5 / "Extend" build
-- ============================================================================
-- CONSOLIDATED RECORD of everything applied live via the Supabase MCP on
-- 2026-08-10 (project uwyqhzotluikawcboldr). ⚠ DO NOT RE-RUN THERE — this
-- file exists for the repo record and fresh environments. Applied as:
--   fix_quarterly_latest_missing_metering_blocks
--   fix_yearly_template_blocks_and_wizard_state
--   fix_yearly_dedicated_service_block
--   v5_entitlements_settlement_layer
--   v5_slim_subscribe_tenant_to_plan
--   v5_free_plan_by_default
--   v5_get_tenant_context_addons_extra
--   v5_extend_touchpoints_storefront (+ keygen + contact-channel fixes,
--   final versions inline below)
--
-- The model (owner, 2026-08-10): Vikuna = SELLER, tenant = BUYER, a plan is
-- a TEMPLATE, buying = assign-template-to-buyer → a real contract. The
-- CONTRACT is the source of truth; entitlements ride its lifecycle.
--
-- Sections:
--   1. Plan-template data repairs (Quarterly/Yearly version-chain damage)
--   2. Entitlements settlement layer (block-driven, contract lifecycle)
--   3. subscribe_tenant_to_plan slimmed (+ p_computed_events)
--   4. Free plan by default (signup trigger + backfill)
--   5. get_tenant_context returns addons_extra
--   6. Extend touchpoints + public storefront (t_touchpoints + RPCs)
-- ============================================================================


-- ════════════════════════════════════════════════════════════════════════
-- SECTION 1 — plan-template data repairs
--
-- Root cause of the "metering blocks show unchecked in Edit mode" bug: the
-- Quarterly template's LIVE version chain diverged. v3 387e804c
-- (is_latest=true) was re-authored via the wizard on 2026-08-10 10:41 and
-- LOST both metering blocks; the quarterly-plan-fixes data migration then
-- wrote the corrected 4-block layout to the STALE v1 row dee98106 at 12:56.
-- The plans listing and Edit mode both filter is_latest=true, so the live
-- Quarterly sold with NO limits and NO grants, and Edit truthfully showed
-- the metering blocks unchecked. The UI matching logic was never wrong.
--
-- Yearly had the same disease latent: its two metering entries BOTH pointed
-- at the FREEMIUM allowance block id, its service entry pointed at the FREE
-- plan's service block, and it had no wizard_state at all (an Edit+save
-- would have produced a bare 2-block version, repeating Quarterly's loss).
-- ════════════════════════════════════════════════════════════════════════

-- 1a. splice the two metering entries from Quarterly v1 into v3 (idempotent)
DO $$
DECLARE
  v_src RECORD; v_dst RECORD;
  v_new_blocks JSONB; v_new_selected JSONB;
BEGIN
  SELECT blocks, settings INTO v_src FROM t_cat_templates WHERE id = 'dee98106-7234-4567-b582-55d6264cd926';
  SELECT blocks, settings INTO v_dst FROM t_cat_templates WHERE id = '387e804c-c3a9-4d66-b2db-e29dae5af3c3';
  IF v_src IS NULL OR v_dst IS NULL THEN RAISE NOTICE 'quarterly rows not found — skipping'; RETURN; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_dst.blocks) b
             WHERE b->'config_overrides'->'config'->'metering' IS NOT NULL) THEN
    RAISE NOTICE 'quarterly v3 already carries metering blocks'; RETURN;
  END IF;
  SELECT v_dst.blocks || COALESCE(jsonb_agg(
           jsonb_set(b, '{order}', to_jsonb((b->>'order')::int + 1)) ORDER BY (b->>'order')::int), '[]'::jsonb)
  INTO v_new_blocks FROM jsonb_array_elements(v_src.blocks) b
  WHERE b->'config_overrides'->'config'->'metering' IS NOT NULL;
  SELECT (v_dst.settings->'wizard_state'->'selectedBlocks') || COALESCE(jsonb_agg(sb), '[]'::jsonb)
  INTO v_new_selected FROM jsonb_array_elements(v_src.settings->'wizard_state'->'selectedBlocks') sb
  WHERE sb->>'categoryId' = 'metering';
  IF jsonb_array_length(v_new_blocks) <> 4 OR jsonb_array_length(v_new_selected) <> 4 THEN
    RAISE EXCEPTION 'quarterly repair post-check failed';
  END IF;
  UPDATE t_cat_templates
  SET blocks = v_new_blocks,
      settings = jsonb_set(settings, '{wizard_state,selectedBlocks}', v_new_selected),
      updated_at = now()
  WHERE id = '387e804c-c3a9-4d66-b2db-e29dae5af3c3';
END $$;

-- 1b + 1c. Yearly: dedicated metering + service catalog blocks (live + test
-- twins cloned from the Quarterly pair's shape), template repointed, and
-- wizard_state generated from Quarterly v3's as the scaffold. The full
-- procedural bodies ran live on 2026-08-10 (migrations
-- fix_yearly_template_blocks_and_wizard_state and
-- fix_yearly_dedicated_service_block); on a FRESH environment the Yearly
-- template should simply be authored correctly in catalog-studio instead of
-- replaying the surgical repair. Post-repair invariants that must hold:
--   * every wizard_state.selectedBlocks id resolves to a same-environment
--     m_cat_blocks row with a matching name
--   * no two selectedBlocks share an id
--   * blocks[] and selectedBlocks agree (4 entries each)


-- ════════════════════════════════════════════════════════════════════════
-- SECTION 2 — entitlements settlement layer
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.fn_apply_contract_entitlements(p_contract_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

  IF v_contract.record_type <> 'contract'
     OR v_contract.is_live IS DISTINCT FROM TRUE
     OR v_contract.status <> 'active' THEN
    RETURN;
  END IF;

  -- top-up purchases are payment-gated in fn_apply_topup_grants — not here
  IF COALESCE(v_contract.metadata->>'source','') = 'topup_purchase' THEN
    RETURN;
  END IF;

  IF v_contract.metadata ? 'entitlements_applied_at' THEN
    RETURN;
  END IF;

  v_subscriber := v_contract.source_tenant_id;
  IF v_subscriber IS NULL THEN RETURN; END IF;   -- buyer is not a tenant

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

  IF NOT v_found THEN RETURN; END IF;

  v_is_switch := (v_contract.metadata ? 'switched_from_contract_id')
                 AND (v_contract.metadata->>'switched_from_contract_id') IS NOT NULL;

  INSERT INTO t_tenant_context (product_code, tenant_id)
  VALUES ('contractnest', v_subscriber)
  ON CONFLICT (product_code, tenant_id) DO NOTHING;

  UPDATE t_tenant_context
  SET billing_mode       = CASE WHEN v_limits <> '{}'::JSONB THEN 'plan' ELSE billing_mode END,
      limit_contracts    = CASE WHEN v_limits <> '{}'::JSONB
                                THEN COALESCE((v_limits->>'contracts')::INT, 0) ELSE limit_contracts END,
      limit_rfqs         = CASE WHEN v_limits <> '{}'::JSONB
                                THEN COALESCE((v_limits->>'rfqs')::INT, 0) ELSE limit_rfqs END,
      credit_grant_rates = CASE WHEN v_grants = '{}'::JSONB THEN credit_grant_rates ELSE v_grants END,
      addon_vani_ai      = ('addon_vani_ai' = ANY(v_flags)) OR addon_vani_ai,
      addon_rfp          = ('addon_rfp'     = ANY(v_flags)) OR addon_rfp,
      addons_extra       = (SELECT COALESCE(addons_extra, '{}'::JSONB) ||
                              COALESCE((SELECT jsonb_object_agg(f, TRUE)
                                        FROM unnest(v_flags) f
                                        WHERE f NOT IN ('addon_vani_ai','addon_rfp')), '{}'::JSONB)),
      flag_can_access    = TRUE,
      usage_contracts    = CASE WHEN v_is_switch THEN 0 ELSE usage_contracts END,
      usage_rfqs         = CASE WHEN v_is_switch THEN 0 ELSE usage_rfqs END,
      credits_whatsapp   = CASE WHEN v_is_switch THEN 0 ELSE credits_whatsapp END,
      credits_sms        = CASE WHEN v_is_switch THEN 0 ELSE credits_sms END,
      credits_email      = CASE WHEN v_is_switch THEN 0 ELSE credits_email END,
      credits_inapp      = CASE WHEN v_is_switch THEN 0 ELSE credits_inapp END,
      updated_at         = now()
  WHERE product_code = 'contractnest' AND tenant_id = v_subscriber;

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

  UPDATE t_contracts
  SET metadata = COALESCE(metadata, '{}'::JSONB)
                 || jsonb_build_object('entitlements_applied_at', now()::TEXT)
  WHERE id = p_contract_id;
END;
$function$;

ALTER TABLE t_tenant_context
  ADD COLUMN IF NOT EXISTS addons_extra JSONB NOT NULL DEFAULT '{}'::JSONB;
COMMENT ON COLUMN t_tenant_context.addons_extra IS
  'Addon flags without a dedicated column, {flag_name: true}. Written by fn_apply_contract_entitlements (mode=flag metering blocks). First consumers: Extend touchpoint flags addon_extend_website/_whatsapp/_email.';

CREATE OR REPLACE FUNCTION public.trg_fn_contract_entitlements()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  BEGIN
    PERFORM fn_apply_contract_entitlements(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'fn_apply_contract_entitlements failed for %: %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

-- deferred: create_contract_transaction inserts the contract row BEFORE its
-- blocks; deferring to COMMIT means the blocks exist when the settlement
-- function reads them
DROP TRIGGER IF EXISTS trg_zz_contract_entitlements_insert ON t_contracts;
CREATE CONSTRAINT TRIGGER trg_zz_contract_entitlements_insert
AFTER INSERT ON t_contracts
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
WHEN (NEW.status = 'active' AND NEW.record_type = 'contract' AND NEW.is_live = TRUE)
EXECUTE FUNCTION trg_fn_contract_entitlements();

DROP TRIGGER IF EXISTS trg_zz_contract_entitlements_status ON t_contracts;
CREATE TRIGGER trg_zz_contract_entitlements_status
AFTER UPDATE OF status ON t_contracts
FOR EACH ROW
WHEN (NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active'
      AND NEW.record_type = 'contract' AND NEW.is_live = TRUE)
EXECUTE FUNCTION trg_fn_contract_entitlements();


-- ════════════════════════════════════════════════════════════════════════
-- SECTION 3 — subscribe_tenant_to_plan, slimmed
--
-- KEEPS  cross-tenant authority, plan-policy guards, the source_tenant_id
--        contact, the switch (cancel via update_contract_status), raising
--        the contract via create_contract_transaction.
-- LOSES  all entitlement application — Section 2's triggers own it now, so
--        a MANUALLY assigned plan template entitles identically.
-- GAINS  p_computed_events: the API derives the REAL billing schedule from
--        the template's wizard_state (contractEventsDerivationService) and
--        passes it through; NULL falls back to the old single upfront event.
-- The 3-arg overload is DROPPED — keeping it would make PostgREST named-
-- argument calls ambiguous.
-- ════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.subscribe_tenant_to_plan(uuid, uuid, uuid);

CREATE OR REPLACE FUNCTION public.subscribe_tenant_to_plan(
    p_template_id           UUID,
    p_subscriber_tenant_id  UUID,
    p_user_id               UUID  DEFAULT NULL,
    p_computed_events       JSONB DEFAULT NULL
)
RETURNS JSONB
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

    -- Response display only — actual application happens in
    -- fn_apply_contract_entitlements at this transaction's COMMIT.
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
        'previous_contract_id', v_previous_contract_id
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Subscription failed: ' || SQLERRM,
        'error_code', 'INTERNAL_ERROR'
    );
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════
-- SECTION 4 — Free plan by default
-- ════════════════════════════════════════════════════════════════════════

-- the default plan is marked by a flag, never a hardcoded id
UPDATE t_cat_templates
SET settings = settings || '{"default_plan": true}'::JSONB
WHERE id = 'b9bd7089-9706-4fec-89a9-ac976b4a11d8';

CREATE OR REPLACE FUNCTION public.trg_fn_default_plan_on_signup()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_default UUID;
  v_result JSONB;
BEGIN
  IF NEW.is_admin IS TRUE OR NEW.is_test IS TRUE THEN
    RETURN NULL;
  END IF;

  SELECT id INTO v_default
  FROM t_cat_templates
  WHERE tenant_id = (SELECT id FROM t_tenants WHERE is_admin = TRUE LIMIT 1)
    AND is_live = TRUE AND is_latest = TRUE AND is_active = TRUE
    AND (settings->>'default_plan')::BOOLEAN IS TRUE
  LIMIT 1;

  IF v_default IS NULL THEN
    RAISE WARNING 'default_plan_on_signup: no default plan template configured';
    RETURN NULL;
  END IF;

  BEGIN
    v_result := subscribe_tenant_to_plan(v_default, NEW.id, NULL);
    IF NOT COALESCE((v_result->>'success')::BOOLEAN, FALSE) THEN
      RAISE WARNING 'default_plan_on_signup failed for %: %', NEW.id, v_result->>'error';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'default_plan_on_signup errored for %: %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_zz_default_plan_on_signup ON t_tenants;
CREATE TRIGGER trg_zz_default_plan_on_signup
AFTER INSERT ON t_tenants
FOR EACH ROW
EXECUTE FUNCTION trg_fn_default_plan_on_signup();

-- backfill: real active tenants without a plan (test tenants excluded —
-- subscribing 112 of them would mint junk contracts in the platform book).
-- Ran live 2026-08-10: 21/21 real active tenants ended on a plan, 0 failures.
DO $$
DECLARE
  v_default UUID; v_platform UUID; r RECORD; v_result JSONB;
  v_ok INT := 0; v_fail INT := 0;
BEGIN
  SELECT id INTO v_platform FROM t_tenants WHERE is_admin = TRUE LIMIT 1;
  SELECT id INTO v_default FROM t_cat_templates
  WHERE tenant_id = v_platform AND is_live = TRUE AND is_latest = TRUE AND is_active = TRUE
    AND (settings->>'default_plan')::BOOLEAN IS TRUE
  LIMIT 1;
  IF v_default IS NULL THEN RAISE EXCEPTION 'no default plan template configured'; END IF;

  FOR r IN
    SELECT t.id, t.name FROM t_tenants t
    WHERE t.is_admin = FALSE AND t.is_test = FALSE AND t.status = 'active'
      AND NOT EXISTS (
        SELECT 1 FROM t_contracts c
        JOIN t_contacts ct ON ct.id = c.buyer_id
        WHERE c.tenant_id = v_platform AND c.is_live = TRUE
          AND c.record_type = 'contract'
          AND c.status IN ('active','pending_acceptance')
          AND COALESCE(c.metadata->>'source','') <> 'topup_purchase'
          AND ct.source_tenant_id = t.id
      )
    ORDER BY t.created_at
  LOOP
    BEGIN
      v_result := subscribe_tenant_to_plan(v_default, r.id, NULL);
      IF COALESCE((v_result->>'success')::BOOLEAN, FALSE) THEN v_ok := v_ok + 1;
      ELSE v_fail := v_fail + 1;
        RAISE WARNING 'backfill failed for % (%): %', r.name, r.id, v_result->>'error';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fail := v_fail + 1;
      RAISE WARNING 'backfill errored for % (%): %', r.name, r.id, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'default-plan backfill: % subscribed, % failed', v_ok, v_fail;
END $$;


-- ════════════════════════════════════════════════════════════════════════
-- SECTION 5 — get_tenant_context returns addons_extra
--
-- One substitution against the live body: the 'addons' object gains
--   || COALESCE(v_context.addons_extra, '{}'::JSONB)
-- so the API/UI can gate on addon_extend_* flags. Full body as applied is in
-- migration v5_get_tenant_context_addons_extra (supabase migration history);
-- reproduce by taking the LIVE get_tenant_context definition and appending
-- the merge to the addons object — never retype the body by hand.
-- ════════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════════
-- SECTION 6 — Extend touchpoints + public storefront
-- ════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS t_touchpoints (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        UUID NOT NULL,
  template_id      UUID NOT NULL REFERENCES t_cat_templates(id),
  touchpoint_type  TEXT NOT NULL CHECK (touchpoint_type IN ('website','whatsapp','email')),
  storefront_key   TEXT NOT NULL UNIQUE,
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  config           JSONB NOT NULL DEFAULT '{}'::JSONB,
  views_count      INTEGER NOT NULL DEFAULT 0,
  purchases_count  INTEGER NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by       UUID,
  UNIQUE (tenant_id, template_id, touchpoint_type)
);
CREATE INDEX IF NOT EXISTS ix_touchpoints_tenant ON t_touchpoints (tenant_id);

ALTER TABLE t_touchpoints ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS touchpoints_tenant_rw ON t_touchpoints;
CREATE POLICY touchpoints_tenant_rw ON t_touchpoints
  USING (tenant_id = (current_setting('request.jwt.claims', true)::jsonb->>'tenant_id')::uuid)
  WITH CHECK (tenant_id = (current_setting('request.jwt.claims', true)::jsonb->>'tenant_id')::uuid);

CREATE OR REPLACE FUNCTION public.fn_touchpoint_entitled(p_tenant_id UUID, p_type TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE v_is_admin BOOLEAN; v_extra JSONB;
BEGIN
  SELECT is_admin INTO v_is_admin FROM t_tenants WHERE id = p_tenant_id;
  IF v_is_admin IS TRUE THEN RETURN TRUE; END IF;   -- platform sells to everyone
  SELECT addons_extra INTO v_extra FROM t_tenant_context
  WHERE product_code = 'contractnest' AND tenant_id = p_tenant_id;
  RETURN COALESCE((v_extra->('addon_extend_' || p_type))::BOOLEAN, FALSE);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_touchpoint(
  p_tenant_id UUID, p_template_id UUID, p_type TEXT, p_user_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tpl RECORD;
  v_row t_touchpoints;
  v_key TEXT;
BEGIN
  IF p_type NOT IN ('website','whatsapp','email') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unknown touchpoint type', 'error_code', 'VALIDATION_ERROR');
  END IF;

  IF NOT fn_touchpoint_entitled(p_tenant_id, p_type) THEN
    RETURN jsonb_build_object('success', false,
      'error', 'This touchpoint is not enabled on your account',
      'error_code', 'TOUCHPOINT_NOT_ENTITLED');
  END IF;

  SELECT * INTO v_tpl FROM t_cat_templates
  WHERE id = p_template_id AND tenant_id = p_tenant_id
    AND is_active = TRUE AND is_latest = TRUE
    AND settings->>'lifecycle' = 'signed_off';
  IF v_tpl.id IS NULL THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Template not found or not published (sign it off first)',
      'error_code', 'TEMPLATE_NOT_PUBLISHABLE');
  END IF;

  SELECT * INTO v_row FROM t_touchpoints
  WHERE tenant_id = p_tenant_id AND template_id = p_template_id AND touchpoint_type = p_type;

  IF v_row.id IS NOT NULL THEN
    UPDATE t_touchpoints SET is_active = TRUE, updated_at = now()
    WHERE id = v_row.id RETURNING * INTO v_row;
  ELSE
    -- built-ins only: pgcrypto's gen_random_bytes is not enabled here
    v_key := 'sf-' || md5(gen_random_uuid()::text || gen_random_uuid()::text || clock_timestamp()::text);
    INSERT INTO t_touchpoints (tenant_id, template_id, touchpoint_type, storefront_key, created_by)
    VALUES (p_tenant_id, p_template_id, p_type, v_key, p_user_id)
    RETURNING * INTO v_row;
  END IF;

  RETURN jsonb_build_object('success', true,
    'touchpoint', jsonb_build_object(
      'id', v_row.id, 'template_id', v_row.template_id,
      'touchpoint_type', v_row.touchpoint_type,
      'storefront_key', v_row.storefront_key,
      'is_active', v_row.is_active,
      'views_count', v_row.views_count, 'purchases_count', v_row.purchases_count));
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_touchpoint_active(
  p_tenant_id UUID, p_touchpoint_id UUID, p_active BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
DECLARE v_row t_touchpoints;
BEGIN
  UPDATE t_touchpoints SET is_active = p_active, updated_at = now()
  WHERE id = p_touchpoint_id AND tenant_id = p_tenant_id
  RETURNING * INTO v_row;
  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Touchpoint not found', 'error_code', 'NOT_FOUND');
  END IF;
  RETURN jsonb_build_object('success', true, 'id', v_row.id, 'is_active', v_row.is_active);
END;
$function$;

CREATE OR REPLACE FUNCTION public.list_touchpoints(p_tenant_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $function$
BEGIN
  RETURN jsonb_build_object('success', true, 'touchpoints', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', tp.id, 'template_id', tp.template_id,
      'template_name', COALESCE(t.display_name, t.name),
      'touchpoint_type', tp.touchpoint_type,
      'storefront_key', tp.storefront_key,
      'is_active', tp.is_active,
      'views_count', tp.views_count, 'purchases_count', tp.purchases_count,
      'created_at', tp.created_at) ORDER BY tp.created_at DESC)
    FROM t_touchpoints tp JOIN t_cat_templates t ON t.id = tp.template_id
    WHERE tp.tenant_id = p_tenant_id), '[]'::JSONB));
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_storefront(p_key TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tp  RECORD;
  v_tpl RECORD;
  v_seller_name TEXT;
BEGIN
  SELECT * INTO v_tp FROM t_touchpoints WHERE storefront_key = p_key AND is_active = TRUE;
  IF v_tp.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'NOT_FOUND');
  END IF;

  IF NOT fn_touchpoint_entitled(v_tp.tenant_id, v_tp.touchpoint_type) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'NOT_ENTITLED');
  END IF;

  SELECT * INTO v_tpl FROM t_cat_templates
  WHERE id = v_tp.template_id AND is_active = TRUE AND settings->>'lifecycle' = 'signed_off';
  IF v_tpl.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'TEMPLATE_GONE');
  END IF;

  SELECT COALESCE(tp.business_name, tn.name) INTO v_seller_name
  FROM t_tenants tn LEFT JOIN t_tenant_profiles tp ON tp.tenant_id = tn.id
  WHERE tn.id = v_tp.tenant_id
  LIMIT 1;

  UPDATE t_touchpoints SET views_count = views_count + 1 WHERE id = v_tp.id;

  -- display-safe subset ONLY: no config, no wizard_state, no internal ids
  RETURN jsonb_build_object(
    'success', true,
    'storefront', jsonb_build_object(
      'seller_name', v_seller_name,
      'touchpoint_type', v_tp.touchpoint_type,
      'template', jsonb_build_object(
        'name', COALESCE(v_tpl.display_name, v_tpl.name),
        'description', v_tpl.description,
        'currency', COALESCE(v_tpl.currency, 'INR'),
        'price', COALESCE(v_tpl.total, 0),
        'term', jsonb_build_object(
          'value', v_tpl.settings->'defaults'->'duration_value',
          'unit',  v_tpl.settings->'defaults'->>'duration_unit'),
        'lines', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'name', b->'config_overrides'->>'name',
            'quantity', COALESCE((b->'config_overrides'->>'quantity')::INT, 1),
            'unit_price', COALESCE((b->'config_overrides'->>'unit_price')::NUMERIC, 0),
            'total_price', COALESCE((b->'config_overrides'->>'total_price')::NUMERIC, 0),
            'billing_cycle', b->'config_overrides'->>'billing_cycle',
            'category', b->'config_overrides'->>'category_id')
            ORDER BY COALESCE((b->>'order')::INT, 0))
          FROM jsonb_array_elements(v_tpl.blocks) b
          WHERE COALESCE(b->'config_overrides'->>'category_id','') NOT IN ('metering')
        ), '[]'::JSONB))));
END;
$function$;

CREATE OR REPLACE FUNCTION public.purchase_from_storefront(p_key TEXT, p_buyer JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tp      RECORD;
  v_tpl     RECORD;
  v_name    TEXT; v_company TEXT; v_email TEXT; v_phone TEXT;
  v_contact UUID;
  v_seq     JSONB;
  v_blocks  JSONB := '[]'::JSONB;
  v_block   JSONB;
  v_payload JSONB;
  v_result  JSONB;
  v_contract UUID;
  v_status  JSONB;
  v_cnak    TEXT; v_secret TEXT;
BEGIN
  SELECT * INTO v_tp FROM t_touchpoints WHERE storefront_key = p_key AND is_active = TRUE;
  IF v_tp.id IS NULL OR NOT fn_touchpoint_entitled(v_tp.tenant_id, v_tp.touchpoint_type) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'NOT_FOUND');
  END IF;

  SELECT * INTO v_tpl FROM t_cat_templates
  WHERE id = v_tp.template_id AND is_active = TRUE AND settings->>'lifecycle' = 'signed_off';
  IF v_tpl.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'TEMPLATE_GONE');
  END IF;

  v_name    := NULLIF(btrim(p_buyer->>'name'), '');
  v_company := NULLIF(btrim(p_buyer->>'company'), '');
  v_email   := NULLIF(lower(btrim(p_buyer->>'email')), '');
  v_phone   := NULLIF(regexp_replace(COALESCE(p_buyer->>'phone',''), '[^0-9+]', '', 'g'), '');

  IF v_name IS NULL OR (v_email IS NULL AND v_phone IS NULL) THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Name and an email or phone number are required',
      'error_code', 'VALIDATION_ERROR');
  END IF;

  -- t_contacts has no email/mobile columns — channels live in
  -- t_contact_channels (channel_type 'email' | 'mobile')
  SELECT c.id INTO v_contact
  FROM t_contacts c
  JOIN t_contact_channels ch ON ch.contact_id = c.id
  WHERE c.tenant_id = v_tp.tenant_id AND c.is_live = TRUE
    AND ((v_email IS NOT NULL AND ch.channel_type = 'email' AND lower(ch.value) = v_email)
      OR (v_phone IS NOT NULL AND ch.channel_type = 'mobile'
          AND regexp_replace(ch.value, '[^0-9+]', '', 'g') = v_phone))
  LIMIT 1;

  IF v_contact IS NULL THEN
    v_seq := get_next_formatted_sequence('CONTACT', v_tp.tenant_id, TRUE);
    IF v_company IS NOT NULL THEN
      INSERT INTO t_contacts (tenant_id, is_live, type, name, company_name, contact_number,
                              classifications, status, is_active, is_seed, source)
      VALUES (v_tp.tenant_id, TRUE, 'corporate', NULL, v_company, v_seq->>'formatted',
              '["client"]'::JSONB, 'active', TRUE, FALSE, 'storefront')
      RETURNING id INTO v_contact;
    ELSE
      INSERT INTO t_contacts (tenant_id, is_live, type, name, company_name, contact_number,
                              classifications, status, is_active, is_seed, source)
      VALUES (v_tp.tenant_id, TRUE, 'individual', v_name, NULL, v_seq->>'formatted',
              '["client"]'::JSONB, 'active', TRUE, FALSE, 'storefront')
      RETURNING id INTO v_contact;
    END IF;

    IF v_email IS NOT NULL THEN
      INSERT INTO t_contact_channels (contact_id, channel_type, value, is_primary)
      VALUES (v_contact, 'email', v_email, TRUE);
    END IF;
    IF v_phone IS NOT NULL THEN
      INSERT INTO t_contact_channels (contact_id, channel_type, value, is_primary)
      VALUES (v_contact, 'mobile', v_phone, v_email IS NULL);
    END IF;
  END IF;

  FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_tpl.blocks, '[]'::JSONB))
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
                            'currency', COALESCE(v_tpl.currency, 'INR'),
                            'notes',    'Storefront: ' || COALESCE(v_tpl.display_name, v_tpl.name))
    ));
  END LOOP;

  v_payload := jsonb_build_object(
    'tenant_id',         v_tp.tenant_id,
    'is_live',           TRUE,
    'record_type',       'contract',
    'contract_type',     'client',
    'name',              COALESCE(v_tpl.display_name, v_tpl.name),
    'buyer_id',          v_contact,
    'buyer_name',        v_name,
    'buyer_email',       v_email,
    'buyer_company',     v_company,
    'currency',          COALESCE(v_tpl.currency, 'INR'),
    'duration_value',    COALESCE((v_tpl.settings->'defaults'->>'duration_value')::INT, 1),
    'duration_unit',     COALESCE(v_tpl.settings->'defaults'->>'duration_unit', 'months'),
    'start_date',        now(),
    'acceptance_method', 'manual',
    'nomenclature_id',   v_tpl.settings->'defaults'->>'nomenclature_id',
    'billing_cycle_type',COALESCE(v_tpl.settings->'defaults'->>'billing_cycle_type', 'unified'),
    'grand_total',       COALESCE(v_tpl.total, 0),
    'total_value',       COALESCE(v_tpl.total, 0),
    'tax_total',         0,
    'discount_total',    0,
    'blocks',            v_blocks,
    'performed_by_type', 'user',
    'metadata',          jsonb_build_object(
                            'source',          'storefront_purchase',
                            'storefront_key',  p_key,
                            'touchpoint_type', v_tp.touchpoint_type,
                            'template_id',     v_tpl.id)
  );

  v_result := create_contract_transaction(v_payload, NULL);
  IF NOT COALESCE((v_result->>'success')::BOOLEAN, FALSE) THEN
    RETURN jsonb_build_object('success', false,
      'error', COALESCE(v_result->>'error', 'Could not create the order'),
      'error_code', 'CONTRACT_CREATE_FAILED', 'detail', v_result);
  END IF;
  v_contract := (v_result->'data'->>'id')::UUID;

  -- pending_acceptance mints the CNAK + secret — the buyer finishes in the
  -- existing public review/accept/pay flow
  v_status := update_contract_status(v_contract, v_tp.tenant_id, 'pending_acceptance',
                                     NULL, v_name, 'system',
                                     'Storefront purchase via ' || v_tp.touchpoint_type);
  IF NOT COALESCE((v_status->>'success')::BOOLEAN, FALSE) THEN
    RETURN jsonb_build_object('success', false,
      'error', COALESCE(v_status->>'error', 'Could not prepare the order for review'),
      'error_code', 'STATUS_TRANSITION_FAILED', 'detail', v_status);
  END IF;

  SELECT global_access_id INTO v_cnak FROM t_contracts WHERE id = v_contract;
  SELECT secret_code INTO v_secret FROM t_contract_access
  WHERE contract_id = v_contract ORDER BY created_at DESC LIMIT 1;

  UPDATE t_touchpoints SET purchases_count = purchases_count + 1 WHERE id = v_tp.id;

  RETURN jsonb_build_object(
    'success', true,
    'contract_number', v_result->'data'->>'contract_number',
    'cnak', v_cnak,
    'secret', v_secret,
    'review_path', CASE WHEN v_cnak IS NOT NULL AND v_secret IS NOT NULL
                        THEN '/contracts/review?cnak=' || v_cnak || '&secret=' || v_secret
                        ELSE NULL END);
END;
$function$;
