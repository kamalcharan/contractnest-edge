-- ============================================================
-- BBB FOUNDATION 002 — One-time LOV backfill for existing tenants
-- New tenants get Roles + Tags seeded at creation (tenants edge fn).
-- This backfills EXISTING tenants that have no such data:
--   1. Creates the Roles / Tags category when the tenant lacks it.
--   2. Inserts the default values ONLY into categories that have
--      zero value rows — a tenant with any values of its own
--      (e.g. vikuna's BBB/VIP/Thought Leader tags) is left untouched.
-- Idempotent: re-running inserts nothing new.
-- Does NOT touch role assignments (t_user_tenant_roles).
-- ============================================================

-- 1. Create missing Roles / Tags categories per tenant ---------------
WITH seed_categories(category_name, display_name, description) AS (
  VALUES
    ('Roles', 'Roles', 'User roles in the system'),
    ('Tags',  'Tags',  'Labels for categorizing contacts')
),
inserted AS (
  INSERT INTO t_category_master (category_name, display_name, is_active, description, tenant_id)
  SELECT s.category_name, s.display_name, true, s.description, t.id
  FROM t_tenants t
  CROSS JOIN seed_categories s
  WHERE NOT EXISTS (
    SELECT 1 FROM t_category_master cm
    WHERE cm.tenant_id = t.id
      AND lower(cm.category_name) = lower(s.category_name)
  )
  RETURNING id
)
SELECT count(*) AS categories_created FROM inserted;

-- 2. Insert default values into empty Roles / Tags categories --------
WITH seed_values(cat, sub_cat_name, display_name, hexcolor, seq, is_deletable) AS (
  VALUES
    ('Roles', 'Owner',  'Owner',  '#32e275', 1, false),
    ('Roles', 'Admin',  'Admin',  '#40E0D0', 2, true),
    ('Roles', 'Member', 'Member', '#3B82F6', 3, true),
    ('Tags',  'Lead',   'Lead',   '#F59E0B', 1, true),
    ('Tags',  'Guest',  'Guest',  '#8B5CF6', 2, true),
    ('Tags',  'VIP',    'VIP',    '#EC4899', 3, true)
),
inserted AS (
  INSERT INTO t_category_details
    (sub_cat_name, display_name, category_id, hexcolor, is_active, sequence_no, tenant_id, is_deletable)
  SELECT v.sub_cat_name, v.display_name, cm.id, v.hexcolor, true, v.seq, cm.tenant_id, v.is_deletable
  FROM t_category_master cm
  JOIN seed_values v ON lower(cm.category_name) = lower(v.cat)
  WHERE NOT EXISTS (
    SELECT 1 FROM t_category_details cd
    WHERE cd.category_id = cm.id
  )
  RETURNING id
)
SELECT count(*) AS values_created FROM inserted;

-- 3. Verification ----------------------------------------------------
SELECT
  (SELECT count(*) FROM t_tenants) AS tenants,
  (SELECT count(DISTINCT tenant_id) FROM t_category_master WHERE lower(category_name) = 'roles') AS tenants_with_roles,
  (SELECT count(DISTINCT tenant_id) FROM t_category_master WHERE lower(category_name) = 'tags')  AS tenants_with_tags;
