-- ============================================================================
-- Migration 023: Service Ticket ↔ Events Junction Table
-- ============================================================================
-- Purpose: t_service_ticket_events — many-to-many link between service tickets
--          and contract events. One ticket can contain multiple events (e.g.
--          service + spare_part events from the same date group). One event
--          typically belongs to one ticket, but the schema allows flexibility.
--
-- Depends on: 012 (t_contract_events), 022 (t_service_tickets)
-- ============================================================================


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T1: t_service_ticket_events
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE TABLE IF NOT EXISTS t_service_ticket_events (
    id                      UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    ticket_id               UUID NOT NULL,
    event_id                UUID NOT NULL,

    -- Denormalized for quick reads (avoids JOINs for buyer view)
    event_type              TEXT,                                   -- 'service' | 'spare_part' | 'billing'
    block_name              TEXT,                                   -- denormalized from contract event

    -- Audit
    created_at              TIMESTAMPTZ DEFAULT NOW(),

    -- Foreign keys
    CONSTRAINT fk_ste_ticket
        FOREIGN KEY (ticket_id) REFERENCES t_service_tickets(id) ON DELETE CASCADE,
    CONSTRAINT fk_ste_event
        FOREIGN KEY (event_id) REFERENCES t_contract_events(id) ON DELETE CASCADE,

    -- Each event can only be linked to a ticket once
    CONSTRAINT uq_ticket_event UNIQUE (ticket_id, event_id)
);


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T2: Indexes
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Find all events for a ticket
CREATE INDEX IF NOT EXISTS idx_ste_ticket
    ON t_service_ticket_events (ticket_id);

-- Find which ticket an event belongs to
CREATE INDEX IF NOT EXISTS idx_ste_event
    ON t_service_ticket_events (event_id);

-- Combined lookup
CREATE INDEX IF NOT EXISTS idx_ste_ticket_type
    ON t_service_ticket_events (ticket_id, event_type);


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T3: RLS Policies
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ALTER TABLE t_service_ticket_events ENABLE ROW LEVEL SECURITY;

-- Tenant members can view links (via ticket's tenant_id)
CREATE POLICY "Tenant members can view ticket events"
    ON t_service_ticket_events FOR SELECT
    USING (
        ticket_id IN (
            SELECT st.id FROM t_service_tickets st
            WHERE st.tenant_id IN (
                SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
            )
        )
    );

-- Tenant members can create links
CREATE POLICY "Tenant members can create ticket events"
    ON t_service_ticket_events FOR INSERT
    WITH CHECK (
        ticket_id IN (
            SELECT st.id FROM t_service_tickets st
            WHERE st.tenant_id IN (
                SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
            )
        )
    );

-- Tenant members can delete links (unlink an event from a ticket)
CREATE POLICY "Tenant members can delete ticket events"
    ON t_service_ticket_events FOR DELETE
    USING (
        ticket_id IN (
            SELECT st.id FROM t_service_tickets st
            WHERE st.tenant_id IN (
                SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
            )
        )
    );

-- Service role full access
CREATE POLICY "Service role full access to ticket events"
    ON t_service_ticket_events FOR ALL
    USING (auth.role() = 'service_role');


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T4: Grants
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT ALL ON t_service_ticket_events TO service_role;
GRANT SELECT, INSERT, DELETE ON t_service_ticket_events TO authenticated;


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Comments
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

COMMENT ON TABLE t_service_ticket_events IS
    'Junction table linking service tickets to contract events. '
    'One ticket groups multiple events for a single field visit.';

COMMENT ON COLUMN t_service_ticket_events.event_type IS
    'Denormalized from t_contract_events for quick reads without JOIN';

COMMENT ON COLUMN t_service_ticket_events.block_name IS
    'Denormalized from t_contract_events for buyer (CNAK) display';
