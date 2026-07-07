-- ============================================================================
-- Migration: Stage 3 Appointments — 012 Table + RPCs
-- ============================================================================
-- Purpose (POA §4, Stage 3 — the one greenfield backend piece):
--   t_appointments: scheduling layer on service events (1 active appointment
--   per event, enforced by unique index). Statuses:
--     requested → accepted | declined | rescheduled | no_response
--     accepted  → completed | rescheduled | no_response | declined
--     rescheduled → accepted | declined | no_response
--     no_response → requested | accepted | declined
--     completed / declined are terminal ("declined" = no appointment needed)
--   Accepting WITH a date syncs the linked service event's scheduled_date
--   (audit row + version bump) so the Service Schedule reflects reality.
--   Manual mode: no JTD dispatch from appointments (appointment_reminder has
--   no configured provider template; VaNi stage adds auto-chasing).
-- Depends on: contracts/012 (t_contract_events), operations-loop/002 ('due')
-- Safe to re-run: Yes
-- Applied by: OWNER — project uwyqhzotluikawcboldr
-- ============================================================================

-- ─────────────────────────────────────────────
-- Table
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS t_appointments (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL,
    contract_id       UUID NOT NULL REFERENCES t_contracts(id) ON DELETE CASCADE,
    event_id          UUID NOT NULL REFERENCES t_contract_events(id) ON DELETE CASCADE,

    status            TEXT NOT NULL DEFAULT 'requested',
    proposed_slots    JSONB DEFAULT '[]'::jsonb,      -- [{slot: timestamptz, note}]
    scheduled_at      TIMESTAMPTZ,                     -- agreed slot (set on accept)
    assigned_to       UUID,
    assigned_to_name  TEXT,
    notes             TEXT,
    last_activity_at  TIMESTAMPTZ DEFAULT now(),       -- follow-up ageing

    version           INT NOT NULL DEFAULT 1,
    is_live           BOOLEAN DEFAULT true,
    is_active         BOOLEAN DEFAULT true,
    created_at        TIMESTAMPTZ DEFAULT now(),
    updated_at        TIMESTAMPTZ DEFAULT now(),
    created_by        UUID,
    updated_by        UUID
);

COMMENT ON TABLE t_appointments IS
    'Scheduling layer on service events (Stage 3). One active appointment per event; the kanban board (Operations → Appointments) works these.';

-- Hard idempotency: one active appointment per event (scanner re-runs safe)
CREATE UNIQUE INDEX IF NOT EXISTS uq_appointments_event
    ON t_appointments (event_id)
    WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_appointments_board
    ON t_appointments (tenant_id, status)
    WHERE is_active = true;

-- ─────────────────────────────────────────────
-- RPC: create_appointment (manual "request appointment" for an event)
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_appointment(
    p_tenant_id       UUID,
    p_event_id        UUID,
    p_notes           TEXT DEFAULT NULL,
    p_created_by      UUID DEFAULT NULL,
    p_created_by_name TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_evt RECORD;
    v_id  UUID;
BEGIN
    IF p_tenant_id IS NULL OR p_event_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id and event_id are required');
    END IF;

    SELECT e.id, e.tenant_id, e.contract_id, e.event_type, e.scheduled_date, e.is_live, e.status
    INTO v_evt
    FROM t_contract_events e
    WHERE e.id = p_event_id AND e.tenant_id = p_tenant_id AND e.is_active = true;

    IF v_evt IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Event not found', 'code', 'NOT_FOUND');
    END IF;

    IF v_evt.event_type <> 'service' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Appointments apply to service events only', 'code', 'INVALID_EVENT_TYPE');
    END IF;

    IF v_evt.status IN ('completed', 'cancelled') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Event is already closed', 'code', 'INVALID_STATUS');
    END IF;

    BEGIN
        INSERT INTO t_appointments
            (tenant_id, contract_id, event_id, status, proposed_slots, notes, is_live, created_by, updated_by)
        VALUES
            (p_tenant_id, v_evt.contract_id, p_event_id, 'requested',
             jsonb_build_array(jsonb_build_object('slot', v_evt.scheduled_date, 'note', 'event date')),
             p_notes, COALESCE(v_evt.is_live, true), p_created_by, p_created_by)
        RETURNING id INTO v_id;
    EXCEPTION WHEN unique_violation THEN
        RETURN jsonb_build_object('success', false, 'error', 'An active appointment already exists for this event', 'code', 'APPOINTMENT_EXISTS');
    END;

    INSERT INTO t_audit_log
        (tenant_id, entity_type, entity_id, contract_id, category, action, description, new_value, performed_by, performed_by_name)
    VALUES
        (p_tenant_id, 'appointment', v_id, v_evt.contract_id, 'status', 'appointment_requested',
         'Appointment requested for service event',
         jsonb_build_object('event_id', p_event_id, 'status', 'requested'),
         p_created_by, p_created_by_name);

    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('id', v_id, 'status', 'requested'));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'Failed to create appointment', 'details', SQLERRM, 'code', 'RPC_ERROR');
END;
$$;

GRANT EXECUTE ON FUNCTION create_appointment(UUID, UUID, TEXT, UUID, TEXT) TO service_role;

-- ─────────────────────────────────────────────
-- RPC: get_appointments_list (board feed — appointment + event + customer)
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_appointments_list(
    p_tenant_id UUID,
    p_is_live   BOOLEAN DEFAULT true,
    p_status    TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_items JSONB;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.event_date ASC NULLS LAST), '[]'::jsonb)
    INTO v_items
    FROM (
        SELECT a.id, a.status, a.proposed_slots, a.scheduled_at,
               a.assigned_to, a.assigned_to_name, a.notes, a.last_activity_at,
               a.version, a.created_at, a.updated_at,
               a.event_id, e.block_name, e.task_id, e.scheduled_date AS event_date, e.status AS event_status,
               a.contract_id, c.contract_number, c.name AS contract_name,
               c.buyer_id,
               COALESCE(c.buyer_company, c.buyer_name) AS buyer_name,
               COALESCE(NULLIF(TRIM(c.buyer_phone), ''), (
                   SELECT ch.value FROM t_contact_channels ch
                   WHERE ch.contact_id = c.buyer_id AND ch.channel_type IN ('mobile', 'whatsapp')
                   ORDER BY CASE ch.channel_type WHEN 'mobile' THEN 0 ELSE 1 END,
                            ch.is_primary DESC NULLS LAST, ch.created_at
                   LIMIT 1)) AS buyer_phone,
               COALESCE(NULLIF(TRIM(c.buyer_email), ''), (
                   SELECT ch.value FROM t_contact_channels ch
                   WHERE ch.contact_id = c.buyer_id AND ch.channel_type = 'email'
                   ORDER BY ch.is_primary DESC NULLS LAST, ch.created_at
                   LIMIT 1)) AS buyer_email
        FROM t_appointments a
        JOIN t_contract_events e ON e.id = a.event_id
        JOIN t_contracts c ON c.id = a.contract_id
        WHERE a.tenant_id = p_tenant_id
          AND a.is_active = true
          AND COALESCE(a.is_live, true) = p_is_live
          AND (p_status IS NULL OR a.status = p_status)
        LIMIT 500
    ) x;

    RETURN jsonb_build_object('success', true, 'data', v_items, 'retrieved_at', now());

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'Failed to fetch appointments', 'details', SQLERRM, 'code', 'RPC_ERROR');
END;
$$;

GRANT EXECUTE ON FUNCTION get_appointments_list(UUID, BOOLEAN, TEXT) TO service_role;

-- ─────────────────────────────────────────────
-- RPC: update_appointment (transitions + accept-syncs-event-date)
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_appointment(
    p_appointment_id   UUID,
    p_tenant_id        UUID,
    p_payload          JSONB,
    p_expected_version INT DEFAULT NULL,
    p_changed_by       UUID DEFAULT NULL,
    p_changed_by_name  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_cur          RECORD;
    v_new_status   TEXT;
    v_scheduled_at TIMESTAMPTZ;
    v_is_valid     BOOLEAN;
    v_evt          RECORD;
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

    -- Transition validation
    IF v_new_status IS DISTINCT FROM v_cur.status THEN
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

    -- Accept syncs the service event's scheduled date (audit + version bump)
    IF v_new_status = 'accepted' AND v_new_status IS DISTINCT FROM v_cur.status THEN
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
                 'Auto: appointment accepted for this slot');
        END IF;
    END IF;

    IF v_new_status IS DISTINCT FROM v_cur.status THEN
        INSERT INTO t_audit_log
            (tenant_id, entity_type, entity_id, contract_id, category, action, description,
             old_value, new_value, performed_by, performed_by_name)
        VALUES
            (p_tenant_id, 'appointment', p_appointment_id, v_cur.contract_id, 'status', 'appointment_status_changed',
             format('Appointment %s → %s', v_cur.status, v_new_status),
             jsonb_build_object('status', v_cur.status),
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
$$;

GRANT EXECUTE ON FUNCTION update_appointment(UUID, UUID, JSONB, INT, UUID, TEXT) TO service_role;
