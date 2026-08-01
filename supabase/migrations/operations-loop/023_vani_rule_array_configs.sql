-- ============================================================================
-- 023 — vani rule validator accepts int-array configs
-- ============================================================================
-- The original update_vani_rule (m_vani_rule_templates + t_vani_rules) rejects
-- any config value that isn't a jsonb 'number', which was fine when every
-- rule's config was a scalar (lead_days: 3). Migration 022 introduced three
-- reminder-schedule rules whose defaults are int arrays:
--
--   notif_group_session_before_days.days                    = [7, 3, 1]
--   notif_group_session_looking_forward.days_before         = [2, 1]
--   notif_group_session_no_show.days_after_no_show          = [2, 4]
--
-- Updating any of them from the tenant Automation Rules UI failed with
-- INVALID_TYPE. This migration replaces the validator with one that dispatches
-- on the template default's shape: number-defaults keep the exact old
-- validation (min/max), array-defaults validate item type + per-item bounds +
-- array length (min_items/max_items). No behavior change for scalar rules.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_vani_rule(
    p_tenant_id uuid,
    p_rule_key text,
    p_config jsonb,
    p_is_enabled boolean,
    p_expected_version integer DEFAULT NULL::integer,
    p_updated_by uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_tpl        m_vani_rule_templates%ROWTYPE;
    v_key        TEXT;
    v_val        NUMERIC;
    v_min        NUMERIC;
    v_max        NUMERIC;
    v_min_items  INTEGER;
    v_max_items  INTEGER;
    v_field_val  JSONB;
    v_default    JSONB;
    v_item       JSONB;
    v_item_val   NUMERIC;
    v_row        t_vani_rules%ROWTYPE;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'TENANT_REQUIRED');
    END IF;

    SELECT * INTO v_tpl FROM m_vani_rule_templates
    WHERE rule_key = p_rule_key AND is_active = true;
    IF v_tpl.rule_key IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_RULE');
    END IF;

    FOR v_key IN SELECT jsonb_object_keys(COALESCE(p_config, '{}'::jsonb))
    LOOP
        IF NOT (v_tpl.default_config ? v_key) THEN
            RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_FIELD',
                                      'field', v_key);
        END IF;

        v_field_val := p_config -> v_key;
        v_default   := v_tpl.default_config -> v_key;

        -- Dispatch on the TEMPLATE's shape, not the incoming value's. This
        -- pins the contract to the template so a caller can't sneak a number
        -- past an array field (or vice versa) and land in an inconsistent state.
        IF jsonb_typeof(v_default) = 'array' THEN
            -- Array field: type + per-item bounds + length bounds.
            IF jsonb_typeof(v_field_val) <> 'array' THEN
                RETURN jsonb_build_object('success', false, 'error', 'INVALID_TYPE',
                                          'field', v_key);
            END IF;

            v_min       := (v_tpl.constraints -> v_key ->> 'min')::numeric;
            v_max       := (v_tpl.constraints -> v_key ->> 'max')::numeric;
            v_min_items := (v_tpl.constraints -> v_key ->> 'min_items')::integer;
            v_max_items := (v_tpl.constraints -> v_key ->> 'max_items')::integer;

            IF v_min_items IS NOT NULL AND jsonb_array_length(v_field_val) < v_min_items THEN
                RETURN jsonb_build_object('success', false, 'error', 'OUT_OF_BOUNDS',
                                          'field', v_key,
                                          'min_items', v_min_items,
                                          'max_items', v_max_items);
            END IF;
            IF v_max_items IS NOT NULL AND jsonb_array_length(v_field_val) > v_max_items THEN
                RETURN jsonb_build_object('success', false, 'error', 'OUT_OF_BOUNDS',
                                          'field', v_key,
                                          'min_items', v_min_items,
                                          'max_items', v_max_items);
            END IF;

            FOR v_item IN SELECT jsonb_array_elements(v_field_val)
            LOOP
                IF jsonb_typeof(v_item) <> 'number' THEN
                    RETURN jsonb_build_object('success', false, 'error', 'INVALID_TYPE',
                                              'field', v_key);
                END IF;
                v_item_val := v_item::numeric;
                IF (v_min IS NOT NULL AND v_item_val < v_min)
                   OR (v_max IS NOT NULL AND v_item_val > v_max) THEN
                    RETURN jsonb_build_object('success', false, 'error', 'OUT_OF_BOUNDS',
                                              'field', v_key,
                                              'min', v_min, 'max', v_max);
                END IF;
            END LOOP;

        ELSIF jsonb_typeof(v_default) = 'number' THEN
            -- Scalar field: identical to the original validator.
            IF jsonb_typeof(v_field_val) <> 'number' THEN
                RETURN jsonb_build_object('success', false, 'error', 'INVALID_TYPE',
                                          'field', v_key);
            END IF;
            v_val := (p_config ->> v_key)::numeric;
            v_min := (v_tpl.constraints -> v_key ->> 'min')::numeric;
            v_max := (v_tpl.constraints -> v_key ->> 'max')::numeric;
            IF (v_min IS NOT NULL AND v_val < v_min) OR (v_max IS NOT NULL AND v_val > v_max) THEN
                RETURN jsonb_build_object('success', false, 'error', 'OUT_OF_BOUNDS',
                                          'field', v_key, 'min', v_min, 'max', v_max);
            END IF;

        ELSE
            -- Anything else in default_config is a template-side error.
            -- Reject rather than storing a value that no consumer knows how to read.
            RETURN jsonb_build_object('success', false, 'error', 'UNSUPPORTED_TEMPLATE_TYPE',
                                      'field', v_key,
                                      'template_type', jsonb_typeof(v_default));
        END IF;
    END LOOP;

    INSERT INTO t_vani_rules (tenant_id, rule_key, config, is_enabled, updated_by)
    VALUES (p_tenant_id, p_rule_key, COALESCE(p_config, '{}'::jsonb),
            COALESCE(p_is_enabled, true), p_updated_by)
    ON CONFLICT (tenant_id, rule_key) DO UPDATE SET
        config     = COALESCE(p_config, t_vani_rules.config),
        is_enabled = COALESCE(p_is_enabled, t_vani_rules.is_enabled),
        version    = t_vani_rules.version + 1,
        updated_at = now(),
        updated_by = COALESCE(p_updated_by, t_vani_rules.updated_by)
    WHERE p_expected_version IS NULL
       OR t_vani_rules.version = p_expected_version
    RETURNING * INTO v_row;

    IF v_row.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'VERSION_CONFLICT');
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'rule_key', v_row.rule_key,
        'config', v_tpl.default_config || v_row.config,
        'is_enabled', v_row.is_enabled,
        'version', v_row.version
    );
END;
$function$;
