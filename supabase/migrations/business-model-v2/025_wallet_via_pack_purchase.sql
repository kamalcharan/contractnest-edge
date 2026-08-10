-- ============================================================================
-- Business Model V4 — wallet top-up rides the existing pack-purchase rail
--
-- Retires the bespoke topup_wallet() RPC from 024_wallet_mode.sql. Owner
-- correction: a wallet top-up does not need its own RPC, its own API route,
-- or its own UI — it needs a template. Phase D already built the entire
-- "buy something from the platform" pipe (purchase_topup_template, its
-- payment trigger, the /packs and /packs/purchase edge handlers, the
-- Credit packs section on the Plans page). Reusing it end to end.
--
-- What changes: purchase_topup_template and fn_apply_topup_grants each learn
-- ONE more shape — a template tagged category='wallet_topup' has no
-- metering block at all; its own PRICE is what gets credited to the wallet,
-- on payment, in paise. Every other code path (the contact, the contract,
-- the invoice, the idempotency guard, the payment trigger) is untouched and
-- shared with ordinary credit packs.
--
-- What does NOT change: trg_fn_wallet_charge / trg_wallet_charge (the hard-
-- block ₹200/₹400 charge on contract/RFQ creation, from 024) — that part
-- has nothing to do with how the wallet got funded.
-- ============================================================================


-- ── 1. retire the bespoke RPC + its payment trigger ────────────────────────
DROP TRIGGER IF EXISTS trg_wallet_topup_on_payment ON public.t_invoices;
DROP FUNCTION IF EXISTS public.trg_fn_wallet_topup_on_payment();
DROP FUNCTION IF EXISTS public.fn_apply_wallet_topup(UUID);
DROP FUNCTION IF EXISTS public.topup_wallet(UUID, BIGINT, UUID);


-- ── 2. purchase_topup_template: recognize category='wallet_topup' ─────────
-- Everything is identical to the 023 version except the block-scan/
-- validation block, marked below.
CREATE OR REPLACE FUNCTION public.purchase_topup_template(
    p_template_id UUID, p_buyer_tenant_id UUID, p_user_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
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
    v_wallet_paise BIGINT := NULL;
    v_events      JSONB := '[]'::JSONB;
    v_payload     JSONB;
    v_result      JSONB;
    v_contract_id UUID;
    v_dur_value   INTEGER;
    v_dur_unit    TEXT;
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

    -- ── CHANGED: what makes a template a PACK ──────────────────────────
    -- A credit pack grants notification credits once (a one_time metering
    -- block). A wallet top-up has NO metering block at all — its own price
    -- IS the amount credited, in paise. Both are still "buy this from the
    -- platform"; only what happens on payment differs (see
    -- fn_apply_topup_grants below).
    IF v_template.category = 'wallet_topup' THEN
        v_wallet_paise := ROUND(COALESCE(v_template.total, 0) * 100)::BIGINT;
    ELSE
        FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_template.blocks, '[]'::JSONB))
        LOOP
            v_meter := v_block->'config_overrides'->'config'->'metering';
            CONTINUE WHEN v_meter IS NULL;
            IF v_meter->>'mode' = 'one_time' AND v_meter->'grants' IS NOT NULL THEN
                v_grants := v_grants || v_meter->'grants';
            END IF;
        END LOOP;
    END IF;

    IF v_grants = '{}'::JSONB AND (v_wallet_paise IS NULL OR v_wallet_paise <= 0) THEN
        RETURN jsonb_build_object('success', false,
            'error', 'This template grants nothing once and tops up no wallet - it is a plan, not a credit pack',
            'error_code', 'NOT_A_TOPUP_PACK');
    END IF;
    -- ── END CHANGED ─────────────────────────────────────────────────────

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
        -- CHANGED: wallet_topup_paise added alongside topup_grants. A given
        -- pack produces one or the other, never both, but both keys always
        -- exist on the payload so fn_apply_topup_grants never has to guess.
        'metadata',          jsonb_build_object(
                                'source',            'topup_purchase',
                                'pack_template_id',  v_template.id,
                                'buyer_tenant_id',   p_buyer_tenant_id,
                                'topup_grants',      v_grants,
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

    -- A free pack (₹0) has nothing to collect, so apply immediately. A
    -- wallet top-up is never ₹0 in practice (author sets a real price), so
    -- this branch stays credit-pack-only in effect but the check itself is
    -- unchanged and correct either way.
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
        'wallet_paise',    v_wallet_paise,
        'credits_pending', COALESCE(v_template.total, 0) > 0
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ── 3. fn_apply_topup_grants: also apply a wallet credit ───────────────────
-- Same idempotency guard covers both concerns (one EXISTS check on
-- reference_type='topup_contract' + reference_id, at the top, before either
-- branch runs) — a contract is either a credit pack or a wallet top-up,
-- never both, but the guard doesn't need to know which.
CREATE OR REPLACE FUNCTION public.fn_apply_topup_grants(p_contract_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_c           RECORD;
    v_buyer       UUID;
    v_grants      JSONB;
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

    -- ── NEW: wallet top-up branch ──────────────────────────────────────
    -- Ensures a context row exists (a first-time wallet buyer may have
    -- never touched a plan, so may have no row at all — same ON CONFLICT
    -- DO NOTHING pattern subscribe_tenant_to_plan uses), then funds the
    -- wallet and switches the tenant into per_contract billing. Money and
    -- mode land together, on payment — unlike the retired topup_wallet(),
    -- which switched mode immediately on purchase. This is more correct:
    -- a tenant should not appear to be in per_contract mode with zero
    -- entitlement before they have actually paid for it.
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
    -- ── END NEW ──────────────────────────────────────────────────────

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


-- ── 4. get_tenant_context / trg_fn_plan_contract_lapsed: simplify back ────
-- 024_wallet_mode.sql added a 'wallet_topup' source value to both
-- exclusion lists, for the now-retired topup_wallet(). Every wallet top-up
-- now goes through purchase_topup_template, which has only ever used
-- metadata.source = 'topup_purchase' — the same value credit packs use.
-- Reverted back to the single value both checks had before 024, since
-- 'wallet_topup' can no longer occur anywhere.
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
          AND COALESCE(c.metadata->>'source', '') <> 'topup_purchase'
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

        'wallet', jsonb_build_object(
            'balance_paise', COALESCE(v_context.wallet_balance_paise, 0),
            'balance_rupees', ROUND(COALESCE(v_context.wallet_balance_paise, 0) / 100.0, 2)
        ),

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
            'over_limit', v_context.flag_over_limit
        ),

        'retrieved_at', NOW()
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_fn_plan_contract_lapsed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_platform_id UUID;
    v_subscriber  UUID;
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NULL;
    END IF;

    IF NEW.status NOT IN ('expired', 'cancelled', 'terminated') THEN
        RETURN NULL;
    END IF;

    IF COALESCE(NEW.metadata->>'source', '') = 'topup_purchase' THEN
        RETURN NULL;
    END IF;

    SELECT id INTO v_platform_id FROM t_tenants WHERE is_admin = TRUE LIMIT 1;

    IF v_platform_id IS NULL OR NEW.tenant_id <> v_platform_id THEN
        RETURN NULL;
    END IF;

    SELECT ct.source_tenant_id INTO v_subscriber
    FROM t_contacts ct WHERE ct.id = NEW.buyer_id;

    IF v_subscriber IS NULL THEN
        RETURN NULL;
    END IF;

    UPDATE t_tenant_context
    SET limit_contracts = 0,
        limit_rfqs      = 0,
        updated_at      = NOW()
    WHERE tenant_id = v_subscriber
      AND product_code = 'contractnest';

    RETURN NULL;

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'plan lapse handling failed for contract %: %', NEW.id, SQLERRM;
    RETURN NULL;
END;
$function$;
