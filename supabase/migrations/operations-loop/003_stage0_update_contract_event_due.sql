-- ============================================================================
-- Migration: Stage 0 Runtime Loop — 003 update_contract_event accepts 'due'
-- ============================================================================
-- Purpose: The scanner sets events to 'due' (and 'overdue') directly. The
--          user-facing write RPC update_contract_event (contracts/013) has a
--          hardcoded transition CASE that does not know 'due' — without this
--          change the UI could not move a 'due' event to in_progress or
--          cancel it (INVALID_TRANSITION).
--          This is a full CREATE OR REPLACE of the 013 function with EXACTLY
--          ONE functional change: the added CASE branch for 'due'
--          (marked "STAGE 0 CHANGE" below). Everything else is verbatim.
-- Depends on: contracts/013_contract_events_rpc_functions.sql
-- Safe to re-run: Yes (CREATE OR REPLACE)
-- Applied by: OWNER — project uwyqhzotluikawcboldr
-- ============================================================================

CREATE OR REPLACE FUNCTION update_contract_event(
    p_event_id          UUID,
    p_tenant_id         UUID,
    p_payload           JSONB,              -- fields to update
    p_expected_version  INT,
    p_changed_by        UUID,
    p_changed_by_name   TEXT DEFAULT NULL,
    p_reason            TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current           RECORD;
    v_new_status        TEXT;
    v_is_valid          BOOLEAN;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_event_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'event_id is required');
    END IF;

    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    IF p_expected_version IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'version is required for optimistic concurrency'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Lock row + version check
    -- ═══════════════════════════════════════════
    SELECT * INTO v_current
    FROM t_contract_events
    WHERE id = p_event_id
      AND tenant_id = p_tenant_id
      AND is_active = true
    FOR UPDATE;

    IF v_current IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Event not found',
            'event_id', p_event_id
        );
    END IF;

    IF v_current.version <> p_expected_version THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Version conflict — event was modified by another user',
            'error_code', 'VERSION_CONFLICT',
            'current_version', v_current.version,
            'expected_version', p_expected_version
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Validate status transition (if changing)
    -- ═══════════════════════════════════════════
    IF p_payload ? 'status' THEN
        v_new_status := p_payload->>'status';

        -- Same status → no-op on status field
        IF v_new_status = v_current.status THEN
            NULL; -- skip validation
        ELSE
            v_is_valid := CASE
                WHEN v_current.status = 'scheduled'   AND v_new_status IN ('in_progress', 'cancelled')                         THEN true
                -- STAGE 0 CHANGE: scanner-set 'due' behaves like 'scheduled' for manual moves
                WHEN v_current.status = 'due'          AND v_new_status IN ('in_progress', 'cancelled')                         THEN true
                WHEN v_current.status = 'in_progress'  AND v_new_status IN ('completed', 'cancelled', 'overdue')                THEN true
                WHEN v_current.status = 'overdue'      AND v_new_status IN ('in_progress', 'completed', 'cancelled')            THEN true
                -- Terminal states: no transitions out
                WHEN v_current.status IN ('completed', 'cancelled')                                                              THEN false
                ELSE false
            END;

            IF NOT v_is_valid THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', format('Invalid status transition: %s → %s', v_current.status, v_new_status),
                    'error_code', 'INVALID_TRANSITION',
                    'current_status', v_current.status,
                    'requested_status', v_new_status
                );
            END IF;
        END IF;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Audit trail — one row per changed field
    -- ═══════════════════════════════════════════
    IF p_payload ? 'status' AND p_payload->>'status' IS DISTINCT FROM v_current.status THEN
        INSERT INTO t_contract_event_audit (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
        VALUES (p_event_id, p_tenant_id, 'status', v_current.status, p_payload->>'status', p_changed_by, p_changed_by_name, p_reason);
    END IF;

    IF p_payload ? 'scheduled_date' AND (p_payload->>'scheduled_date')::TIMESTAMPTZ IS DISTINCT FROM v_current.scheduled_date THEN
        INSERT INTO t_contract_event_audit (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
        VALUES (p_event_id, p_tenant_id, 'scheduled_date', v_current.scheduled_date::TEXT, p_payload->>'scheduled_date', p_changed_by, p_changed_by_name, p_reason);
    END IF;

    IF p_payload ? 'assigned_to' AND (p_payload->>'assigned_to')::UUID IS DISTINCT FROM v_current.assigned_to THEN
        INSERT INTO t_contract_event_audit (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
        VALUES (p_event_id, p_tenant_id, 'assigned_to', v_current.assigned_to::TEXT, p_payload->>'assigned_to', p_changed_by, p_changed_by_name, p_reason);
    END IF;

    IF p_payload ? 'notes' AND p_payload->>'notes' IS DISTINCT FROM v_current.notes THEN
        INSERT INTO t_contract_event_audit (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
        VALUES (p_event_id, p_tenant_id, 'notes', v_current.notes, p_payload->>'notes', p_changed_by, p_changed_by_name, p_reason);
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 4: Update event + increment version
    -- ═══════════════════════════════════════════
    UPDATE t_contract_events SET
        status          = CASE WHEN p_payload ? 'status'         THEN p_payload->>'status'                       ELSE status END,
        scheduled_date  = CASE WHEN p_payload ? 'scheduled_date' THEN (p_payload->>'scheduled_date')::TIMESTAMPTZ ELSE scheduled_date END,
        assigned_to     = CASE WHEN p_payload ? 'assigned_to'    THEN (p_payload->>'assigned_to')::UUID           ELSE assigned_to END,
        assigned_to_name= CASE WHEN p_payload ? 'assigned_to_name' THEN p_payload->>'assigned_to_name'           ELSE assigned_to_name END,
        notes           = CASE WHEN p_payload ? 'notes'          THEN p_payload->>'notes'                        ELSE notes END,
        version         = version + 1,
        updated_by      = p_changed_by
    WHERE id = p_event_id
      AND tenant_id = p_tenant_id;

    -- ═══════════════════════════════════════════
    -- STEP 5: Return updated event
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', p_event_id,
            'contract_id', v_current.contract_id,
            'status', CASE WHEN p_payload ? 'status' THEN p_payload->>'status' ELSE v_current.status END,
            'version', v_current.version + 1,
            'from_status', v_current.status,
            'to_status', CASE WHEN p_payload ? 'status' THEN p_payload->>'status' ELSE v_current.status END
        ),
        'updated_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to update contract event',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION update_contract_event(UUID, UUID, JSONB, INT, UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION update_contract_event(UUID, UUID, JSONB, INT, UUID, TEXT, TEXT) TO service_role;
