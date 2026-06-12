-- Sprint 1 / Buyer persona — Template-driven registry seeding (founder design)
-- Replaces the consent-blind placeholder hierarchy (seed_onboarding_facility_nodes,
-- which ignored the buyer's picks and seeded a generic site/building/floor tree)
-- with seeding driven by the resource templates the buyer actually consented to:
--   resource_type_id = 'equipment' → appears in /equipment-registry
--   resource_type_id = 'asset'     → appears in /facility-registry
-- Rows land with is_live = false; Screen8BEquipmentStep promotes them to
-- is_live = true on confirmation (existing pattern, unchanged).
--
-- Idempotency: one row per (tenant, template, ownership self) seeded from
-- onboarding — re-running skips templates already seeded. Safe under concurrent
-- retries via the unique partial index below (INSERT ... ON CONFLICT DO NOTHING).

-- Race-condition guard for double-submitted onboarding seeds
CREATE UNIQUE INDEX IF NOT EXISTS ux_car_onboarding_seed_template
  ON t_client_asset_registry (tenant_id, template_id)
  WHERE ownership_type = 'self'
    AND (specifications ->> 'seeded_from') = 'onboarding';

CREATE OR REPLACE FUNCTION seed_onboarding_registry_assets(
  p_tenant_id    uuid,
  p_template_ids uuid[],
  p_created_by   uuid DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_template RECORD;
  v_seeded   integer := 0;
  v_skipped  integer := 0;
  v_names    text[]  := '{}';
BEGIN
  IF p_tenant_id IS NULL OR p_template_ids IS NULL OR array_length(p_template_ids, 1) IS NULL THEN
    RETURN json_build_object('assetsSeeded', 0, 'skipped', 0, 'names', '[]'::json);
  END IF;

  FOR v_template IN
    SELECT rt.id, rt.name, rt.resource_type_id
    FROM m_catalog_resource_templates rt
    WHERE rt.id = ANY (p_template_ids)
      AND rt.is_active = true
  LOOP
    BEGIN
      INSERT INTO t_client_asset_registry (
        tenant_id, ownership_type, resource_type_id, template_id,
        name, status, condition, criticality,
        specifications, is_active, is_live,
        created_by, updated_by
      )
      VALUES (
        p_tenant_id, 'self', v_template.resource_type_id, v_template.id,
        v_template.name, 'active', 'good', 'medium',
        jsonb_build_object(
          'seeded_from', 'onboarding',
          'resource_template_id', v_template.id,
          'resource_template_name', v_template.name
        ),
        true, false,
        p_created_by, p_created_by
      )
      ON CONFLICT (tenant_id, template_id)
        WHERE ownership_type = 'self' AND (specifications ->> 'seeded_from') = 'onboarding'
        DO NOTHING;

      IF FOUND THEN
        v_seeded := v_seeded + 1;
        v_names := array_append(v_names, v_template.name);
      ELSE
        v_skipped := v_skipped + 1;
      END IF;
    EXCEPTION WHEN unique_violation THEN
      v_skipped := v_skipped + 1;
    END;
  END LOOP;

  RETURN json_build_object(
    'assetsSeeded', v_seeded,
    'skipped',      v_skipped,
    'names',        to_json(v_names)
  );
END;
$$;

COMMENT ON FUNCTION seed_onboarding_registry_assets(uuid, uuid[], uuid) IS
  'Sprint 1 buyer-persona seed: inserts one self-owned registry entry per consented resource template (equipment → /equipment-registry, asset → /facility-registry), is_live=false until Screen8B confirmation. Idempotent per (tenant, template). Supersedes seed_onboarding_facility_nodes for onboarding.';

COMMENT ON COLUMN t_client_asset_registry.template_id IS
  'FK-by-convention to m_catalog_resource_templates.id when the asset was created from a template (incl. onboarding seeds). Lineage column for asset → resource template traversal.';
