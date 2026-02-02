    -- =============================================================
    -- CONTRACT ACCESS TABLE + GLOBAL ACCESS ID (CNAK)
    -- Migration: contracts/004_contract_access_table.sql
    -- Purpose: CNAK (ContractNest Access Key) system
    --   - Adds global_access_id column to t_contracts
    --   - Creates t_contract_access mapping table for external access
    -- =============================================================

    -- ─────────────────────────────────────────────────────────────
    -- 1. Add global_access_id column to t_contracts
    -- ─────────────────────────────────────────────────────────────
    ALTER TABLE t_contracts
    ADD COLUMN IF NOT EXISTS global_access_id VARCHAR(12);

    -- Unique within tenant (CNAK + tenant_id is always the lookup pair)
    CREATE UNIQUE INDEX IF NOT EXISTS idx_contracts_tenant_cnak
    ON t_contracts (tenant_id, global_access_id)
    WHERE global_access_id IS NOT NULL;

    -- Fast lookup by CNAK alone (for public access validation)
    CREATE INDEX IF NOT EXISTS idx_contracts_cnak
    ON t_contracts (global_access_id)
    WHERE global_access_id IS NOT NULL;


    -- ─────────────────────────────────────────────────────────────
    -- 2. Create t_contract_access table
    -- ─────────────────────────────────────────────────────────────
    CREATE TABLE IF NOT EXISTS t_contract_access (
        id                    UUID DEFAULT gen_random_uuid() PRIMARY KEY,

        -- Contract reference
        contract_id           UUID NOT NULL,
        global_access_id      VARCHAR(12) NOT NULL,     -- CNAK-XXXXXX (denormalized for direct lookups)

        -- Tenant context
        tenant_id             UUID NOT NULL,             -- owner tenant (contract belongs to this tenant)
        creator_tenant_id     UUID NOT NULL,             -- tenant who created the contract

        -- Accessor (the party being granted access)
        accessor_tenant_id    UUID,                      -- tenant being granted access (NULL if external/unknown)
        accessor_role         VARCHAR(20) NOT NULL,      -- 'client' | 'vendor' | 'partner'
        accessor_contact_id   UUID,                      -- link to t_contacts if known
        accessor_email        TEXT,                      -- for verification / notifications
        accessor_name         TEXT,                      -- display name

        -- Access control
        is_active             BOOLEAN DEFAULT true,
        expires_at            TIMESTAMPTZ,               -- optional expiry

        -- Audit
        created_by            UUID,
        created_at            TIMESTAMPTZ DEFAULT NOW(),
        updated_at            TIMESTAMPTZ DEFAULT NOW(),

        -- FK to contracts
        CONSTRAINT fk_contract_access_contract
            FOREIGN KEY (contract_id) REFERENCES t_contracts(id) ON DELETE CASCADE
    );


    -- ─────────────────────────────────────────────────────────────
    -- 3. Indexes for t_contract_access
    -- ─────────────────────────────────────────────────────────────

    -- Primary lookup: CNAK + tenant (public access validation)
    CREATE INDEX IF NOT EXISTS idx_contract_access_cnak_lookup
        ON t_contract_access (tenant_id, global_access_id)
        WHERE is_active = true;

    -- By contract (list all access grants for a contract)
    CREATE INDEX IF NOT EXISTS idx_contract_access_contract
        ON t_contract_access (contract_id);

    -- By accessor tenant (find all contracts a tenant has access to)
    CREATE INDEX IF NOT EXISTS idx_contract_access_accessor
        ON t_contract_access (accessor_tenant_id)
        WHERE accessor_tenant_id IS NOT NULL AND is_active = true;

    -- Prevent duplicate grants: one role per accessor per contract
    CREATE UNIQUE INDEX IF NOT EXISTS idx_contract_access_unique_grant
        ON t_contract_access (contract_id, accessor_role, COALESCE(accessor_tenant_id, '00000000-0000-0000-0000-000000000000'::UUID));


    -- ─────────────────────────────────────────────────────────────
    -- 4. RLS Policies for t_contract_access
    -- ─────────────────────────────────────────────────────────────

    ALTER TABLE t_contract_access ENABLE ROW LEVEL SECURITY;

    -- Public can validate contract access via CNAK + tenant_id
    -- (mirrors the invitation system's "Public can validate invitations" policy)
    CREATE POLICY "Public can validate contract access"
        ON t_contract_access
        FOR SELECT
        USING (
            global_access_id IS NOT NULL
            AND tenant_id IS NOT NULL
            AND is_active = true
        );

    -- Tenant members can view all access grants for their contracts
    CREATE POLICY "Tenant members can view contract access"
        ON t_contract_access
        FOR SELECT
        USING (
            tenant_id IN (
                SELECT ut.tenant_id
                FROM t_user_tenants ut
                WHERE ut.user_id = auth.uid()
            )
        );

    -- Tenant members can create access grants for their contracts
    CREATE POLICY "Tenant members can create contract access"
        ON t_contract_access
        FOR INSERT
        WITH CHECK (
            tenant_id IN (
                SELECT ut.tenant_id
                FROM t_user_tenants ut
                WHERE ut.user_id = auth.uid()
            )
        );

    -- Tenant members can update access grants for their contracts
    CREATE POLICY "Tenant members can update contract access"
        ON t_contract_access
        FOR UPDATE
        USING (
            tenant_id IN (
                SELECT ut.tenant_id
                FROM t_user_tenants ut
                WHERE ut.user_id = auth.uid()
            )
        );


    -- ─────────────────────────────────────────────────────────────
    -- 5. Grants
    -- ─────────────────────────────────────────────────────────────

    -- Service role (edge functions) — full access
    GRANT ALL ON t_contract_access TO service_role;

    -- Authenticated users — governed by RLS
    GRANT SELECT, INSERT, UPDATE ON t_contract_access TO authenticated;

    -- Anon/public — read only via RLS policy (CNAK validation)
    GRANT SELECT ON t_contract_access TO anon;
