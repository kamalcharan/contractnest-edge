-- ============================================================================
-- CATALOG STUDIO: Add is_live Column to cat_blocks
-- ============================================================================
-- Purpose: Track whether a block belongs to live or test environment
--
-- Context:
-- - The frontend sets x-environment header based on AuthContext.isLive
-- - This column allows filtering blocks by environment
-- - Default is true (live) for backwards compatibility
-- ============================================================================

-- Add is_live column
ALTER TABLE cat_blocks
ADD COLUMN IF NOT EXISTS is_live BOOLEAN NOT NULL DEFAULT true;

-- ============================================================================
-- INDEX for environment filtering
-- ============================================================================

-- Index for is_live lookups (commonly filtered)
CREATE INDEX IF NOT EXISTS idx_cat_blocks_is_live ON cat_blocks(is_live);

-- Composite index for tenant + environment + active blocks
CREATE INDEX IF NOT EXISTS idx_cat_blocks_tenant_live_active
ON cat_blocks(tenant_id, is_live, is_active) WHERE is_active = true;

-- ============================================================================
-- COMMENT
-- ============================================================================

COMMENT ON COLUMN cat_blocks.is_live IS 'If true, block is in live environment. If false, block is in test/sandbox environment.';

-- ============================================================================
-- VERIFICATION QUERY
-- ============================================================================

-- Run this to verify the change:
-- SELECT column_name, data_type, is_nullable, column_default
-- FROM information_schema.columns
-- WHERE table_name = 'cat_blocks'
-- AND column_name = 'is_live';
