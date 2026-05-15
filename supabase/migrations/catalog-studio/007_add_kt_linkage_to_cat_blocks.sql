-- CATALOG STUDIO: Add KT Linkage Columns to m_cat_blocks
-- Phase 2 — Task 8
--
-- Adds two columns to m_cat_blocks:
--   resource_template_id  → FK to m_catalog_resource_templates, enables indexed queries
--                           across all blocks generated from the same KT
--   kt_checkpoint_ids     → array of checkpoint UUIDs that define the scope of
--                           work for a service block (e.g. Filter Cleaning,
--                           Coil Cleaning, Gas Pressure Check)
--
-- Note: knowledge_tree_ref JSONB (already present) stores origin context
-- { resource_template_id, variant_id } as write-once provenance.
-- These two new columns are NOT duplicates — they serve different purposes.

ALTER TABLE m_cat_blocks
  ADD COLUMN IF NOT EXISTS resource_template_id UUID
    REFERENCES m_catalog_resource_templates(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS kt_checkpoint_ids UUID[]
    DEFAULT NULL;

-- Index for: "show all catalog blocks generated from this KT"
-- Used by Onboarding Agent and Catalog Studio KT linkage queries
CREATE INDEX IF NOT EXISTS idx_cat_blocks_resource_template
  ON m_cat_blocks(resource_template_id)
  WHERE resource_template_id IS NOT NULL;

COMMENT ON COLUMN m_cat_blocks.resource_template_id IS
  'FK to m_catalog_resource_templates. Links block to the Knowledge Tree it was generated from. Enables indexed lookup of all blocks for a given KT.';

COMMENT ON COLUMN m_cat_blocks.kt_checkpoint_ids IS
  'Array of m_equipment_checkpoints UUIDs that define the scope of work for this service block. E.g. [Filter Cleaning, Coil Cleaning, Gas Pressure Check].';
