-- 009_registry_seed_structured.sql
--
-- Buyer registry seeding, restructured to mirror the USER'S OWN pattern.
--
-- PRINCIPLE (owner, 2026-08-01): the registry is selection-driven — the
-- tenant picks what they own on /start/serve — and seeding must keep that
-- (nothing invented), but the OUTPUT must look like what the product's own
-- manual add flow produces, not a flat dump.
--
-- WHAT THE MANUAL FLOW PRODUCES (verified live): hierarchy rows carrying
-- specifications.entity_type ('campus' -> 'building' -> floor/zone/unit,
-- per entityTypeConfig.ts) linked by parent_asset_id, with equipment
-- attached underneath and a human 'location'.
--
-- WHAT THE OLD SEED PRODUCED (verified live, e.g. tenant "setup"): one flat
-- row per picked template — no parents (the done screen's "Campus →
-- Building → Floor → Unit" claim had nothing behind it), every row
-- condition=good/criticality=medium, no location. Rows, not a registry.
--
-- NEW SHAPE — still strictly selection-driven:
--   Main Site (campus)                        ← skeleton, once per tenant
--   └─ Building A (building)                  ← skeleton, once per tenant
--      ├─ <facility pick> (zone)              ← one per picked 'asset' template
--      └─ <equipment pick>                    ← one per picked equipment template,
--         criticality varied by class, located, sample-flagged
--
-- Same signature as before (plus optional p_site_name) — the API caller
-- (seedTenantTemplatesService) needs no change. Idempotency unchanged for
-- template rows (partial unique on tenant_id+template_id for onboarding
-- seeds); skeleton nodes get their own existence checks. is_live stays
-- false (test env), same philosophy as sample contacts.
--
-- Part 2 backfills EXISTING flat-seeded tenants into the same structure.

-- ============================================================================
-- 1. Structured seeding RPC
-- ============================================================================
-- The new optional p_site_name changes the signature, and CREATE OR REPLACE
-- with a different arg list creates an OVERLOAD, not a replacement — the
-- API's 3-named-arg rpc() call would then match both functions and fail as
-- ambiguous. Drop the old signature explicitly first.
DROP FUNCTION IF EXISTS public.seed_onboarding_registry_assets(uuid, uuid[], uuid);

CREATE OR REPLACE FUNCTION public.seed_onboarding_registry_assets(
  p_tenant_id   uuid,
  p_template_ids uuid[],
  p_created_by  uuid DEFAULT NULL::uuid,
  p_site_name   text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_template    RECORD;
  v_seeded      integer := 0;
  v_skipped     integer := 0;
  v_names       text[]  := '{}';
  v_campus_id   uuid;
  v_building_id uuid;
  v_site_name   text := COALESCE(NULLIF(trim(p_site_name), ''), 'Main Site');
  v_criticality text;
  v_is_facility boolean;
BEGIN
  IF p_tenant_id IS NULL OR p_template_ids IS NULL OR array_length(p_template_ids, 1) IS NULL THEN
    RETURN json_build_object('assetsSeeded', 0, 'skipped', 0, 'names', '[]'::json);
  END IF;

  -- ── Skeleton: one campus + one building per tenant (idempotent) ───────────
  SELECT id INTO v_campus_id
  FROM t_client_asset_registry
  WHERE tenant_id = p_tenant_id AND ownership_type = 'self' AND is_live = false
    AND specifications->>'seeded_from' = 'onboarding'
    AND specifications->>'entity_type' = 'campus'
  LIMIT 1;

  IF v_campus_id IS NULL THEN
    INSERT INTO t_client_asset_registry (
      tenant_id, ownership_type, resource_type_id, template_id,
      name, status, condition, criticality,
      specifications, is_active, is_live, created_by, updated_by
    ) VALUES (
      p_tenant_id, 'self', 'asset', NULL,
      v_site_name, 'active', 'good', 'medium',
      jsonb_build_object('seeded_from', 'onboarding', 'entity_type', 'campus', 'is_sample', true),
      true, false, p_created_by, p_created_by
    )
    RETURNING id INTO v_campus_id;
  END IF;

  SELECT id INTO v_building_id
  FROM t_client_asset_registry
  WHERE tenant_id = p_tenant_id AND ownership_type = 'self' AND is_live = false
    AND specifications->>'seeded_from' = 'onboarding'
    AND specifications->>'entity_type' = 'building'
  LIMIT 1;

  IF v_building_id IS NULL THEN
    INSERT INTO t_client_asset_registry (
      tenant_id, ownership_type, resource_type_id, template_id,
      name, status, condition, criticality, parent_asset_id, location,
      specifications, is_active, is_live, created_by, updated_by
    ) VALUES (
      p_tenant_id, 'self', 'asset', NULL,
      'Building A', 'active', 'good', 'medium', v_campus_id, v_site_name,
      jsonb_build_object('seeded_from', 'onboarding', 'entity_type', 'building', 'is_sample', true),
      true, false, p_created_by, p_created_by
    )
    RETURNING id INTO v_building_id;
  END IF;

  -- ── Selection-driven rows, one per picked template ────────────────────────
  FOR v_template IN
    SELECT rt.id, rt.name, rt.resource_type_id
    FROM m_catalog_resource_templates rt
    WHERE rt.id = ANY (p_template_ids)
      AND rt.is_active = true
  LOOP
    BEGIN
      v_is_facility := (v_template.resource_type_id = 'asset');

      -- Plausible criticality by equipment class instead of a wall of 'medium'.
      v_criticality := CASE
        WHEN lower(v_template.name) ~ '(dg set|generator|transformer|elevator|lift|ups|boiler|fire|substation|power plant|oxygen|chiller)'
          THEN 'high'
        WHEN lower(v_template.name) ~ '(parking|washroom|restroom|landscap|garden|signage|pantry)'
          THEN 'low'
        ELSE 'medium'
      END;

      INSERT INTO t_client_asset_registry (
        tenant_id, ownership_type, resource_type_id, template_id,
        name, status, condition, criticality, parent_asset_id, location,
        specifications, is_active, is_live, created_by, updated_by
      )
      VALUES (
        p_tenant_id, 'self', v_template.resource_type_id, v_template.id,
        v_template.name, 'active', 'good', v_criticality,
        v_building_id, 'Building A · ' || v_site_name,
        jsonb_build_object(
          'seeded_from', 'onboarding',
          'resource_template_id', v_template.id,
          'resource_template_name', v_template.name,
          'is_sample', true
        )
        -- Facility picks become hierarchy nodes the entity views understand;
        -- 'zone' is valid under a building per entityTypeConfig.
        || CASE WHEN v_is_facility THEN jsonb_build_object('entity_type', 'zone') ELSE '{}'::jsonb END,
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
    'names',        to_json(v_names),
    'campusId',     v_campus_id,
    'buildingId',   v_building_id
  );
END;
$function$;

-- ============================================================================
-- 2. Backfill: restructure EXISTING flat-seeded tenants into the same shape
-- ============================================================================
-- Only touches onboarding-seeded, self-owned, test-env rows that have no
-- parent — i.e. exactly the flat dump the old RPC produced. Manual rows and
-- anything the tenant edited into a hierarchy are untouched.
DO $$
DECLARE
  v_tenant RECORD;
  v_campus_id   uuid;
  v_building_id uuid;
BEGIN
  FOR v_tenant IN
    SELECT DISTINCT tenant_id
    FROM t_client_asset_registry
    WHERE ownership_type = 'self' AND is_live = false
      AND specifications->>'seeded_from' = 'onboarding'
      AND parent_asset_id IS NULL
      AND specifications->>'entity_type' IS NULL   -- flat template rows only
  LOOP
    -- skeleton (reuse if a prior run created it)
    SELECT id INTO v_campus_id FROM t_client_asset_registry
    WHERE tenant_id = v_tenant.tenant_id AND ownership_type='self' AND is_live=false
      AND specifications->>'seeded_from'='onboarding' AND specifications->>'entity_type'='campus'
    LIMIT 1;
    IF v_campus_id IS NULL THEN
      INSERT INTO t_client_asset_registry (
        tenant_id, ownership_type, resource_type_id, template_id, name, status,
        condition, criticality, specifications, is_active, is_live
      ) VALUES (
        v_tenant.tenant_id, 'self', 'asset', NULL, 'Main Site', 'active',
        'good', 'medium',
        jsonb_build_object('seeded_from','onboarding','entity_type','campus','is_sample',true),
        true, false
      ) RETURNING id INTO v_campus_id;
    END IF;

    SELECT id INTO v_building_id FROM t_client_asset_registry
    WHERE tenant_id = v_tenant.tenant_id AND ownership_type='self' AND is_live=false
      AND specifications->>'seeded_from'='onboarding' AND specifications->>'entity_type'='building'
    LIMIT 1;
    IF v_building_id IS NULL THEN
      INSERT INTO t_client_asset_registry (
        tenant_id, ownership_type, resource_type_id, template_id, name, status,
        condition, criticality, parent_asset_id, location, specifications, is_active, is_live
      ) VALUES (
        v_tenant.tenant_id, 'self', 'asset', NULL, 'Building A', 'active',
        'good', 'medium', v_campus_id, 'Main Site',
        jsonb_build_object('seeded_from','onboarding','entity_type','building','is_sample',true),
        true, false
      ) RETURNING id INTO v_building_id;
    END IF;

    -- attach the flat rows: facility templates become zone nodes, equipment
    -- gets varied criticality + a location; all marked is_sample
    UPDATE t_client_asset_registry r
    SET parent_asset_id = v_building_id,
        location = COALESCE(r.location, 'Building A · Main Site'),
        criticality = CASE
          WHEN lower(r.name) ~ '(dg set|generator|transformer|elevator|lift|ups|boiler|fire|substation|power plant|oxygen|chiller)' THEN 'high'
          WHEN lower(r.name) ~ '(parking|washroom|restroom|landscap|garden|signage|pantry)' THEN 'low'
          ELSE r.criticality
        END,
        specifications = r.specifications
          || jsonb_build_object('is_sample', true)
          || CASE WHEN r.resource_type_id = 'asset'
                  THEN jsonb_build_object('entity_type','zone') ELSE '{}'::jsonb END,
        updated_at = now()
    WHERE r.tenant_id = v_tenant.tenant_id
      AND r.ownership_type = 'self' AND r.is_live = false
      AND r.specifications->>'seeded_from' = 'onboarding'
      AND r.parent_asset_id IS NULL
      AND r.specifications->>'entity_type' IS NULL;
  END LOOP;
END $$;
