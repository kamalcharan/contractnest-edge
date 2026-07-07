-- ============================================================================
-- Migration: Stage 0 Runtime Loop — 002 'due' Status in Event Status Config
-- ============================================================================
-- Purpose: The scanner introduces the lifecycle 'scheduled → due → overdue'
--          (POA-OPERATIONS-READINESS-2026-07-07 Stage 0). The status config
--          system (contracts/018) has no 'due' status — this migration seeds
--          it for 'service' and 'billing' event types:
--            1. Bumps display_order of existing statuses (>= 2) so 'due'
--               slots in right after 'scheduled' — across ALL scopes
--               (system rows AND the per-tenant copies made by 019).
--            2. Inserts system-default 'due' status + transitions.
--            3. Re-runs seed_event_status_defaults() for every active tenant
--               so existing tenants get the tenant-scoped copies
--               (get_event_status_config prefers tenant rows).
-- Depends on: contracts/018_event_status_config.sql (tables + seed RPC),
--             contracts/019 (tenant backfill)
-- Safe to re-run: Yes (guarded — bump/insert only when 'due' is absent)
-- Applied by: OWNER — project uwyqhzotluikawcboldr
-- ============================================================================

DO $$
DECLARE
    v_tenant RECORD;
    v_result JSONB;
BEGIN
    -- Guard: run once. If the system 'due' row exists, everything below did.
    IF EXISTS (
        SELECT 1 FROM m_event_status_config
        WHERE tenant_id IS NULL AND event_type = 'service' AND status_code = 'due'
    ) THEN
        RAISE NOTICE 'Status ''due'' already seeded — skipping.';
        RETURN;
    END IF;

    -- 1. Make room at display_order 2 (all scopes: system + tenant copies)
    UPDATE m_event_status_config
    SET display_order = display_order + 1,
        updated_at = now()
    WHERE event_type IN ('service', 'billing')
      AND display_order >= 2
      AND status_code <> 'due';

    -- 2a. System-default 'due' statuses
    INSERT INTO m_event_status_config
        (tenant_id, event_type, status_code, display_name, description, hex_color, icon_name, display_order, is_initial, is_terminal, source)
    VALUES
        (NULL, 'service', 'due', 'Due', 'Scheduled date is approaching — action needed',      '#F59E0B', 'BellRing', 2, false, false, 'system'),
        (NULL, 'billing', 'due', 'Due', 'Billing date is approaching — invoice generation due', '#F59E0B', 'BellRing', 2, false, false, 'system')
    ON CONFLICT (tenant_id, event_type, status_code) DO NOTHING;

    -- 2b. System-default transitions involving 'due'
    INSERT INTO m_event_status_transitions
        (tenant_id, event_type, from_status, to_status, requires_reason)
    VALUES
        -- service
        (NULL, 'service', 'scheduled', 'due',         false),
        (NULL, 'service', 'due',       'assigned',    false),
        (NULL, 'service', 'due',       'in_progress', false),
        (NULL, 'service', 'due',       'overdue',     false),
        (NULL, 'service', 'due',       'cancelled',   true),
        -- billing
        (NULL, 'billing', 'scheduled', 'due',               false),
        (NULL, 'billing', 'due',       'invoice_generated', false),
        (NULL, 'billing', 'due',       'overdue',           false),
        (NULL, 'billing', 'due',       'cancelled',         true)
    ON CONFLICT (tenant_id, event_type, from_status, to_status) DO NOTHING;

    -- 3. Copy new system rows into tenant scope for existing active tenants
    --    (seed_event_status_defaults uses ON CONFLICT DO NOTHING, so only the
    --    new 'due' rows are added; existing tenant customizations untouched)
    FOR v_tenant IN
        SELECT id, name FROM t_tenants WHERE status = 'active' ORDER BY created_at
    LOOP
        v_result := seed_event_status_defaults(v_tenant.id);
        RAISE NOTICE 'Tenant [%] %: % statuses, % transitions added',
            v_tenant.id, v_tenant.name,
            v_result->>'statuses_seeded', v_result->>'transitions_seeded';
    END LOOP;

    RAISE NOTICE '''due'' status seeded for service + billing (system + tenant scopes).';
END;
$$;
