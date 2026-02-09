-- ============================================================================
-- Migration 026: Service Ticket RPC Functions
-- ============================================================================
-- Purpose: CRUD operations for service tickets
--
-- RPCs:
--   create_service_ticket    — Create ticket, generate TKT number, link events, audit
--   update_service_ticket    — Update status/assignment/notes with optimistic concurrency
--   get_service_tickets_list — Paginated list with filters
--   get_service_ticket_detail — Single ticket with linked events + evidence
--
-- Depends on: 022 (t_service_tickets), 023 (t_service_ticket_events),
--             024 (t_service_evidence), 025 (t_audit_log)
-- ============================================================================


-- ============================================================================
-- RPC: create_service_ticket
-- Creates a ticket, auto-generates TKT-XXXXX number, links events, writes audit
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
    -- Link events to ticket
    -- ═══════════════════════════════════════════
    IF array_length(p_event_ids, 1) > 0 THEN
        FOREACH v_event_id IN ARRAY p_event_ids
        LOOP
            -- Get event details for denormalization
            SELECT event_type, block_name INTO v_event_rec
            FROM t_contract_events
            WHERE id = v_event_id AND tenant_id = p_tenant_id;

            IF v_event_rec IS NOT NULL THEN
                INSERT INTO t_service_ticket_events (
                    ticket_id, event_id, event_type, block_name
                ) VALUES (
                    v_ticket_id, v_event_id, v_event_rec.event_type, v_event_rec.block_name
                ) ON CONFLICT (ticket_id, event_id) DO NOTHING;
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
-- Updates ticket with optimistic concurrency + audit trail
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


-- ============================================================================
-- RPC: get_service_tickets_list
-- Paginated list with filters (contract, status, assignment, date range)
-- ============================================================================
CREATE OR REPLACE FUNCTION get_service_tickets_list(
    p_tenant_id     UUID,
    p_contract_id   UUID DEFAULT NULL,
    p_status        TEXT DEFAULT NULL,
    p_assigned_to   UUID DEFAULT NULL,
    p_date_from     TEXT DEFAULT NULL,
    p_date_to       TEXT DEFAULT NULL,
    p_page          INT DEFAULT 1,
    p_per_page      INT DEFAULT 20,
    p_is_live       BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_offset    INT;
    v_total     INT;
    v_result    JSONB;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;

    -- Count total matching
    SELECT COUNT(*) INTO v_total
    FROM t_service_tickets st
    WHERE st.tenant_id = p_tenant_id
      AND st.is_active = true
      AND st.is_live = p_is_live
      AND (p_contract_id IS NULL OR st.contract_id = p_contract_id)
      AND (p_status IS NULL OR st.status = p_status)
      AND (p_assigned_to IS NULL OR st.assigned_to = p_assigned_to)
      AND (p_date_from IS NULL OR st.scheduled_date >= p_date_from::TIMESTAMPTZ)
      AND (p_date_to IS NULL OR st.scheduled_date <= p_date_to::TIMESTAMPTZ);

    -- Fetch page
    SELECT jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'tickets', COALESCE(jsonb_agg(ticket_row ORDER BY ticket_row->>'scheduled_date' DESC NULLS LAST), '[]'::jsonb),
            'pagination', jsonb_build_object(
                'page', p_page,
                'per_page', p_per_page,
                'total', v_total,
                'total_pages', CEIL(v_total::NUMERIC / p_per_page)
            )
        )
    ) INTO v_result
    FROM (
        SELECT jsonb_build_object(
            'id', st.id,
            'ticket_number', st.ticket_number,
            'contract_id', st.contract_id,
            'status', st.status,
            'scheduled_date', st.scheduled_date,
            'started_at', st.started_at,
            'completed_at', st.completed_at,
            'assigned_to', st.assigned_to,
            'assigned_to_name', st.assigned_to_name,
            'created_by_name', st.created_by_name,
            'notes', st.notes,
            'version', st.version,
            'created_at', st.created_at,
            'event_count', (
                SELECT COUNT(*) FROM t_service_ticket_events ste WHERE ste.ticket_id = st.id
            ),
            'evidence_count', (
                SELECT COUNT(*) FROM t_service_evidence se WHERE se.ticket_id = st.id AND se.is_active = true
            )
        ) AS ticket_row
        FROM t_service_tickets st
        WHERE st.tenant_id = p_tenant_id
          AND st.is_active = true
          AND st.is_live = p_is_live
          AND (p_contract_id IS NULL OR st.contract_id = p_contract_id)
          AND (p_status IS NULL OR st.status = p_status)
          AND (p_assigned_to IS NULL OR st.assigned_to = p_assigned_to)
          AND (p_date_from IS NULL OR st.scheduled_date >= p_date_from::TIMESTAMPTZ)
          AND (p_date_to IS NULL OR st.scheduled_date <= p_date_to::TIMESTAMPTZ)
        ORDER BY st.scheduled_date DESC NULLS LAST
        LIMIT p_per_page OFFSET v_offset
    ) sub;

    RETURN COALESCE(v_result, jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'tickets', '[]'::jsonb,
            'pagination', jsonb_build_object('page', p_page, 'per_page', p_per_page, 'total', 0, 'total_pages', 0)
        )
    ));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'code', 'RPC_ERROR');
END;
$$;


-- ============================================================================
-- RPC: get_service_ticket_detail
-- Single ticket with linked events + evidence summary
-- ============================================================================
CREATE OR REPLACE FUNCTION get_service_ticket_detail(
    p_ticket_id     UUID,
    p_tenant_id     UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_ticket    JSONB;
    v_events    JSONB;
    v_evidence  JSONB;
BEGIN
    -- Fetch ticket
    SELECT jsonb_build_object(
        'id', st.id,
        'ticket_number', st.ticket_number,
        'contract_id', st.contract_id,
        'status', st.status,
        'scheduled_date', st.scheduled_date,
        'started_at', st.started_at,
        'completed_at', st.completed_at,
        'assigned_to', st.assigned_to,
        'assigned_to_name', st.assigned_to_name,
        'created_by', st.created_by,
        'created_by_name', st.created_by_name,
        'notes', st.notes,
        'completion_notes', st.completion_notes,
        'version', st.version,
        'created_at', st.created_at,
        'updated_at', st.updated_at
    ) INTO v_ticket
    FROM t_service_tickets st
    WHERE st.id = p_ticket_id AND st.tenant_id = p_tenant_id AND st.is_active = true;

    IF v_ticket IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Ticket not found', 'code', 'NOT_FOUND');
    END IF;

    -- Fetch linked events
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', ce.id,
            'event_type', ce.event_type,
            'block_id', ce.block_id,
            'block_name', ce.block_name,
            'status', ce.status,
            'scheduled_date', ce.scheduled_date,
            'amount', ce.amount,
            'currency', ce.currency,
            'task_id', ce.task_id
        )
    ), '[]'::jsonb) INTO v_events
    FROM t_service_ticket_events ste
    JOIN t_contract_events ce ON ce.id = ste.event_id
    WHERE ste.ticket_id = p_ticket_id;

    -- Fetch evidence
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', se.id,
            'evidence_type', se.evidence_type,
            'label', se.label,
            'description', se.description,
            'status', se.status,
            'block_name', se.block_name,
            'file_url', se.file_url,
            'file_name', se.file_name,
            'file_type', se.file_type,
            'otp_verified', se.otp_verified,
            'form_template_name', se.form_template_name,
            'uploaded_by_name', se.uploaded_by_name,
            'verified_by_name', se.verified_by_name,
            'created_at', se.created_at
        ) ORDER BY se.created_at
    ), '[]'::jsonb) INTO v_evidence
    FROM t_service_evidence se
    WHERE se.ticket_id = p_ticket_id AND se.is_active = true;

    RETURN jsonb_build_object(
        'success', true,
        'data', v_ticket || jsonb_build_object(
            'events', v_events,
            'evidence', v_evidence
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'code', 'RPC_ERROR');
END;
$$;
