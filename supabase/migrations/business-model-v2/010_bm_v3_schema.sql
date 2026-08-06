-- ============================================================
-- BUSINESS MODEL V3 — 010 : Additive schema for Sprint 1
-- ============================================================
-- Spec      : ClaudeDocumentation/BusinessModel/BUSINESS_MODEL_V3_SPEC.md
-- POA       : ClaudeDocumentation/BusinessModel/BUSINESS_MODEL_V3_POA.md  (Sprint 1, Step 2)
-- Baseline  : ClaudeDocumentation/BusinessModel/SPRINT1_STEP1_BASELINE.md
--
-- SAFETY: This migration is ADDITIVE ONLY.
--   - No column is dropped, renamed or retyped.
--   - No function, trigger or index is altered.
--   - Nothing reads or writes the new columns until Step 3.
--   => Applying this alone changes NO behaviour and cannot break anything.
--
-- Idempotent: every statement is IF NOT EXISTS / guarded. Safe to re-run.
--
-- NOTE: t_bm_credit_lot (FIFO lots) is deliberately NOT created here.
--   Owner decision 2026-08-05: credits never expire, they are consumed and
--   have no end date. Baseline §5 D6 confirms nothing has ever written
--   expires_at (purchase_topup computes an expiry then discards it, because
--   add_credits has no expiry parameter). Lots exist only to make expiry
--   correct, so they are deferred until Mode A (the 1-year wallet) ships.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. t_bm_topup_pack.channel
-- ------------------------------------------------------------
-- Baseline §5 D5: purchase_topup passes channel = NULL with a comment
-- claiming it is "determined by credit_type" — it is not. t_bm_topup_pack
-- has no channel column, so channel is only implied by the pack NAME
-- ("WhatsApp 500 Pack"). Result: buying a WhatsApp pack credits the POOLED
-- bucket (channel IS NULL) instead of the WhatsApp pool, which is invisible
-- to the WhatsApp gate.
--
-- This column is the data half of that fix. The purchase_topup rework that
-- passes it through lands in Step 3.

ALTER TABLE t_bm_topup_pack
    ADD COLUMN IF NOT EXISTS channel TEXT;

COMMENT ON COLUMN t_bm_topup_pack.channel IS
    'Notification channel this pack credits: whatsapp | email | sms | inapp. '
    'NULL for non-notification credit types (e.g. ai_report) or a pooled pack. '
    'Values must match t_bm_credit_balance.channel and the Channels LOV.';

-- ------------------------------------------------------------
-- 2. t_tenant_context — billing mode + wallet
-- ------------------------------------------------------------
-- Spec §5.4. Every gate needs to know whether to check a wallet balance or
-- a plan quota. t_tenant_context had no such field.

ALTER TABLE t_tenant_context
    ADD COLUMN IF NOT EXISTS billing_mode TEXT NOT NULL DEFAULT 'freemium';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_tenant_context_billing_mode'
    ) THEN
        ALTER TABLE t_tenant_context
            ADD CONSTRAINT chk_tenant_context_billing_mode
            CHECK (billing_mode IN ('freemium','poc','per_contract','plan','exempt'));
    END IF;
END $$;

COMMENT ON COLUMN t_tenant_context.billing_mode IS
    'How this tenant is billed. freemium = first free contracts; poc = paid '
    'short-term trial contract; per_contract = wallet (Mode A); plan = '
    'quarterly/yearly quota (Mode B); exempt = platform tenant, no metering.';

-- Money is stored in PAISE as an integer. Never use a float for currency.
-- Rupees 1,000 = 100000 paise. bigint, not integer, to leave headroom.
ALTER TABLE t_tenant_context
    ADD COLUMN IF NOT EXISTS wallet_balance_paise BIGINT NOT NULL DEFAULT 0;

COMMENT ON COLUMN t_tenant_context.wallet_balance_paise IS
    'Cached wallet balance in PAISE (Mode A). Mirrors the t_bm_credit_balance '
    'row with credit_type = ''wallet''. Cached so gates read one row.';

-- ------------------------------------------------------------
-- 3. t_tenant_context — fourth notification channel
-- ------------------------------------------------------------
-- Owner decision 2026-08-05: four per-channel pools (whatsapp, email, sms,
-- inapp), each starting at 0, each topped up cumulatively on contract
-- creation. Any of the tenant's contracts may draw on the pool.
-- t_tenant_context already had whatsapp/sms/email/pooled but no inapp.

ALTER TABLE t_tenant_context
    ADD COLUMN IF NOT EXISTS credits_inapp INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN t_tenant_context.credits_inapp IS
    'Available in-app notification credits. Fourth channel; not yet activated.';

ALTER TABLE t_tenant_context
    ADD COLUMN IF NOT EXISTS flag_can_send_inapp BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN t_tenant_context.flag_can_send_inapp IS
    'TRUE if tenant can send in-app notifications (active sub + credits > 0).';

-- ------------------------------------------------------------
-- 4. t_tenant_context — configurable credit grant rates
-- ------------------------------------------------------------
-- Owner decision 2026-08-05: "each contract 15 credits — it is NOT hardcoded,
-- it should be managed in catalog-studio by a human."
--
-- The authoring surface is a metering block on the platform contract template
-- (config.metering). This column caches the RESOLVED rates for the tenant so
-- the contract-creation hook does not have to walk back to the plan's blocks
-- on every single contract.
--
-- Shape:
--   { "whatsapp": 15, "email": 15, "sms": 0, "inapp": 0 }
-- Written by the settlement hook (Step 8) when a platform contract settles.
-- An empty object means "grant nothing".

ALTER TABLE t_tenant_context
    ADD COLUMN IF NOT EXISTS credit_grant_rates JSONB NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN t_tenant_context.credit_grant_rates IS
    'Credits granted per tenant-contract created, per channel, e.g. '
    '{"whatsapp":15,"email":15,"sms":0,"inapp":0}. Authored as a metering '
    'block in catalog-studio; resolved here by the settlement hook. '
    'NOT hardcoded anywhere in application code.';

-- ------------------------------------------------------------
-- 5. t_tenant_context — limits and usage the plans actually need
-- ------------------------------------------------------------
-- Spec §5.5. Existing columns cover users / contracts / storage_mb only.
-- Plans, freemium and the test caps also bound contacts, templates and RFQs.
--
-- NULL = unlimited (the convention already used by limit_users /
-- limit_contracts). This is how the Vikuna platform tenant is made
-- unconstrained — NULL, never a large sentinel number, which would still
-- trigger near-limit warnings and eventually run out.

ALTER TABLE t_tenant_context
    ADD COLUMN IF NOT EXISTS limit_contacts  INTEGER,
    ADD COLUMN IF NOT EXISTS limit_templates INTEGER,
    ADD COLUMN IF NOT EXISTS limit_rfqs      INTEGER;

COMMENT ON COLUMN t_tenant_context.limit_contacts  IS 'Max contacts. NULL = unlimited.';
COMMENT ON COLUMN t_tenant_context.limit_templates IS 'Max catalog templates. NULL = unlimited.';
COMMENT ON COLUMN t_tenant_context.limit_rfqs      IS 'Max RFQs for the period. NULL = unlimited.';

ALTER TABLE t_tenant_context
    ADD COLUMN IF NOT EXISTS usage_contacts  INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS usage_templates INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS usage_rfqs      INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN t_tenant_context.usage_contacts  IS 'Contacts used this period (is_live = true only).';
COMMENT ON COLUMN t_tenant_context.usage_templates IS 'Templates used this period (is_live = true only).';
COMMENT ON COLUMN t_tenant_context.usage_rfqs      IS 'RFQs raised this period (is_live = true only).';

-- ------------------------------------------------------------
-- 6. Freemium counters
-- ------------------------------------------------------------
-- Owner decision: 3 free contracts + 1 free RFQ before any billing starts,
-- and those free contracts DO still grant notification credits.
-- Counted separately from usage_* because usage_* resets each billing
-- period, whereas freemium is consumed once in the tenant's lifetime.

ALTER TABLE t_tenant_context
    ADD COLUMN IF NOT EXISTS freemium_contracts_used INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS freemium_rfqs_used      INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN t_tenant_context.freemium_contracts_used IS
    'Lifetime count of free contracts consumed (default allowance 3). '
    'Never reset by a billing period. is_live = true only.';
COMMENT ON COLUMN t_tenant_context.freemium_rfqs_used IS
    'Lifetime count of free RFQs consumed (default allowance 1). '
    'Never reset by a billing period. is_live = true only.';

-- ------------------------------------------------------------
-- 7. Index for the OPS widget / ledger attribution
-- ------------------------------------------------------------
-- Step 3 makes add_credits / deduct_credits write t_bm_credit_transaction
-- rows carrying reference_type + reference_id (baseline §4 D1). The OPS
-- Tenant Context widget reads that journal per tenant, newest first.

CREATE INDEX IF NOT EXISTS idx_bm_credit_txn_tenant_created
    ON t_bm_credit_transaction (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_bm_credit_txn_reference
    ON t_bm_credit_transaction (reference_type, reference_id)
    WHERE reference_id IS NOT NULL;

COMMIT;

-- ============================================================
-- POST-APPLY VERIFICATION (run manually, expect 15)
-- ============================================================
-- SELECT count(*) FROM information_schema.columns
--  WHERE table_name = 't_tenant_context'
--    AND column_name IN ('billing_mode','wallet_balance_paise','credits_inapp',
--        'flag_can_send_inapp','credit_grant_rates','limit_contacts',
--        'limit_templates','limit_rfqs','usage_contacts','usage_templates',
--        'usage_rfqs','freemium_contracts_used','freemium_rfqs_used')
-- UNION ALL
-- SELECT count(*) FROM information_schema.columns
--  WHERE table_name = 't_bm_topup_pack' AND column_name = 'channel';
--
-- Behaviour check — nothing should have changed:
--   SELECT * FROM t_bm_credit_balance;   -- still 4 rows, untouched
--   SELECT count(*) FROM t_tenant_context;  -- still 0
-- ============================================================
