-- ============================================================
-- Migration: 001_create_t_sequence_counters
-- Description: Create sequence counters table for runtime sequence state
-- Author: Claude
-- Date: 2025-12-03
-- ============================================================

-- ============================================================
-- TABLE: t_sequence_counters
-- Purpose: Stores runtime counter values for each sequence type per tenant
-- Separated from config (in t_category_details.form_settings) for:
--   1. Clean separation of config vs. state
--   2. Faster atomic increments
--   3. Better concurrent access handling
-- ============================================================

CREATE TABLE IF NOT EXISTS public.t_sequence_counters (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Foreign key to t_category_details (sequence type definition)
    -- Links to entries where category_master.category_name = 'sequence_numbers'
    sequence_type_id UUID NOT NULL,

    -- Tenant isolation
    tenant_id UUID NOT NULL REFERENCES public.t_tenants(id) ON DELETE CASCADE,

    -- Runtime counter value
    current_value INTEGER NOT NULL DEFAULT 0,

    -- For reset functionality (yearly/monthly resets)
    last_reset_date TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- Environment separation (live/test mode)
    is_live BOOLEAN NOT NULL DEFAULT true,

    -- Audit fields
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by UUID,
    updated_by UUID,

    -- Unique constraint: one counter per sequence_type per tenant per environment
    CONSTRAINT uq_sequence_counter_unique UNIQUE (sequence_type_id, tenant_id, is_live)
);

-- ============================================================
-- INDEXES
-- ============================================================

-- Index for fast lookup by tenant and sequence type
CREATE INDEX IF NOT EXISTS idx_sequence_counters_tenant_type
ON public.t_sequence_counters(tenant_id, sequence_type_id);

-- Index for environment filtering
CREATE INDEX IF NOT EXISTS idx_sequence_counters_is_live
ON public.t_sequence_counters(is_live);

-- Composite index for the most common query pattern
CREATE INDEX IF NOT EXISTS idx_sequence_counters_lookup
ON public.t_sequence_counters(tenant_id, sequence_type_id, is_live);

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================

-- Enable RLS
ALTER TABLE public.t_sequence_counters ENABLE ROW LEVEL SECURITY;

-- Policy: Tenant isolation for SELECT
CREATE POLICY tenant_isolation_sequence_counters_select
ON public.t_sequence_counters
FOR SELECT
USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

-- Policy: Tenant isolation for INSERT
CREATE POLICY tenant_isolation_sequence_counters_insert
ON public.t_sequence_counters
FOR INSERT
WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

-- Policy: Tenant isolation for UPDATE
CREATE POLICY tenant_isolation_sequence_counters_update
ON public.t_sequence_counters
FOR UPDATE
USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

-- Policy: Tenant isolation for DELETE
CREATE POLICY tenant_isolation_sequence_counters_delete
ON public.t_sequence_counters
FOR DELETE
USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

-- ============================================================
-- TRIGGER: Auto-update updated_at timestamp
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_sequence_counters_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sequence_counters_updated_at
    BEFORE UPDATE ON public.t_sequence_counters
    FOR EACH ROW
    EXECUTE FUNCTION public.update_sequence_counters_updated_at();

-- ============================================================
-- FUNCTION: get_next_sequence_number (Atomic increment)
-- Purpose: Atomically get and increment sequence counter
-- Returns: The next sequence number
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_next_sequence_number(
    p_sequence_type_id UUID,
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true
)
RETURNS INTEGER AS $$
DECLARE
    v_next_value INTEGER;
    v_config JSONB;
    v_start_value INTEGER;
BEGIN
    -- Try to increment existing counter atomically
    UPDATE public.t_sequence_counters
    SET current_value = current_value + 1,
        updated_at = NOW()
    WHERE sequence_type_id = p_sequence_type_id
      AND tenant_id = p_tenant_id
      AND is_live = p_is_live
    RETURNING current_value INTO v_next_value;

    -- If no row was updated, we need to create one
    IF v_next_value IS NULL THEN
        -- Get the start_value from form_settings in t_category_details
        SELECT COALESCE((form_settings->>'start_value')::INTEGER, 1)
        INTO v_start_value
        FROM public.t_category_details
        WHERE id = p_sequence_type_id;

        -- Default to 1 if not found
        IF v_start_value IS NULL THEN
            v_start_value := 1;
        END IF;

        -- Insert new counter with start_value
        INSERT INTO public.t_sequence_counters (
            sequence_type_id,
            tenant_id,
            current_value,
            is_live,
            last_reset_date
        )
        VALUES (
            p_sequence_type_id,
            p_tenant_id,
            v_start_value,
            p_is_live,
            NOW()
        )
        ON CONFLICT (sequence_type_id, tenant_id, is_live)
        DO UPDATE SET
            current_value = t_sequence_counters.current_value + 1,
            updated_at = NOW()
        RETURNING current_value INTO v_next_value;
    END IF;

    RETURN v_next_value;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FUNCTION: format_sequence_number
-- Purpose: Format sequence number using config from form_settings
-- Returns: Formatted string like "CT-0001" or "INV-2025-00001"
-- ============================================================

CREATE OR REPLACE FUNCTION public.format_sequence_number(
    p_sequence_type_id UUID,
    p_sequence_value INTEGER
)
RETURNS TEXT AS $$
DECLARE
    v_config JSONB;
    v_prefix TEXT;
    v_separator TEXT;
    v_suffix TEXT;
    v_padding INTEGER;
    v_formatted TEXT;
BEGIN
    -- Get config from form_settings
    SELECT form_settings INTO v_config
    FROM public.t_category_details
    WHERE id = p_sequence_type_id;

    IF v_config IS NULL THEN
        -- Return plain number if no config
        RETURN p_sequence_value::TEXT;
    END IF;

    -- Extract config values with defaults
    v_prefix := COALESCE(v_config->>'prefix', '');
    v_separator := COALESCE(v_config->>'separator', '');
    v_suffix := COALESCE(v_config->>'suffix', '');
    v_padding := COALESCE((v_config->>'padding_length')::INTEGER, 4);

    -- Build formatted string
    v_formatted := v_prefix || v_separator || LPAD(p_sequence_value::TEXT, v_padding, '0') || v_suffix;

    RETURN v_formatted;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FUNCTION: get_next_formatted_sequence
-- Purpose: Combined function to get next sequence and format it
-- Returns: JSON with formatted value and raw number
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

    -- Get next value
    v_next_value := public.get_next_sequence_number(v_sequence_type_id, p_tenant_id, p_is_live);

    -- Format it
    v_formatted := public.format_sequence_number(v_sequence_type_id, v_next_value);

    RETURN jsonb_build_object(
        'formatted', v_formatted,
        'sequence', v_next_value,
        'prefix', COALESCE(v_config->>'prefix', ''),
        'separator', COALESCE(v_config->>'separator', ''),
        'suffix', COALESCE(v_config->>'suffix', '')
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- COMMENTS
-- ============================================================

COMMENT ON TABLE public.t_sequence_counters IS 'Stores runtime counter values for sequence number generation. Config is in t_category_details.form_settings.';
COMMENT ON COLUMN public.t_sequence_counters.sequence_type_id IS 'FK to t_category_details entry under sequence_numbers category';
COMMENT ON COLUMN public.t_sequence_counters.current_value IS 'Current counter value. Incremented atomically on each use.';
COMMENT ON COLUMN public.t_sequence_counters.last_reset_date IS 'When the counter was last reset (for yearly/monthly resets)';
COMMENT ON COLUMN public.t_sequence_counters.is_live IS 'Environment flag - true for live, false for test mode';

COMMENT ON FUNCTION public.get_next_sequence_number IS 'Atomically increments and returns the next sequence number';
COMMENT ON FUNCTION public.format_sequence_number IS 'Formats a sequence number using config from form_settings';
COMMENT ON FUNCTION public.get_next_formatted_sequence IS 'Combined function: gets next sequence and formats it in one call';
