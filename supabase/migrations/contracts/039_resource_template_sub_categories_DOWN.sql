-- Rollback: Remove sub_category column from m_catalog_resource_templates
ALTER TABLE m_catalog_resource_templates DROP COLUMN IF EXISTS sub_category;
