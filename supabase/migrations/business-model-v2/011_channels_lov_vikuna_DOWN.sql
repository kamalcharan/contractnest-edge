-- ============================================================
-- BUSINESS MODEL V3 — 011 DOWN : remove Notification Channels LOV
-- ============================================================
-- Removes the seeded channel values and the category, for the admin
-- tenant only. Safe while nothing references the LOV.
--
-- Values were seeded is_deletable = false, so this is the supported way
-- to remove them.
-- ============================================================

BEGIN;

DELETE FROM t_category_details cd
USING t_category_master cm, t_tenants t
WHERE cd.category_id = cm.id
  AND cm.tenant_id = t.id
  AND t.is_admin = true
  AND lower(cm.category_name) = 'notification_channels'
  AND lower(cd.sub_cat_name) IN ('whatsapp','email','sms','inapp');

DELETE FROM t_category_master cm
USING t_tenants t
WHERE cm.tenant_id = t.id
  AND t.is_admin = true
  AND lower(cm.category_name) = 'notification_channels'
  AND NOT EXISTS (
      SELECT 1 FROM t_category_details cd WHERE cd.category_id = cm.id
  );

COMMIT;
