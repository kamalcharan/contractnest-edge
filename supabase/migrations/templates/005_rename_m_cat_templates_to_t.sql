-- 005_rename_m_cat_templates_to_t.sql
-- Rename m_cat_templates → t_cat_templates
-- These are transactional template records, not static master data.
-- The "t_" prefix aligns with the transactional naming convention.
--
-- Rollback:
--   ALTER TABLE t_cat_templates RENAME TO m_cat_templates;

-- Step 1: Rename table
ALTER TABLE IF EXISTS m_cat_templates RENAME TO t_cat_templates;

-- Step 2: Update self-referencing FK comment
COMMENT ON COLUMN t_cat_templates.copied_from_id IS 'Reference to source template when copied (self-FK to t_cat_templates.id)';

-- Step 3: Update table comment
COMMENT ON TABLE t_cat_templates IS 'Catalog templates - reusable contract template assemblies (renamed from m_cat_templates)';

-- Step 4: Verify rename
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 't_cat_templates') THEN
    RAISE EXCEPTION 'Rename failed: t_cat_templates table not found';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'm_cat_templates') THEN
    RAISE EXCEPTION 'Rename incomplete: old m_cat_templates table still exists';
  END IF;
  RAISE NOTICE 'SUCCESS: Table renamed - m_cat_templates → t_cat_templates';
END $$;
