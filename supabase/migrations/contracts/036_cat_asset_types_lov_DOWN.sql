-- ============================================================================
-- ROLLBACK: 036_cat_asset_types_lov.sql
-- Removes cat_asset_types category and all its detail rows.
-- ============================================================================

-- Delete detail rows first (FK constraint)
DELETE FROM m_category_details
WHERE category_id IN (
    SELECT id FROM m_category_master WHERE category_name = 'cat_asset_types'
);

-- Delete the master category
DELETE FROM m_category_master WHERE category_name = 'cat_asset_types';
