-- ============================================================================
-- CATALOG STUDIO: cat_blocks Table
-- ============================================================================
-- Purpose: Global blocks library for Catalog Studio
-- Scope: GLOBAL (not tenant-specific)
--
-- Key Design Decisions:
-- 1. No tenant_id - blocks are global
-- 2. is_admin - only admin can use this block to create templates
-- 3. is_active - inactive blocks hidden from frontend
-- 4. visible - only is_admin users see invisible blocks
-- 5. NO DB constraints for enums - values from m_category_master/details
-- ============================================================================

-- Create the cat_blocks table
CREATE TABLE IF NOT EXISTS cat_blocks (
    -- Primary Key
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Block Classification (references m_category_details.id for 'cat_block_type')
    block_type_id UUID NOT NULL,

    -- Display Information
    name VARCHAR(255) NOT NULL,
    display_name VARCHAR(255),
    icon VARCHAR(50) DEFAULT '📦',
    description TEXT,

    -- Industry & Categorization
    tags JSONB DEFAULT '[]',              -- Industry-specific tags for filtering
    category VARCHAR(100),                 -- Custom grouping/folder

    -- Block Configuration (type-specific settings)
    config JSONB NOT NULL DEFAULT '{}',

    -- Pricing Configuration
    pricing_mode_id UUID,                  -- References m_category_details for 'cat_pricing_mode'
    base_price DECIMAL(12,2),
    currency VARCHAR(3) DEFAULT 'INR',
    price_type_id UUID,                    -- References m_category_details for 'cat_price_type'
    tax_rate DECIMAL(5,2) DEFAULT 18.00,
    hsn_sac_code VARCHAR(20),

    -- Resource-based pricing (when pricing_mode = resource_based)
    resource_pricing JSONB,

    -- Variant-based pricing (when pricing_mode = variant_based)
    variant_pricing JSONB,

    -- Access Control
    is_admin BOOLEAN NOT NULL DEFAULT false,  -- Only admin can use to create templates
    visible BOOLEAN NOT NULL DEFAULT true,    -- Only is_admin users see invisible blocks

    -- Status (references m_category_details for 'cat_block_status')
    status_id UUID,
    is_active BOOLEAN NOT NULL DEFAULT true,  -- Inactive blocks hidden from frontend

    -- Versioning
    version INTEGER NOT NULL DEFAULT 1,

    -- Ordering
    sequence_no INTEGER DEFAULT 0,

    -- Soft Delete
    is_deletable BOOLEAN NOT NULL DEFAULT true,

    -- Audit Fields
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    updated_by UUID
);

-- ============================================================================
-- INDEXES
-- ============================================================================

-- Primary lookup indexes
CREATE INDEX idx_cat_blocks_block_type ON cat_blocks(block_type_id);
CREATE INDEX idx_cat_blocks_status ON cat_blocks(status_id);
CREATE INDEX idx_cat_blocks_is_active ON cat_blocks(is_active);
CREATE INDEX idx_cat_blocks_is_admin ON cat_blocks(is_admin);
CREATE INDEX idx_cat_blocks_visible ON cat_blocks(visible);

-- Pricing indexes
CREATE INDEX idx_cat_blocks_pricing_mode ON cat_blocks(pricing_mode_id);

-- Search and filter indexes
CREATE INDEX idx_cat_blocks_tags ON cat_blocks USING GIN(tags);
CREATE INDEX idx_cat_blocks_config ON cat_blocks USING GIN(config);
CREATE INDEX idx_cat_blocks_category ON cat_blocks(category);

-- Ordering
CREATE INDEX idx_cat_blocks_sequence ON cat_blocks(sequence_no);

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================

ALTER TABLE cat_blocks ENABLE ROW LEVEL SECURITY;

-- Read policy: All authenticated users can read active, visible blocks
-- Admin users can read all blocks
CREATE POLICY read_cat_blocks ON cat_blocks
    FOR SELECT
    USING (
        (is_active = true AND visible = true)
        OR
        (auth.jwt() ->> 'is_admin')::boolean = true
    );

-- Write policy: Only admin users can insert/update/delete
CREATE POLICY write_cat_blocks ON cat_blocks
    FOR ALL
    USING ((auth.jwt() ->> 'is_admin')::boolean = true)
    WITH CHECK ((auth.jwt() ->> 'is_admin')::boolean = true);

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION update_cat_blocks_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_cat_blocks_updated_at
    BEFORE UPDATE ON cat_blocks
    FOR EACH ROW
    EXECUTE FUNCTION update_cat_blocks_updated_at();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE cat_blocks IS 'Global blocks library for Catalog Studio. Blocks are reusable units (service, spare, billing, etc.) used to build templates.';
COMMENT ON COLUMN cat_blocks.block_type_id IS 'References m_category_details.id where category = cat_block_type';
COMMENT ON COLUMN cat_blocks.pricing_mode_id IS 'References m_category_details.id where category = cat_pricing_mode';
COMMENT ON COLUMN cat_blocks.price_type_id IS 'References m_category_details.id where category = cat_price_type';
COMMENT ON COLUMN cat_blocks.status_id IS 'References m_category_details.id where category = cat_block_status';
COMMENT ON COLUMN cat_blocks.is_admin IS 'If true, only admin can use this block to create templates. Tenants can use templates containing this block.';
COMMENT ON COLUMN cat_blocks.visible IS 'If false, only is_admin users can see this block in the UI.';
COMMENT ON COLUMN cat_blocks.tags IS 'Industry-specific tags for filtering (e.g., ["healthcare", "fitness"])';
COMMENT ON COLUMN cat_blocks.config IS 'Type-specific configuration (duration, location, evidence, etc.)';
COMMENT ON COLUMN cat_blocks.resource_pricing IS 'Resource-based pricing configuration with options array';
COMMENT ON COLUMN cat_blocks.variant_pricing IS 'Variant-based pricing configuration with options array';
