-- ============================================================================
-- P1: Client Asset Registry + Contract Junction + Denorm on t_contracts
-- Migration: contracts/037_asset_registry_tables.sql
-- Phase: P1 — Client-Owned Asset Foundation
--
-- What this does:
--   1. CREATE t_client_asset_registry — unified table for client-owned equipment AND entities
--   2. CREATE t_contract_assets — junction: which assets are covered by which contract
--   3. ALTER t_contracts — add asset_count (INT) + asset_summary (JSONB)
--   4. Indexes + RLS policies
--
-- Design decisions:
--   - Assets belong to CLIENTS (contacts), not the tenant.
--     owner_contact_id is NOT NULL — every asset has an owner.
--   - Equipment + entities in ONE table, distinguished by resource_type_id
--   - Equipment-specific fields (serial_number, warranty_expiry) NULL for entities
--   - Entity-specific fields (area_sqft, dimensions) NULL for equipment
--   - Overflow → specifications JSONB
--   - Hierarchy via parent_asset_id self-reference
--   - is_live = environment switch (live/test), is_active = soft delete
--
-- Rollback: See 037_asset_registry_tables_DOWN.sql
-- ============================================================================

-- ============================================================================
-- TABLE 1: t_client_asset_registry
-- ============================================================================

CREATE TABLE IF NOT EXISTS t_client_asset_registry (
    id                      UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id               UUID NOT NULL,

    -- Ownership (REQUIRED — every asset belongs to a client contact)
    owner_contact_id        UUID NOT NULL,

    -- Classification
    resource_type_id        VARCHAR(50) NOT NULL,
    asset_type_id           UUID,
    parent_asset_id         UUID,
    template_id             UUID,
    industry_id             UUID,

    -- Identity
    name                    VARCHAR(255) NOT NULL,
    code                    VARCHAR(100),
    description             TEXT,

    -- Status
    status                  VARCHAR(30) NOT NULL DEFAULT 'active',
    condition               VARCHAR(30) NOT NULL DEFAULT 'good',
    criticality             VARCHAR(30) NOT NULL DEFAULT 'medium',
    location                TEXT,

    -- Equipment-specific (NULL for entities)
    make                    VARCHAR(255),
    model                   VARCHAR(255),
    serial_number           VARCHAR(255),
    purchase_date           DATE,
    warranty_expiry         DATE,
    last_service_date       DATE,

    -- Entity-specific (NULL for equipment)
    area_sqft               NUMERIC(12,2),
    dimensions              JSONB,
    capacity                INTEGER,

    -- Overflow & metadata
    specifications          JSONB DEFAULT '{}'::jsonb,
    tags                    JSONB DEFAULT '[]'::jsonb,
    image_url               TEXT,

    -- Environment & soft delete
    is_active               BOOLEAN NOT NULL DEFAULT true,
    is_live                 BOOLEAN NOT NULL DEFAULT true,

    -- Audit
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by              UUID,
    updated_by              UUID,

    -- Foreign keys
    CONSTRAINT fk_car_resource_type
        FOREIGN KEY (resource_type_id) REFERENCES m_catalog_resource_types(id),
    CONSTRAINT fk_car_parent_asset
        FOREIGN KEY (parent_asset_id) REFERENCES t_client_asset_registry(id) ON DELETE SET NULL,
    CONSTRAINT fk_car_template
        FOREIGN KEY (template_id) REFERENCES m_catalog_resource_templates(id) ON DELETE SET NULL,

    -- Constraints
    CONSTRAINT chk_car_status
        CHECK (status IN ('active','inactive','under_repair','decommissioned')),
    CONSTRAINT chk_car_condition
        CHECK (condition IN ('good','fair','poor','critical')),
    CONSTRAINT chk_car_criticality
        CHECK (criticality IN ('low','medium','high','critical'))
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_car_tenant_id
    ON t_client_asset_registry(tenant_id);
CREATE INDEX IF NOT EXISTS idx_car_owner_contact
    ON t_client_asset_registry(owner_contact_id);
CREATE INDEX IF NOT EXISTS idx_car_tenant_owner
    ON t_client_asset_registry(tenant_id, owner_contact_id);
CREATE INDEX IF NOT EXISTS idx_car_tenant_type
    ON t_client_asset_registry(tenant_id, resource_type_id);
CREATE INDEX IF NOT EXISTS idx_car_tenant_live_active
    ON t_client_asset_registry(tenant_id, is_live, is_active);
CREATE INDEX IF NOT EXISTS idx_car_parent
    ON t_client_asset_registry(parent_asset_id) WHERE parent_asset_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_car_serial
    ON t_client_asset_registry(serial_number) WHERE serial_number IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_car_code
    ON t_client_asset_registry(tenant_id, code) WHERE code IS NOT NULL;

-- RLS
ALTER TABLE t_client_asset_registry ENABLE ROW LEVEL SECURITY;

CREATE POLICY "car_tenant_isolation" ON t_client_asset_registry
    FOR ALL
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE POLICY "car_service_role_bypass" ON t_client_asset_registry
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- ============================================================================
-- TABLE 2: t_contract_assets (junction)
-- ============================================================================

CREATE TABLE IF NOT EXISTS t_contract_assets (
    id                      UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    contract_id             UUID NOT NULL,
    asset_id                UUID NOT NULL,
    tenant_id               UUID NOT NULL,

    coverage_type           VARCHAR(50),
    service_terms           JSONB DEFAULT '{}'::jsonb,
    pricing_override        JSONB,
    notes                   TEXT,

    is_active               BOOLEAN NOT NULL DEFAULT true,
    is_live                 BOOLEAN NOT NULL DEFAULT true,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_ca_contract
        FOREIGN KEY (contract_id) REFERENCES t_contracts(id) ON DELETE CASCADE,
    CONSTRAINT fk_ca_asset
        FOREIGN KEY (asset_id) REFERENCES t_client_asset_registry(id) ON DELETE CASCADE,

    CONSTRAINT uq_ca_contract_asset UNIQUE (contract_id, asset_id)
);

CREATE INDEX IF NOT EXISTS idx_ca_contract ON t_contract_assets(contract_id);
CREATE INDEX IF NOT EXISTS idx_ca_asset ON t_contract_assets(asset_id);
CREATE INDEX IF NOT EXISTS idx_ca_tenant_live ON t_contract_assets(tenant_id, is_live);

ALTER TABLE t_contract_assets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ca_tenant_isolation" ON t_contract_assets
    FOR ALL
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE POLICY "ca_service_role_bypass" ON t_contract_assets
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- ============================================================================
-- ALTER t_contracts: Add denormalized asset columns
-- ============================================================================

ALTER TABLE t_contracts
    ADD COLUMN IF NOT EXISTS asset_count    INT   DEFAULT 0,
    ADD COLUMN IF NOT EXISTS asset_summary  JSONB DEFAULT '[]'::jsonb;

COMMENT ON COLUMN t_contracts.asset_count IS 'Denormalized count of linked assets from t_contract_assets';
COMMENT ON COLUMN t_contracts.asset_summary IS 'Denormalized JSON array: [{"id":"...","name":"MRI Scanner #1","type":"equipment"}]';
