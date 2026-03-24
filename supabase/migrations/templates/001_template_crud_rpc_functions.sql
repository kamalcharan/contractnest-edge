-- =============================================================
-- TEMPLATE MANAGEMENT: CRUD RPC Functions
-- Migration: templates/001_template_crud_rpc_functions.sql
-- Functions: get_templates_list, get_template_by_id,
--            create_template_transaction, update_template_transaction,
--            delete_template_soft
-- Table: m_cat_templates (already exists via catalog-studio + global-templates)
-- =============================================================


-- ─────────────────────────────────────────────────────────────
-- 1. get_templates_list
--    Paginated list with filters, JSON shaping in Postgres
--    SECURITY DEFINER for hot-path read (patterns-rls.md)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_templates_list(
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true,
    p_category VARCHAR DEFAULT NULL,          -- filter by category
    p_status_id UUID DEFAULT NULL,            -- filter by status
    p_is_system BOOLEAN DEFAULT NULL,         -- NULL = all, true = system only, false = tenant only
    p_search VARCHAR DEFAULT NULL,            -- search name / display_name / description
    p_page INTEGER DEFAULT 1,
    p_per_page INTEGER DEFAULT 20,
    p_sort_by VARCHAR DEFAULT 'created_at',   -- created_at | name | category | total | sequence_no
    p_sort_order VARCHAR DEFAULT 'desc'       -- asc | desc
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_total INTEGER;
    v_total_pages INTEGER;
    v_offset INTEGER;
    v_templates JSONB;
    v_query TEXT;
    v_count_query TEXT;
    v_where TEXT := '';
    v_order TEXT;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    -- Clamp pagination (patterns-scale.md: max 100)
    p_page := GREATEST(p_page, 1);
    p_per_page := LEAST(GREATEST(p_per_page, 1), 100);
    v_offset := (p_page - 1) * p_per_page;

    -- ═══════════════════════════════════════════
    -- STEP 1: Build WHERE clause
    --   Tenant sees: own templates + system templates + public templates
    --   Matches RLS logic but in SECURITY DEFINER for performance
    -- ═══════════════════════════════════════════
    v_where := format(
        'WHERE t.is_active = true AND t.is_live = %L AND (t.tenant_id = %L OR (t.tenant_id IS NULL AND t.is_system = true) OR t.is_public = true)',
        p_is_live, p_tenant_id
    );

    IF p_category IS NOT NULL THEN
        v_where := v_where || format(' AND t.category = %L', p_category);
    END IF;

    IF p_status_id IS NOT NULL THEN
        v_where := v_where || format(' AND t.status_id = %L', p_status_id);
    END IF;

    IF p_is_system IS NOT NULL THEN
        v_where := v_where || format(' AND t.is_system = %L', p_is_system);
    END IF;

    IF p_search IS NOT NULL AND TRIM(p_search) <> '' THEN
        v_where := v_where || format(
            ' AND (t.name ILIKE %L OR t.display_name ILIKE %L OR t.description ILIKE %L)',
            '%' || TRIM(p_search) || '%',
            '%' || TRIM(p_search) || '%',
            '%' || TRIM(p_search) || '%'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Build ORDER BY
    -- ═══════════════════════════════════════════
    v_order := CASE p_sort_by
        WHEN 'name' THEN 't.name'
        WHEN 'category' THEN 't.category'
        WHEN 'total' THEN 't.total'
        WHEN 'sequence_no' THEN 't.sequence_no'
        ELSE 't.created_at'
    END;

    v_order := v_order || CASE WHEN LOWER(p_sort_order) = 'asc' THEN ' ASC' ELSE ' DESC' END;

    -- ═══════════════════════════════════════════
    -- STEP 3: Get total count
    -- ═══════════════════════════════════════════
    v_count_query := 'SELECT COUNT(*) FROM m_cat_templates t ' || v_where;
    EXECUTE v_count_query INTO v_total;

    v_total_pages := CEIL(v_total::NUMERIC / p_per_page);

    -- ═══════════════════════════════════════════
    -- STEP 4: Fetch paginated templates with JSON shaping
    -- ═══════════════════════════════════════════
    v_query := format(
        'SELECT COALESCE(jsonb_agg(row_data ORDER BY rn), ''[]''::JSONB)
         FROM (
             SELECT
                 ROW_NUMBER() OVER (ORDER BY %s) as rn,
                 jsonb_build_object(
                     ''id'', t.id,
                     ''tenant_id'', t.tenant_id,
                     ''name'', t.name,
                     ''display_name'', t.display_name,
                     ''description'', t.description,
                     ''category'', t.category,
                     ''tags'', COALESCE(t.tags, ''[]''::JSONB),
                     ''cover_image'', t.cover_image,
                     ''currency'', t.currency,
                     ''tax_rate'', t.tax_rate,
                     ''subtotal'', t.subtotal,
                     ''total'', t.total,
                     ''is_system'', t.is_system,
                     ''is_public'', t.is_public,
                     ''copied_from_id'', t.copied_from_id,
                     ''industry_tags'', COALESCE(t.industry_tags, ''[]''::JSONB),
                     ''status_id'', t.status_id,
                     ''version'', t.version,
                     ''sequence_no'', t.sequence_no,
                     ''is_live'', t.is_live,
                     ''created_by'', t.created_by,
                     ''created_at'', t.created_at,
                     ''updated_at'', t.updated_at,
                     ''blocks_count'', COALESCE(jsonb_array_length(t.blocks), 0)
                 ) AS row_data
             FROM m_cat_templates t
             %s
             ORDER BY %s
             LIMIT %s OFFSET %s
         ) sub',
        v_order,
        v_where,
        v_order,
        p_per_page,
        v_offset
    );

    EXECUTE v_query INTO v_templates;

    -- ═══════════════════════════════════════════
    -- STEP 5: Return response
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', COALESCE(v_templates, '[]'::JSONB),
        'pagination', jsonb_build_object(
            'page', p_page,
            'per_page', p_per_page,
            'total', v_total,
            'total_pages', v_total_pages
        ),
        'filters', jsonb_build_object(
            'category', p_category,
            'status_id', p_status_id,
            'is_system', p_is_system,
            'search', p_search,
            'sort_by', p_sort_by,
            'sort_order', p_sort_order
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch templates',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_templates_list(UUID, BOOLEAN, VARCHAR, UUID, BOOLEAN, VARCHAR, INTEGER, INTEGER, VARCHAR, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION get_templates_list(UUID, BOOLEAN, VARCHAR, UUID, BOOLEAN, VARCHAR, INTEGER, INTEGER, VARCHAR, VARCHAR) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 2. get_template_by_id
--    Single template with full block details expanded
--    SECURITY DEFINER for hot-path read
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_template_by_id(
    p_template_id UUID,
    p_tenant_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_template RECORD;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_template_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'template_id is required'
        );
    END IF;

    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Fetch template
    --   Access: own tenant OR system/global OR public
    -- ═══════════════════════════════════════════
    SELECT * INTO v_template
    FROM m_cat_templates
    WHERE id = p_template_id
      AND is_active = true
      AND (
          tenant_id = p_tenant_id
          OR (tenant_id IS NULL AND is_system = true)
          OR is_public = true
      );

    IF v_template IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Template not found',
            'template_id', p_template_id
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Return full template with all fields
    --   blocks JSONB is stored directly on the template row
    --   (not a junction table like contracts)
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', v_template.id,
            'tenant_id', v_template.tenant_id,
            'name', v_template.name,
            'display_name', v_template.display_name,
            'description', v_template.description,
            'category', v_template.category,
            'tags', COALESCE(v_template.tags, '[]'::JSONB),
            'cover_image', v_template.cover_image,

            -- Block Assembly
            'blocks', COALESCE(v_template.blocks, '[]'::JSONB),
            'blocks_count', COALESCE(jsonb_array_length(v_template.blocks), 0),

            -- Pricing
            'currency', v_template.currency,
            'tax_rate', v_template.tax_rate,
            'discount_config', COALESCE(v_template.discount_config, '{}'::JSONB),
            'subtotal', v_template.subtotal,
            'total', v_template.total,

            -- Settings
            'settings', COALESCE(v_template.settings, '{}'::JSONB),

            -- System/Admin
            'is_system', v_template.is_system,
            'is_public', v_template.is_public,
            'copied_from_id', v_template.copied_from_id,
            'industry_tags', COALESCE(v_template.industry_tags, '[]'::JSONB),

            -- Status & Version
            'status_id', v_template.status_id,
            'version', v_template.version,
            'sequence_no', v_template.sequence_no,
            'is_live', v_template.is_live,
            'is_deletable', v_template.is_deletable,

            -- Audit
            'created_by', v_template.created_by,
            'updated_by', v_template.updated_by,
            'created_at', v_template.created_at,
            'updated_at', v_template.updated_at
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch template',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_template_by_id(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_template_by_id(UUID, UUID) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 3. create_template_transaction
--    Atomic create with idempotency
--    Follows create_contract_transaction pattern
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_template_transaction(
    p_payload JSONB,
    p_idempotency_key VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    -- Extracted fields
    v_tenant_id UUID;
    v_is_live BOOLEAN;
    v_created_by UUID;
    v_is_system BOOLEAN;

    -- Result
    v_template_id UUID;
    v_template RECORD;

    -- Idempotency
    v_idempotency RECORD;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    v_tenant_id := (p_payload->>'tenant_id')::UUID;
    v_is_live := COALESCE((p_payload->>'is_live')::BOOLEAN, true);
    v_created_by := (p_payload->>'created_by')::UUID;
    v_is_system := COALESCE((p_payload->>'is_system')::BOOLEAN, false);

    -- System templates have NULL tenant_id; tenant templates require tenant_id
    IF v_is_system = false AND v_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required for non-system templates'
        );
    END IF;

    IF p_payload->>'name' IS NULL OR TRIM(p_payload->>'name') = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Template name is required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Idempotency check
    -- ═══════════════════════════════════════════
    IF p_idempotency_key IS NOT NULL AND v_tenant_id IS NOT NULL THEN
        SELECT * INTO v_idempotency
        FROM check_idempotency(
            p_idempotency_key,
            v_tenant_id,
            'create_template_transaction'
        );

        IF v_idempotency.found THEN
            RETURN v_idempotency.response_body;
        END IF;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Insert template
    -- ═══════════════════════════════════════════
    INSERT INTO m_cat_templates (
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
        CASE WHEN v_is_system THEN NULL ELSE v_tenant_id END,
        v_is_live,
        TRIM(p_payload->>'name'),
        p_payload->>'display_name',
        p_payload->>'description',
        p_payload->>'category',
        COALESCE(p_payload->'tags', '[]'::JSONB),
        p_payload->>'cover_image',
        COALESCE(p_payload->'blocks', '[]'::JSONB),
        COALESCE(p_payload->>'currency', 'INR'),
        COALESCE((p_payload->>'tax_rate')::DECIMAL, 18.00),
        COALESCE(p_payload->'discount_config', '{"allowed": true, "max_percent": 20}'::JSONB),
        (p_payload->>'subtotal')::DECIMAL,
        (p_payload->>'total')::DECIMAL,
        COALESCE(p_payload->'settings', '{}'::JSONB),
        v_is_system,
        (p_payload->>'copied_from_id')::UUID,
        COALESCE(p_payload->'industry_tags', '[]'::JSONB),
        COALESCE((p_payload->>'is_public')::BOOLEAN, false),
        true,
        (p_payload->>'status_id')::UUID,
        1,
        COALESCE((p_payload->>'sequence_no')::INTEGER, 0),
        COALESCE((p_payload->>'is_deletable')::BOOLEAN, true),
        v_created_by,
        v_created_by
    )
    RETURNING id INTO v_template_id;

    -- ═══════════════════════════════════════════
    -- STEP 3: Fetch created template for response
    -- ═══════════════════════════════════════════
    SELECT * INTO v_template
    FROM m_cat_templates
    WHERE id = v_template_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Build success response
    -- ═══════════════════════════════════════════
    DECLARE
        v_response JSONB;
    BEGIN
        v_response := jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'id', v_template.id,
                'tenant_id', v_template.tenant_id,
                'name', v_template.name,
                'display_name', v_template.display_name,
                'description', v_template.description,
                'category', v_template.category,
                'tags', COALESCE(v_template.tags, '[]'::JSONB),
                'cover_image', v_template.cover_image,
                'blocks', COALESCE(v_template.blocks, '[]'::JSONB),
                'blocks_count', COALESCE(jsonb_array_length(v_template.blocks), 0),
                'currency', v_template.currency,
                'tax_rate', v_template.tax_rate,
                'discount_config', COALESCE(v_template.discount_config, '{}'::JSONB),
                'subtotal', v_template.subtotal,
                'total', v_template.total,
                'settings', COALESCE(v_template.settings, '{}'::JSONB),
                'is_system', v_template.is_system,
                'is_public', v_template.is_public,
                'copied_from_id', v_template.copied_from_id,
                'industry_tags', COALESCE(v_template.industry_tags, '[]'::JSONB),
                'status_id', v_template.status_id,
                'version', v_template.version,
                'is_live', v_template.is_live,
                'created_by', v_template.created_by,
                'created_at', v_template.created_at
            ),
            'created_at', NOW()
        );

        -- Store idempotency (if key provided)
        IF p_idempotency_key IS NOT NULL AND v_tenant_id IS NOT NULL THEN
            PERFORM store_idempotency(
                p_idempotency_key,
                v_tenant_id,
                'create_template_transaction',
                'POST',
                NULL,
                200,
                v_response,
                24
            );
        END IF;

        RETURN v_response;
    END;

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to create template',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION create_template_transaction(JSONB, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION create_template_transaction(JSONB, VARCHAR) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 4. update_template_transaction
--    Update with optimistic concurrency (version check)
--    Short transaction per patterns-correctness.md
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_template_transaction(
    p_template_id UUID,
    p_tenant_id UUID,
    p_payload JSONB,
    p_expected_version INTEGER DEFAULT NULL,
    p_idempotency_key VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current RECORD;
    v_updated_by UUID;
    v_idempotency RECORD;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_template_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'template_id is required'
        );
    END IF;

    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    v_updated_by := (p_payload->>'updated_by')::UUID;

    -- ═══════════════════════════════════════════
    -- STEP 1: Idempotency check
    -- ═══════════════════════════════════════════
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_idempotency
        FROM check_idempotency(
            p_idempotency_key,
            p_tenant_id,
            'update_template_transaction'
        );

        IF v_idempotency.found THEN
            RETURN v_idempotency.response_body;
        END IF;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Fetch current template & verify ownership
    -- ═══════════════════════════════════════════
    SELECT * INTO v_current
    FROM m_cat_templates
    WHERE id = p_template_id
      AND is_active = true
      AND (tenant_id = p_tenant_id OR tenant_id IS NULL);

    IF v_current IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Template not found or access denied',
            'template_id', p_template_id
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Optimistic concurrency check
    -- ═══════════════════════════════════════════
    IF p_expected_version IS NOT NULL AND v_current.version <> p_expected_version THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Version conflict — template was modified by another user',
            'current_version', v_current.version,
            'expected_version', p_expected_version
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 4: Update only provided fields (COALESCE preserves existing)
    -- ═══════════════════════════════════════════
    UPDATE m_cat_templates
    SET
        name            = COALESCE(NULLIF(TRIM(p_payload->>'name'), ''), name),
        display_name    = CASE WHEN p_payload ? 'display_name' THEN p_payload->>'display_name' ELSE display_name END,
        description     = CASE WHEN p_payload ? 'description' THEN p_payload->>'description' ELSE description END,
        category        = CASE WHEN p_payload ? 'category' THEN p_payload->>'category' ELSE category END,
        tags            = CASE WHEN p_payload ? 'tags' THEN p_payload->'tags' ELSE tags END,
        cover_image     = CASE WHEN p_payload ? 'cover_image' THEN p_payload->>'cover_image' ELSE cover_image END,
        blocks          = CASE WHEN p_payload ? 'blocks' THEN p_payload->'blocks' ELSE blocks END,
        currency        = CASE WHEN p_payload ? 'currency' THEN p_payload->>'currency' ELSE currency END,
        tax_rate        = CASE WHEN p_payload ? 'tax_rate' THEN (p_payload->>'tax_rate')::DECIMAL ELSE tax_rate END,
        discount_config = CASE WHEN p_payload ? 'discount_config' THEN p_payload->'discount_config' ELSE discount_config END,
        subtotal        = CASE WHEN p_payload ? 'subtotal' THEN (p_payload->>'subtotal')::DECIMAL ELSE subtotal END,
        total           = CASE WHEN p_payload ? 'total' THEN (p_payload->>'total')::DECIMAL ELSE total END,
        settings        = CASE WHEN p_payload ? 'settings' THEN p_payload->'settings' ELSE settings END,
        industry_tags   = CASE WHEN p_payload ? 'industry_tags' THEN p_payload->'industry_tags' ELSE industry_tags END,
        is_public       = CASE WHEN p_payload ? 'is_public' THEN (p_payload->>'is_public')::BOOLEAN ELSE is_public END,
        status_id       = CASE WHEN p_payload ? 'status_id' THEN (p_payload->>'status_id')::UUID ELSE status_id END,
        sequence_no     = CASE WHEN p_payload ? 'sequence_no' THEN (p_payload->>'sequence_no')::INTEGER ELSE sequence_no END,
        version         = version + 1,
        updated_by      = COALESCE(v_updated_by, updated_by),
        updated_at      = NOW()
    WHERE id = p_template_id;

    -- ═══════════════════════════════════════════
    -- STEP 5: Fetch updated template for response
    -- ═══════════════════════════════════════════
    SELECT * INTO v_current
    FROM m_cat_templates
    WHERE id = p_template_id;

    DECLARE
        v_response JSONB;
    BEGIN
        v_response := jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'id', v_current.id,
                'tenant_id', v_current.tenant_id,
                'name', v_current.name,
                'display_name', v_current.display_name,
                'description', v_current.description,
                'category', v_current.category,
                'tags', COALESCE(v_current.tags, '[]'::JSONB),
                'cover_image', v_current.cover_image,
                'blocks', COALESCE(v_current.blocks, '[]'::JSONB),
                'blocks_count', COALESCE(jsonb_array_length(v_current.blocks), 0),
                'currency', v_current.currency,
                'tax_rate', v_current.tax_rate,
                'discount_config', COALESCE(v_current.discount_config, '{}'::JSONB),
                'subtotal', v_current.subtotal,
                'total', v_current.total,
                'settings', COALESCE(v_current.settings, '{}'::JSONB),
                'is_system', v_current.is_system,
                'is_public', v_current.is_public,
                'industry_tags', COALESCE(v_current.industry_tags, '[]'::JSONB),
                'status_id', v_current.status_id,
                'version', v_current.version,
                'is_live', v_current.is_live,
                'updated_by', v_current.updated_by,
                'updated_at', v_current.updated_at
            ),
            'updated_at', NOW()
        );

        -- Store idempotency
        IF p_idempotency_key IS NOT NULL THEN
            PERFORM store_idempotency(
                p_idempotency_key,
                p_tenant_id,
                'update_template_transaction',
                'PUT',
                NULL,
                200,
                v_response,
                24
            );
        END IF;

        RETURN v_response;
    END;

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to update template',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION update_template_transaction(UUID, UUID, JSONB, INTEGER, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION update_template_transaction(UUID, UUID, JSONB, INTEGER, VARCHAR) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 5. delete_template_soft
--    Soft delete: is_active = false
--    Respects is_deletable flag
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION delete_template_soft(
    p_template_id UUID,
    p_tenant_id UUID,
    p_deleted_by UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current RECORD;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_template_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'template_id is required'
        );
    END IF;

    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Fetch and verify
    -- ═══════════════════════════════════════════
    SELECT * INTO v_current
    FROM m_cat_templates
    WHERE id = p_template_id
      AND is_active = true
      AND tenant_id = p_tenant_id;

    IF v_current IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Template not found or access denied',
            'template_id', p_template_id
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Check if deletable
    -- ═══════════════════════════════════════════
    IF v_current.is_deletable = false THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'This template cannot be deleted',
            'template_id', p_template_id
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Soft delete
    -- ═══════════════════════════════════════════
    UPDATE m_cat_templates
    SET
        is_active = false,
        updated_by = COALESCE(p_deleted_by, updated_by),
        updated_at = NOW()
    WHERE id = p_template_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Return success
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', p_template_id,
            'deleted', true
        ),
        'deleted_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to delete template',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION delete_template_soft(UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION delete_template_soft(UUID, UUID, UUID) TO service_role;
