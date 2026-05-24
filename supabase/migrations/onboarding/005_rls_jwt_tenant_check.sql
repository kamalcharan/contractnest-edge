-- Migration: Update RLS policies to support JWT-based tenant checks
-- Description: The car_tenant_isolation policy only checks current_setting('app.tenant_id')
--              which is set by edge functions but NOT by direct Supabase API server clients.
--              This migration adds auth.jwt() ->> 'tenant_id' as a fallback so that
--              API server requests (using user JWT in Authorization header) also satisfy RLS.
--              Edge function behaviour is unchanged — current_setting() still takes priority.
-- Date: 2026-05-21

-- ============================================================================
-- t_client_asset_registry — support both current_setting() and JWT tenant checks
-- ============================================================================

DROP POLICY IF EXISTS "car_tenant_isolation" ON "public"."t_client_asset_registry";

CREATE POLICY "car_tenant_isolation"
    ON "public"."t_client_asset_registry"
    FOR ALL
    USING (
        "tenant_id" = COALESCE(
            NULLIF(current_setting('app.tenant_id', true), '')::uuid,
            (auth.jwt() ->> 'tenant_id')::uuid
        )
    )
    WITH CHECK (
        "tenant_id" = COALESCE(
            NULLIF(current_setting('app.tenant_id', true), '')::uuid,
            (auth.jwt() ->> 'tenant_id')::uuid
        )
    );

-- service_role bypass stays unchanged (idempotent recreate)
DROP POLICY IF EXISTS "car_service_role_bypass" ON "public"."t_client_asset_registry";

CREATE POLICY "car_service_role_bypass"
    ON "public"."t_client_asset_registry"
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- ============================================================================
-- t_idempotency_keys — allow authenticated users to read/write their own records
-- ============================================================================

DROP POLICY IF EXISTS "idempotency_tenant_rw" ON "public"."t_idempotency_keys";

CREATE POLICY "idempotency_tenant_rw"
    ON "public"."t_idempotency_keys"
    FOR ALL
    TO authenticated
    USING ("tenant_id" = (auth.jwt() ->> 'tenant_id')::uuid)
    WITH CHECK ("tenant_id" = (auth.jwt() ->> 'tenant_id')::uuid);
