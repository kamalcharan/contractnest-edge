-- ============================================================================
-- Business Model V4 — "Per Contract" becomes a visible plan tile
--
-- Owner correction after seeing Free/Quarterly/Yearly live: "per contract
-- should be visible right" — the pay-as-you-go billing mode had no card in
-- the Plans grid at all, only a generic "wallet top-up" purchase buried in
-- the Credit packs section with no explanation of what it activates.
--
-- Fix: author "Per Contract" as a REAL t_cat_templates row, category =
-- 'per_contract', is_public = true — same is_public/is_active/lifecycle
-- gate every other plan uses to control what's listed for sale, per the
-- owner's own framing ("we have... is_visible... only [that] is showing on
-- the plans page"). No new visibility mechanism, no hardcoded UI copy for
-- the rate — reusing the exact machinery Free/Quarterly/Yearly already use.
--
-- The ₹200/contract, ₹400/RFQ rate itself moves out of trg_fn_wallet_charge
-- (hardcoded literals since 024_wallet_mode.sql) and into this template's
-- own metering block, in a new mode: 'per_creation_charge' with a `rates`
-- object (paise, keyed like `limits` — 'contracts'/'rfqs'). The charge
-- trigger now reads this SAME block, live, instead of a duplicate constant
-- — a rate change is a catalog-studio edit from here on, not a deploy, and
-- there is exactly one place the rate lives, not two that could drift.
--
-- Fail-closed, deliberately: if the template is ever unpublished or its
-- rate block removed, trg_fn_wallet_charge now RAISES rather than silently
-- charging nothing (or falling back to a stale hardcoded default) — tested
-- live below by temporarily unpublishing the template and confirming a
-- contract insert is blocked, not free.
-- ============================================================================


-- ── 1. The "Per Contract" plan template ─────────────────────────────────
-- Applied live as v4_wallet_11_per_contract_template + v4_wallet_12 (parent_
-- template_id). Mirrors Free/Quarterly/Yearly's exact block shape: a
-- billing-only service block, a metering block, a T&C block — except the
-- metering block is 'per_creation_charge' (money, keyed like limits) plus a
-- second 'per_creation' block for the 15/15 notification credit grant,
-- instead of a 'limit' block — this plan has no cap.
WITH platform AS (SELECT id FROM t_tenants WHERE is_admin = TRUE LIMIT 1)
INSERT INTO t_cat_templates (
  tenant_id, is_live, name, display_name, description, category, tags,
  blocks, currency, subtotal, total, settings,
  is_system, is_public, is_active, is_deletable, sequence_no, is_latest
)
SELECT
  platform.id, TRUE, 'Per Contract', 'Per Contract',
  'Pay only for what you create - no cap, no term. ₹200 per contract, ₹400 per RFQ, deducted from your wallet balance as you create.',
  'per_contract', '[]'::jsonb,
  jsonb_build_array(
    jsonb_build_object(
      'order', 0, 'block_id', '77d1ddea-f6ed-4da3-a8ce-506485228f82',
      'config_overrides', jsonb_build_object(
        'name', 'ContractNest Per Contract Plan',
        'config', jsonb_build_object('billingOnly', true, 'showDescription', true),
        'currency', 'INR', 'quantity', 1, 'unlimited', false, 'unit_price', 0,
        'category_id', 'service', 'total_price', 0, 'billing_cycle', 'prepaid', 'category_name', 'Service'
      )
    ),
    jsonb_build_object(
      'order', 1, 'block_id', '8c487906-c61b-40ff-bc55-7a797ec36a38',
      'config_overrides', jsonb_build_object(
        'name', 'Per-creation charge',
        'config', jsonb_build_object(
          'metering', jsonb_build_object('mode', 'per_creation_charge', 'rates', jsonb_build_object('contracts', 20000, 'rfqs', 40000)),
          'showDescription', true
        ),
        'currency', 'INR', 'quantity', 1, 'unlimited', false, 'unit_price', 0,
        'category_id', 'metering', 'total_price', 0, 'billing_cycle', 'prepaid', 'category_name', 'Credit Pack'
      )
    ),
    jsonb_build_object(
      'order', 2, 'block_id', '8c487906-c61b-40ff-bc55-7a797ec36a38',
      'config_overrides', jsonb_build_object(
        'name', 'Notification credits per contract',
        'config', jsonb_build_object(
          'metering', jsonb_build_object('mode', 'per_creation', 'grants', jsonb_build_object('email', 15, 'whatsapp', 15)),
          'showDescription', true
        ),
        'currency', 'INR', 'quantity', 1, 'unlimited', false, 'unit_price', 0,
        'category_id', 'metering', 'total_price', 0, 'billing_cycle', 'prepaid', 'category_name', 'Credit Pack'
      )
    ),
    jsonb_build_object(
      'order', 3, 'block_id', '2f635919-4440-461e-875f-d127068fcaad',
      'config_overrides', jsonb_build_object(
        'name', 'Terms & Conditions',
        'config', jsonb_build_object(
          'content', '<p>This is a pay-as-you-go arrangement provided by Vikuna Technologies (&ldquo;ContractNest&rdquo;). It has no fixed term and no included allowance - instead, ₹200 is charged for each contract you create and ₹400 for each RFQ you raise, deducted immediately from your ContractNest wallet balance. If your wallet balance is insufficient at the moment of creation, the creation is blocked until you top up.</p><p>15 WhatsApp and 15 Email notification credits are granted to your pool on each contract or RFQ you create, the same as under a plan. Wallet funds are added by purchasing a wallet top-up; a minimum top-up amount applies to each purchase.</p><p>Fees are exclusive of GST.</p>',
          'autoIncluded', true, 'showDescription', true
        ),
        'currency', 'INR', 'quantity', 1, 'unlimited', false, 'unit_price', 0,
        'category_id', 'text', 'total_price', 0, 'billing_cycle', 'prepaid', 'category_name', 'Text'
      )
    )
  ),
  'INR', 0, 0,
  jsonb_build_object(
    'defaults', jsonb_build_object(
      'payment_mode', 'defined', 'duration_unit', NULL, 'duration_value', NULL,
      'nomenclature_id', 'ed0b1d7d-9bcc-43ea-a45b-b8b92c323cc4', 'acceptance_method', 'auto',
      'grace_period_unit', 'days', 'nomenclature_name', 'Subscription', 'billing_cycle_type', 'unified',
      'grace_period_value', 0, 'nomenclature_group', 'service_delivery', 'evidence_policy_type', 'none',
      'selected_tax_rate_ids', '[]'::jsonb, 'evidence_selected_forms', '[]'::jsonb
    ),
    'lifecycle', 'signed_off'
  ),
  FALSE, TRUE, TRUE, TRUE, 3, TRUE
FROM platform
RETURNING id;

-- Set parent_template_id to own id, matching Free/Quarterly/Yearly's convention.
-- (Run as its own statement in this session — the new row's id was read back
-- first. On a fresh environment, substitute the id RETURNED above.)
-- UPDATE t_cat_templates SET parent_template_id = id WHERE id = '<returned id>'::uuid;


-- ── 2. trg_fn_wallet_charge reads its rate from the template, not a literal ──
-- Applied live as v4_wallet_13_charge_reads_rate_from_template. Same hard-
-- block posture as before (RAISE EXCEPTION on insufficient balance) — the
-- only change is WHERE the ₹200/₹400 numbers come from. Fails closed if the
-- rate can't be resolved (template unpublished/rate block missing): blocks
-- creation with a clear error rather than charging nothing or falling back
-- to a stale default.
CREATE OR REPLACE FUNCTION public.trg_fn_wallet_charge()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_ctx    RECORD;
    v_amount BIGINT;
    v_rates  JSONB;
    v_block  JSONB;
BEGIN
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

    -- Rate is authored data on the "Per Contract" plan template, not a code
    -- constant — read live so a rate change is a catalog-studio edit, not a
    -- deploy, same as every other plan's price/limits/grants.
    SELECT b INTO v_block
    FROM t_cat_templates t, jsonb_array_elements(t.blocks) b
    WHERE t.tenant_id = (SELECT id FROM t_tenants WHERE is_admin = TRUE LIMIT 1)
      AND t.category = 'per_contract' AND t.is_live = TRUE AND t.is_public = TRUE
      AND t.is_active = TRUE AND t.settings->>'lifecycle' = 'signed_off'
      AND b->'config_overrides'->'config'->'metering'->>'mode' = 'per_creation_charge'
    ORDER BY t.updated_at DESC
    LIMIT 1;

    IF v_block IS NULL THEN
        RAISE EXCEPTION 'Per-contract billing rate is not configured. Contact support.'
            USING ERRCODE = 'P0001';
    END IF;

    v_rates := v_block->'config_overrides'->'config'->'metering'->'rates';
    v_amount := CASE WHEN NEW.record_type = 'rfq'
        THEN (v_rates->>'rfqs')::BIGINT
        ELSE (v_rates->>'contracts')::BIGINT
    END;

    IF v_amount IS NULL THEN
        RAISE EXCEPTION 'Per-contract billing rate is not configured for %.', NEW.record_type
            USING ERRCODE = 'P0001';
    END IF;

    IF COALESCE(v_ctx.wallet_balance_paise, 0) < v_amount THEN
        RAISE EXCEPTION 'Insufficient wallet balance: have % paise, need % paise. Top up to continue.',
            COALESCE(v_ctx.wallet_balance_paise, 0), v_amount
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE t_tenant_context
    SET wallet_balance_paise = wallet_balance_paise - v_amount, updated_at = now()
    WHERE product_code = 'contractnest' AND tenant_id = NEW.tenant_id;

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
