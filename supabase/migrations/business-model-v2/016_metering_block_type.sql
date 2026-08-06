-- ============================================================
-- BUSINESS MODEL V3 — 016 : Metering block type ("Credit Pack")
-- ============================================================
-- Sprint 1, Step 6.  APPLIED to production 2026-08-05.
--
-- Follows the Group Session precedent exactly. In cat_block_type, `session`
-- is the only other is_deletable = true row, and it exists ONLY to make the
-- picker card discoverable — the engine branches on config, never on the type
-- name. A Group Session is a service block with config.audience='group'; a
-- Credit Pack is a service block with config.metering.
--
-- SEEDED is_active = FALSE, DELIBERATELY.
--   m_category_details has NO tenant_id — it is platform-wide. And
--   mergeWithFallback() in the UI appends DB categories that are absent from
--   the fallback list. So an active row would surface a "Credit Pack" card to
--   EVERY tenant the moment this migration lands, while the admin-only UI gate
--   still needs building and deploying.
--
--   useBlockTypes.ts requests `?is_active=true`, so inactive = invisible
--   everywhere, with no exposure window.
--
-- TO ACTIVATE, once the UI gate below is deployed:
--   UPDATE m_category_details SET is_active = true
--    WHERE sub_cat_name = 'metering'
--      AND category_id = (SELECT id FROM m_category_master
--                          WHERE category_name = 'cat_block_type');
--
-- The UI gate (shipped alongside, in contractnest-ui):
--   types/catalogStudio.ts          BlockCategory gains `adminOnly?: boolean`
--   utils/catalog-studio/categories.ts
--                                   metering added to BLOCK_CATEGORIES and to
--                                   MVP_CATEGORY_OVERRIDES as adminOnly
--   hooks/queries/useBlockTypes.ts  useBlockCategories filters adminOnly types
--                                   unless currentTenant.is_admin
--
-- Resulting block_type_id: dc3d7169-6d1d-44f0-afab-83a23589d609
--
-- Idempotent.
-- ============================================================

INSERT INTO m_category_details (
    sub_cat_name, display_name, category_id, hexcolor, icon_name,
    is_active, sequence_no, description, is_deletable, tool_tip
)
SELECT
    'metering',
    'Credit Pack',
    cm.id,
    '#0EA5E9',
    'Wallet',
    false,
    9,
    'Platform metering block. Grants notification credits, sets limits, or '
    'toggles an add-on when a platform contract settles. Stored as a service '
    'block carrying config.metering.',
    true,
    'Admin only. Used to build ContractNest plan templates.'
FROM m_category_master cm
WHERE cm.category_name = 'cat_block_type'
  AND NOT EXISTS (
      SELECT 1 FROM m_category_details cd
      WHERE cd.category_id = cm.id AND lower(cd.sub_cat_name) = 'metering'
  );

-- ============================================================
-- VERIFICATION
-- ============================================================
-- SELECT cd.sub_cat_name, cd.display_name, cd.is_active, cd.is_deletable, cd.id
--   FROM m_category_master cm
--   JOIN m_category_details cd ON cd.category_id = cm.id
--  WHERE cm.category_name = 'cat_block_type'
--  ORDER BY cd.sequence_no;
--
-- Expect a 10th row: metering / Credit Pack / is_active = false / deletable = true
-- ============================================================

-- ============================================================
-- DOWN
-- ============================================================
-- DELETE FROM m_category_details cd
--  USING m_category_master cm
--  WHERE cd.category_id = cm.id
--    AND cm.category_name = 'cat_block_type'
--    AND cd.sub_cat_name = 'metering';
--
-- Safe only while no m_cat_blocks row references this block_type_id.
-- ============================================================
