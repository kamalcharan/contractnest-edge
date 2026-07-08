-- ============================================================================
-- 016 — get_vani_briefing v2 (owner feedback round, 2026-07-08)
-- ============================================================================
-- Feedback: the scanner's first pass auto-requested 21 appointments for the
-- overdue-event backlog in one cron run → the Briefing feed showed a barrage
-- of identical "Appointment requested" rows with no context, drowning
-- everything else.
--
-- Changes vs 015's version (function fully replaced):
--   1. Appointment feed entries join t_contract_events → title carries the
--      block name, detail carries the service-due date.
--   2. Per-kind cap in the feed: each source contributes at most 8 newest
--      rows before the merged ORDER BY..LIMIT 20 — a burst of one kind can
--      no longer flood the feed.
--   3. "Needs you" appointment items include block_name + event_date so the
--      UI can label them meaningfully.
-- ============================================================================

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
          'created_at', a.created_at,
          'block_name', a.block_name, 'event_date', a.event_date))
        FROM (
          SELECT ap.*, e.block_name, e.scheduled_date AS event_date
          FROM t_appointments ap
          LEFT JOIN t_contract_events e ON e.id = ap.event_id
          WHERE ap.tenant_id = p_tenant_id AND ap.is_live = p_is_live AND ap.is_active = true
            AND ap.status = 'requested'
          ORDER BY ap.created_at ASC LIMIT 5
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

  -- "What VaNi did": merged feed, max 8 newest per kind so one burst
  -- (e.g. the scanner's first backlog pass) can't drown the others
  WITH feed AS (
    SELECT at, obj FROM (
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
      ORDER BY created_at DESC LIMIT 8
    ) r
    UNION ALL
    SELECT at, obj FROM (
      SELECT created_at AS at, jsonb_build_object(
        'kind', 'invoice_drafted',
        'title', 'Draft invoice ' || COALESCE(invoice_number, ''),
        'detail', COALESCE(total_amount::text, ''),
        'id', id, 'contract_id', contract_id, 'at', created_at) AS obj
      FROM t_invoices
      WHERE tenant_id = p_tenant_id AND is_live = p_is_live AND is_active = true
        AND status = 'draft' AND contract_event_id IS NOT NULL
        AND created_at > v_since
      ORDER BY created_at DESC LIMIT 8
    ) i
    UNION ALL
    SELECT at, obj FROM (
      SELECT a.created_at AS at, jsonb_build_object(
        'kind', 'appointment_requested',
        'title', 'Appointment requested' || COALESCE(' · ' || e.block_name, ''),
        'detail', CASE
                    WHEN e.scheduled_date IS NOT NULL
                      THEN 'service due ' || to_char(e.scheduled_date, 'DD Mon YYYY')
                    ELSE COALESCE(a.assigned_to_name, '')
                  END,
        'id', a.id, 'contract_id', a.contract_id, 'at', a.created_at) AS obj
      FROM t_appointments a
      LEFT JOIN t_contract_events e ON e.id = a.event_id
      WHERE a.tenant_id = p_tenant_id AND a.is_live = p_is_live AND a.is_active = true
        AND a.created_at > v_since
      ORDER BY a.created_at DESC LIMIT 8
    ) ap
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
