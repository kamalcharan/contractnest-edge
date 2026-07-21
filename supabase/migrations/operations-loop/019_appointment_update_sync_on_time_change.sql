-- update_appointment previously gated BOTH the t_contract_events sync and
-- the t_audit_log insert purely on `status` changing. A same-status
-- reschedule (accepted -> accepted with a new scheduled_at, which the
-- Appointments board's one-step Reschedule flow now performs) silently
-- skipped both — no Contract-Tasks sync, no audit trail. Confirmed live
-- against a real BBB appointment before this fix: status-only reschedule
-- wrote nothing to either table.
--
-- Fix: add v_status_changed / v_time_changed booleans and fire the sync +
-- audit blocks on EITHER changing, not just status. Also added a guard so
-- an in-place time-only "accept" (status already accepted) still requires
-- a scheduled_at. Already applied live and verified — this file is the
-- permanent record.

CREATE OR REPLACE FUNCTION public.update_appointment(p_appointment_id uuid, p_tenant_id uuid, p_payload jsonb, p_expected_version integer DEFAULT NULL::integer, p_changed_by uuid DEFAULT NULL::uuid, p_changed_by_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_cur          RECORD;
    v_new_status   TEXT;
    v_scheduled_at TIMESTAMPTZ;
    v_is_valid     BOOLEAN;
    v_evt          RECORD;
    v_status_changed BOOLEAN;
    v_time_changed BOOLEAN;
BEGIN
    SELECT * INTO v_cur
    FROM t_appointments
    WHERE id = p_appointment_id AND tenant_id = p_tenant_id AND is_active = true
    FOR UPDATE;

    IF v_cur IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Appointment not found', 'code', 'NOT_FOUND');
    END IF;

    IF p_expected_version IS NOT NULL AND v_cur.version <> p_expected_version THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Version conflict — appointment was modified by another user',
            'code', 'VERSION_CONFLICT',
            'current_version', v_cur.version
        );
    END IF;

    v_new_status   := COALESCE(p_payload->>'status', v_cur.status);
    v_scheduled_at := COALESCE((p_payload->>'scheduled_at')::TIMESTAMPTZ, v_cur.scheduled_at);
    v_status_changed := v_new_status IS DISTINCT FROM v_cur.status;
    v_time_changed := v_scheduled_at IS DISTINCT FROM v_cur.scheduled_at;

    IF v_status_changed THEN
        v_is_valid := CASE
            WHEN v_cur.status = 'requested'   AND v_new_status IN ('accepted', 'declined', 'rescheduled', 'no_response') THEN true
            WHEN v_cur.status = 'accepted'    AND v_new_status IN ('completed', 'rescheduled', 'no_response', 'declined') THEN true
            WHEN v_cur.status = 'rescheduled' AND v_new_status IN ('accepted', 'declined', 'no_response')                THEN true
            WHEN v_cur.status = 'no_response' AND v_new_status IN ('requested', 'accepted', 'declined')                  THEN true
            WHEN v_cur.status IN ('completed', 'declined')                                                                THEN false
            ELSE false
        END;

        IF NOT v_is_valid THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', format('Invalid transition: %s → %s', v_cur.status, v_new_status),
                'code', 'INVALID_TRANSITION'
            );
        END IF;

        IF v_new_status = 'accepted' AND v_scheduled_at IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'scheduled_at is required to accept an appointment',
                'code', 'MISSING_SCHEDULED_AT'
            );
        END IF;
    END IF;

    IF NOT v_status_changed AND v_time_changed AND v_new_status = 'accepted' AND v_scheduled_at IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'scheduled_at is required to accept an appointment',
            'code', 'MISSING_SCHEDULED_AT'
        );
    END IF;

    UPDATE t_appointments
    SET status           = v_new_status,
        scheduled_at     = v_scheduled_at,
        proposed_slots   = COALESCE((p_payload->'proposed_slots'), proposed_slots),
        assigned_to      = COALESCE((p_payload->>'assigned_to')::UUID, assigned_to),
        assigned_to_name = COALESCE(p_payload->>'assigned_to_name', assigned_to_name),
        notes            = COALESCE(p_payload->>'notes', notes),
        last_activity_at = now(),
        version          = version + 1,
        updated_by       = p_changed_by,
        updated_at       = now()
    WHERE id = p_appointment_id;

    IF v_new_status = 'accepted' AND v_time_changed THEN
        SELECT id, status, scheduled_date INTO v_evt
        FROM t_contract_events
        WHERE id = v_cur.event_id AND is_active = true
        FOR UPDATE;

        IF v_evt.id IS NOT NULL AND v_evt.scheduled_date IS DISTINCT FROM v_scheduled_at THEN
            UPDATE t_contract_events
            SET scheduled_date = v_scheduled_at, version = version + 1,
                updated_by = p_changed_by, updated_at = now()
            WHERE id = v_evt.id;

            INSERT INTO t_contract_event_audit
                (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
            VALUES
                (v_evt.id, p_tenant_id, 'scheduled_date', v_evt.scheduled_date::TEXT, v_scheduled_at::TEXT,
                 p_changed_by, COALESCE(p_changed_by_name, 'Appointments'),
                 CASE WHEN v_status_changed THEN 'Auto: appointment accepted for this slot' ELSE 'Auto: appointment rescheduled to a new slot' END);
        END IF;
    END IF;

    IF v_status_changed OR v_time_changed THEN
        INSERT INTO t_audit_log
            (tenant_id, entity_type, entity_id, contract_id, category, action, description,
             old_value, new_value, performed_by, performed_by_name)
        VALUES
            (p_tenant_id, 'appointment', p_appointment_id,
             v_cur.contract_id,
             CASE WHEN v_status_changed THEN 'status' ELSE 'schedule' END,
             CASE WHEN v_status_changed THEN 'appointment_status_changed' ELSE 'appointment_rescheduled' END,
             CASE WHEN v_status_changed THEN format('Appointment %s → %s', v_cur.status, v_new_status)
                  ELSE format('Appointment rescheduled to %s', v_scheduled_at) END,
             jsonb_build_object('status', v_cur.status, 'scheduled_at', v_cur.scheduled_at),
             jsonb_build_object('status', v_new_status, 'scheduled_at', v_scheduled_at),
             p_changed_by, p_changed_by_name);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', p_appointment_id,
            'status', v_new_status,
            'scheduled_at', v_scheduled_at,
            'version', v_cur.version + 1
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'Failed to update appointment', 'details', SQLERRM, 'code', 'RPC_ERROR');
END;
$function$;
