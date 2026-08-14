-- ═══════════════════════════════════════════════════════════════
-- Migration 077: Restore tax-rate CRUD atomic RPCs
-- ═══════════════════════════════════════════════════════════════
-- ROOT CAUSE: create_tax_rate_atomic / update_tax_rate_atomic /
-- delete_tax_rate_atomic — called by supabase/functions/tax-settings/
-- index.ts for every rate create/edit/delete — do not exist in the
-- database. Confirmed via pg_proc: zero functions matching
-- '%tax_rate%' besides the (unwired, no triggers attached)
-- ensure_single_default_tax_rate / validate_tax_rate_business_rules /
-- get_next_tax_rate_sequence / reorder_tax_rate_sequences helpers.
--
-- Same class of bug as migration 064 (functions applied live outside
-- any tracked migration, then lost in a later reset) — in fact almost
-- certainly the SAME incident: 064 restored two sibling RPCs from this
-- exact edge function file (get_tax_settings_with_rates,
-- create_or_update_tax_settings) on 2026-07-19 after finding those
-- missing, but never checked the other three RPCs the same file also
-- calls. Data confirms the timeline: t_tax_rates.version increments
-- (proving real updates worked) as late as 2026-01-14; BBB's rates
-- were still createable on 2026-07-16 (3 days before the 064 fix);
-- zero successful edits/deletes anywhere since — nobody happened to
-- try editing a rate again until now (2026-08-14), which is how this
-- sat undetected for a month.
--
-- The edge function already calls these exact RPC names with these
-- exact param names, and already parses specific error shapes from
-- them (DUPLICATE_TAX_RATE:{...} message, error.code 'P0002' for not
-- found, error.code '40001' for optimistic-concurrency conflict,
-- message containing 'already deleted' / 'default tax rate' for
-- delete-guard cases) — see index.ts handleCreateRate/handleUpdateRate/
-- handleDeleteRate. No edge function or API changes required; this
-- migration only recreates the DB-side functions to match that
-- existing, already-deployed contract.
-- ═══════════════════════════════════════════════════════════════

-- 1. create_tax_rate_atomic
--    Duplicate check (same name+rate, active) -> raises
--    'DUPLICATE_TAX_RATE:{...}' (edge fn regex-parses this exact
--    string). Assigns next sequence_no. Forces is_default=true if
--    this is the tenant's first active rate (mirrors the unwired
--    validate_tax_rate_business_rules logic). Unsets other defaults
--    if p_is_default=true. Returns the inserted row as JSONB.
CREATE OR REPLACE FUNCTION create_tax_rate_atomic(
    p_tenant_id UUID,
    p_name VARCHAR,
    p_rate NUMERIC,
    p_is_default BOOLEAN DEFAULT FALSE,
    p_description TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_existing RECORD;
    v_active_count INTEGER;
    v_next_seq INTEGER;
    v_final_default BOOLEAN;
    v_new RECORD;
BEGIN
    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION 'tenant_id is required';
    END IF;

    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        RAISE EXCEPTION 'Tax rate name cannot be empty';
    END IF;

    IF p_rate IS NULL OR p_rate < 0 OR p_rate > 100 THEN
        RAISE EXCEPTION 'Tax rate must be between 0 and 100 percent';
    END IF;

    -- Duplicate check: same (normalized) name + rate, still active
    SELECT * INTO v_existing
    FROM t_tax_rates
    WHERE tenant_id = p_tenant_id
      AND is_active = true
      AND UPPER(TRIM(name)) = UPPER(TRIM(p_name))
      AND rate = p_rate
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'DUPLICATE_TAX_RATE:%',
            jsonb_build_object('existing_rate', to_jsonb(v_existing))::text;
    END IF;

    SELECT COUNT(*) INTO v_active_count
    FROM t_tax_rates
    WHERE tenant_id = p_tenant_id AND is_active = true;

    -- First active rate for the tenant is always the default
    v_final_default := (v_active_count = 0) OR COALESCE(p_is_default, false);

    v_next_seq := get_next_tax_rate_sequence(p_tenant_id);

    IF v_final_default THEN
        UPDATE t_tax_rates
        SET is_default = false, updated_at = now()
        WHERE tenant_id = p_tenant_id AND is_active = true AND is_default = true;
    END IF;

    INSERT INTO t_tax_rates (
        tenant_id, name, rate, description, sequence_no,
        is_default, is_active, version, created_at, updated_at
    ) VALUES (
        p_tenant_id, TRIM(p_name), p_rate, NULLIF(TRIM(p_description), ''), v_next_seq,
        v_final_default, true, 1, now(), now()
    )
    RETURNING * INTO v_new;

    RETURN to_jsonb(v_new);
END;
$$;

GRANT EXECUTE ON FUNCTION create_tax_rate_atomic(UUID, VARCHAR, NUMERIC, BOOLEAN, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION create_tax_rate_atomic(UUID, VARCHAR, NUMERIC, BOOLEAN, TEXT) TO service_role;

-- 2. update_tax_rate_atomic
--    Row-not-found -> ERRCODE 'P0002' (edge fn checks this exact
--    code). Version mismatch -> ERRCODE '40001' (optimistic
--    concurrency; edge fn already handles this as "modified by
--    another user"). NULL params mean "leave unchanged" (matches the
--    edge fn's requestData?.field !== undefined ? value : null
--    mapping). Same duplicate-check + default-switch as create.
--    Increments version, updates updated_at.
CREATE OR REPLACE FUNCTION update_tax_rate_atomic(
    p_tenant_id UUID,
    p_rate_id UUID,
    p_name VARCHAR DEFAULT NULL,
    p_rate NUMERIC DEFAULT NULL,
    p_is_default BOOLEAN DEFAULT NULL,
    p_description TEXT DEFAULT NULL,
    p_expected_version INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current RECORD;
    v_existing RECORD;
    v_new_name VARCHAR;
    v_new_rate NUMERIC;
    v_new_default BOOLEAN;
    v_updated RECORD;
BEGIN
    SELECT * INTO v_current
    FROM t_tax_rates
    WHERE id = p_rate_id AND tenant_id = p_tenant_id AND is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tax rate not found or has been deleted' USING ERRCODE = 'P0002';
    END IF;

    IF p_expected_version IS NOT NULL AND v_current.version <> p_expected_version THEN
        RAISE EXCEPTION 'Tax rate was modified by another user' USING ERRCODE = '40001';
    END IF;

    v_new_name := COALESCE(NULLIF(TRIM(p_name), ''), v_current.name);
    v_new_rate := COALESCE(p_rate, v_current.rate);
    v_new_default := COALESCE(p_is_default, v_current.is_default);

    IF v_new_rate < 0 OR v_new_rate > 100 THEN
        RAISE EXCEPTION 'Tax rate must be between 0 and 100 percent';
    END IF;

    -- Duplicate check against other active rates
    SELECT * INTO v_existing
    FROM t_tax_rates
    WHERE tenant_id = p_tenant_id
      AND is_active = true
      AND id <> p_rate_id
      AND UPPER(TRIM(name)) = UPPER(TRIM(v_new_name))
      AND rate = v_new_rate
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'DUPLICATE_TAX_RATE:%',
            jsonb_build_object('existing_rate', to_jsonb(v_existing))::text;
    END IF;

    IF v_new_default THEN
        UPDATE t_tax_rates
        SET is_default = false, updated_at = now()
        WHERE tenant_id = p_tenant_id AND is_active = true AND is_default = true AND id <> p_rate_id;
    END IF;

    UPDATE t_tax_rates
    SET name = v_new_name,
        rate = v_new_rate,
        is_default = v_new_default,
        description = CASE WHEN p_description IS NOT NULL THEN NULLIF(TRIM(p_description), '') ELSE description END,
        version = version + 1,
        updated_at = now()
    WHERE id = p_rate_id
    RETURNING * INTO v_updated;

    RETURN to_jsonb(v_updated);
END;
$$;

GRANT EXECUTE ON FUNCTION update_tax_rate_atomic(UUID, UUID, VARCHAR, NUMERIC, BOOLEAN, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION update_tax_rate_atomic(UUID, UUID, VARCHAR, NUMERIC, BOOLEAN, TEXT, INTEGER) TO service_role;

-- 3. delete_tax_rate_atomic (soft delete)
--    Not-found -> 'P0002'. Already-inactive -> message containing
--    'already deleted'. Default rate -> message containing 'default
--    tax rate' (edge fn blocks this with "set another rate as default
--    first" rather than auto-reassigning — matches its existing
--    error-branch expectations). Returns {deletedRate: <row>} since
--    the edge fn's audit log reads data.deletedRate.
CREATE OR REPLACE FUNCTION delete_tax_rate_atomic(
    p_tenant_id UUID,
    p_rate_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current RECORD;
    v_deleted RECORD;
BEGIN
    SELECT * INTO v_current
    FROM t_tax_rates
    WHERE id = p_rate_id AND tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tax rate not found' USING ERRCODE = 'P0002';
    END IF;

    IF v_current.is_active = false THEN
        RAISE EXCEPTION 'Tax rate is already deleted';
    END IF;

    IF v_current.is_default = true THEN
        RAISE EXCEPTION 'Cannot delete the default tax rate. Please set another rate as default first.';
    END IF;

    UPDATE t_tax_rates
    SET is_active = false, version = version + 1, updated_at = now()
    WHERE id = p_rate_id
    RETURNING * INTO v_deleted;

    RETURN jsonb_build_object('deletedRate', to_jsonb(v_deleted));
END;
$$;

GRANT EXECUTE ON FUNCTION delete_tax_rate_atomic(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION delete_tax_rate_atomic(UUID, UUID) TO service_role;
