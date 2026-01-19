-- ============================================================================
-- Business Model - Product Config Features Migration
-- ============================================================================
-- Purpose: Add config versioning and history tracking to t_bm_product_config
-- Depends on: Phase 1 tables (t_bm_product_config must exist)
-- ============================================================================

-- ============================================================================
-- 1. ADD CONFIG VERSION COLUMN
-- ============================================================================
ALTER TABLE t_bm_product_config
ADD COLUMN IF NOT EXISTS config_version TEXT DEFAULT '1.0';

-- Add updated_by column for audit
ALTER TABLE t_bm_product_config
ADD COLUMN IF NOT EXISTS updated_by UUID;

-- Ensure updated_at exists and has default
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 't_bm_product_config' AND column_name = 'updated_at'
    ) THEN
        ALTER TABLE t_bm_product_config ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();
    END IF;
END $$;

-- ============================================================================
-- 2. CREATE HISTORY TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS t_bm_product_config_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_code TEXT NOT NULL,
    config_version TEXT NOT NULL,
    product_name TEXT,
    billing_config JSONB NOT NULL,
    changelog TEXT,
    created_by UUID,
    created_at TIMESTAMPTZ DEFAULT NOW(),

    -- Unique constraint on product + version
    UNIQUE(product_code, config_version)
);

-- Index for fast lookups
CREATE INDEX IF NOT EXISTS idx_product_config_history_code
ON t_bm_product_config_history(product_code);

CREATE INDEX IF NOT EXISTS idx_product_config_history_version
ON t_bm_product_config_history(product_code, config_version);

-- ============================================================================
-- 3. CREATE TRIGGER FOR UPDATED_AT
-- ============================================================================
CREATE OR REPLACE FUNCTION update_product_config_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_product_config_updated ON t_bm_product_config;
CREATE TRIGGER trg_product_config_updated
    BEFORE UPDATE ON t_bm_product_config
    FOR EACH ROW
    EXECUTE FUNCTION update_product_config_timestamp();

-- ============================================================================
-- 4. CREATE TRIGGER FOR HISTORY ON UPDATE
-- ============================================================================
CREATE OR REPLACE FUNCTION save_product_config_history()
RETURNS TRIGGER AS $$
BEGIN
    -- Only save history if billing_config actually changed
    IF OLD.billing_config IS DISTINCT FROM NEW.billing_config THEN
        INSERT INTO t_bm_product_config_history (
            product_code,
            config_version,
            product_name,
            billing_config,
            changelog,
            created_by,
            created_at
        ) VALUES (
            OLD.product_code,
            OLD.config_version,
            OLD.product_name,
            OLD.billing_config,
            'Auto-saved before update',
            NEW.updated_by,
            NOW()
        )
        ON CONFLICT (product_code, config_version) DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_product_config_history ON t_bm_product_config;
CREATE TRIGGER trg_product_config_history
    BEFORE UPDATE ON t_bm_product_config
    FOR EACH ROW
    EXECUTE FUNCTION save_product_config_history();

-- ============================================================================
-- 5. RPC FUNCTION: GET PRODUCT CONFIG
-- ============================================================================
CREATE OR REPLACE FUNCTION get_product_config(
    p_product_code TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_config RECORD;
BEGIN
    SELECT * INTO v_config
    FROM t_bm_product_config
    WHERE product_code = p_product_code
      AND is_active = true;

    IF v_config IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Product config not found',
            'product_code', p_product_code
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'product_code', v_config.product_code,
        'product_name', v_config.product_name,
        'config_version', v_config.config_version,
        'billing_config', v_config.billing_config,
        'is_active', v_config.is_active,
        'updated_at', v_config.updated_at
    );
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION get_product_config(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_product_config(TEXT) TO service_role;

-- ============================================================================
-- 6. RPC FUNCTION: LIST ALL PRODUCT CONFIGS
-- ============================================================================
CREATE OR REPLACE FUNCTION list_product_configs()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_configs JSONB;
BEGIN
    SELECT jsonb_agg(
        jsonb_build_object(
            'product_code', product_code,
            'product_name', product_name,
            'config_version', config_version,
            'is_active', is_active,
            'updated_at', updated_at,
            'plan_types', billing_config->'plan_types',
            'feature_count', jsonb_array_length(COALESCE(billing_config->'features', '[]'::jsonb))
        ) ORDER BY product_name
    )
    INTO v_configs
    FROM t_bm_product_config
    WHERE is_active = true;

    RETURN jsonb_build_object(
        'success', true,
        'products', COALESCE(v_configs, '[]'::jsonb),
        'count', COALESCE(jsonb_array_length(v_configs), 0)
    );
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION list_product_configs() TO authenticated;
GRANT EXECUTE ON FUNCTION list_product_configs() TO service_role;

-- ============================================================================
-- 7. RPC FUNCTION: GET PRODUCT CONFIG HISTORY
-- ============================================================================
CREATE OR REPLACE FUNCTION get_product_config_history(
    p_product_code TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_history JSONB;
BEGIN
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', id,
            'config_version', config_version,
            'changelog', changelog,
            'created_at', created_at,
            'created_by', created_by
        ) ORDER BY created_at DESC
    )
    INTO v_history
    FROM t_bm_product_config_history
    WHERE product_code = p_product_code;

    RETURN jsonb_build_object(
        'success', true,
        'product_code', p_product_code,
        'history', COALESCE(v_history, '[]'::jsonb),
        'count', COALESCE(jsonb_array_length(v_history), 0)
    );
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION get_product_config_history(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_product_config_history(TEXT) TO service_role;

-- ============================================================================
-- COMMENTS
-- ============================================================================
COMMENT ON TABLE t_bm_product_config_history IS
'Stores historical versions of product billing configurations for audit and rollback';

COMMENT ON FUNCTION get_product_config(TEXT) IS
'Returns the active billing configuration for a specific product';

COMMENT ON FUNCTION list_product_configs() IS
'Returns a summary list of all active product configurations';

COMMENT ON FUNCTION get_product_config_history(TEXT) IS
'Returns the version history for a specific product configuration';
