-- ============================================================
-- Migration: 005_alter_sequence_counters_for_tenant_settings
-- Description: Add tenant-specific settings columns to t_sequence_counters
--              This makes t_sequence_counters the single source of truth
--              for tenant's sequence configurations (not t_category_details)
-- Author: Claude
-- Date: 2025-12-17
-- ============================================================

-- ============================================================
-- STEP 1: Add sequence_code column (direct lookup, no join needed)
-- ============================================================
ALTER TABLE public.t_sequence_counters
ADD COLUMN IF NOT EXISTS sequence_code TEXT;

-- ============================================================
-- STEP 2: Add tenant-specific settings columns
-- ============================================================
ALTER TABLE public.t_sequence_counters
ADD COLUMN IF NOT EXISTS prefix TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS separator TEXT DEFAULT '-',
ADD COLUMN IF NOT EXISTS suffix TEXT DEFAULT '',
ADD COLUMN IF NOT EXISTS padding_length INTEGER DEFAULT 4,
ADD COLUMN IF NOT EXISTS start_value INTEGER DEFAULT 1,
ADD COLUMN IF NOT EXISTS increment_by INTEGER DEFAULT 1,
ADD COLUMN IF NOT EXISTS reset_frequency TEXT DEFAULT 'NEVER';

-- Add display metadata columns
ALTER TABLE public.t_sequence_counters
ADD COLUMN IF NOT EXISTS display_name TEXT,
ADD COLUMN IF NOT EXISTS description TEXT,
ADD COLUMN IF NOT EXISTS hexcolor TEXT DEFAULT '#3B82F6',
ADD COLUMN IF NOT EXISTS icon_name TEXT DEFAULT 'Hash',
ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT true;

-- ============================================================
-- STEP 3: Populate sequence_code from existing sequence_type_id
-- ============================================================
UPDATE public.t_sequence_counters sc
SET sequence_code = cd.sub_cat_name,
    prefix = COALESCE(cd.form_settings->>'prefix', ''),
    separator = COALESCE(cd.form_settings->>'separator', '-'),
    suffix = COALESCE(cd.form_settings->>'suffix', ''),
    padding_length = COALESCE((cd.form_settings->>'padding_length')::INTEGER, 4),
    start_value = COALESCE((cd.form_settings->>'start_value')::INTEGER, 1),
    increment_by = COALESCE((cd.form_settings->>'increment_by')::INTEGER, 1),
    reset_frequency = COALESCE(cd.form_settings->>'reset_frequency', 'NEVER'),
    display_name = cd.display_name,
    description = cd.description,
    hexcolor = cd.hexcolor,
    icon_name = cd.icon_name
FROM public.t_category_details cd
WHERE sc.sequence_type_id = cd.id
AND sc.sequence_code IS NULL;

-- ============================================================
-- STEP 4: Update constraints
-- ============================================================

-- Drop old unique constraint if exists
ALTER TABLE public.t_sequence_counters
DROP CONSTRAINT IF EXISTS uq_sequence_counter_unique;

-- Add new unique constraint (sequence_code based)
ALTER TABLE public.t_sequence_counters
ADD CONSTRAINT uq_sequence_counter UNIQUE (sequence_code, tenant_id, is_live);

-- ============================================================
-- STEP 5: Create indexes for fast lookups
-- ============================================================
DROP INDEX IF EXISTS idx_sequence_counters_code_tenant;
CREATE INDEX idx_sequence_counters_code_tenant
ON public.t_sequence_counters(sequence_code, tenant_id, is_live);

DROP INDEX IF EXISTS idx_sequence_counters_tenant;
CREATE INDEX idx_sequence_counters_tenant
ON public.t_sequence_counters(tenant_id);

-- ============================================================
-- STEP 6: Make sequence_type_id nullable (no longer required)
-- ============================================================
ALTER TABLE public.t_sequence_counters
ALTER COLUMN sequence_type_id DROP NOT NULL;

-- ============================================================
-- STEP 7: Update RLS policies (if needed)
-- ============================================================
-- Existing policies should still work as they filter by tenant_id

-- ============================================================
-- STEP 8: Create helper function to get next formatted sequence
-- This is the SERVICE LAYER for other modules
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_next_formatted_sequence_v2(
    p_sequence_code TEXT,
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true
)
RETURNS JSONB AS $$
DECLARE
    v_counter RECORD;
    v_next_value INTEGER;
    v_formatted TEXT;
BEGIN
    -- Get and lock the counter row for atomic update
    SELECT * INTO v_counter
    FROM public.t_sequence_counters
    WHERE sequence_code = p_sequence_code
      AND tenant_id = p_tenant_id
      AND is_live = p_is_live
    FOR UPDATE;

    IF v_counter IS NULL THEN
        RAISE EXCEPTION 'Sequence % not found for tenant in % environment',
            p_sequence_code,
            CASE WHEN p_is_live THEN 'LIVE' ELSE 'TEST' END;
    END IF;

    -- Calculate next value
    IF v_counter.current_value = 0 THEN
        -- First use: start from start_value
        v_next_value := COALESCE(v_counter.start_value, 1);
    ELSE
        -- Subsequent uses: increment
        v_next_value := v_counter.current_value + COALESCE(v_counter.increment_by, 1);
    END IF;

    -- Update counter
    UPDATE public.t_sequence_counters
    SET current_value = v_next_value,
        updated_at = NOW()
    WHERE id = v_counter.id;

    -- Format the number
    v_formatted := COALESCE(v_counter.prefix, '') ||
                   COALESCE(v_counter.separator, '') ||
                   LPAD(v_next_value::TEXT, COALESCE(v_counter.padding_length, 4), '0') ||
                   COALESCE(v_counter.suffix, '');

    RETURN jsonb_build_object(
        'formatted', v_formatted,
        'raw_value', v_next_value,
        'sequence_code', p_sequence_code,
        'prefix', COALESCE(v_counter.prefix, ''),
        'separator', COALESCE(v_counter.separator, ''),
        'suffix', COALESCE(v_counter.suffix, '')
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- COMMENTS
-- ============================================================
COMMENT ON COLUMN public.t_sequence_counters.sequence_code IS 'Direct sequence type code (CONTACT, CONTRACT, etc.) - no join needed';
COMMENT ON COLUMN public.t_sequence_counters.prefix IS 'Tenant-specific prefix (e.g., CT, CN, INV)';
COMMENT ON COLUMN public.t_sequence_counters.separator IS 'Separator between prefix and number (e.g., -)';
COMMENT ON COLUMN public.t_sequence_counters.padding_length IS 'Number of digits to pad with zeros';
COMMENT ON COLUMN public.t_sequence_counters.start_value IS 'Initial starting value for the sequence';
COMMENT ON FUNCTION public.get_next_formatted_sequence_v2 IS 'Service layer function: atomically gets and increments sequence, returns formatted number';
