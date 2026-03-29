-- 004_add_versioning_columns.sql
-- Adds copy-on-write versioning support to t_cat_templates
-- On edit: original row marked is_latest=false, new row inserted with incremented version

-- Add is_latest flag (true = current version shown in UI, false = historical/legacy)
ALTER TABLE t_cat_templates
  ADD COLUMN IF NOT EXISTS is_latest BOOLEAN NOT NULL DEFAULT true;

-- Add parent_template_id to link version chain back to the original template
-- All versions of the same template share the same parent_template_id
-- For the very first version, parent_template_id = id (self)
ALTER TABLE t_cat_templates
  ADD COLUMN IF NOT EXISTS parent_template_id UUID;

-- Backfill: set parent_template_id = id for all existing rows (they are all originals)
UPDATE t_cat_templates
  SET parent_template_id = id
  WHERE parent_template_id IS NULL;

-- Index for fast lookups: show only latest versions
CREATE INDEX IF NOT EXISTS idx_cat_templates_is_latest
  ON t_cat_templates (is_latest)
  WHERE is_latest = true;

-- Index for version chain lookups
CREATE INDEX IF NOT EXISTS idx_cat_templates_parent
  ON t_cat_templates (parent_template_id);

-- Composite index for common query: latest + active
CREATE INDEX IF NOT EXISTS idx_cat_templates_latest_active
  ON t_cat_templates (is_latest, is_active)
  WHERE is_latest = true AND is_active = true;

COMMENT ON COLUMN t_cat_templates.is_latest IS 'True for the current version, false for historical/legacy versions';
COMMENT ON COLUMN t_cat_templates.parent_template_id IS 'Links all versions of the same template. Points to the original template ID.';
