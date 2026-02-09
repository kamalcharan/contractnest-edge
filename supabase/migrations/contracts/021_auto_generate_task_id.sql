-- ============================================================================
-- Migration 021: Auto-generate task_id on Event Insert
-- ============================================================================
-- Purpose: Update insert_contract_events_batch to auto-generate TSK-XXXXX
--          for each new event using the TASK sequence from t_category_details.
-- Depends on: 013 (original RPC), 020 (task_id column + backfill)
-- Approach: CREATE OR REPLACE to redefine the function with task_id logic
-- ============================================================================

CREATE OR REPLACE FUNCTION insert_contract_events_batch(
    p_tenant_id         UUID,
    p_contract_id       UUID,
    p_events            JSONB,
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
    -- Task ID generation
    v_task_prefix       TEXT := 'TSK';
    v_task_separator    TEXT := '-';
    v_task_padding      INT := 5;
    v_task_counter      INT := 10001;
    v_task_id           TEXT;
    v_seq_record        RECORD;
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
    -- STEP 0b: Load TASK sequence config
    -- ═══════════════════════════════════════════
    SELECT
        COALESCE(form_settings->>'prefix', 'TSK') AS prefix,
        COALESCE(form_settings->>'separator', '-') AS separator,
        COALESCE((form_settings->>'padding_length')::INT, 5) AS padding,
        COALESCE((form_settings->>'start_value')::INT, 10001) AS counter
    INTO v_seq_record
    FROM t_category_details
    WHERE tenant_id = p_tenant_id
      AND sub_cat_name = 'TASK'
    LIMIT 1;

    IF v_seq_record IS NOT NULL THEN
        v_task_prefix   := v_seq_record.prefix;
        v_task_separator := v_seq_record.separator;
        v_task_padding  := v_seq_record.padding;
        v_task_counter  := v_seq_record.counter;
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
    -- STEP 2: Bulk insert events with task_id
    -- ═══════════════════════════════════════════
    FOR v_event IN SELECT * FROM jsonb_array_elements(p_events)
    LOOP
        -- Generate task_id
        v_task_id := v_task_prefix || v_task_separator || LPAD(v_task_counter::TEXT, v_task_padding, '0');

        INSERT INTO t_contract_events (
            tenant_id,
            contract_id,
            task_id,
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
            v_task_id,
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
        v_task_counter := v_task_counter + 1;
    END LOOP;

    -- ═══════════════════════════════════════════
    -- STEP 2b: Advance sequence counter
    -- ═══════════════════════════════════════════
    UPDATE t_category_details
    SET form_settings = jsonb_set(
        COALESCE(form_settings, '{}'::JSONB),
        '{start_value}',
        to_jsonb(v_task_counter)
    )
    WHERE tenant_id = p_tenant_id
      AND sub_cat_name = 'TASK';

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
