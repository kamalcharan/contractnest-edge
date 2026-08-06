-- ============================================================
-- BUSINESS MODEL V3 — 011 : Notification Channels LOV (Vikuna only)
-- ============================================================
-- Owner request 2026-08-05: the list of notification channels should be
-- maintained as an LOV under /settings/lov in the Vikuna (admin) tenant,
-- not hardcoded.
--
-- Seeds ONLY the platform tenant (t_tenants.is_admin = true). Ordinary
-- tenants do not get this category — they consume channels, they do not
-- define them.
--
-- CRITICAL: sub_cat_name values are the lowercase channel KEYS and must
-- match exactly:
--     t_bm_credit_balance.channel
--     t_bm_topup_pack.channel            (added in migration 010)
--     t_tenant_context.credit_grant_rates JSONB keys
--     t_tenant_context.credits_<channel> columns
-- Display casing lives in display_name. Changing a sub_cat_name silently
-- detaches a channel from its credit pool.
--
-- Currently ACTIVE channels: whatsapp, email.
-- Seeded but inactive: sms, inapp (is_active = false; flip when launched).
--
-- Idempotent: guarded by NOT EXISTS on both category and values.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. Create the category for the admin tenant
-- ------------------------------------------------------------
INSERT INTO t_category_master (
    category_name, display_name, is_active, description,
    order_sequence, tenant_id, is_live
)
SELECT
    'notification_channels',
    'Notification Channels',
    true,
    'Channels through which notifications are sent. Each channel has its own '
    'per-tenant credit pool. Keys must match t_bm_credit_balance.channel.',
    90,
    t.id,
    true
FROM t_tenants t
WHERE t.is_admin = true
  AND NOT EXISTS (
      SELECT 1 FROM t_category_master cm
      WHERE cm.tenant_id = t.id
        AND lower(cm.category_name) = 'notification_channels'
        AND cm.is_live = true
  );

-- ------------------------------------------------------------
-- 2. Insert the channel values
-- ------------------------------------------------------------
WITH admin_category AS (
    SELECT cm.id AS category_id, cm.tenant_id
    FROM t_category_master cm
    JOIN t_tenants t ON t.id = cm.tenant_id AND t.is_admin = true
    WHERE lower(cm.category_name) = 'notification_channels'
      AND cm.is_live = true
),
seed(sub_cat_name, display_name, hexcolor, icon_name, sequence_no, is_active, tool_tip) AS (
    VALUES
        ('whatsapp', 'WhatsApp', '#10B981', 'message-circle', 1, true,
         'WhatsApp notifications via MSG91. Active.'),
        ('email',    'Email',    '#3B82F6', 'mail',           2, true,
         'Email notifications. Active.'),
        ('sms',      'SMS',      '#F59E0B', 'smartphone',     3, false,
         'SMS notifications via MSG91. Not yet activated.'),
        ('inapp',    'In-App',   '#8B5CF6', 'bell',           4, false,
         'In-app notifications. Not yet activated.')
)
INSERT INTO t_category_details (
    sub_cat_name, display_name, category_id, hexcolor, icon_name,
    is_active, sequence_no, description, tenant_id, is_deletable,
    tool_tip, is_live
)
SELECT
    s.sub_cat_name, s.display_name, ac.category_id, s.hexcolor, s.icon_name,
    s.is_active, s.sequence_no, s.tool_tip, ac.tenant_id,
    false,          -- is_deletable: deleting a channel would orphan its credit pool
    s.tool_tip,
    true
FROM admin_category ac
CROSS JOIN seed s
WHERE NOT EXISTS (
    SELECT 1 FROM t_category_details cd
    WHERE cd.category_id = ac.category_id
      AND lower(cd.sub_cat_name) = s.sub_cat_name
);

COMMIT;

-- ============================================================
-- POST-APPLY VERIFICATION
-- ============================================================
-- SELECT cd.sub_cat_name, cd.display_name, cd.is_active, cd.sequence_no
--   FROM t_category_details cd
--   JOIN t_category_master cm ON cm.id = cd.category_id
--   JOIN t_tenants t ON t.id = cm.tenant_id AND t.is_admin = true
--  WHERE cm.category_name = 'notification_channels'
--  ORDER BY cd.sequence_no;
--
-- Expect exactly 4 rows: whatsapp/WhatsApp/t, email/Email/t,
--                        sms/SMS/f, inapp/In-App/f
--
-- Visible in the app at /settings/lov while signed in as the Vikuna tenant.
-- ============================================================
