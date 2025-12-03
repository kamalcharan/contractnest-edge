-- ============================================================
-- Migration: 004_sequence_reset_functions
-- Description: Functions for handling sequence resets (yearly/monthly)
-- Author: Claude
-- Date: 2025-12-03
-- ============================================================

-- ============================================================
-- FUNCTION: check_and_reset_sequence
-- Purpose: Check if a sequence needs resetting based on reset_frequency
-- Called before getting next sequence number
-- ============================================================

CREATE OR REPLACE FUNCTION public.check_and_reset_sequence(
    p_sequence_type_id UUID,
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true
)
RETURNS BOOLEAN AS $$
DECLARE
    v_config JSONB;
    v_reset_frequency TEXT;
    v_last_reset_date TIMESTAMP WITH TIME ZONE;
    v_start_value INTEGER;
    v_should_reset BOOLEAN := false;
    v_current_year INTEGER;
    v_last_reset_year INTEGER;
    v_current_month INTEGER;
    v_last_reset_month INTEGER;
    v_current_quarter INTEGER;
    v_last_reset_quarter INTEGER;
BEGIN
    -- Get config and last reset date
    SELECT
        cd.form_settings,
        sc.last_reset_date
    INTO v_config, v_last_reset_date
    FROM public.t_category_details cd
    LEFT JOIN public.t_sequence_counters sc
        ON sc.sequence_type_id = cd.id
        AND sc.tenant_id = p_tenant_id
        AND sc.is_live = p_is_live
    WHERE cd.id = p_sequence_type_id;

    IF v_config IS NULL THEN
        RETURN false;
    END IF;

    v_reset_frequency := UPPER(COALESCE(v_config->>'reset_frequency', 'NEVER'));
    v_start_value := COALESCE((v_config->>'start_value')::INTEGER, 1);

    -- If never reset or no counter exists yet, return false
    IF v_reset_frequency = 'NEVER' OR v_last_reset_date IS NULL THEN
        RETURN false;
    END IF;

    -- Calculate time components
    v_current_year := EXTRACT(YEAR FROM NOW());
    v_last_reset_year := EXTRACT(YEAR FROM v_last_reset_date);
    v_current_month := EXTRACT(MONTH FROM NOW());
    v_last_reset_month := EXTRACT(MONTH FROM v_last_reset_date);
    v_current_quarter := EXTRACT(QUARTER FROM NOW());
    v_last_reset_quarter := EXTRACT(QUARTER FROM v_last_reset_date);

    -- Check reset conditions
    CASE v_reset_frequency
        WHEN 'YEARLY' THEN
            v_should_reset := v_current_year > v_last_reset_year;
        WHEN 'MONTHLY' THEN
            v_should_reset := (v_current_year > v_last_reset_year) OR
                             (v_current_year = v_last_reset_year AND v_current_month > v_last_reset_month);
        WHEN 'QUARTERLY' THEN
            v_should_reset := (v_current_year > v_last_reset_year) OR
                             (v_current_year = v_last_reset_year AND v_current_quarter > v_last_reset_quarter);
        ELSE
            v_should_reset := false;
    END CASE;

    -- Perform reset if needed
    IF v_should_reset THEN
        UPDATE public.t_sequence_counters
        SET current_value = v_start_value - 1,  -- -1 because next call will increment
            last_reset_date = NOW(),
            updated_at = NOW()
        WHERE sequence_type_id = p_sequence_type_id
          AND tenant_id = p_tenant_id
          AND is_live = p_is_live;

        RAISE NOTICE 'Sequence % reset to % for tenant %',
            p_sequence_type_id, v_start_value, p_tenant_id;
    END IF;

    RETURN v_should_reset;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FUNCTION: get_next_sequence_number_with_reset (Enhanced version)
-- Purpose: Check for reset before getting next number
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_next_sequence_number_with_reset(
    p_sequence_type_id UUID,
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true
)
RETURNS INTEGER AS $$
DECLARE
    v_was_reset BOOLEAN;
    v_next_value INTEGER;
BEGIN
    -- First check if reset is needed
    v_was_reset := public.check_and_reset_sequence(
        p_sequence_type_id,
        p_tenant_id,
        p_is_live
    );

    -- Then get next value
    v_next_value := public.get_next_sequence_number(
        p_sequence_type_id,
        p_tenant_id,
        p_is_live
    );

    RETURN v_next_value;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- UPDATE: get_next_formatted_sequence to use reset-aware version
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_next_formatted_sequence(
    p_sequence_code TEXT,
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true
)
RETURNS JSONB AS $$
DECLARE
    v_sequence_type_id UUID;
    v_next_value INTEGER;
    v_formatted TEXT;
    v_config JSONB;
    v_was_reset BOOLEAN;
BEGIN
    -- Get sequence_type_id from category_details by code
    SELECT cd.id, cd.form_settings
    INTO v_sequence_type_id, v_config
    FROM public.t_category_details cd
    JOIN public.t_category_master cm ON cd.category_id = cm.id
    WHERE cm.category_name = 'sequence_numbers'
      AND cd.sub_cat_name = p_sequence_code
      AND cd.tenant_id = p_tenant_id
      AND cd.is_live = p_is_live
      AND cd.is_active = true;

    IF v_sequence_type_id IS NULL THEN
        RAISE EXCEPTION 'Sequence type % not found for tenant', p_sequence_code;
    END IF;

    -- Check for reset first
    v_was_reset := public.check_and_reset_sequence(
        v_sequence_type_id,
        p_tenant_id,
        p_is_live
    );

    -- Get next value
    v_next_value := public.get_next_sequence_number(
        v_sequence_type_id,
        p_tenant_id,
        p_is_live
    );

    -- Format it
    v_formatted := public.format_sequence_number(v_sequence_type_id, v_next_value);

    RETURN jsonb_build_object(
        'formatted', v_formatted,
        'sequence', v_next_value,
        'prefix', COALESCE(v_config->>'prefix', ''),
        'separator', COALESCE(v_config->>'separator', ''),
        'suffix', COALESCE(v_config->>'suffix', ''),
        'was_reset', v_was_reset
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FUNCTION: manual_reset_sequence
-- Purpose: Manually reset a sequence to its start value
-- Use case: Admin wants to reset sequence mid-year
-- ============================================================

CREATE OR REPLACE FUNCTION public.manual_reset_sequence(
    p_sequence_code TEXT,
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true,
    p_new_start_value INTEGER DEFAULT NULL  -- NULL = use config start_value
)
RETURNS JSONB AS $$
DECLARE
    v_sequence_type_id UUID;
    v_config JSONB;
    v_start_value INTEGER;
    v_old_value INTEGER;
BEGIN
    -- Get sequence_type_id and config
    SELECT cd.id, cd.form_settings
    INTO v_sequence_type_id, v_config
    FROM public.t_category_details cd
    JOIN public.t_category_master cm ON cd.category_id = cm.id
    WHERE cm.category_name = 'sequence_numbers'
      AND cd.sub_cat_name = p_sequence_code
      AND cd.tenant_id = p_tenant_id
      AND cd.is_live = p_is_live
      AND cd.is_active = true;

    IF v_sequence_type_id IS NULL THEN
        RAISE EXCEPTION 'Sequence type % not found for tenant', p_sequence_code;
    END IF;

    -- Determine start value
    v_start_value := COALESCE(
        p_new_start_value,
        (v_config->>'start_value')::INTEGER,
        1
    );

    -- Get current value before reset
    SELECT current_value INTO v_old_value
    FROM public.t_sequence_counters
    WHERE sequence_type_id = v_sequence_type_id
      AND tenant_id = p_tenant_id
      AND is_live = p_is_live;

    -- Perform reset
    UPDATE public.t_sequence_counters
    SET current_value = v_start_value - 1,  -- -1 because next call will increment
        last_reset_date = NOW(),
        updated_at = NOW()
    WHERE sequence_type_id = v_sequence_type_id
      AND tenant_id = p_tenant_id
      AND is_live = p_is_live;

    -- If no row existed, create one
    IF NOT FOUND THEN
        INSERT INTO public.t_sequence_counters (
            sequence_type_id,
            tenant_id,
            current_value,
            is_live,
            last_reset_date
        )
        VALUES (
            v_sequence_type_id,
            p_tenant_id,
            v_start_value - 1,
            p_is_live,
            NOW()
        );
        v_old_value := 0;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'sequence_code', p_sequence_code,
        'old_value', v_old_value,
        'new_start_value', v_start_value,
        'reset_at', NOW()
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FUNCTION: get_sequence_status
-- Purpose: Get current status of all sequences for a tenant
-- Used by UI to display sequence information
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_sequence_status(
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true
)
RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', cd.id,
            'code', cd.sub_cat_name,
            'name', cd.display_name,
            'config', cd.form_settings,
            'current_value', COALESCE(sc.current_value, 0),
            'last_reset_date', sc.last_reset_date,
            'next_formatted', public.format_sequence_number(
                cd.id,
                COALESCE(sc.current_value, 0) + 1
            ),
            'is_active', cd.is_active,
            'hexcolor', cd.hexcolor,
            'icon_name', cd.icon_name
        )
        ORDER BY cd.sequence_no
    )
    INTO v_result
    FROM public.t_category_details cd
    JOIN public.t_category_master cm ON cd.category_id = cm.id
    LEFT JOIN public.t_sequence_counters sc
        ON sc.sequence_type_id = cd.id
        AND sc.tenant_id = p_tenant_id
        AND sc.is_live = p_is_live
    WHERE cm.category_name = 'sequence_numbers'
      AND cd.tenant_id = p_tenant_id
      AND cd.is_live = p_is_live;

    RETURN COALESCE(v_result, '[]'::JSONB);
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- COMMENTS
-- ============================================================

COMMENT ON FUNCTION public.check_and_reset_sequence IS
'Checks if a sequence needs resetting based on reset_frequency (YEARLY, MONTHLY, QUARTERLY).
Automatically resets to start_value if period has changed.';

COMMENT ON FUNCTION public.manual_reset_sequence IS
'Manually resets a sequence to its start value or a custom value.
Use for admin-initiated resets.';

COMMENT ON FUNCTION public.get_sequence_status IS
'Returns status of all sequence configurations for a tenant.
Includes current value, last reset date, and next formatted number.';

-- ============================================================
-- EXAMPLE USAGE
-- ============================================================

/*
-- Get status of all sequences for a tenant:
SELECT public.get_sequence_status(
    '70f8eb69-9ccf-4a0c-8177-cb6131934344'::uuid,
    true
);

-- Manually reset invoice sequence:
SELECT public.manual_reset_sequence(
    'INVOICE',
    '70f8eb69-9ccf-4a0c-8177-cb6131934344'::uuid,
    true
);

-- Reset to specific value:
SELECT public.manual_reset_sequence(
    'INVOICE',
    '70f8eb69-9ccf-4a0c-8177-cb6131934344'::uuid,
    true,
    50001  -- Start from 50001
);
*/
