-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/004_step3fix_status_v2_materializes_jobs.sql
-- JTD Nucleus — Step 3 checkpoint fix (2026-08-18)
--
-- FOUND ON CN-1019 (first real wizard test): the wizard does NOT create
-- contracts in one shot. It creates an EMPTY DRAFT first (no blocks →
-- no computed_events → Step 2's create-time job block correctly skips),
-- then auto-saves via the V1 update path, then activates — where the V1
-- trigger materialized 16 legacy t_contract_events rows and zero jobs.
-- Proven from t_contract_history: created(draft) → 16× updated → active.
-- Bulk/VaNi single-shot creates DO carry computed_events at create and
-- get jobs; the wizard (highest-traffic caller) needs activation-time
-- materialization.
--
-- THE SEAM (no V1 object touched): trg_queue_contract_events fires only
-- when NEW.computed_events IS NOT NULL. So a V2 status transition that
-- writes jobs and CONSUMES computed_events BEFORE calling the V1 status
-- function makes the V1 trigger skip by its own guard.
--
-- OBJECTS (both NEW):
--   · jtd_materialize_jobs_from_computed(contract, tenant)
--       reads the ROW's computed_events → one n_jtd job per commitment
--       (same mapping as Step 2's create-time block), NULLs
--       computed_events. Idempotent: no-ops if jobs already exist or
--       nothing to consume. Shared by any V2 path that needs it.
--   · update_contract_status_v2(...same 8 args as V1...)
--       IF activating: materialize jobs first (same transaction), THEN
--       call the UNTOUCHED V1 update_contract_status (composition) —
--       CNAK minting, invoice generation, history all behave exactly
--       as V1, but the events trigger sees NULL and stays silent.
--
-- APPLIED LIVE 2026-08-18 — this file is the source-of-record copy.
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.jtd_materialize_jobs_from_computed(
    p_contract_id uuid,
    p_tenant_id   uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_c          RECORD;
    v_existing   integer;
    v_created    integer := 0;
BEGIN
    SELECT id, tenant_id, contract_number, record_type, computed_events,
           created_by, is_live
    INTO v_c
    FROM t_contracts
    WHERE id = p_contract_id AND tenant_id = p_tenant_id;

    IF v_c.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Contract not found');
    END IF;

    IF v_c.record_type IS DISTINCT FROM 'contract' THEN
        RETURN jsonb_build_object('success', true, 'jobs_created', 0, 'skipped', 'not a contract');
    END IF;

    -- Idempotency: jobs already born (single-shot create path) → no-op
    SELECT COUNT(*) INTO v_existing
    FROM n_jtd
    WHERE contract_id = p_contract_id AND tenant_id = p_tenant_id
      AND channel_code IS NULL AND COALESCE(is_active, true);
    IF v_existing > 0 THEN
        RETURN jsonb_build_object('success', true, 'jobs_created', 0, 'skipped', 'jobs already exist', 'existing', v_existing);
    END IF;

    IF v_c.computed_events IS NULL
       OR jsonb_typeof(v_c.computed_events) <> 'array'
       OR jsonb_array_length(v_c.computed_events) = 0 THEN
        RETURN jsonb_build_object('success', true, 'jobs_created', 0, 'skipped', 'no computed_events');
    END IF;

    INSERT INTO n_jtd (
        tenant_id, event_type_code, source_type_code, channel_code,
        source_id, source_ref,
        contract_id, block_id, block_name, category_id,
        billing_sub_type, billing_cycle_label,
        sequence_number, total_occurrences,
        scheduled_at, original_date,
        amount, currency, assigned_to, assigned_to_name, audience,
        status_code, performed_by_type, performed_by_id,
        is_live, created_by, updated_by
    )
    SELECT
        p_tenant_id,
        CASE WHEN ev->>'event_type' = 'service' THEN 'service_visit' ELSE 'payment' END,
        CASE WHEN ev->>'event_type' = 'service' THEN 'service_scheduled' ELSE 'payment_scheduled' END,
        NULL,
        p_contract_id,
        v_c.contract_number,
        p_contract_id,
        ev->>'block_id', ev->>'block_name', ev->>'category_id',
        ev->>'billing_sub_type', ev->>'billing_cycle_label',
        NULLIF(ev->>'sequence_number','')::INTEGER,
        NULLIF(ev->>'total_occurrences','')::INTEGER,
        (ev->>'scheduled_date')::TIMESTAMPTZ,
        (ev->>'scheduled_date')::TIMESTAMPTZ,
        NULLIF(ev->>'amount','')::NUMERIC,
        COALESCE(ev->>'currency', 'INR'),
        NULLIF(ev->>'assigned_to','')::UUID,
        ev->>'assigned_to_name',
        ev->>'audience',
        'scheduled',
        CASE WHEN v_c.created_by IS NOT NULL THEN 'user' ELSE 'system' END,
        v_c.created_by,
        v_c.is_live, v_c.created_by, v_c.created_by
    FROM jsonb_array_elements(v_c.computed_events) ev;

    GET DIAGNOSTICS v_created = ROW_COUNT;

    -- Consume: the V1 activation trigger's own guard
    -- (computed_events IS NOT NULL) now routes around the legacy path.
    UPDATE t_contracts
    SET computed_events = NULL
    WHERE id = p_contract_id AND tenant_id = p_tenant_id;

    RETURN jsonb_build_object('success', true, 'jobs_created', v_created);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to materialize jobs',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$function$;

COMMENT ON FUNCTION public.jtd_materialize_jobs_from_computed IS
'JTD Nucleus: turns a contract''s computed_events into n_jtd job rows (service_visit/payment, channel NULL) and consumes the JSON. Idempotent (skips when jobs exist or nothing to consume). Used by update_contract_status_v2 for wizard-drafted contracts; single-shot V2 creates write jobs at creation.';


CREATE OR REPLACE FUNCTION public.update_contract_status_v2(
    p_contract_id       uuid,
    p_tenant_id         uuid,
    p_new_status        character varying,
    p_performed_by_id   uuid,
    p_performed_by_name character varying,
    p_performed_by_type character varying,
    p_note              text,
    p_version           integer
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_mat jsonb;
BEGIN
    -- Activation: jobs first, same transaction. After this,
    -- computed_events is NULL, so V1's trg_queue_contract_events skips
    -- by its own guard — zero legacy t_contract_events rows are born.
    IF p_new_status = 'active' THEN
        v_mat := jtd_materialize_jobs_from_computed(p_contract_id, p_tenant_id);
        IF COALESCE((v_mat->>'success')::boolean, false) IS DISTINCT FROM true THEN
            RETURN v_mat;  -- surface the failure; nothing transitioned
        END IF;
    END IF;

    -- The UNTOUCHED V1 status engine does everything else exactly as
    -- always: transition validation, CNAK minting, invoice generation,
    -- history. Pure composition.
    RETURN update_contract_status(
        p_contract_id, p_tenant_id, p_new_status,
        p_performed_by_id, p_performed_by_name, p_performed_by_type,
        p_note, p_version
    );
END;
$function$;

COMMENT ON FUNCTION public.update_contract_status_v2 IS
'JTD Nucleus Step 3 fix: V2 status transition. On activation, materializes n_jtd job rows from computed_events and consumes the JSON BEFORE delegating to the untouched V1 update_contract_status — the V1 events trigger then skips by its own computed_events-NOT-NULL guard. All other transitions pass straight through. Covers the wizard''s draft→update→activate path (CN-1019 gap).';
