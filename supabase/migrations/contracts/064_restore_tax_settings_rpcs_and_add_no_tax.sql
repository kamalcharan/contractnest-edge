-- ═══════════════════════════════════════════════════════════════
-- Migration 064: Restore tax-settings save/read RPCs + add 'no_tax' state
-- ═══════════════════════════════════════════════════════════════
-- STATUS: Already applied directly to the Supabase project (2026-07-19)
-- via MCP, verified live. This file tracks that same SQL in source
-- control — do not re-apply if the project already has it (idempotent
-- either way: CREATE OR REPLACE / DROP CONSTRAINT IF EXISTS).
--
-- ROOT CAUSE: create_or_update_tax_settings / get_tax_settings_with_rates
-- were applied directly to Supabase outside any tracked migration at
-- some point before this session — 5 t_tax_settings rows prove real
-- writes happened (one tenant saved 7 times, spanning Jul 2025–Feb
-- 2026). They no longer exist live — confirmed via pg_proc lookup.
-- Zero successful writes since 2026-02-07. The tax-settings edge fn
-- (supabase/functions/tax-settings/index.ts) already calls these exact
-- RPC names with these exact param names — recreating them here, with
-- NO edge fn or API changes required, restores the broken save/load.
-- (Ironic note: this migration itself was first applied via MCP before
-- being written to a file — fixed immediately by writing this file, so
-- the same untracked-drift problem doesn't repeat on this fix.)
--
-- ALSO: widens display_mode to support a third state, 'no_tax', for
-- tenants that are not tax-registered — nothing previously let a
-- tenant declare "I do not charge tax"; the old 2-value CHECK
-- constraint made that structurally impossible. The pricing math
-- (contractEvents.ts taxFactor) already collapses to Price = Total
-- whenever no rate applies, so no_tax needs no math changes — only
-- UI to surface it as a selectable option, which is a separate
-- follow-up (TaxDisplayPanel.tsx + the 4 strict 2-value TypeScript
-- unions in contractnest-api/src/types/taxTypes.ts). This migration
-- only makes 'no_tax' valid/storable at the DB layer.
--
-- VERIFIED LIVE (2026-07-19):
--   - get_tax_settings_with_rates: read path tested against a real
--     tenant (a58ca91a...), returns exact {settings, rates} shape the
--     UI's validateTaxSettingsResponse expects.
--   - create_or_update_tax_settings: invalid display_mode rejected
--     cleanly with zero write (confirmed target tenant's version
--     unchanged at 7 after the rejected call).
--   - Constraint widened, confirmed via pg_get_constraintdef.
-- ═══════════════════════════════════════════════════════════════

-- 1. Widen the constraint
ALTER TABLE t_tax_settings DROP CONSTRAINT IF EXISTS t_tax_settings_display_mode_check;
ALTER TABLE t_tax_settings ADD CONSTRAINT t_tax_settings_display_mode_check
  CHECK (display_mode IN ('including_tax', 'excluding_tax', 'no_tax'));

COMMENT ON COLUMN t_tax_settings.display_mode IS
  'including_tax | excluding_tax = how tax-inclusive/exclusive prices are entered/shown. no_tax = tenant is not tax-registered; no rate should ever apply.';

-- 2. get_tax_settings_with_rates — read path.
--    Returns {settings, rates} exactly as the UI's
--    validateTaxSettingsResponse expects. Auto-creates a default
--    'excluding_tax' settings row on first read if none exists yet.
CREATE OR REPLACE FUNCTION get_tax_settings_with_rates(
    p_tenant_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_settings RECORD;
    v_rates JSONB;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('error', 'tenant_id is required');
    END IF;

    SELECT * INTO v_settings FROM t_tax_settings WHERE tenant_id = p_tenant_id;

    IF v_settings IS NULL THEN
        INSERT INTO t_tax_settings (tenant_id, display_mode, default_tax_rate_id, version)
        VALUES (p_tenant_id, 'excluding_tax', NULL, 1)
        RETURNING * INTO v_settings;
    END IF;

    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', r.id,
                'tenant_id', r.tenant_id,
                'name', r.name,
                'rate', r.rate,
                'description', r.description,
                'sequence_no', r.sequence_no,
                'is_default', r.is_default,
                'is_active', r.is_active,
                'version', r.version,
                'created_at', r.created_at,
                'updated_at', r.updated_at
            )
            ORDER BY r.sequence_no ASC
        ),
        '[]'::JSONB
    )
    INTO v_rates
    FROM t_tax_rates r
    WHERE r.tenant_id = p_tenant_id AND r.is_active = true;

    RETURN jsonb_build_object(
        'settings', jsonb_build_object(
            'id', v_settings.id,
            'tenant_id', v_settings.tenant_id,
            'display_mode', v_settings.display_mode,
            'default_tax_rate_id', v_settings.default_tax_rate_id,
            'version', v_settings.version,
            'created_at', v_settings.created_at,
            'updated_at', v_settings.updated_at
        ),
        'rates', v_rates
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', 'Failed to fetch tax settings: ' || SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION get_tax_settings_with_rates(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_tax_settings_with_rates(UUID) TO service_role;

-- 3. create_or_update_tax_settings — write path.
--    Validates display_mode against the 3 allowed values. When
--    p_display_mode = 'no_tax', default_tax_rate_id is forced to NULL
--    regardless of what's passed in. Upserts on tenant_id (unique
--    constraint already exists: unique_tenant_tax_settings).
CREATE OR REPLACE FUNCTION create_or_update_tax_settings(
    p_tenant_id UUID,
    p_display_mode VARCHAR,
    p_default_tax_rate_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_existing RECORD;
    v_settings RECORD;
    v_is_update BOOLEAN;
    v_effective_rate_id UUID;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('error', 'tenant_id is required');
    END IF;

    IF p_display_mode NOT IN ('including_tax', 'excluding_tax', 'no_tax') THEN
        RETURN jsonb_build_object('error', 'Invalid display_mode. Must be "including_tax", "excluding_tax", or "no_tax"');
    END IF;

    v_effective_rate_id := CASE WHEN p_display_mode = 'no_tax' THEN NULL ELSE p_default_tax_rate_id END;

    SELECT * INTO v_existing FROM t_tax_settings WHERE tenant_id = p_tenant_id;
    v_is_update := v_existing IS NOT NULL;

    IF v_is_update THEN
        UPDATE t_tax_settings
        SET display_mode = p_display_mode,
            default_tax_rate_id = v_effective_rate_id,
            version = version + 1,
            updated_at = now()
        WHERE tenant_id = p_tenant_id
        RETURNING * INTO v_settings;
    ELSE
        INSERT INTO t_tax_settings (tenant_id, display_mode, default_tax_rate_id, version)
        VALUES (p_tenant_id, p_display_mode, v_effective_rate_id, 1)
        RETURNING * INTO v_settings;
    END IF;

    RETURN jsonb_build_object(
        'settings', jsonb_build_object(
            'id', v_settings.id,
            'tenant_id', v_settings.tenant_id,
            'display_mode', v_settings.display_mode,
            'default_tax_rate_id', v_settings.default_tax_rate_id,
            'version', v_settings.version,
            'created_at', v_settings.created_at,
            'updated_at', v_settings.updated_at
        ),
        'is_update', v_is_update
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', 'Failed to save tax settings: ' || SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION create_or_update_tax_settings(UUID, VARCHAR, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION create_or_update_tax_settings(UUID, VARCHAR, UUID) TO service_role;
