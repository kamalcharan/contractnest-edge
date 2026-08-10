-- ============================================================================
-- Business Model V4 — Per-contract mode (Mode A / wallet billing)
--
-- ₹200 per contract, ₹400 per RFQ, deducted from a pre-funded wallet balance
-- (t_tenant_context.wallet_balance_paise) at the MOMENT of creation, hard
-- block on insufficient balance. 15 WhatsApp + 15 Email credits granted per
-- creation, via the metering machinery that already exists — nothing new
-- there, only credit_grant_rates needs to be set when a tenant enters this
-- mode.
--
-- billing_mode value is 'per_contract' — matches chk_tenant_context_billing_mode
-- (ARRAY['freemium','poc','per_contract','plan','exempt']). Internal naming
-- (wallet_balance_paise, topup_wallet, trg_fn_wallet_charge, credit_type=
-- 'wallet' in the journal) stays "wallet" throughout — that is the plain-
-- English name for what this is — only the actual billing_mode COLUMN VALUE
-- has to be the constraint's spelling.
--
-- Deliberately NOT built here: the 1-year FIFO top-up-lot expiry described
-- in BUSINESS_MODEL_V3_SPEC.md §5.1. That section calls it "the largest
-- single piece of work the commercial model implies" — a proper lots ledger,
-- oldest-first consumption, per-lot expiry job. Owner decision 2026-08-09:
-- ship without expiry first, same posture notification credits already have
-- (D2 — nothing expires). wallet_balance_paise is a single running balance;
-- top-ups only add to it, nothing ever removes value except spend.
-- ============================================================================


-- ── 1. get_tenant_context: exclude wallet top-ups from plan resolution ─────
-- Same collision Phase D solved for credit packs: a wallet top-up is a
-- contract raised by the platform tenant FOR a subscriber, structurally
-- identical to a plan subscription. Without this exclusion, topping up would
-- make the tenant's OWN top-up contract display as "their plan."
-- Also surfaces the wallet balance itself, which get_tenant_context never
-- returned before this — nothing read wallet_balance_paise anywhere.
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
          AND COALESCE(c.metadata->>'source', '') NOT IN ('topup_purchase', 'wallet_topup')
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


-- ── 2. trg_fn_plan_contract_lapsed: exclude wallet top-ups ─────────────────
-- A wallet top-up eventually reaching a terminal contract status must never
-- zero limit_contracts/limit_rfqs, which for a per_contract tenant are NULL
-- (uncapped by count; the wallet balance is what caps them) and must stay
-- that way.
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

    IF COALESCE(NEW.metadata->>'source', '') IN ('topup_purchase', 'wallet_topup') THEN
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


-- ── 3. top up the wallet ────────────────────────────────────────────────
-- Unlike a plan or a credit pack, a wallet top-up has no catalog price — the
-- tenant names an amount, floored at the spec's ₹1,000 minimum. It still
-- raises a real contract (so GST/invoicing works the same as everything
-- else), but the price block is built here rather than read off a template,
-- because there is no template: the amount is chosen at call time.
--
-- Entering per_contract mode (billing_mode, uncapped count limits, the
-- 15/15 per-creation grant rate) is set HERE, immediately — same precedent
-- as subscribe_tenant_to_plan, which activates entitlements on subscribe,
-- not on payment. Only the MONEY (wallet_balance_paise) waits for payment,
-- via fn_apply_wallet_topup below — same "credits land on payment" rule
-- Phase D established for packs.
CREATE OR REPLACE FUNCTION public.topup_wallet(
    p_buyer_tenant_id UUID, p_amount_paise BIGINT, p_user_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_platform_id UUID;
    v_buyer       RECORD;
    v_contact_id  UUID;
    v_seq         JSONB;
    v_amount_rs   NUMERIC;
    v_payload     JSONB;
    v_result      JSONB;
    v_contract_id UUID;
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
            'error', 'The platform tenant cannot top up its own wallet',
            'error_code', 'SELF_PURCHASE');
    END IF;

    -- Spec minimum: ₹1,000 = 100000 paise.
    IF p_amount_paise IS NULL OR p_amount_paise < 100000 THEN
        RETURN jsonb_build_object('success', false,
            'error', 'Minimum top-up is ₹1,000', 'error_code', 'BELOW_MINIMUM');
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
            'wallet_topup', p_buyer_tenant_id, p_user_id
        )
        RETURNING id INTO v_contact_id;
    END IF;

    v_amount_rs := ROUND(p_amount_paise / 100.0, 2);

    v_payload := jsonb_build_object(
        'tenant_id',         v_platform_id,
        'is_live',           TRUE,
        'record_type',       'contract',
        'contract_type',     'client',
        'name',              'Wallet Top-up',
        'buyer_id',          v_contact_id,
        'buyer_company',     v_buyer.name,
        'currency',          'INR',
        'duration_value',    1,
        'duration_unit',     'months',
        'start_date',        now(),
        'acceptance_method', 'auto',
        'billing_cycle_type','unified',
        'grand_total',       v_amount_rs,
        'total_value',       v_amount_rs,
        'tax_total',         0,
        'discount_total',    0,
        'blocks',            jsonb_build_array(jsonb_build_object(
            'position',        0,
            'source_type',     'catalog',
            'source_block_id', '77d1ddea-f6ed-4da3-a8ce-506485228f82',
            'block_name',      'Wallet Top-up',
            'category_id',     'service',
            'category_name',   'Service',
            'unit_price',      v_amount_rs,
            'quantity',        1,
            'billing_cycle',   'prepaid',
            'total_price',     v_amount_rs,
            'custom_fields',   jsonb_build_object(
                                  'config',   jsonb_build_object('billingOnly', true),
                                  'currency', 'INR',
                                  'notes',    'Wallet top-up'
                               )
        )),
        'computed_events',   jsonb_build_array(jsonb_build_object(
            'id', 'billing-1',
            'event_type', 'billing',
            'category_id', '',
            'block_name', 'Wallet Top-up',
            'scheduled_date', now(),
            'amount', v_amount_rs,
            'status', 'pending'
        )),
        'created_by',        p_user_id,
        'performed_by_type', 'user',
        'metadata',          jsonb_build_object(
                                'source',            'wallet_topup',
                                'buyer_tenant_id',   p_buyer_tenant_id,
                                'topup_amount_paise', p_amount_paise
                             )
    );

    v_result := create_contract_transaction(v_payload, NULL);

    IF NOT COALESCE((v_result->>'success')::BOOLEAN, FALSE) THEN
        RETURN jsonb_build_object('success', false,
            'error', COALESCE(v_result->>'error', 'Contract creation failed'),
            'error_code', 'CONTRACT_CREATE_FAILED', 'detail', v_result);
    END IF;

    v_contract_id := (v_result->'data'->>'id')::UUID;

    -- Mode switch happens now, not on payment. First top-up ever for this
    -- tenant sets it up; a later top-up from an already-per_contract tenant
    -- is a no-op on these fields (re-set to the same values).
    INSERT INTO t_tenant_context (product_code, tenant_id, billing_mode)
    VALUES ('contractnest', p_buyer_tenant_id, 'per_contract')
    ON CONFLICT (product_code, tenant_id) DO NOTHING;

    UPDATE t_tenant_context
    SET billing_mode      = 'per_contract',
        -- NULL, not 0 — a per_contract tenant is uncapped by COUNT. The
        -- wallet balance is the only cap, enforced by trg_fn_wallet_charge.
        limit_contracts   = NULL,
        limit_rfqs        = NULL,
        credit_grant_rates = jsonb_build_object('whatsapp', 15, 'email', 15),
        flag_can_access   = TRUE,
        updated_at        = now()
    WHERE product_code = 'contractnest'
      AND tenant_id = p_buyer_tenant_id;

    RETURN jsonb_build_object(
        'success', true,
        'contract_id',     v_contract_id,
        'contract_number', v_result->'data'->>'contract_number',
        'contact_id',      v_contact_id,
        'amount_paise',    p_amount_paise,
        'amount_rupees',   v_amount_rs,
        'currency',        'INR',
        'balance_pending', TRUE
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ── 4. money in, wallet balance up ──────────────────────────────────────
-- Idempotent the same way fn_apply_topup_grants is: look for the journal
-- row a previous application of this same contract would have written.
CREATE OR REPLACE FUNCTION public.fn_apply_wallet_topup(p_contract_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_c       RECORD;
    v_buyer   UUID;
    v_amount  BIGINT;
    v_before  BIGINT;
    v_after   BIGINT;
BEGIN
    SELECT id, name, contract_number, metadata INTO v_c
    FROM t_contracts WHERE id = p_contract_id;

    IF NOT FOUND OR COALESCE(v_c.metadata->>'source', '') <> 'wallet_topup' THEN
        RETURN jsonb_build_object('success', true, 'applied', false, 'reason', 'not_a_wallet_topup');
    END IF;

    IF EXISTS (SELECT 1 FROM t_credit_journal
               WHERE reference_type = 'wallet_topup_contract' AND reference_id = p_contract_id) THEN
        RETURN jsonb_build_object('success', true, 'applied', false, 'reason', 'already_applied');
    END IF;

    v_buyer  := (v_c.metadata->>'buyer_tenant_id')::UUID;
    v_amount := (v_c.metadata->>'topup_amount_paise')::BIGINT;

    IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object('success', true, 'applied', false, 'reason', 'nothing_to_apply');
    END IF;

    SELECT wallet_balance_paise INTO v_before
    FROM t_tenant_context
    WHERE product_code = 'contractnest' AND tenant_id = v_buyer
    FOR UPDATE;

    v_before := COALESCE(v_before, 0);
    v_after  := v_before + v_amount;

    UPDATE t_tenant_context
    SET wallet_balance_paise = v_after, updated_at = now()
    WHERE product_code = 'contractnest' AND tenant_id = v_buyer;

    INSERT INTO t_credit_journal (
        tenant_id, credit_type, channel, transaction_type, quantity,
        balance_before, balance_after, reference_type, reference_id, description
    ) VALUES (
        v_buyer, 'wallet', NULL, 'topup', v_amount,
        v_before, v_after, 'wallet_topup_contract', p_contract_id,
        'Wallet top-up ' || COALESCE(v_c.contract_number, '')
    );

    RETURN jsonb_build_object('success', true, 'applied', true,
        'contract_id', p_contract_id, 'amount_paise', v_amount, 'balance_after', v_after);

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'wallet topup apply failed for contract %: %', p_contract_id, SQLERRM;
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;


CREATE OR REPLACE FUNCTION public.trg_fn_wallet_topup_on_payment()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$function$
BEGIN
    IF NEW.status <> 'paid' OR COALESCE(OLD.status, '') = 'paid' THEN
        RETURN NULL;
    END IF;

    IF NEW.contract_id IS NULL THEN
        RETURN NULL;
    END IF;

    PERFORM fn_apply_wallet_topup(NEW.contract_id);
    RETURN NULL;

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'wallet topup on payment failed for invoice %: %', NEW.id, SQLERRM;
    RETURN NULL;
END;
$function$;

-- Coexists with trg_topup_credits_on_payment (Phase D) on the same table and
-- event — each checks its own metadata.source and no-ops otherwise, so a
-- pack payment and a wallet payment never cross-fire the wrong handler.
DROP TRIGGER IF EXISTS trg_wallet_topup_on_payment ON public.t_invoices;
CREATE TRIGGER trg_wallet_topup_on_payment
    AFTER UPDATE OF status ON public.t_invoices
    FOR EACH ROW EXECUTE FUNCTION public.trg_fn_wallet_topup_on_payment();


-- ── 5. the charge itself — hard block, BEFORE the contract exists ─────────
-- BEFORE INSERT, not AFTER: a hard block must stop the row from ever being
-- created, and only a BEFORE trigger raising an exception can do that. This
-- is why it is a SEPARATE trigger from trg_fn_contract_consumption (which
-- stays AFTER INSERT and untouched) rather than folded into it.
--
-- Scoped to billing_mode = 'per_contract' only — plan-mode and exempt
-- tenants are untouched, and a plan-subscription or pack-purchase contract
-- (raised under the PLATFORM tenant, whose billing_mode is 'exempt') never
-- reaches the charge branch at all.
--
-- Known gap, explicitly not solved here: a contract DERIVED from an already-
-- paid-for RFQ should be free (its ₹400 already covered it, per spec §7),
-- but t_contracts has no column linking a derived contract back to its
-- originating RFQ today — confirmed by inspection, no rfq_id/source_rfq_id
-- exists. Until that linkage exists, an RFQ-derived contract under a
-- per_contract tenant WILL be charged ₹200 again. Flagging, not silently
-- fixing — the linkage is Sprint 3 / RFQ-handover scope, not this
-- migration's.
CREATE OR REPLACE FUNCTION public.trg_fn_wallet_charge()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$function$
DECLARE
    v_ctx    RECORD;
    v_amount BIGINT;
BEGIN
    -- Test environment is never charged real money — same posture Phase B
    -- gave notification credits.
    IF NEW.is_live IS DISTINCT FROM TRUE THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_ctx
    FROM t_tenant_context
    WHERE product_code = 'contractnest' AND tenant_id = NEW.tenant_id
    FOR UPDATE;

    IF v_ctx IS NULL OR v_ctx.billing_mode <> 'per_contract' THEN
        RETURN NEW;
    END IF;

    v_amount := CASE WHEN NEW.record_type = 'rfq' THEN 40000 ELSE 20000 END;

    IF COALESCE(v_ctx.wallet_balance_paise, 0) < v_amount THEN
        RAISE EXCEPTION 'Insufficient wallet balance: have % paise, need % paise. Top up to continue.',
            COALESCE(v_ctx.wallet_balance_paise, 0), v_amount
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE t_tenant_context
    SET wallet_balance_paise = wallet_balance_paise - v_amount, updated_at = now()
    WHERE product_code = 'contractnest' AND tenant_id = NEW.tenant_id;

    -- NEW.id already exists here — BEFORE INSERT still assigns defaults
    -- (gen_random_uuid()) before the trigger body runs.
    INSERT INTO t_credit_journal (
        tenant_id, credit_type, channel, transaction_type, quantity,
        balance_before, balance_after, reference_type, reference_id, description
    ) VALUES (
        NEW.tenant_id, 'wallet', NULL, 'deduction', v_amount,
        v_ctx.wallet_balance_paise, v_ctx.wallet_balance_paise - v_amount,
        'contract',
        NEW.id,
        CASE WHEN NEW.record_type = 'rfq' THEN 'RFQ creation charge' ELSE 'Contract creation charge' END
    );

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_wallet_charge ON public.t_contracts;
CREATE TRIGGER trg_wallet_charge
    BEFORE INSERT ON public.t_contracts
    FOR EACH ROW EXECUTE FUNCTION public.trg_fn_wallet_charge();


-- ── 6. pre-existing bug fix, uncovered by testing this migration ──────────
-- trg_fn_context_credit_flags (Phase A) computed "is this tenant active
-- enough to send" from a hardcoded list of billing_mode values that included
-- 'wallet' — a value that has NEVER been valid; the real CHECK constraint
-- (chk_tenant_context_billing_mode) has always said 'per_contract'. Because
-- this billing_mode had never been exercised by any real tenant before this
-- migration, the mismatch was silent: v_status fell through to NULL,
-- fn_recalc_credit_flags returned NULL flags, and the UPDATE that grants
-- credits (add_credits -> fn_credit_apply) failed a NOT NULL constraint on
-- flag_can_send_whatsapp — silently, because the caller
-- (trg_fn_contract_consumption) catches all exceptions and only RAISE
-- WARNINGs. Caught live: usage_contracts and credit grants were both zero
-- after a real per_contract contract creation, traced to this one line.
CREATE OR REPLACE FUNCTION public.trg_fn_context_credit_flags()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
    v_status TEXT;
    v_flags  RECORD;
    v_w INTEGER; v_s INTEGER; v_e INTEGER; v_i INTEGER; v_p INTEGER;
BEGIN
    v_status := COALESCE(
        NEW.subscription_status,
        CASE WHEN NEW.billing_mode IN ('plan', 'per_contract', 'freemium', 'exempt')
             THEN 'active' END);

    v_w := GREATEST(0, COALESCE(NEW.credits_whatsapp,0)
             - COALESCE((NEW.credits_reserved->>'notification:whatsapp')::INT, 0));
    v_s := GREATEST(0, COALESCE(NEW.credits_sms,0)
             - COALESCE((NEW.credits_reserved->>'notification:sms')::INT, 0));
    v_e := GREATEST(0, COALESCE(NEW.credits_email,0)
             - COALESCE((NEW.credits_reserved->>'notification:email')::INT, 0));
    v_i := GREATEST(0, COALESCE(NEW.credits_inapp,0)
             - COALESCE((NEW.credits_reserved->>'notification:inapp')::INT, 0));
    v_p := GREATEST(0, COALESCE(NEW.credits_pooled,0)
             - COALESCE((NEW.credits_reserved->>'notification:_')::INT, 0));

    SELECT * INTO v_flags
    FROM fn_recalc_credit_flags(v_w, v_s, v_e, v_p, v_status, v_i);

    NEW.flag_can_send_whatsapp := v_flags.can_send_whatsapp;
    NEW.flag_can_send_sms      := v_flags.can_send_sms;
    NEW.flag_can_send_email    := v_flags.can_send_email;
    NEW.flag_can_send_inapp    := v_flags.can_send_inapp;
    NEW.flag_credits_low       := v_flags.credits_low;

    RETURN NEW;
END;
$function$;
