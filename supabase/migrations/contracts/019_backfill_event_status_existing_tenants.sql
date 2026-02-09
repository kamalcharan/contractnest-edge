-- ============================================================================
-- Migration 019: Backfill Event Status Defaults for Existing Tenants
-- ============================================================================
-- Purpose: One-time migration to seed event status config for all existing
--          tenants. New tenants get this automatically during onboarding.
-- Depends on: 018_event_status_config.sql (tables + system defaults + seed RPC)
-- Safe to re-run: Yes (seed_event_status_defaults uses ON CONFLICT DO NOTHING)
-- ============================================================================

-- Call seed_event_status_defaults for every active tenant
-- This copies system defaults (tenant_id IS NULL) into tenant-specific rows
DO $$
DECLARE
    v_tenant RECORD;
    v_result JSONB;
    v_total_tenants INT := 0;
    v_total_statuses INT := 0;
    v_total_transitions INT := 0;
BEGIN
    RAISE NOTICE '=== Starting event status backfill for existing tenants ===';

    FOR v_tenant IN
        SELECT id, name
        FROM t_tenants
        WHERE status = 'active'
        ORDER BY created_at
    LOOP
        v_result := seed_event_status_defaults(v_tenant.id);

        v_total_tenants := v_total_tenants + 1;
        v_total_statuses := v_total_statuses + COALESCE((v_result->>'statuses_seeded')::INT, 0);
        v_total_transitions := v_total_transitions + COALESCE((v_result->>'transitions_seeded')::INT, 0);

        RAISE NOTICE 'Tenant [%] %: % statuses, % transitions',
            v_tenant.id,
            v_tenant.name,
            v_result->>'statuses_seeded',
            v_result->>'transitions_seeded';
    END LOOP;

    RAISE NOTICE '=== Backfill complete: % tenants, % statuses, % transitions ===',
        v_total_tenants, v_total_statuses, v_total_transitions;
END;
$$;
