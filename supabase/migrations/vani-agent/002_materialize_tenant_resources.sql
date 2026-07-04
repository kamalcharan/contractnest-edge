-- ============================================================================
-- Resources materialization (owner decision 2026-07-02):
--   1) Onboarding puts the tenant's PICKED equipment/facilities into Resources
--      (t_category_resources_master) — the tenant's working set.
--   2) Catalog-studio picks dependencies from Resources, not Business Profile.
--
-- This migration:
--   a) creates materialize_tenant_resources(p_tenant_id) — SECURITY DEFINER,
--      idempotent: inserts one Resources row per DISTINCT selected template
--      that has no same-name row of the same type yet. Called by the API
--      right after onboarding selections are persisted (and by reseed).
--   b) backfills ALL existing tenants once (fixes hubb's empty Resources).
--
-- ⚠️ OWNER-APPLIED ONLY via Supabase SQL editor. Creates new objects +
--    inserts missing rows; modifies/deletes nothing.
-- ============================================================================

CREATE OR REPLACE FUNCTION "public"."materialize_tenant_resources"(
    p_tenant_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_inserted INTEGER := 0;
BEGIN
    INSERT INTO t_category_resources_master (
        id, tenant_id, resource_type_id, name, display_name, description,
        sub_category, sequence_no, is_active, is_deletable, is_live,
        created_at, updated_at
    )
    SELECT
        gen_random_uuid(),
        p_tenant_id,
        rt.resource_type_id,
        rt.name,
        rt.name,
        rt.description,
        rt.sub_category,
        COALESCE(rt.sort_order, 100),
        true,
        true,
        true,
        now(),
        now()
    FROM (
        SELECT DISTINCT resource_template_id
        FROM t_tenant_selected_resources
        WHERE tenant_id = p_tenant_id
    ) tsr
    JOIN m_catalog_resource_templates rt ON rt.id = tsr.resource_template_id
    WHERE rt.is_active = true
      AND NOT EXISTS (
        SELECT 1 FROM t_category_resources_master m
        WHERE m.tenant_id = p_tenant_id
          AND lower(m.name) = lower(rt.name)
          AND m.resource_type_id = rt.resource_type_id
          AND m.is_live = true
      );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    RETURN json_build_object('resourcesMaterialized', v_inserted);
END;
$$;

-- API authenticates with the anon key (auditService pattern); onboarding
-- runs as the authenticated user.
GRANT EXECUTE ON FUNCTION materialize_tenant_resources(UUID) TO anon, authenticated;

COMMENT ON FUNCTION materialize_tenant_resources(UUID) IS
  'Materializes a tenant''s onboarding-selected resource templates into t_category_resources_master (idempotent). Called after persistSelectedResources and on reseed.';

-- ── One-time backfill for ALL existing tenants with unmaterialized picks ────
DO $$
DECLARE
    v_tenant UUID;
    v_total  INTEGER := 0;
    v_result JSON;
BEGIN
    FOR v_tenant IN (SELECT DISTINCT tenant_id FROM t_tenant_selected_resources)
    LOOP
        v_result := materialize_tenant_resources(v_tenant);
        v_total := v_total + (v_result->>'resourcesMaterialized')::int;
    END LOOP;
    RAISE NOTICE 'Backfill complete: % resources materialized across tenants', v_total;
END $$;

-- Verify hubb (should now list HVAC System, DG Set, Elevator/Lift, UPS, …):
-- SELECT resource_type_id, name, sub_category
-- FROM t_category_resources_master
-- WHERE tenant_id = '1f0a8dd2-d467-458f-8598-fe5c69548d7e' AND is_live = true
-- ORDER BY resource_type_id, name;
