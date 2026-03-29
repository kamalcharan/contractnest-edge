-- =============================================================
-- TEMPLATE MANAGEMENT: Copy Template to Tenant
-- Migration: templates/003_copy_template_rpc.sql
-- Function: copy_template_to_tenant
--
-- Purpose: Copies a system/global/public template into a tenant's
--          own space. Sets copied_from_id for lineage tracking.
--          Tenant gets full ownership of the copy (can edit/delete).
--
-- Use cases:
--   1. Admin publishes a system template → tenant copies to customize
--   2. Tenant sees a public template in gallery → copies to their space
-- =============================================================

CREATE OR REPLACE FUNCTION copy_template_to_tenant(
    p_source_template_id UUID,
    p_tenant_id UUID,
    p_created_by UUID,
    p_is_live BOOLEAN DEFAULT true,
    p_name_override VARCHAR DEFAULT NULL,       -- optional rename on copy
    p_idempotency_key VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_source RECORD;
    v_new_id UUID;
    v_new_name VARCHAR;
    v_idempotency RECORD;
    v_response JSONB;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_source_template_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'source_template_id is required'
        );
    END IF;

    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Idempotency check
    -- ═══════════════════════════════════════════
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_idempotency
        FROM check_idempotency(
            p_idempotency_key,
            p_tenant_id,
            'copy_template_to_tenant'
        );

        IF v_idempotency.found THEN
            RETURN v_idempotency.response_body;
        END IF;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Fetch source template (verify access)
    --   Can copy from: system templates, public templates, own tenant templates
    -- ═══════════════════════════════════════════
    SELECT * INTO v_source
    FROM t_cat_templates
    WHERE id = p_source_template_id
      AND is_active = true
      AND (
          (tenant_id IS NULL AND is_system = true)
          OR is_public = true
          OR tenant_id = p_tenant_id
      );

    IF v_source IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Source template not found or access denied',
            'source_template_id', p_source_template_id
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Generate copy name
    -- ═══════════════════════════════════════════
    IF p_name_override IS NOT NULL AND TRIM(p_name_override) <> '' THEN
        v_new_name := TRIM(p_name_override);
    ELSE
        v_new_name := v_source.name || ' (Copy)';
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 4: Insert copy into tenant's space
    --   Key differences from source:
    --   - tenant_id = target tenant (not NULL/source)
    --   - is_system = false (tenant-owned)
    --   - copied_from_id = source template id (lineage)
    --   - version = 1 (fresh start)
    --   - is_deletable = true (tenant can delete their copy)
    -- ═══════════════════════════════════════════
    INSERT INTO t_cat_templates (
        tenant_id,
        is_live,
        name,
        display_name,
        description,
        category,
        tags,
        cover_image,
        blocks,
        currency,
        tax_rate,
        discount_config,
        subtotal,
        total,
        settings,
        is_system,
        copied_from_id,
        industry_tags,
        is_public,
        is_active,
        status_id,
        version,
        sequence_no,
        is_deletable,
        created_by,
        updated_by
    )
    VALUES (
        p_tenant_id,                                -- tenant owns the copy
        p_is_live,
        v_new_name,
        COALESCE(v_source.display_name, v_new_name),
        v_source.description,
        v_source.category,
        COALESCE(v_source.tags, '[]'::JSONB),
        v_source.cover_image,
        COALESCE(v_source.blocks, '[]'::JSONB),     -- deep copy of blocks JSONB
        v_source.currency,
        v_source.tax_rate,
        COALESCE(v_source.discount_config, '{"allowed": true, "max_percent": 20}'::JSONB),
        v_source.subtotal,
        v_source.total,
        COALESCE(v_source.settings, '{}'::JSONB),
        false,                                       -- NOT system — tenant owned
        p_source_template_id,                        -- lineage tracking
        COALESCE(v_source.industry_tags, '[]'::JSONB),
        false,                                       -- private by default
        true,
        v_source.status_id,
        1,                                           -- fresh version
        0,
        true,                                        -- tenant can delete their copy
        p_created_by,
        p_created_by
    )
    RETURNING id INTO v_new_id;

    -- ═══════════════════════════════════════════
    -- STEP 5: Build response
    -- ═══════════════════════════════════════════
    v_response := jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', v_new_id,
            'tenant_id', p_tenant_id,
            'name', v_new_name,
            'copied_from_id', p_source_template_id,
            'source_template_name', v_source.name,
            'source_was_system', v_source.is_system,
            'blocks_count', COALESCE(jsonb_array_length(v_source.blocks), 0),
            'version', 1,
            'is_live', p_is_live,
            'created_by', p_created_by,
            'created_at', NOW()
        ),
        'created_at', NOW()
    );

    -- Store idempotency
    IF p_idempotency_key IS NOT NULL THEN
        PERFORM store_idempotency(
            p_idempotency_key,
            p_tenant_id,
            'copy_template_to_tenant',
            'POST',
            NULL,
            200,
            v_response,
            24
        );
    END IF;

    RETURN v_response;

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to copy template',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION copy_template_to_tenant(UUID, UUID, UUID, BOOLEAN, VARCHAR, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION copy_template_to_tenant(UUID, UUID, UUID, BOOLEAN, VARCHAR, VARCHAR) TO service_role;

-- ─────────────────────────────────────────────────────────────
-- Comments
-- ─────────────────────────────────────────────────────────────
COMMENT ON FUNCTION copy_template_to_tenant IS 'Copies a system/public/own template into a tenant space. The copy is fully owned by the tenant (editable, deletable). copied_from_id tracks lineage back to the source template.';
