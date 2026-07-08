-- ============================================================================
-- 015 — VaNi trial + Briefing feed (vani-trial-and-briefing batch)
-- ============================================================================
-- 1. Seeds the VaNi product plan (t_bm_pricing_plan / t_bm_plan_version) so
--    trial subscriptions have a valid version_id to reference.
-- 2. One-VaNi-subscription-per-tenant guard (partial unique index) — the
--    race-condition guard for double-clicked trial CTAs.
-- 3. RPC start_vani_trial(tenant)  — idempotent 7-day trial creation.
-- 4. RPC get_vani_briefing(tenant) — tenant-scoped aggregation feeding the
--    VaNi → Briefing page (header counts, "Needs you", "What VaNi did").
--
-- Verified against live schema 2026-07-07:
--   t_bm_tenant_subscription(status, trial_start_date, trial_ends, product_code)
--   n_jtd.source_type_code IN ('payment_due','service_reminder','appointment_reminder')
--   t_contract_events.event_type IN ('billing','service'), status IN ('scheduled','due','overdue')
--   t_invoices.status IN ('draft','unpaid','partially_paid','paid')
--   t_appointments.status ('requested', ...) ; ticket link = t_service_ticket_events(event_id)
--
-- Grant convention per 007: SECURITY DEFINER + search_path=public + service_role only.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. REPAIR pre-existing broken trigger (discovered by dry-run 2026-07-07)
--    trg_subscription_update_context (AFTER INSERT OR UPDATE on
--    t_bm_tenant_subscription) was written against an older schema draft:
--    it references NEW.plan_version_id / NEW.id / NEW.current_period_start /
--    NEW.current_period_end / NEW.trial_end_date — none exist on the live
--    table (actual: version_id / subscription_id / start_date / renewal_date /
--    trial_ends). Result: EVERY insert/update on t_bm_tenant_subscription
--    fails (t_tenant_context has 0 rows — the sync has never run).
--    Rewritten below against the real live columns; behavior preserved.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_update_context_on_subscription()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_product_code TEXT;
    v_plan_name TEXT;
    v_flags RECORD;
BEGIN
    v_product_code := COALESCE(NEW.product_code, 'contractnest');

    -- Plan name lives on t_bm_pricing_plan (t_bm_plan_version has no name)
    SELECT p.name INTO v_plan_name
    FROM t_bm_plan_version v
    JOIN t_bm_pricing_plan p ON p.plan_id = v.plan_id
    WHERE v.version_id = NEW.version_id;

    INSERT INTO t_tenant_context (
        product_code, tenant_id, subscription_id, subscription_status,
        plan_name, billing_cycle, period_start, period_end,
        trial_end_date, grace_end_date, next_billing_date,
        flag_can_access, updated_at
    )
    VALUES (
        v_product_code,
        NEW.tenant_id,
        NEW.subscription_id,
        NEW.status,
        v_plan_name,
        NEW.billing_cycle,
        NEW.start_date::date,
        NEW.renewal_date::date,
        NEW.trial_ends::date,
        NEW.grace_end_date::date,
        NEW.next_billing_date,
        NEW.status IN ('active', 'trial', 'grace_period'),
        NOW()
    )
    ON CONFLICT (product_code, tenant_id)
    DO UPDATE SET
        subscription_id = EXCLUDED.subscription_id,
        subscription_status = EXCLUDED.subscription_status,
        plan_name = EXCLUDED.plan_name,
        billing_cycle = EXCLUDED.billing_cycle,
        period_start = EXCLUDED.period_start,
        period_end = EXCLUDED.period_end,
        trial_end_date = EXCLUDED.trial_end_date,
        grace_end_date = EXCLUDED.grace_end_date,
        next_billing_date = EXCLUDED.next_billing_date,
        flag_can_access = EXCLUDED.flag_can_access,
        updated_at = NOW();

    SELECT * INTO v_flags
    FROM fn_recalc_credit_flags(
        COALESCE((SELECT credits_whatsapp FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id), 0),
        COALESCE((SELECT credits_sms FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id), 0),
        COALESCE((SELECT credits_email FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id), 0),
        COALESCE((SELECT credits_pooled FROM t_tenant_context WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id), 0),
        NEW.status
    );

    UPDATE t_tenant_context SET
        flag_can_send_whatsapp = v_flags.can_send_whatsapp,
        flag_can_send_sms = v_flags.can_send_sms,
        flag_can_send_email = v_flags.can_send_email,
        flag_credits_low = v_flags.credits_low
    WHERE product_code = v_product_code AND tenant_id = NEW.tenant_id;

    RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------------------
-- 1. Seed VaNi plan + active version (deterministic ids, idempotent)
-- ----------------------------------------------------------------------------
INSERT INTO t_bm_pricing_plan (
  plan_id, name, description, plan_type, trial_duration, is_visible,
  is_archived, default_currency_code, supported_currencies, product_code
) VALUES (
  'b0000002-0000-0000-0000-000000000002',
  'VaNi',
  'VaNi virtual employee — autopilot layer over ContractNest operations (trial: 7 days)',
  'Per User',        -- plan_type CHECK allows only 'Per User'/'Per Contract'; VaNi bills flat (units=1)
  7,
  false,               -- not shown in public pricing UI yet
  false,
  'INR',
  '["INR"]'::jsonb,
  'contractnest'     -- FK to m_products (whole products only); VaNi is a ContractNest
                     -- add-on. Subscription rows carry product_code='vani' (no FK there).
)
ON CONFLICT (plan_id) DO NOTHING;

INSERT INTO t_bm_plan_version (
  version_id, plan_id, version_number, is_active, effective_date,
  changelog, created_by, tiers, features, notifications, billing_config
) VALUES (
  'c0000002-0000-0000-0000-000000000002',
  'b0000002-0000-0000-0000-000000000002',
  'v1',
  true,
  CURRENT_DATE,
  'Initial VaNi plan version — base subscription, credits metered separately',
  'system',
  '[{"tier": 1, "name": "Base", "base_price": 5000, "currency": "INR", "billing_cycle": "monthly"}]'::jsonb,
  '[]'::jsonb,
  '[]'::jsonb,
  '{"base_price": 5000, "currency": "INR", "billing_cycle": "monthly", "product_code": "vani"}'::jsonb
)
ON CONFLICT (version_id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 2. One VaNi subscription row per tenant (also the ON CONFLICT target)
-- ----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_bm_tenant_subscription_vani
  ON t_bm_tenant_subscription (tenant_id)
  WHERE product_code = 'vani';

-- ----------------------------------------------------------------------------
-- 3. start_vani_trial — idempotent trial creation
--    Second call (double-click, retry, expired trial) returns the existing
--    row with started_now=false instead of erroring or extending the trial.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION start_vani_trial(p_tenant_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_version_id UUID := 'c0000002-0000-0000-0000-000000000002';
  v_tier JSONB;
  v_row t_bm_tenant_subscription%ROWTYPE;
  v_started_now BOOLEAN := false;
BEGIN
  IF p_tenant_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TENANT_REQUIRED');
  END IF;

  SELECT COALESCE(tiers -> 0, '{}'::jsonb) INTO v_tier
  FROM t_bm_plan_version
  WHERE version_id = v_version_id AND is_active = true;

  IF v_tier IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'VANI_PLAN_MISSING');
  END IF;

  INSERT INTO t_bm_tenant_subscription (
    tenant_id, version_id, status, currency_code, units, current_tier,
    amount_per_billing, billing_cycle, start_date, renewal_date,
    trial_start_date, trial_ends, product_code, metadata
  ) VALUES (
    p_tenant_id, v_version_id, 'trial', 'INR', 1, v_tier,
    5000, 'monthly', now(), now() + interval '7 days',
    now(), now() + interval '7 days', 'vani',
    jsonb_build_object('source', 'vani_landing_trial')
  )
  ON CONFLICT (tenant_id) WHERE product_code = 'vani' DO NOTHING;

  v_started_now := FOUND;

  SELECT * INTO v_row
  FROM t_bm_tenant_subscription
  WHERE tenant_id = p_tenant_id AND product_code = 'vani'
  LIMIT 1;

  IF v_row.subscription_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRIAL_CREATE_FAILED');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'started_now', v_started_now,
    'status', v_row.status,
    'trial_start_date', v_row.trial_start_date,
    'trial_ends', v_row.trial_ends,
    'trial_active', (v_row.status IN ('active','trialing')
                     OR (v_row.status = 'trial' AND v_row.trial_ends > now()))
  );
END;
$$;

REVOKE ALL ON FUNCTION start_vani_trial(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION start_vani_trial(UUID) TO service_role;

-- ----------------------------------------------------------------------------
-- 4. get_vani_briefing — everything the Briefing page renders, one call
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_vani_briefing(
  p_tenant_id UUID,
  p_is_live BOOLEAN DEFAULT true,
  p_feed_days INTEGER DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_since TIMESTAMPTZ := now() - make_interval(days => GREATEST(COALESCE(p_feed_days, 7), 1));
  v_header JSONB;
  v_needs JSONB;
  v_feed JSONB;
BEGIN
  IF p_tenant_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TENANT_REQUIRED');
  END IF;

  -- Header: what ran automatically (24h / 7d)
  SELECT jsonb_build_object(
    'reminders_24h', COUNT(*) FILTER (WHERE created_at > now() - interval '24 hours'),
    'reminders_7d',  COUNT(*)
  ) INTO v_header
  FROM n_jtd
  WHERE tenant_id = p_tenant_id
    AND is_live = p_is_live
    AND source_type_code IN ('payment_due', 'service_reminder', 'appointment_reminder')
    AND created_at > now() - interval '7 days';

  v_header := v_header || jsonb_build_object(
    'invoices_drafted_7d', (
      SELECT COUNT(*) FROM t_invoices
      WHERE tenant_id = p_tenant_id AND is_live = p_is_live AND is_active = true
        AND status = 'draft' AND created_at > now() - interval '7 days'
    ),
    'appointments_requested_7d', (
      SELECT COUNT(*) FROM t_appointments
      WHERE tenant_id = p_tenant_id AND is_live = p_is_live AND is_active = true
        AND created_at > now() - interval '7 days'
    )
  );

  -- "Needs you": each group = count + top items, deep-linked by the UI
  v_needs := jsonb_build_object(
    'draft_invoices', jsonb_build_object(
      'count', (
        SELECT COUNT(*) FROM t_invoices
        WHERE tenant_id = p_tenant_id AND is_live = p_is_live AND is_active = true
          AND status = 'draft'
      ),
      'items', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', i.id, 'invoice_number', i.invoice_number,
          'total_amount', i.total_amount, 'due_date', i.due_date,
          'contract_id', i.contract_id))
        FROM (
          SELECT * FROM t_invoices
          WHERE tenant_id = p_tenant_id AND is_live = p_is_live AND is_active = true
            AND status = 'draft'
          ORDER BY created_at DESC LIMIT 5
        ) i), '[]'::jsonb)
    ),
    'overdue_invoices', jsonb_build_object(
      'count', (
        SELECT COUNT(*) FROM t_invoices
        WHERE tenant_id = p_tenant_id AND is_live = p_is_live AND is_active = true
          AND status IN ('unpaid', 'partially_paid')
          AND balance > 0 AND due_date < CURRENT_DATE
      ),
      'items', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', i.id, 'invoice_number', i.invoice_number,
          'balance', i.balance, 'due_date', i.due_date,
          'days_overdue', (CURRENT_DATE - i.due_date),
          'contract_id', i.contract_id))
        FROM (
          SELECT * FROM t_invoices
          WHERE tenant_id = p_tenant_id AND is_live = p_is_live AND is_active = true
            AND status IN ('unpaid', 'partially_paid')
            AND balance > 0 AND due_date < CURRENT_DATE
          ORDER BY balance DESC LIMIT 5
        ) i), '[]'::jsonb)
    ),
    'appointments_requested', jsonb_build_object(
      'count', (
        SELECT COUNT(*) FROM t_appointments
        WHERE tenant_id = p_tenant_id AND is_live = p_is_live AND is_active = true
          AND status = 'requested'
      ),
      'items', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', a.id, 'contract_id', a.contract_id, 'event_id', a.event_id,
          'scheduled_at', a.scheduled_at, 'assigned_to_name', a.assigned_to_name,
          'created_at', a.created_at))
        FROM (
          SELECT * FROM t_appointments
          WHERE tenant_id = p_tenant_id AND is_live = p_is_live AND is_active = true
            AND status = 'requested'
          ORDER BY created_at ASC LIMIT 5
        ) a), '[]'::jsonb)
    ),
    'unticketed_service_events', jsonb_build_object(
      'count', (
        SELECT COUNT(*) FROM t_contract_events e
        WHERE e.tenant_id = p_tenant_id AND e.is_live = p_is_live AND e.is_active = true
          AND e.event_type = 'service' AND e.status IN ('due', 'overdue')
          AND NOT EXISTS (SELECT 1 FROM t_service_ticket_events te WHERE te.event_id = e.id)
      ),
      'items', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', e.id, 'block_name', e.block_name,
          'scheduled_date', e.scheduled_date, 'status', e.status,
          'contract_id', e.contract_id))
        FROM (
          SELECT * FROM t_contract_events e
          WHERE e.tenant_id = p_tenant_id AND e.is_live = p_is_live AND e.is_active = true
            AND e.event_type = 'service' AND e.status IN ('due', 'overdue')
            AND NOT EXISTS (SELECT 1 FROM t_service_ticket_events te WHERE te.event_id = e.id)
          ORDER BY e.scheduled_date ASC LIMIT 5
        ) e), '[]'::jsonb)
    )
  );

  -- "What VaNi did": union feed of the scanner's real automatic actions
  WITH feed AS (
    SELECT created_at AS at, jsonb_build_object(
      'kind', 'reminder',
      'title', CASE source_type_code
                 WHEN 'payment_due' THEN 'Payment reminder sent'
                 WHEN 'service_reminder' THEN 'Service reminder sent'
                 ELSE 'Appointment request sent' END,
      'detail', COALESCE(recipient_name, recipient_contact, ''),
      'channel', channel_code, 'status', status_code,
      'ref', source_ref, 'at', created_at) AS obj
    FROM n_jtd
    WHERE tenant_id = p_tenant_id AND is_live = p_is_live
      AND source_type_code IN ('payment_due', 'service_reminder', 'appointment_reminder')
      AND created_at > v_since
    UNION ALL
    SELECT created_at, jsonb_build_object(
      'kind', 'invoice_drafted',
      'title', 'Draft invoice ' || COALESCE(invoice_number, ''),
      'detail', COALESCE(total_amount::text, ''),
      'id', id, 'contract_id', contract_id, 'at', created_at)
    FROM t_invoices
    WHERE tenant_id = p_tenant_id AND is_live = p_is_live AND is_active = true
      AND status = 'draft' AND contract_event_id IS NOT NULL
      AND created_at > v_since
    UNION ALL
    SELECT created_at, jsonb_build_object(
      'kind', 'appointment_requested',
      'title', 'Appointment requested',
      'detail', COALESCE(assigned_to_name, ''),
      'id', id, 'contract_id', contract_id, 'at', created_at)
    FROM t_appointments
    WHERE tenant_id = p_tenant_id AND is_live = p_is_live AND is_active = true
      AND created_at > v_since
  )
  SELECT COALESCE(jsonb_agg(obj ORDER BY at DESC), '[]'::jsonb) INTO v_feed
  FROM (SELECT at, obj FROM feed ORDER BY at DESC LIMIT 20) t;

  RETURN jsonb_build_object(
    'success', true,
    'header', v_header,
    'needs_you', v_needs,
    'feed', v_feed,
    'generated_at', now()
  );
END;
$$;

REVOKE ALL ON FUNCTION get_vani_briefing(UUID, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_vani_briefing(UUID, BOOLEAN, INTEGER) TO service_role;
