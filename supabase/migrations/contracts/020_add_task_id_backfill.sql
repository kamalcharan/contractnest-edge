-- ============================================================================
-- Migration 020: Add task_id Column + Backfill Existing Events
-- ============================================================================
-- Purpose:
--   1. Add task_id column to t_contract_events
--   2. Generate TSK-XXXXX for all existing events (per tenant, ordered by created_at)
--   3. Advance sequence counter in t_category_details so new events don't clash
-- Format: TSK-XXXXX (prefix=TSK, separator=-, padding=5, start=10001)
-- Safe to re-run: Yes (only updates rows where task_id IS NULL)
-- ============================================================================

-- Step 1: Add task_id column if not exists
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 't_contract_events' AND column_name = 'task_id'
    ) THEN
        ALTER TABLE t_contract_events ADD COLUMN task_id TEXT;
        RAISE NOTICE 'Added task_id column to t_contract_events';
    ELSE
        RAISE NOTICE 'task_id column already exists, skipping ALTER';
    END IF;
END;
$$;

-- Step 2: Backfill task_ids for all existing events that don't have one
-- Assigns sequential TSK-XXXXX per tenant, ordered by created_at
DO $$
DECLARE
    v_tenant RECORD;
    v_event RECORD;
    v_counter INT;
    v_task_id TEXT;
    v_total_updated INT := 0;
    v_tenant_count INT := 0;
    v_max_counter INT;
BEGIN
    RAISE NOTICE '=== Starting task_id backfill ===';

    -- Process each tenant separately
    FOR v_tenant IN
        SELECT DISTINCT tenant_id
        FROM t_contract_events
        WHERE task_id IS NULL
        ORDER BY tenant_id
    LOOP
        v_counter := 10001;  -- TSK start value from sequences.seed.ts
        v_tenant_count := v_tenant_count + 1;

        -- Assign sequential task_ids within this tenant
        FOR v_event IN
            SELECT id
            FROM t_contract_events
            WHERE tenant_id = v_tenant.tenant_id
              AND task_id IS NULL
            ORDER BY created_at, id
        LOOP
            v_task_id := 'TSK-' || LPAD(v_counter::TEXT, 5, '0');

            UPDATE t_contract_events
            SET task_id = v_task_id
            WHERE id = v_event.id;

            v_counter := v_counter + 1;
            v_total_updated := v_total_updated + 1;
        END LOOP;

        v_max_counter := v_counter;  -- Next available number

        RAISE NOTICE 'Tenant [%]: assigned % task_ids (TSK-10001 to TSK-%)',
            v_tenant.tenant_id,
            v_counter - 10001,
            LPAD((v_counter - 1)::TEXT, 5, '0');

        -- Step 3: Update the sequence counter in t_category_details
        -- so next auto-generated task_id picks up from where we left off
        UPDATE t_category_details
        SET form_settings = jsonb_set(
            COALESCE(form_settings, '{}'::jsonb),
            '{start_value}',
            to_jsonb(v_max_counter)
        )
        WHERE tenant_id = v_tenant.tenant_id
          AND sub_cat_name = 'TASK'
          AND COALESCE((form_settings->>'start_value')::INT, 10001) < v_max_counter;

        IF FOUND THEN
            RAISE NOTICE 'Tenant [%]: advanced TASK sequence counter to %',
                v_tenant.tenant_id, v_max_counter;
        END IF;
    END LOOP;

    RAISE NOTICE '=== Backfill complete: % events across % tenants ===',
        v_total_updated, v_tenant_count;
END;
$$;

-- Step 4: Create index on task_id for lookups
CREATE INDEX IF NOT EXISTS idx_contract_events_task_id
    ON t_contract_events (task_id)
    WHERE task_id IS NOT NULL;

-- Step 5: Create unique index per tenant to prevent duplicate task_ids
CREATE UNIQUE INDEX IF NOT EXISTS idx_contract_events_tenant_task_id
    ON t_contract_events (tenant_id, task_id)
    WHERE task_id IS NOT NULL;
