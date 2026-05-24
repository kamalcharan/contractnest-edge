-- Migration: Ensure service_role bypass RLS on tables used by seed skill
-- Description: The seedTenantOnIndustryConfirmed skill runs server-side with
--              the Supabase service role key. This migration ensures the
--              service_role can write to t_client_asset_registry and
--              t_idempotency_keys without being blocked by tenant-isolation
--              RLS policies.
-- Date: 2026-05-21

-- ============================================================================
-- t_client_asset_registry — ensure service_role bypass
-- ============================================================================
-- The tenant-isolation policy (car_tenant_isolation) uses current_setting()
-- which is not set in server-side service clients. The service_role bypass
-- must exist and be idempotently recreated here.

ALTER TABLE "public"."t_client_asset_registry" ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "car_service_role_bypass" ON "public"."t_client_asset_registry";

CREATE POLICY "car_service_role_bypass"
    ON "public"."t_client_asset_registry"
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- ============================================================================
-- t_idempotency_keys — add RLS + service_role bypass
-- ============================================================================
-- The idempotency table did not have RLS enabled in its original migration.
-- Enable it with a service_role bypass so the seed skill can write records.

ALTER TABLE "public"."t_idempotency_keys" ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "idempotency_service_role_bypass" ON "public"."t_idempotency_keys";

CREATE POLICY "idempotency_service_role_bypass"
    ON "public"."t_idempotency_keys"
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- Allow authenticated users to read their own idempotency records (edge function reads)
DROP POLICY IF EXISTS "idempotency_tenant_read" ON "public"."t_idempotency_keys";

CREATE POLICY "idempotency_tenant_read"
    ON "public"."t_idempotency_keys"
    FOR SELECT
    TO authenticated
    USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
