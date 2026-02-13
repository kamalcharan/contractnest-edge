-- ============================================================================
-- P1d: Unified Asset Registry + Contract Junction + Denorm on t_contracts
-- Migration: contracts/037_asset_registry_tables.sql
-- Phase: P1 — Equipment & Entity Foundation
--
-- What this does:
--   1. CREATE t_tenant_asset_registry — unified table for equipment AND entities
--   2. CREATE t_contract_assets — junction: which assets are covered by which contract
--   3. ALTER t_contracts — add asset_count (INT) + asset_summary (JSONB)
--   4. Indexes + RLS policies
--
-- Design decisions:
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
-- TABLE 1: t_tenant_asset_registry
-- ============================================================================

CREATE TABLE IF NOT EXISTS t_tenant_asset_registry (
    id                      UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id               UUID NOT NULL,

    -- Classification
    resource_type_id        VARCHAR(50) NOT NULL,               -- FK → m_catalog_resource_types(id): 'equipment','asset','consumable'
    asset_type_id           UUID,                               -- FK → m_category_details(id): LOV pricing variant (1BHK, Split AC 1.5T)
    parent_asset_id         UUID,                               -- self-ref: Building→Floor→Room, equipment groups
    template_id             UUID,                               -- which m_catalog_resource_templates seeded this
    industry_id             UUID,                               -- FK → m_catalog_industries(id): for filtering

    -- Identity
    name                    VARCHAR(255) NOT NULL,
    code                    VARCHAR(100),                       -- tenant internal code: "MRI-001", "BLK-A-FL3"
    description             TEXT,

    -- Status & ownership
    status                  VARCHAR(30) NOT NULL DEFAULT 'active',   -- active | inactive | under_repair | decommissioned
    condition               VARCHAR(30) NOT NULL DEFAULT 'good',     -- good | fair | poor | critical
    criticality             VARCHAR(30) NOT NULL DEFAULT 'medium',   -- low | medium | high | critical
    owner_contact_id        UUID,                               -- FK → t_contacts(id): who owns this asset
    location                TEXT,                               -- free-text location

    -- Equipment-specific (NULL for entities)
    make                    VARCHAR(255),
    model                   VARCHAR(255),
    serial_number           VARCHAR(255),
    purchase_date           DATE,
    warranty_expiry         DATE,
    last_service_date       DATE,

    -- Entity-specific (NULL for equipment)
    area_sqft               NUMERIC(12,2),
    dimensions              JSONB,                              -- {"length":50,"width":30,"height":10,"unit":"ft"}
    capacity                INTEGER,                            -- occupancy / units

    -- Overflow & metadata
    specifications          JSONB DEFAULT '{}'::jsonb,          -- type-specific extras
    tags                    JSONB DEFAULT '[]'::jsonb,
    image_url               TEXT,

    -- Environment & soft delete
    is_active               BOOLEAN NOT NULL DEFAULT true,      -- soft delete
    is_live                 BOOLEAN NOT NULL DEFAULT true,      -- live vs test

    -- Audit
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by              UUID,
    updated_by              UUID,

    -- Foreign keys
    CONSTRAINT fk_tar_resource_type
        FOREIGN KEY (resource_type_id) REFERENCES m_catalog_resource_types(id),
    CONSTRAINT fk_tar_parent_asset
        FOREIGN KEY (parent_asset_id) REFERENCES t_tenant_asset_registry(id) ON DELETE SET NULL,
    CONSTRAINT fk_tar_template
        FOREIGN KEY (template_id) REFERENCES m_catalog_resource_templates(id) ON DELETE SET NULL,

    -- Constraints
    CONSTRAINT chk_tar_status
        CHECK (status IN ('active','inactive','under_repair','decommissioned')),
    CONSTRAINT chk_tar_condition
        CHECK (condition IN ('good','fair','poor','critical')),
    CONSTRAINT chk_tar_criticality
        CHECK (criticality IN ('low','medium','high','critical'))
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_tar_tenant_id
    ON t_tenant_asset_registry(tenant_id);
CREATE INDEX IF NOT EXISTS idx_tar_tenant_type
    ON t_tenant_asset_registry(tenant_id, resource_type_id);
CREATE INDEX IF NOT EXISTS idx_tar_tenant_live_active
    ON t_tenant_asset_registry(tenant_id, is_live, is_active);
CREATE INDEX IF NOT EXISTS idx_tar_parent
    ON t_tenant_asset_registry(parent_asset_id) WHERE parent_asset_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tar_serial
    ON t_tenant_asset_registry(serial_number) WHERE serial_number IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tar_code
    ON t_tenant_asset_registry(tenant_id, code) WHERE code IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tar_owner
    ON t_tenant_asset_registry(owner_contact_id) WHERE owner_contact_id IS NOT NULL;

-- RLS
ALTER TABLE t_tenant_asset_registry ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tar_tenant_isolation" ON t_tenant_asset_registry
    FOR ALL
    USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE POLICY "tar_service_role_bypass" ON t_tenant_asset_registry
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

    -- Per-asset coverage details
    coverage_type           VARCHAR(50),                        -- comprehensive | non_comprehensive | preventive | on_demand
    service_terms           JSONB DEFAULT '{}'::jsonb,          -- per-asset terms override
    pricing_override        JSONB,                              -- per-asset pricing if different from contract default
    notes                   TEXT,

    -- Environment & soft delete
    is_active               BOOLEAN NOT NULL DEFAULT true,
    is_live                 BOOLEAN NOT NULL DEFAULT true,

    -- Audit
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Foreign keys
    CONSTRAINT fk_ca_contract
        FOREIGN KEY (contract_id) REFERENCES t_contracts(id) ON DELETE CASCADE,
    CONSTRAINT fk_ca_asset
        FOREIGN KEY (asset_id) REFERENCES t_tenant_asset_registry(id) ON DELETE CASCADE,

    -- Prevent duplicate asset-contract links
    CONSTRAINT uq_ca_contract_asset UNIQUE (contract_id, asset_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_ca_contract
    ON t_contract_assets(contract_id);
CREATE INDEX IF NOT EXISTS idx_ca_asset
    ON t_contract_assets(asset_id);
CREATE INDEX IF NOT EXISTS idx_ca_tenant_live
    ON t_contract_assets(tenant_id, is_live);

-- RLS
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

-- Comment for clarity
COMMENT ON COLUMN t_contracts.asset_count IS 'Denormalized count of linked assets from t_contract_assets';
COMMENT ON COLUMN t_contracts.asset_summary IS 'Denormalized JSON array: [{"id":"...","name":"MRI Scanner #1","type":"equipment"}]';
