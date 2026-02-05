-- =============================================================
-- CONTRACT EVENTS TABLES
-- Migration: contracts/012_contract_events_tables.sql
-- Purpose:
--   T1: t_contract_events — lifecycle events for contracts
--       (service milestones + billing schedule)
--   T2: t_contract_event_audit — full audit trail for every
--       status change, date shift, and reassignment
--   T3: ALTER t_contracts — add computed_events JSONB column
--       (wizard stores event preview here; PGMQ worker moves
--        them to t_contract_events on contract confirmation)
--
-- Event types: 'service' | 'billing'
-- Billing sub-types: 'upfront' | 'emi' | 'on_completion' | 'recurring'
-- Statuses: 'scheduled' → 'in_progress' → 'completed' / 'cancelled' / 'overdue'
-- (VaNi AI statuses will extend this list in a future migration)
-- =============================================================


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T1.1  t_contract_events
-- One row per service milestone or billing installment.
-- Created in bulk when contract status → confirmed/accepted.
-- Source data: computed_events JSONB on t_contracts.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE TABLE IF NOT EXISTS t_contract_events (
    id                      UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id               UUID NOT NULL,
    contract_id             UUID NOT NULL,

    -- Block reference (denormalized from t_contract_blocks)
    block_id                TEXT,                               -- source block identifier
    block_name              TEXT,                               -- denormalized for display
    category_id             TEXT,                               -- block category

    -- Event classification
    event_type              TEXT NOT NULL,                      -- 'service' | 'billing'
    billing_sub_type        TEXT,                               -- 'upfront' | 'emi' | 'on_completion' | 'recurring' | NULL (service events)
    billing_cycle_label     TEXT,                               -- "EMI 2/5", "Monthly 3/6", NULL (service events)
    sequence_number         INT,                                -- 1-based position in series
    total_occurrences       INT,                                -- total events in this series

    -- Scheduling
    scheduled_date          TIMESTAMPTZ NOT NULL,               -- user-adjusted date (from preview)
    original_date           TIMESTAMPTZ NOT NULL,               -- system-computed date (immutable)

    -- Financials (billing events only)
    amount                  NUMERIC,                            -- billing amount; NULL for service events
    currency                TEXT DEFAULT 'INR',                 -- currency code

    -- Status & assignment
    status                  TEXT NOT NULL DEFAULT 'scheduled',  -- managed via update_contract_event RPC
    assigned_to             UUID,                               -- FK to team member (user)
    assigned_to_name        TEXT,                               -- denormalized for display
    notes                   TEXT,                               -- optional notes

    -- Concurrency & environment
    version                 INT NOT NULL DEFAULT 1,             -- optimistic concurrency (incremented on each update)
    is_live                 BOOLEAN DEFAULT true,               -- live vs test environment
    is_active               BOOLEAN DEFAULT true,               -- soft delete

    -- Audit
    created_at              TIMESTAMPTZ DEFAULT NOW(),
    updated_at              TIMESTAMPTZ DEFAULT NOW(),
    created_by              UUID,
    updated_by              UUID,

    -- Foreign keys
    CONSTRAINT fk_ce_contract
        FOREIGN KEY (contract_id) REFERENCES t_contracts(id) ON DELETE CASCADE
);


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T1.2  t_contract_event_audit
-- Immutable log of every change to a contract event.
-- One row per field change (status, scheduled_date, assigned_to, etc.)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE TABLE IF NOT EXISTS t_contract_event_audit (
    id                      UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    event_id                UUID NOT NULL,                      -- FK → t_contract_events
    tenant_id               UUID NOT NULL,                      -- denormalized for RLS + queries

    -- What changed
    field_changed           TEXT NOT NULL,                      -- 'status', 'scheduled_date', 'assigned_to', 'notes', etc.
    old_value               TEXT,                               -- previous value (cast to text)
    new_value               TEXT,                               -- new value (cast to text)

    -- Who changed it
    changed_by              UUID,                               -- user ID
    changed_by_name         TEXT,                               -- denormalized for display
    reason                  TEXT,                               -- optional note explaining the change

    -- When
    changed_at              TIMESTAMPTZ DEFAULT NOW() NOT NULL,

    -- Foreign keys
    CONSTRAINT fk_cea_event
        FOREIGN KEY (event_id) REFERENCES t_contract_events(id) ON DELETE CASCADE
);


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T1.3  Indexes
-- Designed for 6 query views:
--   1. Events of a contract + status
--   2. Events under a customer (contact) + status
--   3. Events vs dates for a contract (today/tomorrow/this week/next week)
--   4. Events vs dates for a customer
--   5. Tenant-wide dashboard
--   6. All above filtered by assigned_to
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Contract-scoped queries (views 1, 3)
CREATE INDEX IF NOT EXISTS idx_ce_contract
    ON t_contract_events (contract_id)
    WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_ce_contract_status
    ON t_contract_events (contract_id, status)
    WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_ce_contract_date
    ON t_contract_events (contract_id, scheduled_date)
    WHERE is_active = true;

-- Tenant-scoped queries (view 5 — dashboard)
CREATE INDEX IF NOT EXISTS idx_ce_tenant_status
    ON t_contract_events (tenant_id, status)
    WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_ce_tenant_date
    ON t_contract_events (tenant_id, scheduled_date)
    WHERE is_active = true;

-- Assignment-scoped queries (view 6)
CREATE INDEX IF NOT EXISTS idx_ce_tenant_assigned_status
    ON t_contract_events (tenant_id, assigned_to, status)
    WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_ce_assigned_date
    ON t_contract_events (assigned_to, scheduled_date)
    WHERE is_active = true AND assigned_to IS NOT NULL;

-- Event type filter (used across all views)
CREATE INDEX IF NOT EXISTS idx_ce_contract_type
    ON t_contract_events (contract_id, event_type)
    WHERE is_active = true;

-- Audit table indexes
CREATE INDEX IF NOT EXISTS idx_cea_event
    ON t_contract_event_audit (event_id);

CREATE INDEX IF NOT EXISTS idx_cea_event_date
    ON t_contract_event_audit (event_id, changed_at DESC);

CREATE INDEX IF NOT EXISTS idx_cea_tenant
    ON t_contract_event_audit (tenant_id, changed_at DESC);


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T1.4  Triggers
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Auto-update updated_at on t_contract_events
CREATE OR REPLACE FUNCTION update_contract_events_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_contract_events_updated_at ON t_contract_events;
CREATE TRIGGER trigger_contract_events_updated_at
    BEFORE UPDATE ON t_contract_events
    FOR EACH ROW
    EXECUTE FUNCTION update_contract_events_updated_at();


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T1.5  RLS Policies
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ALTER TABLE t_contract_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE t_contract_event_audit ENABLE ROW LEVEL SECURITY;

-- ── t_contract_events ──

-- Tenant members can view events
CREATE POLICY "Tenant members can view contract events"
    ON t_contract_events FOR SELECT
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Tenant members can create events
CREATE POLICY "Tenant members can create contract events"
    ON t_contract_events FOR INSERT
    WITH CHECK (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Tenant members can update events
CREATE POLICY "Tenant members can update contract events"
    ON t_contract_events FOR UPDATE
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Service role full access (for Edge Functions / PGMQ worker)
CREATE POLICY "Service role full access to contract events"
    ON t_contract_events FOR ALL
    USING (auth.role() = 'service_role');

-- ── t_contract_event_audit ──

-- Tenant members can view audit logs
CREATE POLICY "Tenant members can view contract event audit"
    ON t_contract_event_audit FOR SELECT
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Tenant members can create audit logs
CREATE POLICY "Tenant members can create contract event audit"
    ON t_contract_event_audit FOR INSERT
    WITH CHECK (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Service role full access (for Edge Functions / PGMQ worker)
CREATE POLICY "Service role full access to contract event audit"
    ON t_contract_event_audit FOR ALL
    USING (auth.role() = 'service_role');


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T1.6  Grants
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT ALL ON t_contract_events TO service_role;
GRANT SELECT, INSERT, UPDATE ON t_contract_events TO authenticated;

GRANT ALL ON t_contract_event_audit TO service_role;
GRANT SELECT, INSERT ON t_contract_event_audit TO authenticated;


-- =============================================================
-- T2: ALTER t_contracts — add computed_events column
-- =============================================================
-- The wizard's EventsPreviewStep saves computed events (with
-- any user date-adjustments) into this JSONB column during
-- contract creation via create_contract_transaction.
--
-- When the contract status changes to 'confirmed'/'accepted',
-- a trigger fires pgmq_send → worker RPC reads this column,
-- bulk-inserts into t_contract_events, then NULLs it out.
--
-- Schema of each element in the JSONB array:
-- {
--   "block_id": "...",
--   "block_name": "...",
--   "category_id": "...",
--   "event_type": "service" | "billing",
--   "billing_sub_type": "upfront" | "emi" | "on_completion" | "recurring" | null,
--   "billing_cycle_label": "EMI 2/5" | null,
--   "sequence_number": 1,
--   "total_occurrences": 5,
--   "scheduled_date": "2025-03-15T00:00:00Z",
--   "original_date": "2025-03-15T00:00:00Z",
--   "amount": 5000.00,
--   "currency": "INR",
--   "assigned_to": null,
--   "assigned_to_name": null,
--   "notes": null
-- }
-- =============================================================

ALTER TABLE t_contracts
    ADD COLUMN IF NOT EXISTS computed_events JSONB DEFAULT NULL;

COMMENT ON COLUMN t_contracts.computed_events
    IS 'Wizard-computed events (service + billing). Stored on creation, moved to t_contract_events on confirmation, then NULLed.';
