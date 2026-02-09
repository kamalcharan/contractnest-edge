-- ============================================================================
-- Migration 025: Contract Audit Log Table
-- ============================================================================
-- Purpose: t_audit_log — unified, immutable audit trail for all contract-level
--          changes. Captures status transitions, content edits, team assignments,
--          evidence uploads, and billing actions in one queryable table.
--
-- This is a HIGHER-LEVEL audit than t_contract_event_audit (migration 012),
-- which tracks per-event field changes. t_audit_log captures:
--   - Contract status changes
--   - Service ticket lifecycle (create, assign, start, complete, cancel)
--   - Evidence uploads and verifications
--   - Team member assignments and reassignments
--   - Billing events (invoice generated, payment received)
--   - Content edits (description, blocks, terms)
--
-- Denormalization: performed_by_name stored alongside FKID for buyer visibility.
-- old_value/new_value are JSONB for rich structured change data.
--
-- Immutable: rows are INSERT-only, no UPDATE or DELETE by authenticated users.
--
-- Depends on: 012 (t_contract_events), 022 (t_service_tickets)
-- ============================================================================


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T1: t_audit_log
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE TABLE IF NOT EXISTS t_audit_log (
    id                      UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id               UUID NOT NULL,

    -- What entity changed
    entity_type             TEXT NOT NULL,                          -- 'contract' | 'service_ticket' | 'evidence' | 'event'
    entity_id               UUID NOT NULL,                         -- ID of the changed entity
    contract_id             UUID,                                  -- denormalized for contract-scoped queries (always set)

    -- Classification
    category                TEXT NOT NULL,                          -- 'status' | 'content' | 'assignment' | 'evidence' | 'billing'
    action                  TEXT NOT NULL,                          -- machine-readable: 'status_changed', 'tech_assigned', 'evidence_uploaded', etc.
    description             TEXT,                                   -- human-readable: "Contract status changed", "Technician assigned"

    -- Change data (structured JSONB for rich display)
    old_value               JSONB,                                 -- { "status": "assigned", "assigned_to": "uuid", "assigned_to_name": "Rajesh" }
    new_value               JSONB,                                 -- { "status": "in_progress" }

    -- Who made the change (denormalized)
    performed_by            UUID,                                  -- user ID
    performed_by_name       TEXT,                                  -- denormalized: "Operations Admin"

    -- When (immutable — no updated_at on audit logs)
    created_at              TIMESTAMPTZ DEFAULT NOW() NOT NULL
);


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T2: Indexes
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Contract-scoped queries (AuditTab: all entries for a contract)
CREATE INDEX IF NOT EXISTS idx_al_contract
    ON t_audit_log (contract_id, created_at DESC)
    WHERE contract_id IS NOT NULL;

-- Contract + category filter (AuditTab filter bar)
CREATE INDEX IF NOT EXISTS idx_al_contract_category
    ON t_audit_log (contract_id, category, created_at DESC)
    WHERE contract_id IS NOT NULL;

-- Entity-scoped queries (audit for a specific ticket/evidence/event)
CREATE INDEX IF NOT EXISTS idx_al_entity
    ON t_audit_log (entity_type, entity_id, created_at DESC);

-- Tenant-scoped queries (admin audit dashboard)
CREATE INDEX IF NOT EXISTS idx_al_tenant
    ON t_audit_log (tenant_id, created_at DESC);

-- Tenant + category (dashboard filtered by type)
CREATE INDEX IF NOT EXISTS idx_al_tenant_category
    ON t_audit_log (tenant_id, category, created_at DESC);

-- Who did what (user activity log)
CREATE INDEX IF NOT EXISTS idx_al_performed_by
    ON t_audit_log (performed_by, created_at DESC)
    WHERE performed_by IS NOT NULL;


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T3: RLS Policies
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ALTER TABLE t_audit_log ENABLE ROW LEVEL SECURITY;

-- Tenant members can view audit logs
CREATE POLICY "Tenant members can view audit log"
    ON t_audit_log FOR SELECT
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Tenant members can create audit entries (from client-side actions)
CREATE POLICY "Tenant members can create audit entries"
    ON t_audit_log FOR INSERT
    WITH CHECK (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- NO UPDATE or DELETE policies for authenticated users — audit logs are immutable

-- Service role full access (for Edge Functions / RPCs that write audit entries)
CREATE POLICY "Service role full access to audit log"
    ON t_audit_log FOR ALL
    USING (auth.role() = 'service_role');


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T4: Grants
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT ALL ON t_audit_log TO service_role;
GRANT SELECT, INSERT ON t_audit_log TO authenticated;
-- Note: No UPDATE or DELETE for authenticated — audit log is append-only


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Comments
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

COMMENT ON TABLE t_audit_log IS
    'Unified, immutable audit trail for contract-level changes. Captures status transitions, '
    'assignments, evidence, billing, and content edits. Append-only — no UPDATE/DELETE for users.';

COMMENT ON COLUMN t_audit_log.entity_type IS
    'Type of entity that changed: contract | service_ticket | evidence | event';

COMMENT ON COLUMN t_audit_log.contract_id IS
    'Denormalized contract reference for efficient contract-scoped queries. Always populated.';

COMMENT ON COLUMN t_audit_log.category IS
    'Audit category for filtering: status | content | assignment | evidence | billing';

COMMENT ON COLUMN t_audit_log.old_value IS
    'JSONB snapshot of previous state. Structure varies by action type. '
    'Example for status change: {"status": "assigned", "assigned_to_name": "Rajesh Kumar"}';

COMMENT ON COLUMN t_audit_log.new_value IS
    'JSONB snapshot of new state. '
    'Example for assignment: {"assigned_to": "uuid", "assigned_to_name": "Priya Patel"}';

COMMENT ON COLUMN t_audit_log.performed_by_name IS
    'Denormalized user name for buyer (CNAK) visibility without FK resolution';
