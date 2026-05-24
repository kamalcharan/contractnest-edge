-- Migration: SECURITY DEFINER RPC for onboarding facility node seeding
-- Description: Inserts placeholder facility hierarchy nodes into t_client_asset_registry
--              during buyer onboarding. Runs as the DB owner so RLS is bypassed.
--              Called via supabase.rpc() from the API server using the anon key.
-- Date: 2026-05-21

-- ============================================================================
-- FUNCTION: seed_onboarding_facility_nodes
-- ============================================================================
-- Parameters:
--   p_tenant_id   UUID  — the buyer tenant being onboarded
--   p_industry_id TEXT  — e.g. 'healthcare', 'facility_management'
--
-- Returns: JSON { facilityNodesSeeded: int, skipped: bool }
--
-- Safety: Checks for existing placeholders before inserting (idempotent).
-- ============================================================================

CREATE OR REPLACE FUNCTION "public"."seed_onboarding_facility_nodes"(
    p_tenant_id   UUID,
    p_industry_id TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_existing_count  INTEGER;
    v_template        RECORD;
    v_level_ids       JSONB := '{}';
    v_node_id         UUID;
    v_parent_id       UUID;
    v_parent_key      TEXT;
    v_seeded          INTEGER := 0;
BEGIN
    -- Idempotency: skip if placeholders already exist for this tenant
    SELECT COUNT(*) INTO v_existing_count
    FROM t_client_asset_registry
    WHERE tenant_id = p_tenant_id
      AND ownership_type = 'self'
      AND (specifications ->> 'is_placeholder')::boolean = true;

    IF v_existing_count > 0 THEN
        RETURN json_build_object(
            'facilityNodesSeeded', v_existing_count,
            'skipped', true
        );
    END IF;

    -- Insert one placeholder node per hierarchy level in order
    FOR v_template IN
        SELECT *
        FROM m_facility_hierarchy_templates
        WHERE industry_id = p_industry_id
          AND is_default   = true
        ORDER BY level ASC
    LOOP
        v_node_id := gen_random_uuid();

        -- Resolve parent UUID from level map
        v_parent_id := NULL;
        IF v_template.level > 1 THEN
            v_parent_key := (v_template.level - 1)::text;
            IF v_level_ids ? v_parent_key THEN
                v_parent_id := (v_level_ids ->> v_parent_key)::uuid;
            END IF;
        END IF;

        INSERT INTO t_client_asset_registry (
            id,
            tenant_id,
            owner_contact_id,
            ownership_type,
            resource_type_id,
            name,
            status,
            condition,
            criticality,
            parent_asset_id,
            is_live,
            is_active,
            specifications
        ) VALUES (
            v_node_id,
            p_tenant_id,
            NULL,                         -- self-owned, no contact owner
            'self',
            'asset',
            v_template.label,
            'active',
            'good',
            'low',
            v_parent_id,
            false,                        -- is_live=false until tenant confirms
            true,
            jsonb_build_object(
                'entity_type',      v_template.entity_type,
                'industry_id',      p_industry_id,
                'hierarchy_level',  v_template.level,
                'is_placeholder',   true
            )
        );

        -- Track this level's UUID for child nodes to reference as parent
        v_level_ids := v_level_ids || jsonb_build_object(v_template.level::text, v_node_id::text);
        v_seeded := v_seeded + 1;
    END LOOP;

    RETURN json_build_object(
        'facilityNodesSeeded', v_seeded,
        'skipped', false
    );
END;
$$;

-- ============================================================================
-- GRANTS
-- ============================================================================
-- Allow the API server (anon key → anon role, or user JWT → authenticated role)
-- to call this function. SECURITY DEFINER ensures the INSERT bypasses RLS.

GRANT EXECUTE ON FUNCTION "public"."seed_onboarding_facility_nodes"(UUID, TEXT)
    TO anon, authenticated, service_role;
