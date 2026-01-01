-- ============================================================================
-- CATALOG STUDIO: cat_templates Table
-- ============================================================================
-- Purpose: Templates created from blocks (block-builder output)
-- Scope: TENANT-SPECIFIC with GLOBAL admin templates
--
-- Key Design Decisions:
-- 1. tenant_id NULL = global/admin template (can be copied to tenant space)
-- 2. tenant_id NOT NULL = tenant-specific template
-- 3. is_system = admin-created template that tenants can copy
-- 4. copied_from_id = reference to original template if copied
-- ============================================================================

-- Create the cat_templates table
CREATE TABLE IF NOT EXISTS cat_templates (
    -- Primary Key
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Tenant Ownership
    tenant_id UUID,                        -- NULL for global/admin templates
    is_live BOOLEAN NOT NULL DEFAULT false, -- Environment flag (test/production)

    -- Template Info
    name VARCHAR(255) NOT NULL,
    display_name VARCHAR(255),
    description TEXT,
    category VARCHAR(100),
    tags JSONB DEFAULT '[]',
    cover_image TEXT,                      -- Storage URL for cover image

    -- Block Assembly
    -- Structure: [{ block_id, section, quantity, price_override, sequence, config_override }]
    blocks JSONB NOT NULL DEFAULT '[]',

    -- Pricing Defaults
    currency VARCHAR(3) DEFAULT 'INR',
    tax_rate DECIMAL(5,2) DEFAULT 18.00,
    discount_config JSONB DEFAULT '{"allowed": true, "max_percent": 20}',

    -- Calculated Totals (for display, recalculated on change)
    subtotal DECIMAL(12,2),
    total DECIMAL(12,2),

    -- Template Settings
    settings JSONB DEFAULT '{}',

    -- Admin/System Templates
    is_system BOOLEAN NOT NULL DEFAULT false,  -- Admin-created, can be copied by tenants
    copied_from_id UUID REFERENCES cat_templates(id), -- If copied from another template

    -- Industry Tags (for filtering in template gallery)
    industry_tags JSONB DEFAULT '[]',

    -- Visibility
    is_public BOOLEAN NOT NULL DEFAULT false,  -- Show in public template gallery
    is_active BOOLEAN NOT NULL DEFAULT true,

    -- Status (references m_category_details for 'cat_template_status')
    status_id UUID,

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

-- Tenant lookup
CREATE INDEX idx_cat_templates_tenant ON cat_templates(tenant_id);
CREATE INDEX idx_cat_templates_tenant_live ON cat_templates(tenant_id, is_live);

-- System/Admin templates
CREATE INDEX idx_cat_templates_system ON cat_templates(is_system);
CREATE INDEX idx_cat_templates_copied_from ON cat_templates(copied_from_id);

-- Status and visibility
CREATE INDEX idx_cat_templates_status ON cat_templates(status_id);
CREATE INDEX idx_cat_templates_is_active ON cat_templates(is_active);
CREATE INDEX idx_cat_templates_is_public ON cat_templates(is_public);

-- Search and filter
CREATE INDEX idx_cat_templates_category ON cat_templates(category);
CREATE INDEX idx_cat_templates_tags ON cat_templates USING GIN(tags);
CREATE INDEX idx_cat_templates_industry_tags ON cat_templates USING GIN(industry_tags);
CREATE INDEX idx_cat_templates_blocks ON cat_templates USING GIN(blocks);

-- Ordering
CREATE INDEX idx_cat_templates_sequence ON cat_templates(sequence_no);

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================

ALTER TABLE cat_templates ENABLE ROW LEVEL SECURITY;

-- Read policy:
-- 1. Users can read their own tenant's templates
-- 2. Users can read system/global templates (tenant_id IS NULL AND is_system = true)
-- 3. Users can read public templates
-- 4. Admin users can read all templates
CREATE POLICY read_cat_templates ON cat_templates
    FOR SELECT
    USING (
        -- Own tenant's templates
        (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid AND is_active = true)
        OR
        -- System/global templates
        (tenant_id IS NULL AND is_system = true AND is_active = true)
        OR
        -- Public templates
        (is_public = true AND is_active = true)
        OR
        -- Admin access
        (auth.jwt() ->> 'is_admin')::boolean = true
    );

-- Insert policy: Users can create templates in their own tenant, admin can create system templates
CREATE POLICY insert_cat_templates ON cat_templates
    FOR INSERT
    WITH CHECK (
        -- Tenant users create in their tenant
        (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid)
        OR
        -- Admin can create system templates
        ((auth.jwt() ->> 'is_admin')::boolean = true)
    );

-- Update policy: Users can update their own tenant's templates, admin can update any
CREATE POLICY update_cat_templates ON cat_templates
    FOR UPDATE
    USING (
        (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid)
        OR
        (auth.jwt() ->> 'is_admin')::boolean = true
    )
    WITH CHECK (
        (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid)
        OR
        (auth.jwt() ->> 'is_admin')::boolean = true
    );

-- Delete policy: Users can delete their own tenant's templates, admin can delete any
CREATE POLICY delete_cat_templates ON cat_templates
    FOR DELETE
    USING (
        (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid AND is_deletable = true)
        OR
        (auth.jwt() ->> 'is_admin')::boolean = true
    );

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION update_cat_templates_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_cat_templates_updated_at
    BEFORE UPDATE ON cat_templates
    FOR EACH ROW
    EXECUTE FUNCTION update_cat_templates_updated_at();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE cat_templates IS 'Templates created from blocks using the block-builder. Can be tenant-specific or global system templates.';
COMMENT ON COLUMN cat_templates.tenant_id IS 'NULL for global/admin templates, UUID for tenant-specific templates';
COMMENT ON COLUMN cat_templates.is_system IS 'Admin-created templates that tenants can copy to their space';
COMMENT ON COLUMN cat_templates.copied_from_id IS 'Reference to original template if this was copied from a system template';
COMMENT ON COLUMN cat_templates.blocks IS 'Array of block references: [{block_id, section, quantity, price_override, sequence}]';
COMMENT ON COLUMN cat_templates.is_public IS 'Show in public template gallery for discovery';
COMMENT ON COLUMN cat_templates.industry_tags IS 'Industry tags for filtering in template gallery';
