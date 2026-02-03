-- ============================================================================
-- Admin Tenant Management RPC Functions
-- Purpose: Provide admin dashboard with real tenant list + platform stats
-- ============================================================================

-- ============================================================================
-- 1. GET ADMIN PLATFORM STATS
-- Returns aggregated stats for the admin subscription management dashboard
-- ============================================================================
CREATE OR REPLACE FUNCTION get_admin_platform_stats()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result jsonb;
  v_by_status jsonb;
  v_by_subscription jsonb;
  v_by_tenant_type jsonb;
  v_by_industry jsonb;
  v_total integer;
  v_active integer;
  v_trial integer;
  v_expiring_soon integer;
  v_churned_this_month integer;
  v_new_this_month integer;
BEGIN
  -- Total tenants (exclude system/admin tenants if needed)
  SELECT COUNT(*) INTO v_total FROM t_tenants;

  -- Active tenants
  SELECT COUNT(*) INTO v_active
  FROM t_tenants t
  WHERE t.status = 'active';

  -- Trial tenants (subscription in trial)
  SELECT COUNT(DISTINCT ts.tenant_id) INTO v_trial
  FROM t_bm_tenant_subscription ts
  WHERE ts.status = 'trial';

  -- Expiring soon (trial ending in 7 days)
  SELECT COUNT(DISTINCT ts.tenant_id) INTO v_expiring_soon
  FROM t_bm_tenant_subscription ts
  WHERE ts.status = 'trial'
    AND ts.trial_ends IS NOT NULL
    AND ts.trial_ends <= (NOW() + INTERVAL '7 days')
    AND ts.trial_ends > NOW();

  -- Churned this month (status changed to inactive/cancelled this month)
  SELECT COUNT(*) INTO v_churned_this_month
  FROM t_tenants t
  WHERE t.status IN ('inactive', 'closed')
    AND t.updated_at >= DATE_TRUNC('month', NOW());

  -- New this month
  SELECT COUNT(*) INTO v_new_this_month
  FROM t_tenants t
  WHERE t.created_at >= DATE_TRUNC('month', NOW());

  -- By tenant status
  SELECT jsonb_object_agg(
    COALESCE(status, 'unknown'),
    cnt
  ) INTO v_by_status
  FROM (
    SELECT status, COUNT(*) as cnt
    FROM t_tenants
    GROUP BY status
  ) sub;

  -- By subscription status
  SELECT COALESCE(jsonb_object_agg(sub_status, cnt), '{}'::jsonb) INTO v_by_subscription
  FROM (
    SELECT ts.status as sub_status, COUNT(DISTINCT ts.tenant_id) as cnt
    FROM t_bm_tenant_subscription ts
    GROUP BY ts.status
  ) sub;

  -- By tenant type (based on contacts - buyers vs sellers)
  SELECT jsonb_build_object(
    'buyers', COALESCE((
      SELECT COUNT(DISTINCT c.tenant_id)
      FROM t_contacts c
      WHERE c.type = 'corporate'
        AND EXISTS (SELECT 1 FROM t_contacts c2 WHERE c2.tenant_id = c.tenant_id AND c2.classifications::text LIKE '%buyer%')
    ), 0),
    'sellers', COALESCE((
      SELECT COUNT(DISTINCT c.tenant_id)
      FROM t_contacts c
      WHERE c.type = 'corporate'
        AND EXISTS (SELECT 1 FROM t_contacts c2 WHERE c2.tenant_id = c.tenant_id AND c2.classifications::text LIKE '%seller%')
    ), 0),
    'mixed', 0,
    'unknown', 0
  ) INTO v_by_tenant_type;

  -- By industry
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'industry_id', tp.industry_id,
      'industry_name', COALESCE(tp.industry_id, 'Unknown'),
      'count', cnt
    )
  ), '[]'::jsonb) INTO v_by_industry
  FROM (
    SELECT tp.industry_id, COUNT(*) as cnt
    FROM t_tenant_profiles tp
    WHERE tp.industry_id IS NOT NULL
    GROUP BY tp.industry_id
    ORDER BY cnt DESC
    LIMIT 10
  ) tp;

  -- Build result
  v_result := jsonb_build_object(
    'total_tenants', v_total,
    'active_tenants', v_active,
    'trial_tenants', v_trial,
    'expiring_soon', v_expiring_soon,
    'churned_this_month', v_churned_this_month,
    'new_this_month', v_new_this_month,
    'by_status', COALESCE(v_by_status, '{}'::jsonb),
    'by_subscription', v_by_subscription,
    'by_tenant_type', v_by_tenant_type,
    'by_industry', v_by_industry
  );

  RETURN v_result;
END;
$$;

-- ============================================================================
-- 2. GET ADMIN TENANT LIST
-- Returns paginated list of tenants with profile, subscription, and stats
-- ============================================================================
CREATE OR REPLACE FUNCTION get_admin_tenant_list(
  p_page integer DEFAULT 1,
  p_limit integer DEFAULT 20,
  p_status text DEFAULT NULL,
  p_subscription_status text DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_sort_by text DEFAULT 'created_at',
  p_sort_direction text DEFAULT 'desc'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_offset integer;
  v_total integer;
  v_tenants jsonb;
BEGIN
  v_offset := (p_page - 1) * p_limit;

  -- Count total matching tenants
  SELECT COUNT(*) INTO v_total
  FROM t_tenants t
  WHERE (p_status IS NULL OR t.status = p_status)
    AND (p_search IS NULL OR t.name ILIKE '%' || p_search || '%');

  -- Get tenant list with all metadata
  SELECT COALESCE(jsonb_agg(tenant_row), '[]'::jsonb) INTO v_tenants
  FROM (
    SELECT jsonb_build_object(
      'id', t.id,
      'name', t.name,
      'workspace_code', t.workspace_code,
      'status', t.status,
      'is_admin', COALESCE(t.is_admin, false),
      'created_at', t.created_at,
      'profile', CASE
        WHEN tp.id IS NOT NULL THEN jsonb_build_object(
          'business_name', tp.business_name,
          'business_email', tp.business_email,
          'logo_url', tp.logo_url,
          'industry_id', tp.industry_id,
          'industry_name', tp.industry_id,
          'city', tp.city
        )
        ELSE NULL
      END,
      'subscription', CASE
        WHEN ts.subscription_id IS NOT NULL THEN jsonb_build_object(
          'status', ts.status,
          'product_code', ts.product_code,
          'billing_cycle', ts.billing_cycle,
          'trial_end_date', ts.trial_ends,
          'next_billing_date', ts.next_billing_date,
          'days_until_expiry', CASE
            WHEN ts.trial_ends IS NOT NULL AND ts.trial_ends > NOW()
            THEN EXTRACT(DAY FROM ts.trial_ends - NOW())::integer
            ELSE NULL
          END
        )
        ELSE NULL
      END,
      'stats', jsonb_build_object(
        'total_users', COALESCE((
          SELECT COUNT(*) FROM t_user_tenants ut
          WHERE ut.tenant_id = t.id AND ut.status = 'active'
        ), 0),
        'total_contacts', COALESCE((
          SELECT COUNT(*) FROM t_contacts c
          WHERE c.tenant_id = t.id AND c.is_live = true
        ), 0),
        'total_contracts', COALESCE((
          SELECT COUNT(*) FROM t_contracts ct
          WHERE ct.tenant_id = t.id AND ct.is_live = true AND ct.is_active = true
        ), 0),
        'storage_used_mb', COALESCE(t.storage_consumed, 0),
        'storage_limit_mb', COALESCE(t.storage_quota, 40),
        'tenant_type', 'mixed'
      )
    ) as tenant_row
    FROM t_tenants t
    LEFT JOIN t_tenant_profiles tp ON tp.tenant_id = t.id
    LEFT JOIN LATERAL (
      SELECT * FROM t_bm_tenant_subscription sub
      WHERE sub.tenant_id = t.id
      ORDER BY sub.created_at DESC
      LIMIT 1
    ) ts ON true
    WHERE (p_status IS NULL OR t.status = p_status)
      AND (p_search IS NULL OR t.name ILIKE '%' || p_search || '%')
      AND (p_subscription_status IS NULL OR ts.status = p_subscription_status)
    ORDER BY
      CASE WHEN p_sort_by = 'name' AND p_sort_direction = 'asc' THEN t.name END ASC,
      CASE WHEN p_sort_by = 'name' AND p_sort_direction = 'desc' THEN t.name END DESC,
      CASE WHEN p_sort_by = 'created_at' AND p_sort_direction = 'asc' THEN t.created_at END ASC,
      CASE WHEN p_sort_by = 'created_at' AND p_sort_direction = 'desc' THEN t.created_at END DESC,
      CASE WHEN p_sort_by = 'status' AND p_sort_direction = 'asc' THEN t.status END ASC,
      CASE WHEN p_sort_by = 'status' AND p_sort_direction = 'desc' THEN t.status END DESC,
      t.created_at DESC
    LIMIT p_limit
    OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object(
    'tenants', v_tenants,
    'pagination', jsonb_build_object(
      'current_page', p_page,
      'total_pages', CEIL(v_total::float / p_limit)::integer,
      'total_records', v_total,
      'limit', p_limit,
      'has_next', (v_offset + p_limit) < v_total,
      'has_prev', p_page > 1
    )
  );
END;
$$;
