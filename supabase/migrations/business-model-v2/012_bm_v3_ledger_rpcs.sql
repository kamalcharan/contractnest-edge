-- ============================================================
-- BUSINESS MODEL V3 — 012 : Ledger RPC rework (Sprint 1, Step 3)
-- ============================================================
-- Spec     : BUSINESS_MODEL_V3_SPEC.md §5.2, §5.2b
-- Baseline : SPRINT1_STEP1_BASELINE.md §4, §5   (original definitions, for rollback)
--
-- Fixes four defects:
--   D1  add_credits / deduct_credits write NO t_bm_credit_transaction row;
--       p_reference_id is accepted and discarded. No audit trail exists and
--       per-contract attribution of granted credits is impossible.
--   D3  trg_fn_update_context_on_credit_change aggregates
--       "balance - COALESCE(reserved, 0)" but the column is reserved_balance.
--       Latent only because the function returns early when the tenant has no
--       active subscription, and there are 0 subscription rows today.
--       ⚠ Would throw on EVERY credit change once Sprint 2 assigns subscriptions.
--   D4  purchase_topup inserts t_bm_billing_event(processed, ...); the column
--       is status. Every call fails.
--   D5  purchase_topup passes channel = NULL, so a WhatsApp pack credits the
--       pooled bucket instead of the WhatsApp pool.
--
-- Also threads the fourth channel (inapp) through the flag helper and both
-- context triggers, matching migration 010's credits_inapp / flag_can_send_inapp.
--
-- SIGNATURE CHANGES (both backward compatible):
--   fn_recalc_credit_flags  + p_credits_inapp (defaulted), + can_send_inapp
--   add_credits             + p_reference_type (defaulted, LAST position)
--   Existing 7-positional-arg calls to add_credits still resolve; edge
--   functions call by name, which is unaffected.
--
-- transaction_type is constrained to
--   topup | deduction | expiry | adjustment | refund | transfer | initial
-- so p_source is mapped onto that set rather than stored raw.
--
-- reference_id is UUID on t_bm_credit_transaction but TEXT on the RPC params.
-- Cast is guarded: a non-UUID reference journals as NULL rather than aborting
-- the credit movement.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. fn_recalc_credit_flags — add the in-app channel
-- ------------------------------------------------------------
-- RETURNS TABLE gains a column, so the function must be dropped first.
-- Both callers are recreated below in this same migration.

DROP FUNCTION IF EXISTS public.fn_recalc_credit_flags(integer, integer, integer, integer, text);

CREATE FUNCTION public.fn_recalc_credit_flags(
    p_credits_whatsapp  integer,
    p_credits_sms       integer,
    p_credits_email     integer,
    p_credits_pooled    integer,
    p_subscription_status text,
    p_credits_inapp     integer DEFAULT 0
)
RETURNS TABLE(
    can_send_whatsapp boolean,
    can_send_sms      boolean,
    can_send_email    boolean,
    can_send_inapp    boolean,
    credits_low       boolean
)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_is_active BOOLEAN;
    v_low_threshold INTEGER := 10;
BEGIN
    v_is_active := p_subscription_status IN ('active', 'trial', 'grace_period');

    RETURN QUERY SELECT
        v_is_active AND (p_credits_whatsapp + p_credits_pooled) > 0,
        v_is_active AND (p_credits_sms      + p_credits_pooled) > 0,
        v_is_active AND (p_credits_email    + p_credits_pooled) > 0,
        v_is_active AND (p_credits_inapp    + p_credits_pooled) > 0,
        (p_credits_whatsapp + p_credits_sms + p_credits_email
         + p_credits_inapp + p_credits_pooled) < v_low_threshold;
END;
$function$;

-- ------------------------------------------------------------
-- 2. trg_fn_update_context_on_credit_change — D3 FIX
-- ------------------------------------------------------------
-- Changes vs baseline:
--   * "COALESCE(reserved, 0)"  ->  "COALESCE(reserved_balance, 0)"   [D3]
--   * aggregates the inapp channel and sets credits_inapp / flag_can_send_inapp
--   * caches the wallet balance into wallet_balance_paise (Mode A prep)

CREATE OR REPLACE FUNCTION public.trg_fn_update_context_on_credit_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_tenant_id UUID;
    v_product_code TEXT;
    v_whatsapp INTEGER;
    v_sms INTEGER;
    v_email INTEGER;
    v_inapp INTEGER;
    v_pooled INTEGER;
    v_wallet BIGINT;
    v_sub_status TEXT;
    v_flags RECORD;
BEGIN
    v_tenant_id := COALESCE(NEW.tenant_id, OLD.tenant_id);

    SELECT product_code, status INTO v_product_code, v_sub_status
    FROM t_bm_tenant_subscription
    WHERE tenant_id = v_tenant_id
      AND status IN ('active', 'trial', 'grace_period')
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_product_code IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    -- D3: the column is reserved_balance, not reserved.
    SELECT
        COALESCE(SUM(CASE WHEN channel = 'whatsapp' THEN balance - COALESCE(reserved_balance, 0) END), 0),
        COALESCE(SUM(CASE WHEN channel = 'sms'      THEN balance - COALESCE(reserved_balance, 0) END), 0),
        COALESCE(SUM(CASE WHEN channel = 'email'    THEN balance - COALESCE(reserved_balance, 0) END), 0),
        COALESCE(SUM(CASE WHEN channel = 'inapp'    THEN balance - COALESCE(reserved_balance, 0) END), 0),
        COALESCE(SUM(CASE WHEN channel IS NULL      THEN balance - COALESCE(reserved_balance, 0) END), 0)
    INTO v_whatsapp, v_sms, v_email, v_inapp, v_pooled
    FROM t_bm_credit_balance
    WHERE tenant_id = v_tenant_id
      AND credit_type = 'notification'
      AND (expires_at IS NULL OR expires_at > NOW());

    -- Wallet is a separate credit_type, denominated in PAISE.
    SELECT COALESCE(SUM(balance - COALESCE(reserved_balance, 0)), 0)
    INTO v_wallet
    FROM t_bm_credit_balance
    WHERE tenant_id = v_tenant_id
      AND credit_type = 'wallet'
      AND (expires_at IS NULL OR expires_at > NOW());

    SELECT * INTO v_flags
    FROM fn_recalc_credit_flags(v_whatsapp, v_sms, v_email, v_pooled, v_sub_status, v_inapp);

    UPDATE t_tenant_context SET
        credits_whatsapp        = v_whatsapp,
        credits_sms             = v_sms,
        credits_email           = v_email,
        credits_inapp           = v_inapp,
        credits_pooled          = v_pooled,
        wallet_balance_paise    = v_wallet,
        flag_can_send_whatsapp  = v_flags.can_send_whatsapp,
        flag_can_send_sms       = v_flags.can_send_sms,
        flag_can_send_email     = v_flags.can_send_email,
        flag_can_send_inapp     = v_flags.can_send_inapp,
        flag_credits_low        = v_flags.credits_low,
        updated_at              = NOW()
    WHERE product_code = v_product_code
      AND tenant_id = v_tenant_id;

    RETURN COALESCE(NEW, OLD);
END;
$function$;

-- ------------------------------------------------------------
-- 3. trg_fn_update_context_on_subscription — carry inapp through
-- ------------------------------------------------------------
-- Unchanged from baseline except: passes credits_inapp into the flag helper
-- and writes flag_can_send_inapp. Recreated because the helper's signature
-- changed in step 1 above.

CREATE OR REPLACE FUNCTION public.trg_fn_update_context_on_subscription()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
    v_product_code TEXT;
    v_plan_name TEXT;
    v_flags RECORD;
BEGIN
    v_product_code := COALESCE(NEW.product_code, 'contractnest');

    SELECT p.name INTO v_plan_name
    FROM t_bm_plan_version v
    JOIN t_bm_pricing_plan p ON p.plan_id = v.plan_id
    WHERE v.version_id = NEW.version_id;

    INSERT INTO t_tenant_context (
        product_code, tenant_id, subscription_id, subscription_status,
        plan_name, billing_cycle, period_start, period_end,
        trial_end_date, grace_end_date, next_billing_date,
        flag_can_access, updated_at
    )
    VALUES (
        v_product_code, NEW.tenant_id, NEW.subscription_id, NEW.status,
        v_plan_name, NEW.billing_cycle, NEW.start_date::date, NEW.renewal_date::date,
        NEW.trial_ends::date, NEW.grace_end_date::date, NEW.next_billing_date,
        NEW.status IN ('active', 'trial', 'grace_period'), NOW()
    )
    ON CONFLICT (product_code, tenant_id)
    DO UPDATE SET
        subscription_id     = EXCLUDED.subscription_id,
        subscription_status = EXCLUDED.subscription_status,
        plan_name           = EXCLUDED.plan_name,
        billing_cycle       = EXCLUDED.billing_cycle,
        period_start        = EXCLUDED.period_start,
        period_end          = EXCLUDED.period_end,
        trial_end_date      = EXCLUDED.trial_end_date,
        grace_end_date      = EXCLUDED.grace_end_date,
        next_billing_date   = EXCLUDED.next_billing_date,
        flag_can_access     = EXCLUDED.flag_can_access,
        updated_at          = NOW();

    SELECT * INTO v_flags
    FROM fn_recalc_credit_flags(
        COALESCE((SELECT credits_whatsapp FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id), 0),
        COALESCE((SELECT credits_sms      FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id), 0),
        COALESCE((SELECT credits_email    FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id), 0),
        COALESCE((SELECT credits_pooled   FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id), 0),
        NEW.status,
        COALESCE((SELECT credits_inapp    FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id), 0)
    );

    UPDATE t_tenant_context SET
        flag_can_send_whatsapp = v_flags.can_send_whatsapp,
        flag_can_send_sms      = v_flags.can_send_sms,
        flag_can_send_email    = v_flags.can_send_email,
        flag_can_send_inapp    = v_flags.can_send_inapp,
        flag_credits_low       = v_flags.credits_low
    WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id;

    RETURN NEW;
END;
$function$;

-- ------------------------------------------------------------
-- 4. add_credits — D1 FIX (journal write) + reference_type
-- ------------------------------------------------------------
-- Dropped and recreated so the new parameter is added rather than creating an
-- ambiguous overload. p_reference_type is LAST and defaulted, so purchase_topup's
-- 7-positional-argument call still resolves unchanged.

DROP FUNCTION IF EXISTS public.add_credits(uuid, text, integer, text, text, text, text);

CREATE FUNCTION public.add_credits(
    p_tenant_id      uuid,
    p_credit_type    text,
    p_quantity       integer,
    p_channel        text DEFAULT NULL,
    p_source         text DEFAULT 'manual',
    p_reference_id   text DEFAULT NULL,
    p_description    text DEFAULT NULL,
    p_reference_type text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_credit RECORD;
    v_balance_before INTEGER := 0;
    v_new_balance INTEGER;
    v_ref_uuid UUID;
    v_txn_type TEXT;
BEGIN
    IF p_quantity <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Quantity must be positive');
    END IF;

    -- Guarded cast: a non-UUID reference is journalled as NULL (kept verbatim in
    -- metadata) rather than aborting a legitimate credit movement.
    BEGIN
        v_ref_uuid := NULLIF(p_reference_id, '')::uuid;
    EXCEPTION WHEN others THEN
        v_ref_uuid := NULL;
    END;

    -- Map source onto the transaction_type CHECK set.
    v_txn_type := CASE lower(COALESCE(p_source, 'manual'))
                      WHEN 'manual'  THEN 'adjustment'
                      WHEN 'initial' THEN 'initial'
                      WHEN 'refund'  THEN 'refund'
                      ELSE 'topup'
                  END;

    SELECT * INTO v_credit
    FROM t_bm_credit_balance
    WHERE tenant_id = p_tenant_id
      AND credit_type = p_credit_type
      AND (channel IS NOT DISTINCT FROM p_channel)
    FOR UPDATE;

    IF v_credit IS NULL THEN
        v_balance_before := 0;
        INSERT INTO t_bm_credit_balance (
            tenant_id, credit_type, channel, balance, last_topup_at, last_topup_amount
        ) VALUES (
            p_tenant_id, p_credit_type, p_channel, p_quantity, NOW(), p_quantity
        )
        RETURNING balance INTO v_new_balance;
    ELSE
        v_balance_before := v_credit.balance;
        UPDATE t_bm_credit_balance
        SET balance           = balance + p_quantity,
            last_topup_at     = NOW(),
            last_topup_amount = p_quantity,
            updated_at        = NOW()
        WHERE id = v_credit.id
        RETURNING balance INTO v_new_balance;
    END IF;

    -- D1: journal the movement in the SAME transaction as the balance change.
    INSERT INTO t_bm_credit_transaction (
        tenant_id, credit_type, channel, transaction_type, quantity,
        balance_before, balance_after, reference_type, reference_id,
        description, metadata
    ) VALUES (
        p_tenant_id, p_credit_type, p_channel, v_txn_type, p_quantity,
        v_balance_before, v_new_balance,
        COALESCE(p_reference_type, p_source), v_ref_uuid,
        p_description,
        jsonb_build_object('source', p_source, 'reference_id_raw', p_reference_id)
    );

    RETURN jsonb_build_object(
        'success', true,
        'tenant_id', p_tenant_id,
        'credit_type', p_credit_type,
        'channel', p_channel,
        'quantity_added', p_quantity,
        'previous_balance', v_balance_before,
        'new_balance', v_new_balance,
        'source', p_source,
        'reference_type', COALESCE(p_reference_type, p_source),
        'reference_id', p_reference_id,
        'description', p_description
    );
END;
$function$;

-- ------------------------------------------------------------
-- 5. deduct_credits — D1 FIX (journal write)
-- ------------------------------------------------------------
-- Signature unchanged. Only addition is the journal insert; the balance,
-- locking and insufficient-credit behaviour are exactly as captured in the
-- baseline.

CREATE OR REPLACE FUNCTION public.deduct_credits(
    p_tenant_id      uuid,
    p_credit_type    text,
    p_quantity       integer,
    p_channel        text DEFAULT NULL,
    p_reference_type text DEFAULT NULL,
    p_reference_id   text DEFAULT NULL,
    p_description    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_credit RECORD;
    v_available INTEGER;
    v_new_balance INTEGER;
    v_ref_uuid UUID;
BEGIN
    IF p_quantity <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Quantity must be positive');
    END IF;

    BEGIN
        v_ref_uuid := NULLIF(p_reference_id, '')::uuid;
    EXCEPTION WHEN others THEN
        v_ref_uuid := NULL;
    END;

    SELECT * INTO v_credit
    FROM t_bm_credit_balance
    WHERE tenant_id = p_tenant_id
      AND credit_type = p_credit_type
      AND (channel IS NOT DISTINCT FROM p_channel)
      AND (expires_at IS NULL OR expires_at > NOW())
    FOR UPDATE;

    IF v_credit IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'No credit balance found',
            'tenant_id', p_tenant_id,
            'credit_type', p_credit_type,
            'channel', p_channel
        );
    END IF;

    v_available := v_credit.balance - COALESCE(v_credit.reserved_balance, 0);

    IF v_available < p_quantity THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Insufficient credits',
            'required', p_quantity,
            'available', v_available,
            'balance', v_credit.balance,
            'reserved', COALESCE(v_credit.reserved_balance, 0)
        );
    END IF;

    UPDATE t_bm_credit_balance
    SET balance = balance - p_quantity,
        updated_at = NOW()
    WHERE id = v_credit.id
    RETURNING balance INTO v_new_balance;

    -- D1: journal the movement. quantity is stored NEGATIVE for deductions,
    -- matching the convention already used by process_credit_expiry.
    INSERT INTO t_bm_credit_transaction (
        tenant_id, credit_type, channel, transaction_type, quantity,
        balance_before, balance_after, reference_type, reference_id,
        description, metadata
    ) VALUES (
        p_tenant_id, p_credit_type, p_channel, 'deduction', -p_quantity,
        v_credit.balance, v_new_balance, p_reference_type, v_ref_uuid,
        p_description,
        jsonb_build_object('reference_id_raw', p_reference_id)
    );

    RETURN jsonb_build_object(
        'success', true,
        'tenant_id', p_tenant_id,
        'credit_type', p_credit_type,
        'channel', p_channel,
        'quantity_deducted', p_quantity,
        'previous_balance', v_credit.balance,
        'new_balance', v_new_balance,
        'reference_type', p_reference_type,
        'reference_id', p_reference_id,
        'description', p_description
    );
END;
$function$;

-- ------------------------------------------------------------
-- 6. purchase_topup — D4 + D5 FIX
-- ------------------------------------------------------------
--   D4: t_bm_billing_event has `status`, not `processed`. Allowed values are
--       pending | processing | completed | failed | skipped | dead_letter.
--   D5: pass the pack's channel through instead of hardcoding NULL, so a
--       WhatsApp pack credits the WhatsApp pool.
--
-- NOTE: t_bm_topup_pack.channel is NULL on every existing row until the Step 5
-- SKU cleanup populates it. Until then a notification pack still credits the
-- pooled bucket — i.e. no behaviour change from today, but no longer hardcoded.

CREATE OR REPLACE FUNCTION public.purchase_topup(
    p_tenant_id uuid,
    p_pack_id uuid,
    p_payment_reference text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_pack RECORD;
    v_expiry TIMESTAMPTZ;
    v_result JSONB;
BEGIN
    SELECT * INTO v_pack
    FROM t_bm_topup_pack
    WHERE id = p_pack_id
      AND is_active = true;

    IF v_pack IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Topup pack not found or inactive',
            'pack_id', p_pack_id
        );
    END IF;

    -- Retained for the response payload. Credits do not expire (owner decision
    -- 2026-08-05) and add_credits has no expiry parameter, so this is not
    -- written to the balance. Step 5 sets expiry_days = NULL on all packs.
    IF v_pack.expiry_days IS NOT NULL THEN
        v_expiry := NOW() + (v_pack.expiry_days || ' days')::INTERVAL;
    END IF;

    v_result := add_credits(
        p_tenant_id,
        v_pack.credit_type,
        v_pack.quantity,
        v_pack.channel,               -- D5: was hardcoded NULL
        'topup',
        p_pack_id::text,
        'Purchased: ' || v_pack.name,
        'topup_pack'                  -- reference_type
    );

    IF NOT (v_result->>'success')::BOOLEAN THEN
        RETURN v_result;
    END IF;

    -- D4: `status`, not `processed`.
    INSERT INTO t_bm_billing_event (
        tenant_id, event_type, event_data, status, processed_at
    ) VALUES (
        p_tenant_id,
        'credits_purchased',
        jsonb_build_object(
            'pack_id', p_pack_id,
            'pack_name', v_pack.name,
            'credit_type', v_pack.credit_type,
            'channel', v_pack.channel,
            'quantity', v_pack.quantity,
            'price', v_pack.price,
            'currency', v_pack.currency_code,
            'payment_reference', p_payment_reference
        ),
        'completed',
        NOW()
    );

    RETURN jsonb_build_object(
        'success', true,
        'pack', jsonb_build_object(
            'id', v_pack.id,
            'name', v_pack.name,
            'credit_type', v_pack.credit_type,
            'channel', v_pack.channel,
            'quantity', v_pack.quantity,
            'price', v_pack.price,
            'currency', v_pack.currency_code
        ),
        'credits_added', v_pack.quantity,
        'new_balance', v_result->'new_balance',
        'expires_at', v_expiry
    );
END;
$function$;

COMMIT;
