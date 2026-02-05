-- =============================================================
-- CONTRACT EVENTS RPC FUNCTIONS
-- Migration: contracts/013_contract_events_rpc_functions.sql
-- Functions:
--   1. insert_contract_events_batch   (bulk insert + audit)
--   2. update_contract_event          (version check + audit)
--   3. get_contract_events_list       (paginated, multi-scope)
--   4. get_contract_events_date_summary (date buckets, multi-scope)
--   5. process_contract_events_from_computed (PGMQ worker)
--   6. Trigger: queue event creation on contract activation
--
-- All functions: SECURITY DEFINER, search_path = public
-- All reads: single query, JSON shaping in Postgres
-- All writes: transactional, idempotent, audited
-- =============================================================


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- 1. insert_contract_events_batch
--    Bulk-insert events from a JSONB array into t_contract_events.
--    Creates initial audit row per event (status='scheduled').
--    Idempotent via existing t_idempotency_keys framework.
--    Enforces 500-event cap per call.
--
--    Called by: PGMQ worker (process_contract_events_from_computed)
--              or directly via Edge Function on manual trigger.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE OR REPLACE FUNCTION insert_contract_events_batch(
    p_tenant_id         UUID,
    p_contract_id       UUID,
    p_events            JSONB,              -- array of event objects
    p_created_by        UUID,
    p_is_live           BOOLEAN DEFAULT true,
    p_idempotency_key   VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_idempotency       RECORD;
    v_event             JSONB;
    v_event_id          UUID;
    v_inserted_ids      UUID[] := '{}';
    v_count             INT := 0;
    v_max_events        INT := 500;
    v_response          JSONB;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    IF p_contract_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'contract_id is required');
    END IF;

    IF p_events IS NULL OR jsonb_array_length(p_events) = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'events array is required and cannot be empty');
    END IF;

    IF jsonb_array_length(p_events) > v_max_events THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('Cannot insert more than %s events per batch', v_max_events),
            'received', jsonb_array_length(p_events)
        );
    END IF;

    -- Verify contract exists and belongs to tenant
    IF NOT EXISTS (
        SELECT 1 FROM t_contracts
        WHERE id = p_contract_id AND tenant_id = p_tenant_id AND is_active = true
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found',
            'contract_id', p_contract_id
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Idempotency check
    -- ═══════════════════════════════════════════
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_idempotency
        FROM check_idempotency(
            p_idempotency_key,
            p_tenant_id,
            'insert_contract_events_batch'
        );

        IF v_idempotency.found THEN
            RETURN v_idempotency.response_body;
        END IF;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Bulk insert events (unnest JSONB array)
    -- ═══════════════════════════════════════════
    FOR v_event IN SELECT * FROM jsonb_array_elements(p_events)
    LOOP
        INSERT INTO t_contract_events (
            tenant_id,
            contract_id,
            block_id,
            block_name,
            category_id,
            event_type,
            billing_sub_type,
            billing_cycle_label,
            sequence_number,
            total_occurrences,
            scheduled_date,
            original_date,
            amount,
            currency,
            status,
            assigned_to,
            assigned_to_name,
            notes,
            is_live,
            created_by,
            updated_by
        )
        VALUES (
            p_tenant_id,
            p_contract_id,
            v_event->>'block_id',
            v_event->>'block_name',
            v_event->>'category_id',
            v_event->>'event_type',
            v_event->>'billing_sub_type',
            v_event->>'billing_cycle_label',
            (v_event->>'sequence_number')::INT,
            (v_event->>'total_occurrences')::INT,
            (v_event->>'scheduled_date')::TIMESTAMPTZ,
            (v_event->>'original_date')::TIMESTAMPTZ,
            (v_event->>'amount')::NUMERIC,
            COALESCE(v_event->>'currency', 'INR'),
            'scheduled',
            (v_event->>'assigned_to')::UUID,
            v_event->>'assigned_to_name',
            v_event->>'notes',
            p_is_live,
            p_created_by,
            p_created_by
        )
        RETURNING id INTO v_event_id;

        -- Initial audit row
        INSERT INTO t_contract_event_audit (
            event_id, tenant_id,
            field_changed, old_value, new_value,
            changed_by, changed_by_name, reason
        )
        VALUES (
            v_event_id, p_tenant_id,
            'status', NULL, 'scheduled',
            p_created_by, NULL, 'Event created'
        );

        v_inserted_ids := array_append(v_inserted_ids, v_event_id);
        v_count := v_count + 1;
    END LOOP;

    -- ═══════════════════════════════════════════
    -- STEP 3: Build response
    -- ═══════════════════════════════════════════
    v_response := jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'contract_id', p_contract_id,
            'inserted_count', v_count,
            'event_ids', to_jsonb(v_inserted_ids)
        ),
        'created_at', NOW()
    );

    -- Store idempotency (if key provided)
    IF p_idempotency_key IS NOT NULL THEN
        PERFORM store_idempotency(
            p_idempotency_key,
            p_tenant_id,
            'insert_contract_events_batch',
            'POST',
            NULL,
            200,
            v_response,
            24
        );
    END IF;

    RETURN v_response;

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to insert contract events',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION insert_contract_events_batch(UUID, UUID, JSONB, UUID, BOOLEAN, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION insert_contract_events_batch(UUID, UUID, JSONB, UUID, BOOLEAN, VARCHAR) TO service_role;


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- 2. update_contract_event
--    Update a single event: status, scheduled_date, assigned_to, notes.
--    Optimistic concurrency via version field.
--    Validates status transitions.
--    Creates audit row for each changed field.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
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


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- 3. get_contract_events_list
--    Paginated event list — serves ALL 6 query views:
--      Scope: contract (p_contract_id), customer (p_contact_id), or tenant (both NULL)
--      Filters: assigned_to, status, event_type, date range
--    Single dynamic query — all JSON shaping in Postgres.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE OR REPLACE FUNCTION get_contract_events_list(
    p_tenant_id     UUID,
    p_is_live       BOOLEAN DEFAULT true,
    p_contract_id   UUID DEFAULT NULL,          -- scope: specific contract
    p_contact_id    UUID DEFAULT NULL,          -- scope: specific customer/contact
    p_assigned_to   UUID DEFAULT NULL,          -- filter: assigned team member
    p_status        TEXT DEFAULT NULL,           -- filter: event status
    p_event_type    TEXT DEFAULT NULL,           -- filter: 'service' | 'billing'
    p_date_from     TIMESTAMPTZ DEFAULT NULL,   -- filter: scheduled_date >= this
    p_date_to       TIMESTAMPTZ DEFAULT NULL,   -- filter: scheduled_date <= this
    p_page          INT DEFAULT 1,
    p_per_page      INT DEFAULT 50,
    p_sort_by       TEXT DEFAULT 'scheduled_date',
    p_sort_order    TEXT DEFAULT 'asc'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_total     INT;
    v_total_pages INT;
    v_offset    INT;
    v_events    JSONB;
    v_where     TEXT;
    v_order     TEXT;
    v_query     TEXT;
    v_count_query TEXT;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    -- Clamp pagination
    p_page := GREATEST(p_page, 1);
    p_per_page := LEAST(GREATEST(p_per_page, 1), 100);
    v_offset := (p_page - 1) * p_per_page;

    -- ═══════════════════════════════════════════
    -- STEP 1: Build WHERE clause
    -- ═══════════════════════════════════════════
    v_where := format(
        'WHERE ce.tenant_id = %L AND ce.is_live = %L AND ce.is_active = true',
        p_tenant_id, p_is_live
    );

    -- Scope: contract
    IF p_contract_id IS NOT NULL THEN
        v_where := v_where || format(' AND ce.contract_id = %L', p_contract_id);
    END IF;

    -- Scope: customer/contact (joins through t_contracts.buyer_id + t_contract_vendors)
    IF p_contact_id IS NOT NULL THEN
        v_where := v_where || format(
            ' AND ce.contract_id IN (
                SELECT c.id FROM t_contracts c
                WHERE c.tenant_id = %L AND c.is_active = true
                  AND (c.buyer_id = %L
                       OR c.id IN (SELECT cv.contract_id FROM t_contract_vendors cv WHERE cv.contact_id = %L))
            )',
            p_tenant_id, p_contact_id, p_contact_id
        );
    END IF;

    -- Filters
    IF p_assigned_to IS NOT NULL THEN
        v_where := v_where || format(' AND ce.assigned_to = %L', p_assigned_to);
    END IF;

    IF p_status IS NOT NULL THEN
        v_where := v_where || format(' AND ce.status = %L', p_status);
    END IF;

    IF p_event_type IS NOT NULL THEN
        v_where := v_where || format(' AND ce.event_type = %L', p_event_type);
    END IF;

    IF p_date_from IS NOT NULL THEN
        v_where := v_where || format(' AND ce.scheduled_date >= %L', p_date_from);
    END IF;

    IF p_date_to IS NOT NULL THEN
        v_where := v_where || format(' AND ce.scheduled_date <= %L', p_date_to);
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Build ORDER BY
    -- ═══════════════════════════════════════════
    v_order := CASE p_sort_by
        WHEN 'status'     THEN 'ce.status'
        WHEN 'event_type' THEN 'ce.event_type'
        WHEN 'amount'     THEN 'ce.amount'
        WHEN 'created_at' THEN 'ce.created_at'
        WHEN 'block_name' THEN 'ce.block_name'
        ELSE 'ce.scheduled_date'
    END;

    v_order := v_order || CASE WHEN LOWER(p_sort_order) = 'desc' THEN ' DESC' ELSE ' ASC' END;

    -- ═══════════════════════════════════════════
    -- STEP 3: Get total count
    -- ═══════════════════════════════════════════
    v_count_query := 'SELECT COUNT(*) FROM t_contract_events ce ' || v_where;
    EXECUTE v_count_query INTO v_total;

    v_total_pages := CEIL(v_total::NUMERIC / p_per_page);

    -- ═══════════════════════════════════════════
    -- STEP 4: Fetch paginated events with contract name
    -- ═══════════════════════════════════════════
    v_query := format(
        'SELECT COALESCE(jsonb_agg(row_data ORDER BY rn), ''[]''::JSONB)
         FROM (
             SELECT
                 ROW_NUMBER() OVER (ORDER BY %s) as rn,
                 jsonb_build_object(
                     ''id'', ce.id,
                     ''contract_id'', ce.contract_id,
                     ''contract_name'', c.name,
                     ''block_id'', ce.block_id,
                     ''block_name'', ce.block_name,
                     ''category_id'', ce.category_id,
                     ''event_type'', ce.event_type,
                     ''billing_sub_type'', ce.billing_sub_type,
                     ''billing_cycle_label'', ce.billing_cycle_label,
                     ''sequence_number'', ce.sequence_number,
                     ''total_occurrences'', ce.total_occurrences,
                     ''scheduled_date'', ce.scheduled_date,
                     ''original_date'', ce.original_date,
                     ''amount'', ce.amount,
                     ''currency'', ce.currency,
                     ''status'', ce.status,
                     ''assigned_to'', ce.assigned_to,
                     ''assigned_to_name'', ce.assigned_to_name,
                     ''notes'', ce.notes,
                     ''version'', ce.version,
                     ''created_at'', ce.created_at,
                     ''updated_at'', ce.updated_at
                 ) AS row_data
             FROM t_contract_events ce
             LEFT JOIN t_contracts c ON c.id = ce.contract_id
             %s
             ORDER BY %s
             LIMIT %s OFFSET %s
         ) sub',
        v_order,
        v_where,
        v_order,
        p_per_page,
        v_offset
    );

    EXECUTE v_query INTO v_events;

    -- ═══════════════════════════════════════════
    -- STEP 5: Return response
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', COALESCE(v_events, '[]'::JSONB),
        'pagination', jsonb_build_object(
            'page', p_page,
            'per_page', p_per_page,
            'total', v_total,
            'total_pages', v_total_pages
        ),
        'filters', jsonb_build_object(
            'contract_id', p_contract_id,
            'contact_id', p_contact_id,
            'assigned_to', p_assigned_to,
            'status', p_status,
            'event_type', p_event_type,
            'date_from', p_date_from,
            'date_to', p_date_to,
            'sort_by', p_sort_by,
            'sort_order', p_sort_order
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch contract events',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_contract_events_list(UUID, BOOLEAN, UUID, UUID, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, INT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contract_events_list(UUID, BOOLEAN, UUID, UUID, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, INT, TEXT, TEXT) TO service_role;


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- 4. get_contract_events_date_summary
--    Aggregates events into date buckets:
--      overdue, today, tomorrow, this_week, next_week, later
--    Each bucket: total count + breakdown by status + by event_type
--    Same scope filters as get_contract_events_list.
--    Single query — all aggregation in Postgres.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE OR REPLACE FUNCTION get_contract_events_date_summary(
    p_tenant_id     UUID,
    p_is_live       BOOLEAN DEFAULT true,
    p_contract_id   UUID DEFAULT NULL,
    p_contact_id    UUID DEFAULT NULL,
    p_assigned_to   UUID DEFAULT NULL,
    p_event_type    TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result    JSONB;
    v_where     TEXT;
    v_query     TEXT;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Build WHERE clause (same logic as list)
    -- ═══════════════════════════════════════════
    v_where := format(
        'WHERE ce.tenant_id = %L AND ce.is_live = %L AND ce.is_active = true',
        p_tenant_id, p_is_live
    );

    IF p_contract_id IS NOT NULL THEN
        v_where := v_where || format(' AND ce.contract_id = %L', p_contract_id);
    END IF;

    IF p_contact_id IS NOT NULL THEN
        v_where := v_where || format(
            ' AND ce.contract_id IN (
                SELECT c.id FROM t_contracts c
                WHERE c.tenant_id = %L AND c.is_active = true
                  AND (c.buyer_id = %L
                       OR c.id IN (SELECT cv.contract_id FROM t_contract_vendors cv WHERE cv.contact_id = %L))
            )',
            p_tenant_id, p_contact_id, p_contact_id
        );
    END IF;

    IF p_assigned_to IS NOT NULL THEN
        v_where := v_where || format(' AND ce.assigned_to = %L', p_assigned_to);
    END IF;

    IF p_event_type IS NOT NULL THEN
        v_where := v_where || format(' AND ce.event_type = %L', p_event_type);
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Aggregate into date buckets
    --   All in one query using FILTER
    -- ═══════════════════════════════════════════
    v_query := format(
        'SELECT jsonb_build_object(
            ''overdue'', jsonb_build_object(
                ''total'', COUNT(*) FILTER (WHERE ce.status = ''overdue''),
                ''by_type'', jsonb_build_object(
                    ''service'', COUNT(*) FILTER (WHERE ce.status = ''overdue'' AND ce.event_type = ''service''),
                    ''billing'', COUNT(*) FILTER (WHERE ce.status = ''overdue'' AND ce.event_type = ''billing'')
                )
            ),
            ''today'', jsonb_build_object(
                ''total'', COUNT(*) FILTER (WHERE ce.scheduled_date::date = CURRENT_DATE AND ce.status <> ''overdue''),
                ''by_status'', jsonb_build_object(
                    ''scheduled'',   COUNT(*) FILTER (WHERE ce.scheduled_date::date = CURRENT_DATE AND ce.status = ''scheduled''),
                    ''in_progress'', COUNT(*) FILTER (WHERE ce.scheduled_date::date = CURRENT_DATE AND ce.status = ''in_progress''),
                    ''completed'',   COUNT(*) FILTER (WHERE ce.scheduled_date::date = CURRENT_DATE AND ce.status = ''completed'')
                ),
                ''by_type'', jsonb_build_object(
                    ''service'', COUNT(*) FILTER (WHERE ce.scheduled_date::date = CURRENT_DATE AND ce.event_type = ''service'' AND ce.status <> ''overdue''),
                    ''billing'', COUNT(*) FILTER (WHERE ce.scheduled_date::date = CURRENT_DATE AND ce.event_type = ''billing'' AND ce.status <> ''overdue'')
                )
            ),
            ''tomorrow'', jsonb_build_object(
                ''total'', COUNT(*) FILTER (WHERE ce.scheduled_date::date = CURRENT_DATE + 1 AND ce.status <> ''overdue''),
                ''by_status'', jsonb_build_object(
                    ''scheduled'',   COUNT(*) FILTER (WHERE ce.scheduled_date::date = CURRENT_DATE + 1 AND ce.status = ''scheduled''),
                    ''in_progress'', COUNT(*) FILTER (WHERE ce.scheduled_date::date = CURRENT_DATE + 1 AND ce.status = ''in_progress'')
                ),
                ''by_type'', jsonb_build_object(
                    ''service'', COUNT(*) FILTER (WHERE ce.scheduled_date::date = CURRENT_DATE + 1 AND ce.event_type = ''service'' AND ce.status <> ''overdue''),
                    ''billing'', COUNT(*) FILTER (WHERE ce.scheduled_date::date = CURRENT_DATE + 1 AND ce.event_type = ''billing'' AND ce.status <> ''overdue'')
                )
            ),
            ''this_week'', jsonb_build_object(
                ''total'', COUNT(*) FILTER (
                    WHERE ce.scheduled_date::date > CURRENT_DATE + 1
                      AND ce.scheduled_date::date <= (date_trunc(''week'', CURRENT_DATE) + interval ''6 days'')::date
                      AND ce.status <> ''overdue''
                ),
                ''by_status'', jsonb_build_object(
                    ''scheduled'',   COUNT(*) FILTER (
                        WHERE ce.scheduled_date::date > CURRENT_DATE + 1
                          AND ce.scheduled_date::date <= (date_trunc(''week'', CURRENT_DATE) + interval ''6 days'')::date
                          AND ce.status = ''scheduled''
                    ),
                    ''in_progress'', COUNT(*) FILTER (
                        WHERE ce.scheduled_date::date > CURRENT_DATE + 1
                          AND ce.scheduled_date::date <= (date_trunc(''week'', CURRENT_DATE) + interval ''6 days'')::date
                          AND ce.status = ''in_progress''
                    )
                ),
                ''by_type'', jsonb_build_object(
                    ''service'', COUNT(*) FILTER (
                        WHERE ce.scheduled_date::date > CURRENT_DATE + 1
                          AND ce.scheduled_date::date <= (date_trunc(''week'', CURRENT_DATE) + interval ''6 days'')::date
                          AND ce.event_type = ''service'' AND ce.status <> ''overdue''
                    ),
                    ''billing'', COUNT(*) FILTER (
                        WHERE ce.scheduled_date::date > CURRENT_DATE + 1
                          AND ce.scheduled_date::date <= (date_trunc(''week'', CURRENT_DATE) + interval ''6 days'')::date
                          AND ce.event_type = ''billing'' AND ce.status <> ''overdue''
                    )
                )
            ),
            ''next_week'', jsonb_build_object(
                ''total'', COUNT(*) FILTER (
                    WHERE ce.scheduled_date::date > (date_trunc(''week'', CURRENT_DATE) + interval ''6 days'')::date
                      AND ce.scheduled_date::date <= (date_trunc(''week'', CURRENT_DATE) + interval ''13 days'')::date
                      AND ce.status <> ''overdue''
                ),
                ''by_status'', jsonb_build_object(
                    ''scheduled'',   COUNT(*) FILTER (
                        WHERE ce.scheduled_date::date > (date_trunc(''week'', CURRENT_DATE) + interval ''6 days'')::date
                          AND ce.scheduled_date::date <= (date_trunc(''week'', CURRENT_DATE) + interval ''13 days'')::date
                          AND ce.status = ''scheduled''
                    ),
                    ''in_progress'', COUNT(*) FILTER (
                        WHERE ce.scheduled_date::date > (date_trunc(''week'', CURRENT_DATE) + interval ''6 days'')::date
                          AND ce.scheduled_date::date <= (date_trunc(''week'', CURRENT_DATE) + interval ''13 days'')::date
                          AND ce.status = ''in_progress''
                    )
                ),
                ''by_type'', jsonb_build_object(
                    ''service'', COUNT(*) FILTER (
                        WHERE ce.scheduled_date::date > (date_trunc(''week'', CURRENT_DATE) + interval ''6 days'')::date
                          AND ce.scheduled_date::date <= (date_trunc(''week'', CURRENT_DATE) + interval ''13 days'')::date
                          AND ce.event_type = ''service'' AND ce.status <> ''overdue''
                    ),
                    ''billing'', COUNT(*) FILTER (
                        WHERE ce.scheduled_date::date > (date_trunc(''week'', CURRENT_DATE) + interval ''6 days'')::date
                          AND ce.scheduled_date::date <= (date_trunc(''week'', CURRENT_DATE) + interval ''13 days'')::date
                          AND ce.event_type = ''billing'' AND ce.status <> ''overdue''
                    )
                )
            ),
            ''later'', jsonb_build_object(
                ''total'', COUNT(*) FILTER (
                    WHERE ce.scheduled_date::date > (date_trunc(''week'', CURRENT_DATE) + interval ''13 days'')::date
                      AND ce.status <> ''overdue''
                ),
                ''by_type'', jsonb_build_object(
                    ''service'', COUNT(*) FILTER (
                        WHERE ce.scheduled_date::date > (date_trunc(''week'', CURRENT_DATE) + interval ''13 days'')::date
                          AND ce.event_type = ''service'' AND ce.status <> ''overdue''
                    ),
                    ''billing'', COUNT(*) FILTER (
                        WHERE ce.scheduled_date::date > (date_trunc(''week'', CURRENT_DATE) + interval ''13 days'')::date
                          AND ce.event_type = ''billing'' AND ce.status <> ''overdue''
                    )
                )
            ),
            ''totals'', jsonb_build_object(
                ''all'', COUNT(*),
                ''by_status'', jsonb_build_object(
                    ''scheduled'',   COUNT(*) FILTER (WHERE ce.status = ''scheduled''),
                    ''in_progress'', COUNT(*) FILTER (WHERE ce.status = ''in_progress''),
                    ''completed'',   COUNT(*) FILTER (WHERE ce.status = ''completed''),
                    ''cancelled'',   COUNT(*) FILTER (WHERE ce.status = ''cancelled''),
                    ''overdue'',     COUNT(*) FILTER (WHERE ce.status = ''overdue'')
                ),
                ''by_type'', jsonb_build_object(
                    ''service'', COUNT(*) FILTER (WHERE ce.event_type = ''service''),
                    ''billing'', COUNT(*) FILTER (WHERE ce.event_type = ''billing'')
                )
            )
        )
        FROM t_contract_events ce
        %s',
        v_where
    );

    EXECUTE v_query INTO v_result;

    -- ═══════════════════════════════════════════
    -- STEP 3: Return response
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', v_result,
        'filters', jsonb_build_object(
            'contract_id', p_contract_id,
            'contact_id', p_contact_id,
            'assigned_to', p_assigned_to,
            'event_type', p_event_type
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch contract events date summary',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_contract_events_date_summary(UUID, BOOLEAN, UUID, UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contract_events_date_summary(UUID, BOOLEAN, UUID, UUID, UUID, TEXT) TO service_role;


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- 5. process_contract_events_from_computed
--    PGMQ worker function — called when contract reaches 'active'.
--    Reads computed_events JSONB from t_contracts,
--    calls insert_contract_events_batch, then NULLs the column.
--    Idempotent: skips if computed_events is NULL or events exist.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE OR REPLACE FUNCTION process_contract_events_from_computed(
    p_contract_id   UUID,
    p_tenant_id     UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_contract      RECORD;
    v_result        JSONB;
    v_existing      INT;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Fetch contract + computed_events
    -- ═══════════════════════════════════════════
    SELECT id, tenant_id, computed_events, created_by, is_live
    INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND tenant_id = p_tenant_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found',
            'contract_id', p_contract_id
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Idempotency — skip if no computed_events
    -- ═══════════════════════════════════════════
    IF v_contract.computed_events IS NULL OR jsonb_array_length(v_contract.computed_events) = 0 THEN
        -- Check if events already exist (previously processed)
        SELECT COUNT(*) INTO v_existing
        FROM t_contract_events
        WHERE contract_id = p_contract_id
          AND tenant_id = p_tenant_id
          AND is_active = true;

        IF v_existing > 0 THEN
            RETURN jsonb_build_object(
                'success', true,
                'data', jsonb_build_object(
                    'contract_id', p_contract_id,
                    'message', 'Events already exist — skipped',
                    'existing_count', v_existing
                )
            );
        ELSE
            RETURN jsonb_build_object(
                'success', false,
                'error', 'No computed_events found on contract',
                'contract_id', p_contract_id
            );
        END IF;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Delegate to insert_contract_events_batch
    -- ═══════════════════════════════════════════
    v_result := insert_contract_events_batch(
        p_tenant_id     := v_contract.tenant_id,
        p_contract_id   := p_contract_id,
        p_events        := v_contract.computed_events,
        p_created_by    := v_contract.created_by,
        p_is_live       := v_contract.is_live,
        p_idempotency_key := 'pgmq_events_' || p_contract_id::TEXT
    );

    -- ═══════════════════════════════════════════
    -- STEP 3: Clean up — NULL out computed_events
    -- ═══════════════════════════════════════════
    IF (v_result->>'success')::BOOLEAN THEN
        UPDATE t_contracts
        SET computed_events = NULL
        WHERE id = p_contract_id
          AND tenant_id = p_tenant_id;
    END IF;

    RETURN v_result;

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to process computed events',
        'details', SQLERRM,
        'error_code', SQLSTATE,
        'contract_id', p_contract_id
    );
END;
$$;

GRANT EXECUTE ON FUNCTION process_contract_events_from_computed(UUID, UUID) TO service_role;


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- 6. Trigger: queue event creation on contract activation
--    When contract status changes to 'active', fire pgmq_send
--    so the worker (process_contract_events_from_computed) picks it up.
--    Follows same PGMQ pattern as JTD queue in update_contract_status.
--    Non-blocking: PGMQ failure does not block the status update.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE OR REPLACE FUNCTION trigger_queue_contract_events()
RETURNS TRIGGER AS $$
BEGIN
    -- Only fire when status changes TO 'active' AND computed_events exists
    IF NEW.status = 'active'
       AND (OLD.status IS DISTINCT FROM NEW.status)
       AND NEW.computed_events IS NOT NULL
       AND jsonb_array_length(NEW.computed_events) > 0
    THEN
        BEGIN
            PERFORM pgmq.send('contract_events_create', jsonb_build_object(
                'contract_id', NEW.id,
                'tenant_id', NEW.tenant_id,
                'triggered_at', NOW()
            ));
        EXCEPTION WHEN OTHERS THEN
            -- PGMQ failure must NOT block the status update
            RAISE NOTICE 'contract_events_create queue failed for contract %: %', NEW.id, SQLERRM;
        END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fire AFTER update so the status change is already committed
DROP TRIGGER IF EXISTS trg_queue_contract_events ON t_contracts;
CREATE TRIGGER trg_queue_contract_events
    AFTER UPDATE OF status ON t_contracts
    FOR EACH ROW
    EXECUTE FUNCTION trigger_queue_contract_events();
