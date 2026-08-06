-- ============================================================
-- BUSINESS MODEL V3 — 015 : Seed the Vikuna platform tenant
-- ============================================================
-- Sprint 1, Step 5.
--
-- Platform tenant confirmed 2026-08-05:
--   name          vikuna
--   id            70f8eb69-9ccf-4a0c-8177-cb6131934344
--   owner         vikunatech@gmail.com  (the only t_user_profiles row with is_admin = true)
--   tenant flags  is_admin = true, is_test = false
--
-- NOT the tenant named "vikunatechnologies" (8527c263…), which is is_test = true,
-- is_admin = false, owned by info@vikuna.io, and has never sold anything. The
-- names are similar; the admin EMAIL is vikunatech@gmail.com and it belongs to
-- the tenant NAMED vikuna.
--
-- Limits are NULL, never a large sentinel number. NULL is the documented
-- "unlimited" convention on these columns and avoids near-limit warnings,
-- arithmetic edge cases and eventual exhaustion.
--
-- billing_mode = 'exempt' so every metering hook skips this tenant outright.
--
-- credit_grant_rates = {} because the platform does not grant credits to itself.
--
-- NOTE: this row is inserted directly rather than through init_tenant_context,
-- because the context triggers currently key off t_bm_tenant_subscription — a
-- table the v3 model does not use (see spec §8: the contract IS the
-- subscription). Repointing those triggers at the platform contract is the next
-- step; until then nothing maintains this row, which is harmless for an exempt
-- tenant whose values never change.
--
-- Idempotent via ON CONFLICT.
-- ============================================================

INSERT INTO t_tenant_context (
    product_code, tenant_id, business_name,
    billing_mode,
    subscription_status,
    limit_users, limit_contracts, limit_storage_mb,
    limit_contacts, limit_templates, limit_rfqs,
    credit_grant_rates,
    flag_can_access,
    flag_can_send_whatsapp, flag_can_send_email,
    flag_can_send_sms, flag_can_send_inapp,
    flag_credits_low, flag_near_limit
) VALUES (
    'contractnest',
    '70f8eb69-9ccf-4a0c-8177-cb6131934344',
    'Vikuna',
    'exempt',
    'active',
    NULL, NULL, NULL,
    NULL, NULL, NULL,
    '{}'::jsonb,
    true,
    true, true, true, true,
    false, false
)
ON CONFLICT (product_code, tenant_id) DO UPDATE SET
    billing_mode      = 'exempt',
    limit_users       = NULL,
    limit_contracts   = NULL,
    limit_storage_mb  = NULL,
    limit_contacts    = NULL,
    limit_templates   = NULL,
    limit_rfqs        = NULL,
    flag_can_access   = true,
    updated_at        = now();

-- ============================================================
-- VERIFICATION
-- ============================================================
-- SELECT tenant_id, business_name, billing_mode, limit_contracts,
--        limit_users, limit_contacts, flag_can_access
--   FROM t_tenant_context
--  WHERE tenant_id = '70f8eb69-9ccf-4a0c-8177-cb6131934344';
--
-- Expect: billing_mode = exempt, every limit_* NULL, flag_can_access = true
-- ============================================================
