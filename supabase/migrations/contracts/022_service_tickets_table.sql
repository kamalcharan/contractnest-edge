-- ============================================================================
-- Migration 022: Service Tickets Table
-- ============================================================================
-- Purpose: t_service_tickets — groups contract events into field-executable
--          work units. Each ticket represents one on-site visit or service
--          session containing one or more events (service, spare_part).
--
-- Ticket lifecycle: created → assigned → in_progress → completed / cancelled
-- Ticket number: TKT-XXXXX auto-generated via sequence system
--
-- Denormalization: assigned_to_name, created_by_name stored alongside FKIDs
--                  because buyer (CNAK) will view this data without FK resolution.
--
-- Depends on: 012 (t_contract_events), sequence-numbers/001 (t_sequence_counters)
-- ============================================================================


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T1: t_service_tickets
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE TABLE IF NOT EXISTS t_service_tickets (
    id                      UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id               UUID NOT NULL,
    contract_id             UUID NOT NULL,

    -- Ticket identity
    ticket_number           TEXT,                                   -- TKT-XXXXX, auto-generated
    status                  TEXT NOT NULL DEFAULT 'created',        -- created | assigned | in_progress | evidence_uploaded | completed | cancelled

    -- Scheduling
    scheduled_date          TIMESTAMPTZ,                            -- planned date for service execution
    started_at              TIMESTAMPTZ,                            -- when tech started work
    completed_at            TIMESTAMPTZ,                            -- when service was marked completed

    -- Assignment (denormalized — FKID + name for buyer visibility)
    assigned_to             UUID,                                   -- FK to team member contact
    assigned_to_name        TEXT,                                   -- denormalized: "Rajesh Kumar"

    -- Creator (denormalized)
    created_by              UUID,                                   -- user who created the ticket
    created_by_name         TEXT,                                   -- denormalized: "Operations Admin"

    -- Content
    notes                   TEXT,                                   -- service notes / instructions
    completion_notes        TEXT,                                   -- technician's completion summary

    -- Concurrency & environment
    version                 INT NOT NULL DEFAULT 1,                 -- optimistic concurrency
    is_live                 BOOLEAN DEFAULT true,                   -- live vs test
    is_active               BOOLEAN DEFAULT true,                   -- soft delete

    -- Audit
    created_at              TIMESTAMPTZ DEFAULT NOW(),
    updated_at              TIMESTAMPTZ DEFAULT NOW(),
    updated_by              UUID,

    -- Foreign keys
    CONSTRAINT fk_st_contract
        FOREIGN KEY (contract_id) REFERENCES t_contracts(id) ON DELETE CASCADE
);


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T2: Indexes
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Contract-scoped queries (list tickets for a contract)
CREATE INDEX IF NOT EXISTS idx_st_contract
    ON t_service_tickets (contract_id)
    WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_st_contract_status
    ON t_service_tickets (contract_id, status)
    WHERE is_active = true;

-- Tenant-scoped queries (dashboard, all tickets)
CREATE INDEX IF NOT EXISTS idx_st_tenant_status
    ON t_service_tickets (tenant_id, status)
    WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_st_tenant_date
    ON t_service_tickets (tenant_id, scheduled_date)
    WHERE is_active = true;

-- Assignment-scoped queries (my tickets)
CREATE INDEX IF NOT EXISTS idx_st_assigned
    ON t_service_tickets (tenant_id, assigned_to, status)
    WHERE is_active = true AND assigned_to IS NOT NULL;

-- Ticket number lookup
CREATE UNIQUE INDEX IF NOT EXISTS idx_st_ticket_number
    ON t_service_tickets (tenant_id, ticket_number)
    WHERE ticket_number IS NOT NULL;


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T3: Trigger — auto-update updated_at
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE FUNCTION update_service_tickets_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_service_tickets_updated_at ON t_service_tickets;
CREATE TRIGGER trigger_service_tickets_updated_at
    BEFORE UPDATE ON t_service_tickets
    FOR EACH ROW
    EXECUTE FUNCTION update_service_tickets_updated_at();


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T4: RLS Policies
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ALTER TABLE t_service_tickets ENABLE ROW LEVEL SECURITY;

-- Tenant members can view tickets
CREATE POLICY "Tenant members can view service tickets"
    ON t_service_tickets FOR SELECT
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Tenant members can create tickets
CREATE POLICY "Tenant members can create service tickets"
    ON t_service_tickets FOR INSERT
    WITH CHECK (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Tenant members can update tickets
CREATE POLICY "Tenant members can update service tickets"
    ON t_service_tickets FOR UPDATE
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Service role full access (for Edge Functions / RPCs)
CREATE POLICY "Service role full access to service tickets"
    ON t_service_tickets FOR ALL
    USING (auth.role() = 'service_role');


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T5: Grants
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT ALL ON t_service_tickets TO service_role;
GRANT SELECT, INSERT, UPDATE ON t_service_tickets TO authenticated;


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T6: Seed TKT sequence config for all existing tenants
-- Uses t_category_details under 'sequence_numbers' category
-- Format: TKT-XXXXX (prefix=TKT, separator=-, padding=5, start=10001)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

DO $$
DECLARE
    v_seq_cat_id UUID;
    v_tenant RECORD;
BEGIN
    -- Find the 'sequence_numbers' category master
    SELECT id INTO v_seq_cat_id
    FROM t_category_master
    WHERE category_name = 'sequence_numbers'
    LIMIT 1;

    IF v_seq_cat_id IS NULL THEN
        RAISE NOTICE 'sequence_numbers category not found — TKT sequence must be seeded manually';
        RETURN;
    END IF;

    -- Insert TKT sequence config for each tenant that has TASK but not TKT
    FOR v_tenant IN
        SELECT DISTINCT cd.tenant_id
        FROM t_category_details cd
        WHERE cd.category_id = v_seq_cat_id
          AND cd.sub_cat_name = 'TASK'
          AND cd.is_active = true
          AND NOT EXISTS (
              SELECT 1 FROM t_category_details cd2
              WHERE cd2.category_id = v_seq_cat_id
                AND cd2.tenant_id = cd.tenant_id
                AND cd2.sub_cat_name = 'TKT'
                AND cd2.is_active = true
          )
    LOOP
        INSERT INTO t_category_details (
            category_id,
            tenant_id,
            sub_cat_name,
            display_name,
            description,
            form_settings,
            is_active,
            is_live
        ) VALUES (
            v_seq_cat_id,
            v_tenant.tenant_id,
            'TKT',
            'Service Ticket',
            'Auto-generated ticket number for service tickets (TKT-XXXXX)',
            jsonb_build_object(
                'prefix', 'TKT',
                'separator', '-',
                'padding_length', 5,
                'start_value', 10001
            ),
            true,
            true
        );
        RAISE NOTICE 'Seeded TKT sequence for tenant %', v_tenant.tenant_id;
    END LOOP;
END;
$$;


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Comments
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

COMMENT ON TABLE t_service_tickets IS
    'Service tickets group contract events into field-executable work units. '
    'Each ticket = one on-site visit with assigned technician and evidence collection.';

COMMENT ON COLUMN t_service_tickets.ticket_number IS
    'TKT-XXXXX format, auto-generated via sequence system (t_category_details + t_sequence_counters)';

COMMENT ON COLUMN t_service_tickets.assigned_to_name IS
    'Denormalized name for buyer (CNAK) visibility without FK resolution';

COMMENT ON COLUMN t_service_tickets.status IS
    'created → assigned → in_progress → evidence_uploaded → completed / cancelled';
