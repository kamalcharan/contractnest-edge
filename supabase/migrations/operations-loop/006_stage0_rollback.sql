-- ============================================================================
-- Migration: Stage 0 Runtime Loop — 006 ROLLBACK (apply ONLY to undo Stage 0)
-- ============================================================================
-- Undoes the runtime loop:
--   - unschedules the scanner cron
--   - drops run_contract_event_scanner
--   - restores the ORIGINAL contracts/013 update_contract_event (no 'due')
-- Deliberately KEPT (safe, data-preserving):
--   - dispatch-tracking columns (001) — dropping would destroy audit linkage
--   - 'due' status config rows (002) — events may hold status='due';
--     removing the config would orphan them. To also revert statuses:
--       UPDATE t_contract_events SET status='scheduled', version=version+1
--       WHERE status='due' AND is_active=true;
--     and deactivate config rows:
--       UPDATE m_event_status_config SET is_active=false WHERE status_code='due';
--   - the jtd-worker cron de-dupe (005) — the duplicate was a defect
-- ============================================================================

DO $$
DECLARE
    v_job RECORD;
BEGIN
    FOR v_job IN
        SELECT jobid FROM cron.job WHERE jobname = 'contract-event-scanner'
    LOOP
        PERFORM cron.unschedule(v_job.jobid);
        RAISE NOTICE 'Unscheduled contract-event-scanner (jobid %)', v_job.jobid;
    END LOOP;
END;
$$;

DROP FUNCTION IF EXISTS run_contract_event_scanner(INT, INT, INT, INT);

-- Restore original update_contract_event (verbatim from contracts/013)
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

    IF p_payload ? 'status' THEN
        v_new_status := p_payload->>'status';

        IF v_new_status = v_current.status THEN
            NULL; -- skip validation
        ELSE
            v_is_valid := CASE
                WHEN v_current.status = 'scheduled'   AND v_new_status IN ('in_progress', 'cancelled')                         THEN true
                WHEN v_current.status = 'in_progress'  AND v_new_status IN ('completed', 'cancelled', 'overdue')                THEN true
                WHEN v_current.status = 'overdue'      AND v_new_status IN ('in_progress', 'completed', 'cancelled')            THEN true
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
