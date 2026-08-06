-- ============================================================
-- BUSINESS MODEL V3 — 010 DOWN : revert additive Sprint 1 schema
-- ============================================================
-- Safe to run ONLY while nothing reads or writes these columns —
-- i.e. before Step 3 lands the RPC rework. After Step 3, reverting
-- this migration will break add_credits / deduct_credits / the
-- settlement hook.
--
-- Dropping a column that does not exist is an error, so every drop
-- is IF EXISTS. Nothing else in the schema is touched.
-- ============================================================

BEGIN;

DROP INDEX IF EXISTS idx_bm_credit_txn_reference;
DROP INDEX IF EXISTS idx_bm_credit_txn_tenant_created;

ALTER TABLE t_tenant_context
    DROP CONSTRAINT IF EXISTS chk_tenant_context_billing_mode;

ALTER TABLE t_tenant_context
    DROP COLUMN IF EXISTS freemium_rfqs_used,
    DROP COLUMN IF EXISTS freemium_contracts_used,
    DROP COLUMN IF EXISTS usage_rfqs,
    DROP COLUMN IF EXISTS usage_templates,
    DROP COLUMN IF EXISTS usage_contacts,
    DROP COLUMN IF EXISTS limit_rfqs,
    DROP COLUMN IF EXISTS limit_templates,
    DROP COLUMN IF EXISTS limit_contacts,
    DROP COLUMN IF EXISTS credit_grant_rates,
    DROP COLUMN IF EXISTS flag_can_send_inapp,
    DROP COLUMN IF EXISTS credits_inapp,
    DROP COLUMN IF EXISTS wallet_balance_paise,
    DROP COLUMN IF EXISTS billing_mode;

ALTER TABLE t_bm_topup_pack
    DROP COLUMN IF EXISTS channel;

COMMIT;
