-- ============================================================================
-- Migration: Stage 2 Services — 009 Ticket ↔ Event lifecycle propagation
-- ============================================================================
-- Purpose (owner-agreed 2026-07-07): ticket and event lifecycles were fully
-- decoupled (junction rows only). This wires them:
--   - create_service_ticket: linked SERVICE events at scheduled/due/overdue
--     → 'in_progress' (+ t_contract_event_audit row, version bump)
--   - update_service_ticket: ticket → 'in_progress' pulls lagging linked
--     service events forward; ticket → 'completed' completes linked service
--     events. Ticket cancellation leaves events untouched (manual re-decision).
--   - billing events linked to a ticket are NEVER touched.
-- Both functions are full CREATE OR REPLACE of contracts/026 versions; the
-- additions are marked "STAGE 2 CHANGE". Everything else is verbatim.
-- Depends on: contracts/026, operations-loop/002 ('due' status)
-- Safe to re-run: Yes
-- Applied by: OWNER — project uwyqhzotluikawcboldr
-- ============================================================================

-- ============================================================================
-- RPC: create_service_ticket
-- ============================================================================
CREATE OR REPLACE FUNCTION create_service_ticket(
    p_tenant_id         UUID,
    p_contract_id       UUID,
    p_scheduled_date    TIMESTAMPTZ DEFAULT NULL,
    p_assigned_to       UUID DEFAULT NULL,
    p_assigned_to_name  TEXT DEFAULT NULL,
    p_notes             TEXT DEFAULT NULL,
    p_event_ids         UUID[] DEFAULT '{}',
    p_created_by        UUID DEFAULT NULL,
    p_created_by_name   TEXT DEFAULT NULL,
    p_is_live           BOOLEAN DEFAULT true,
    p_idempotency_key   VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_ticket_id         UUID;
    v_ticket_number     TEXT;
    v_status            TEXT := 'created';
    v_seq_cat_id        UUID;
    v_seq_record        RECORD;
    v_task_prefix       TEXT := 'TKT';
    v_task_separator    TEXT := '-';
    v_task_padding      INT := 5;
    v_task_counter      INT := 10001;
    v_event_id          UUID;
    v_event_rec         RECORD;
BEGIN
    -- ═══════════════════════════════════════════
    -- Validation
    -- ═══════════════════════════════════════════
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    IF p_contract_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'contract_id is required');
    END IF;

    -- Verify contract exists and belongs to tenant
    IF NOT EXISTS (
        SELECT 1 FROM t_contracts
        WHERE id = p_contract_id AND tenant_id = p_tenant_id AND is_active = true
    ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'Contract not found', 'code', 'NOT_FOUND');
    END IF;

    -- ═══════════════════════════════════════════
    -- Generate TKT number via sequence system
    -- ═══════════════════════════════════════════
    SELECT id INTO v_seq_cat_id
    FROM t_category_master
    WHERE category_name = 'sequence_numbers'
    LIMIT 1;

    IF v_seq_cat_id IS NOT NULL THEN
        SELECT
            COALESCE(form_settings->>'prefix', 'TKT') AS prefix,
            COALESCE(form_settings->>'separator', '-') AS separator,
            COALESCE((form_settings->>'padding_length')::INT, 5) AS padding,
            COALESCE((form_settings->>'start_value')::INT, 10001) AS counter
        INTO v_seq_record
        FROM t_category_details
        WHERE tenant_id = p_tenant_id
          AND category_id = v_seq_cat_id
          AND sub_cat_name = 'TKT'
          AND is_active = true
        LIMIT 1;

        IF v_seq_record IS NOT NULL THEN
            v_task_prefix   := v_seq_record.prefix;
            v_task_separator := v_seq_record.separator;
            v_task_padding  := v_seq_record.padding;
            v_task_counter  := v_seq_record.counter;
        END IF;
    END IF;

    v_ticket_number := v_task_prefix || v_task_separator || LPAD(v_task_counter::TEXT, v_task_padding, '0');

    -- If assigned, set status to 'assigned'
    IF p_assigned_to IS NOT NULL THEN
        v_status := 'assigned';
    END IF;

    -- ═══════════════════════════════════════════
    -- Insert ticket
    -- ═══════════════════════════════════════════
    INSERT INTO t_service_tickets (
        tenant_id, contract_id, ticket_number, status,
        scheduled_date, assigned_to, assigned_to_name,
        created_by, created_by_name, notes,
        is_live
    ) VALUES (
        p_tenant_id, p_contract_id, v_ticket_number, v_status,
        p_scheduled_date, p_assigned_to, p_assigned_to_name,
        p_created_by, p_created_by_name, p_notes,
        p_is_live
    ) RETURNING id INTO v_ticket_id;

    -- ═══════════════════════════════════════════
    -- Link events to ticket (+ STAGE 2 CHANGE: propagate to service events)
    -- ═══════════════════════════════════════════
    IF array_length(p_event_ids, 1) > 0 THEN
        FOREACH v_event_id IN ARRAY p_event_ids
        LOOP
            -- Get event details for denormalization (STAGE 2: also status)
            SELECT event_type, block_name, status INTO v_event_rec
            FROM t_contract_events
            WHERE id = v_event_id AND tenant_id = p_tenant_id;

            IF v_event_rec IS NOT NULL THEN
                INSERT INTO t_service_ticket_events (
                    ticket_id, event_id, event_type, block_name
                ) VALUES (
                    v_ticket_id, v_event_id, v_event_rec.event_type, v_event_rec.block_name
                ) ON CONFLICT (ticket_id, event_id) DO NOTHING;

                -- STAGE 2 CHANGE: work has started — service events move to
                -- in_progress (billing events are never touched by tickets)
                IF v_event_rec.event_type = 'service'
                   AND v_event_rec.status IN ('scheduled', 'due', 'overdue') THEN
                    UPDATE t_contract_events
                    SET status = 'in_progress', version = version + 1,
                        updated_by = p_created_by, updated_at = NOW()
                    WHERE id = v_event_id;

                    INSERT INTO t_contract_event_audit
                        (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
                    VALUES
                        (v_event_id, p_tenant_id, 'status', v_event_rec.status, 'in_progress',
                         p_created_by, COALESCE(p_created_by_name, 'Service Execution'),
                         'Auto: service ticket ' || v_ticket_number || ' created');
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- ═══════════════════════════════════════════
    -- Advance TKT sequence counter
    -- ═══════════════════════════════════════════
    IF v_seq_cat_id IS NOT NULL THEN
        UPDATE t_category_details
        SET form_settings = jsonb_set(
            COALESCE(form_settings, '{}'::JSONB),
            '{start_value}',
            to_jsonb(v_task_counter + 1)
        )
        WHERE tenant_id = p_tenant_id
          AND category_id = v_seq_cat_id
          AND sub_cat_name = 'TKT';
    END IF;

    -- ═══════════════════════════════════════════
    -- Write audit entry
    -- ═══════════════════════════════════════════
    INSERT INTO t_audit_log (
        tenant_id, entity_type, entity_id, contract_id,
        category, action, description,
        new_value, performed_by, performed_by_name
    ) VALUES (
        p_tenant_id, 'service_ticket', v_ticket_id, p_contract_id,
        'status', 'ticket_created',
        'Service ticket ' || v_ticket_number || ' created',
        jsonb_build_object(
            'ticket_number', v_ticket_number,
            'status', v_status,
            'assigned_to', p_assigned_to,
            'assigned_to_name', p_assigned_to_name,
            'event_count', COALESCE(array_length(p_event_ids, 1), 0)
        ),
        p_created_by, p_created_by_name
    );

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', v_ticket_id,
            'ticket_number', v_ticket_number,
            'status', v_status,
            'contract_id', p_contract_id
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to create service ticket',
        'details', SQLERRM,
        'code', 'RPC_ERROR'
    );
END;
$$;


-- ============================================================================
-- RPC: update_service_ticket
-- ============================================================================
CREATE OR REPLACE FUNCTION update_service_ticket(
    p_ticket_id         UUID,
    p_tenant_id         UUID,
    p_payload           JSONB,
    p_expected_version  INT DEFAULT NULL,
    p_changed_by        UUID DEFAULT NULL,
    p_changed_by_name   TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current           RECORD;
    v_new_status        TEXT;
    v_new_assigned_to   UUID;
    v_new_assigned_name TEXT;
    v_new_notes         TEXT;
    v_new_comp_notes    TEXT;
    v_contract_id       UUID;
    v_evt               RECORD;   -- STAGE 2 CHANGE
BEGIN
    -- ═══════════════════════════════════════════
    -- Fetch current ticket
    -- ═══════════════════════════════════════════
    SELECT id, tenant_id, contract_id, ticket_number, status,
           assigned_to, assigned_to_name, notes, completion_notes, version
    INTO v_current
    FROM t_service_tickets
    WHERE id = p_ticket_id AND tenant_id = p_tenant_id AND is_active = true;

    IF v_current IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Ticket not found', 'code', 'NOT_FOUND');
    END IF;

    v_contract_id := v_current.contract_id;

    -- ═══════════════════════════════════════════
    -- Optimistic concurrency check
    -- ═══════════════════════════════════════════
    IF p_expected_version IS NOT NULL AND v_current.version != p_expected_version THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Version conflict — ticket was modified by another user',
            'code', 'VERSION_CONFLICT',
            'current_version', v_current.version
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- Extract fields from payload
    -- ═══════════════════════════════════════════
    v_new_status        := COALESCE(p_payload->>'status', v_current.status);
    v_new_assigned_to   := COALESCE((p_payload->>'assigned_to')::UUID, v_current.assigned_to);
    v_new_assigned_name := COALESCE(p_payload->>'assigned_to_name', v_current.assigned_to_name);
    v_new_notes         := COALESCE(p_payload->>'notes', v_current.notes);
    v_new_comp_notes    := COALESCE(p_payload->>'completion_notes', v_current.completion_notes);

    -- ═══════════════════════════════════════════
    -- Audit: status change
    -- ═══════════════════════════════════════════
    IF v_new_status IS DISTINCT FROM v_current.status THEN
        INSERT INTO t_audit_log (
            tenant_id, entity_type, entity_id, contract_id,
            category, action, description,
            old_value, new_value,
            performed_by, performed_by_name
        ) VALUES (
            p_tenant_id, 'service_ticket', p_ticket_id, v_contract_id,
            'status', 'ticket_status_changed',
            'Ticket ' || v_current.ticket_number || ' status changed',
            jsonb_build_object('status', v_current.status),
            jsonb_build_object('status', v_new_status),
            p_changed_by, p_changed_by_name
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- Audit: assignment change
    -- ═══════════════════════════════════════════
    IF v_new_assigned_to IS DISTINCT FROM v_current.assigned_to THEN
        INSERT INTO t_audit_log (
            tenant_id, entity_type, entity_id, contract_id,
            category, action, description,
            old_value, new_value,
            performed_by, performed_by_name
        ) VALUES (
            p_tenant_id, 'service_ticket', p_ticket_id, v_contract_id,
            'assignment', 'tech_assigned',
            'Technician ' || CASE WHEN v_current.assigned_to IS NULL THEN 'assigned' ELSE 'reassigned' END
                || ' for ' || v_current.ticket_number,
            jsonb_build_object('assigned_to', v_current.assigned_to, 'assigned_to_name', v_current.assigned_to_name),
            jsonb_build_object('assigned_to', v_new_assigned_to, 'assigned_to_name', v_new_assigned_name),
            p_changed_by, p_changed_by_name
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- Apply update
    -- ═══════════════════════════════════════════
    UPDATE t_service_tickets
    SET status           = v_new_status,
        assigned_to      = v_new_assigned_to,
        assigned_to_name = v_new_assigned_name,
        notes            = v_new_notes,
        completion_notes = v_new_comp_notes,
        started_at       = CASE WHEN v_new_status = 'in_progress' AND started_at IS NULL THEN NOW() ELSE started_at END,
        completed_at     = CASE WHEN v_new_status = 'completed' THEN NOW() ELSE completed_at END,
        version          = version + 1,
        updated_by       = p_changed_by
    WHERE id = p_ticket_id;

    -- ═══════════════════════════════════════════
    -- STAGE 2 CHANGE: propagate ticket lifecycle to linked SERVICE events
    --   ticket → in_progress : pull lagging events forward
    --   ticket → completed   : complete the events
    --   ticket → cancelled   : events untouched (manual re-decision)
    -- ═══════════════════════════════════════════
    IF v_new_status IS DISTINCT FROM v_current.status
       AND v_new_status IN ('in_progress', 'completed') THEN
        FOR v_evt IN
            SELECT ce.id, ce.status
            FROM t_service_ticket_events ste
            JOIN t_contract_events ce ON ce.id = ste.event_id
            WHERE ste.ticket_id = p_ticket_id
              AND ce.tenant_id = p_tenant_id
              AND ce.is_active = true
              AND ce.event_type = 'service'
              AND (
                    (v_new_status = 'in_progress' AND ce.status IN ('scheduled', 'due', 'overdue'))
                 OR (v_new_status = 'completed'   AND ce.status IN ('scheduled', 'due', 'overdue', 'in_progress'))
              )
        LOOP
            UPDATE t_contract_events
            SET status = v_new_status, version = version + 1,
                updated_by = p_changed_by, updated_at = NOW()
            WHERE id = v_evt.id;

            INSERT INTO t_contract_event_audit
                (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
            VALUES
                (v_evt.id, p_tenant_id, 'status', v_evt.status, v_new_status,
                 p_changed_by, COALESCE(p_changed_by_name, 'Service Execution'),
                 'Auto: ticket ' || v_current.ticket_number ||
                 CASE WHEN v_new_status = 'completed' THEN ' completed' ELSE ' started' END);
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', p_ticket_id,
            'ticket_number', v_current.ticket_number,
            'status', v_new_status,
            'version', v_current.version + 1
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to update service ticket',
        'details', SQLERRM,
        'code', 'RPC_ERROR'
    );
END;
$$;
