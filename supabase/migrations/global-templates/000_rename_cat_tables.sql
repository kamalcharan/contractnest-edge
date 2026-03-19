-- ============================================================================
-- GLOBAL TEMPLATES: Step 0 - Rename cat_blocks → m_cat_blocks, cat_templates → m_cat_templates
-- ============================================================================
-- Purpose: Align table names with master data naming convention (m_ prefix)
-- These tables hold global/master data, not tenant-scoped transactional data
--
-- Impact:
--   - PostgreSQL auto-updates: constraints, triggers, RLS policies, FKs
--   - Index NAMES remain unchanged (cosmetic, no functional impact)
--   - Edge functions must update .from() calls
--
-- Rollback:
--   ALTER TABLE m_cat_blocks RENAME TO cat_blocks;
--   ALTER TABLE m_cat_templates RENAME TO cat_templates;
-- ============================================================================

-- Step 1: Rename tables
ALTER TABLE IF EXISTS cat_blocks RENAME TO m_cat_blocks;
ALTER TABLE IF EXISTS cat_templates RENAME TO m_cat_templates;

-- Step 2: Update self-referencing FK comment (FK constraint auto-updates)
COMMENT ON COLUMN m_cat_templates.copied_from_id IS 'Reference to source template when copied (self-FK to m_cat_templates.id)';

-- Step 3: Update table comments
COMMENT ON TABLE m_cat_blocks IS 'Master catalog blocks - reusable building blocks for contract templates (renamed from cat_blocks)';
COMMENT ON TABLE m_cat_templates IS 'Master catalog templates - reusable contract template assemblies (renamed from cat_templates)';

-- Step 4: Verify rename
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'm_cat_blocks') THEN
    RAISE EXCEPTION 'Rename failed: m_cat_blocks table not found';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'm_cat_templates') THEN
    RAISE EXCEPTION 'Rename failed: m_cat_templates table not found';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'cat_blocks') THEN
    RAISE EXCEPTION 'Rename incomplete: old cat_blocks table still exists';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'cat_templates') THEN
    RAISE EXCEPTION 'Rename incomplete: old cat_templates table still exists';
  END IF;
  RAISE NOTICE 'SUCCESS: Tables renamed - cat_blocks → m_cat_blocks, cat_templates → m_cat_templates';
END $$;
