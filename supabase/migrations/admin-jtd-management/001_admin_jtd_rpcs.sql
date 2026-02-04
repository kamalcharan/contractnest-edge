-- ============================================================================
-- Admin JTD Management RPC Functions — Release 1 (Observability)
-- Purpose: Give platform admin visibility into JTD queue, tenant usage,
--          event history, and worker health across ALL tenants.
-- Prereq:  jtd-framework migrations (001–003), admin-tenant-management
-- ============================================================================


-- ============================================================================
-- 1. GET JTD QUEUE METRICS (Admin)
-- Extends the existing jtd_queue_metrics() with DLQ stats, per-status
-- breakdown, and oldest stuck-message age — everything an admin needs
-- to decide "is the system healthy right now?"
-- ============================================================================
CREATE OR REPLACE FUNCTION get_admin_jtd_queue_metrics()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result           jsonb;
  v_queue_length     bigint;
  v_oldest_age_sec   int;
  v_newest_age_sec   int;
  v_dlq_length       bigint;
  v_dlq_oldest_sec   int;
  v_by_status        jsonb;
  v_by_event_type    jsonb;
  v_by_channel       jsonb;
  v_processing_count bigint;
  v_scheduled_due    bigint;
  v_failed_retryable bigint;
  v_no_credits_count bigint;
BEGIN
  -- ---- Main queue depth ----
  SELECT count(*) INTO v_queue_length
  FROM pgmq.q_jtd_queue;

  SELECT EXTRACT(EPOCH FROM (NOW() - MIN(enqueued_at)))::int INTO v_oldest_age_sec
  FROM pgmq.q_jtd_queue;

  SELECT EXTRACT(EPOCH FROM (NOW() - MAX(enqueued_at)))::int INTO v_newest_age_sec
  FROM pgmq.q_jtd_queue;

  -- ---- DLQ depth ----
  SELECT count(*) INTO v_dlq_length
  FROM pgmq.q_jtd_dlq;

  SELECT EXTRACT(EPOCH FROM (NOW() - MIN(enqueued_at)))::int INTO v_dlq_oldest_sec
  FROM pgmq.q_jtd_dlq;

  -- ---- JTD status distribution (all tenants, live only) ----
  SELECT COALESCE(jsonb_object_agg(status_code, cnt), '{}'::jsonb)
  INTO v_by_status
  FROM (
    SELECT status_code, count(*) AS cnt
    FROM n_jtd
    WHERE is_live = true
    GROUP BY status_code
  ) sub;

  -- ---- By event type (last 24 h) ----
  SELECT COALESCE(jsonb_object_agg(event_type_code, cnt), '{}'::jsonb)
  INTO v_by_event_type
  FROM (
    SELECT event_type_code, count(*) AS cnt
    FROM n_jtd
    WHERE is_live = true
      AND created_at >= NOW() - INTERVAL '24 hours'
    GROUP BY event_type_code
  ) sub;

  -- ---- By channel (last 24 h) ----
  SELECT COALESCE(jsonb_object_agg(COALESCE(channel_code, 'unset'), cnt), '{}'::jsonb)
  INTO v_by_channel
  FROM (
    SELECT channel_code, count(*) AS cnt
    FROM n_jtd
    WHERE is_live = true
      AND created_at >= NOW() - INTERVAL '24 hours'
    GROUP BY channel_code
  ) sub;

  -- ---- Actionable counts ----
  SELECT count(*) INTO v_processing_count
  FROM n_jtd
  WHERE status_code = 'processing' AND is_live = true;

  SELECT count(*) INTO v_scheduled_due
  FROM n_jtd
  WHERE status_code = 'scheduled'
    AND scheduled_at <= NOW()
    AND is_live = true;

  SELECT count(*) INTO v_failed_retryable
  FROM n_jtd
  WHERE status_code = 'failed'
    AND retry_count < max_retries
    AND is_live = true;

  SELECT count(*) INTO v_no_credits_count
  FROM n_jtd
  WHERE status_code = 'no_credits' AND is_live = true;

  -- ---- Assemble ----
  v_result := jsonb_build_object(
    'main_queue', jsonb_build_object(
      'length',          COALESCE(v_queue_length, 0),
      'oldest_age_sec',  v_oldest_age_sec,
      'newest_age_sec',  v_newest_age_sec
    ),
    'dlq', jsonb_build_object(
      'length',          COALESCE(v_dlq_length, 0),
      'oldest_age_sec',  v_dlq_oldest_sec
    ),
    'status_distribution',  v_by_status,
    'last_24h', jsonb_build_object(
      'by_event_type',   v_by_event_type,
      'by_channel',      v_by_channel
    ),
    'actionable', jsonb_build_object(
      'currently_processing', COALESCE(v_processing_count, 0),
      'scheduled_due',        COALESCE(v_scheduled_due, 0),
      'failed_retryable',     COALESCE(v_failed_retryable, 0),
      'no_credits_waiting',   COALESCE(v_no_credits_count, 0)
    ),
    'generated_at', NOW()
  );

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION get_admin_jtd_queue_metrics IS
  'Admin: queue depth, DLQ, status distribution, actionable counts';


-- ============================================================================
-- 2. GET ADMIN JTD TENANT STATS
-- Per-tenant JTD usage: volume, channel mix, success/failure rates, costs.
-- Paginated + filterable so it scales with tenant count.
-- ============================================================================
CREATE OR REPLACE FUNCTION get_admin_jtd_tenant_stats(
  p_page        int  DEFAULT 1,
  p_limit       int  DEFAULT 20,
  p_search      text DEFAULT NULL,
  p_sort_by     text DEFAULT 'total_jtds',
  p_sort_dir    text DEFAULT 'desc'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offset  int;
  v_total   int;
  v_tenants jsonb;
  v_global  jsonb;
BEGIN
  v_offset := (p_page - 1) * p_limit;

  -- ---- Global totals (quick scan) ----
  SELECT jsonb_build_object(
    'total_jtds',        count(*),
    'total_sent',        count(*) FILTER (WHERE status_code IN ('sent','delivered','read')),
    'total_failed',      count(*) FILTER (WHERE status_code = 'failed'),
    'total_no_credits',  count(*) FILTER (WHERE status_code = 'no_credits'),
    'total_cost',        COALESCE(sum(cost), 0)
  ) INTO v_global
  FROM n_jtd
  WHERE is_live = true;

  -- ---- Count matching tenants ----
  SELECT count(DISTINCT j.tenant_id) INTO v_total
  FROM n_jtd j
  JOIN t_tenants t ON t.id = j.tenant_id
  WHERE j.is_live = true
    AND (p_search IS NULL OR t.name ILIKE '%' || p_search || '%');

  -- ---- Per-tenant aggregation ----
  SELECT COALESCE(jsonb_agg(row_data), '[]'::jsonb) INTO v_tenants
  FROM (
    SELECT jsonb_build_object(
      'tenant_id',        t.id,
      'tenant_name',      t.name,
      'tenant_status',    t.status,
      'vani_enabled',     COALESCE(tc.vani_enabled, false),
      'total_jtds',       count(j.id),
      'sent',             count(j.id) FILTER (WHERE j.status_code IN ('sent','delivered','read')),
      'failed',           count(j.id) FILTER (WHERE j.status_code = 'failed'),
      'pending',          count(j.id) FILTER (WHERE j.status_code IN ('created','pending','queued','processing')),
      'no_credits',       count(j.id) FILTER (WHERE j.status_code = 'no_credits'),
      'cancelled',        count(j.id) FILTER (WHERE j.status_code = 'cancelled'),
      'success_rate',     CASE
                            WHEN count(j.id) FILTER (WHERE j.status_code IN ('sent','delivered','read','failed')) > 0
                            THEN round(
                              100.0 * count(j.id) FILTER (WHERE j.status_code IN ('sent','delivered','read'))
                              / count(j.id) FILTER (WHERE j.status_code IN ('sent','delivered','read','failed'))
                            , 1)
                            ELSE 0
                          END,
      'total_cost',       COALESCE(sum(j.cost), 0),
      'by_channel',       COALESCE(jsonb_object_agg(
                            COALESCE(j.channel_code, 'unset'),
                            1  -- placeholder, replaced below
                          ) FILTER (WHERE j.channel_code IS NOT NULL), '{}'::jsonb),
      'last_jtd_at',      max(j.created_at),
      'daily_limit',      tc.daily_limit,
      'daily_used',       COALESCE(tc.daily_used, 0),
      'monthly_limit',    tc.monthly_limit,
      'monthly_used',     COALESCE(tc.monthly_used, 0)
    ) AS row_data
    FROM n_jtd j
    JOIN t_tenants t ON t.id = j.tenant_id
    LEFT JOIN n_jtd_tenant_config tc ON tc.tenant_id = j.tenant_id AND tc.is_live = true
    WHERE j.is_live = true
      AND (p_search IS NULL OR t.name ILIKE '%' || p_search || '%')
    GROUP BY t.id, t.name, t.status, tc.vani_enabled, tc.daily_limit, tc.daily_used, tc.monthly_limit, tc.monthly_used
    ORDER BY
      CASE WHEN p_sort_by = 'total_jtds'  AND p_sort_dir = 'desc' THEN count(j.id) END DESC,
      CASE WHEN p_sort_by = 'total_jtds'  AND p_sort_dir = 'asc'  THEN count(j.id) END ASC,
      CASE WHEN p_sort_by = 'failed'      AND p_sort_dir = 'desc' THEN count(j.id) FILTER (WHERE j.status_code = 'failed') END DESC,
      CASE WHEN p_sort_by = 'failed'      AND p_sort_dir = 'asc'  THEN count(j.id) FILTER (WHERE j.status_code = 'failed') END ASC,
      CASE WHEN p_sort_by = 'total_cost'  AND p_sort_dir = 'desc' THEN COALESCE(sum(j.cost), 0) END DESC,
      CASE WHEN p_sort_by = 'total_cost'  AND p_sort_dir = 'asc'  THEN COALESCE(sum(j.cost), 0) END ASC,
      CASE WHEN p_sort_by = 'tenant_name' AND p_sort_dir = 'asc'  THEN t.name END ASC,
      CASE WHEN p_sort_by = 'tenant_name' AND p_sort_dir = 'desc' THEN t.name END DESC,
      count(j.id) DESC  -- fallback
    LIMIT p_limit
    OFFSET v_offset
  ) sub;

  -- ---- Fix by_channel: replace placeholder with real counts ----
  -- (jsonb_object_agg above gives 1 per channel; replace with sub-query)
  SELECT COALESCE(jsonb_agg(
    row_data || jsonb_build_object(
      'by_channel', COALESCE((
        SELECT jsonb_object_agg(ch.channel_code, ch.cnt)
        FROM (
          SELECT channel_code, count(*) AS cnt
          FROM n_jtd
          WHERE tenant_id = (row_data->>'tenant_id')::uuid
            AND is_live = true
            AND channel_code IS NOT NULL
          GROUP BY channel_code
        ) ch
      ), '{}'::jsonb)
    )
  ), '[]'::jsonb) INTO v_tenants
  FROM jsonb_array_elements(v_tenants) AS row_data;

  RETURN jsonb_build_object(
    'global',     v_global,
    'tenants',    v_tenants,
    'pagination', jsonb_build_object(
      'current_page',  p_page,
      'total_pages',   CEIL(v_total::float / p_limit)::int,
      'total_records', v_total,
      'limit',         p_limit,
      'has_next',      (v_offset + p_limit) < v_total,
      'has_prev',      p_page > 1
    )
  );
END;
$$;

COMMENT ON FUNCTION get_admin_jtd_tenant_stats IS
  'Admin: per-tenant JTD volume, channel mix, success rates, costs — paginated';


-- ============================================================================
-- 3. GET ADMIN JTD EVENTS (Event Explorer)
-- Paginated, filterable list of individual JTD records across all tenants.
-- Joins tenant name, status history count, and template name for display.
-- ============================================================================
CREATE OR REPLACE FUNCTION get_admin_jtd_events(
  p_page             int     DEFAULT 1,
  p_limit            int     DEFAULT 50,
  p_tenant_id        uuid    DEFAULT NULL,
  p_status_code      text    DEFAULT NULL,
  p_event_type_code  text    DEFAULT NULL,
  p_channel_code     text    DEFAULT NULL,
  p_source_type_code text    DEFAULT NULL,
  p_search           text    DEFAULT NULL,
  p_date_from        timestamptz DEFAULT NULL,
  p_date_to          timestamptz DEFAULT NULL,
  p_sort_by          text    DEFAULT 'created_at',
  p_sort_dir         text    DEFAULT 'desc'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offset int;
  v_total  int;
  v_events jsonb;
BEGIN
  v_offset := (p_page - 1) * p_limit;

  -- ---- Total matching records ----
  SELECT count(*) INTO v_total
  FROM n_jtd j
  WHERE j.is_live = true
    AND (p_tenant_id        IS NULL OR j.tenant_id        = p_tenant_id)
    AND (p_status_code      IS NULL OR j.status_code      = p_status_code)
    AND (p_event_type_code  IS NULL OR j.event_type_code  = p_event_type_code)
    AND (p_channel_code     IS NULL OR j.channel_code     = p_channel_code)
    AND (p_source_type_code IS NULL OR j.source_type_code = p_source_type_code)
    AND (p_date_from        IS NULL OR j.created_at      >= p_date_from)
    AND (p_date_to          IS NULL OR j.created_at      <= p_date_to)
    AND (p_search           IS NULL
         OR j.recipient_name    ILIKE '%' || p_search || '%'
         OR j.recipient_contact ILIKE '%' || p_search || '%'
         OR j.source_ref        ILIKE '%' || p_search || '%'
         OR j.id::text          ILIKE '%' || p_search || '%');

  -- ---- Paginated event list ----
  SELECT COALESCE(jsonb_agg(row_data), '[]'::jsonb) INTO v_events
  FROM (
    SELECT jsonb_build_object(
      'id',                 j.id,
      'tenant_id',          j.tenant_id,
      'tenant_name',        t.name,
      'event_type_code',    j.event_type_code,
      'channel_code',       j.channel_code,
      'source_type_code',   j.source_type_code,
      'source_ref',         j.source_ref,
      'status_code',        j.status_code,
      'previous_status',    j.previous_status_code,
      'priority',           j.priority,
      'recipient_name',     j.recipient_name,
      'recipient_contact',  j.recipient_contact,
      'template_key',       j.template_key,
      'retry_count',        j.retry_count,
      'max_retries',        j.max_retries,
      'cost',               j.cost,
      'error_message',      j.error_message,
      'error_code',         j.error_code,
      'provider_code',      j.provider_code,
      'provider_message_id',j.provider_message_id,
      'performed_by_type',  j.performed_by_type,
      'performed_by_name',  j.performed_by_name,
      'scheduled_at',       j.scheduled_at,
      'executed_at',        j.executed_at,
      'completed_at',       j.completed_at,
      'created_at',         j.created_at,
      'status_changes',     COALESCE((
        SELECT count(*) FROM n_jtd_status_history sh WHERE sh.jtd_id = j.id
      ), 0)
    ) AS row_data
    FROM n_jtd j
    JOIN t_tenants t ON t.id = j.tenant_id
    WHERE j.is_live = true
      AND (p_tenant_id        IS NULL OR j.tenant_id        = p_tenant_id)
      AND (p_status_code      IS NULL OR j.status_code      = p_status_code)
      AND (p_event_type_code  IS NULL OR j.event_type_code  = p_event_type_code)
      AND (p_channel_code     IS NULL OR j.channel_code     = p_channel_code)
      AND (p_source_type_code IS NULL OR j.source_type_code = p_source_type_code)
      AND (p_date_from        IS NULL OR j.created_at      >= p_date_from)
      AND (p_date_to          IS NULL OR j.created_at      <= p_date_to)
      AND (p_search           IS NULL
           OR j.recipient_name    ILIKE '%' || p_search || '%'
           OR j.recipient_contact ILIKE '%' || p_search || '%'
           OR j.source_ref        ILIKE '%' || p_search || '%'
           OR j.id::text          ILIKE '%' || p_search || '%')
    ORDER BY
      CASE WHEN p_sort_by = 'created_at' AND p_sort_dir = 'desc' THEN j.created_at END DESC,
      CASE WHEN p_sort_by = 'created_at' AND p_sort_dir = 'asc'  THEN j.created_at END ASC,
      CASE WHEN p_sort_by = 'priority'   AND p_sort_dir = 'desc' THEN j.priority   END DESC,
      CASE WHEN p_sort_by = 'priority'   AND p_sort_dir = 'asc'  THEN j.priority   END ASC,
      CASE WHEN p_sort_by = 'status'     AND p_sort_dir = 'asc'  THEN j.status_code END ASC,
      CASE WHEN p_sort_by = 'status'     AND p_sort_dir = 'desc' THEN j.status_code END DESC,
      j.created_at DESC  -- fallback
    LIMIT p_limit
    OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object(
    'events',     v_events,
    'pagination', jsonb_build_object(
      'current_page',  p_page,
      'total_pages',   CEIL(v_total::float / p_limit)::int,
      'total_records', v_total,
      'limit',         p_limit,
      'has_next',      (v_offset + p_limit) < v_total,
      'has_prev',      p_page > 1
    ),
    'generated_at', NOW()
  );
END;
$$;

COMMENT ON FUNCTION get_admin_jtd_events IS
  'Admin: paginated, filterable JTD event list across all tenants';


-- ============================================================================
-- 4. GET ADMIN JTD EVENT DETAIL
-- Single event with full status history timeline — for drill-down.
-- ============================================================================
CREATE OR REPLACE FUNCTION get_admin_jtd_event_detail(
  p_jtd_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event   jsonb;
  v_history jsonb;
BEGIN
  -- ---- Full event record ----
  SELECT jsonb_build_object(
    'id',                  j.id,
    'tenant_id',           j.tenant_id,
    'tenant_name',         t.name,
    'jtd_number',          j.jtd_number,
    'event_type_code',     j.event_type_code,
    'channel_code',        j.channel_code,
    'source_type_code',    j.source_type_code,
    'source_id',           j.source_id,
    'source_ref',          j.source_ref,
    'status_code',         j.status_code,
    'previous_status',     j.previous_status_code,
    'priority',            j.priority,
    'recipient_type',      j.recipient_type,
    'recipient_id',        j.recipient_id,
    'recipient_name',      j.recipient_name,
    'recipient_contact',   j.recipient_contact,
    'template_id',         j.template_id,
    'template_key',        j.template_key,
    'template_variables',  j.template_variables,
    'payload',             j.payload,
    'business_context',    j.business_context,
    'execution_result',    j.execution_result,
    'error_message',       j.error_message,
    'error_code',          j.error_code,
    'provider_code',       j.provider_code,
    'provider_message_id', j.provider_message_id,
    'provider_response',   j.provider_response,
    'retry_count',         j.retry_count,
    'max_retries',         j.max_retries,
    'next_retry_at',       j.next_retry_at,
    'cost',                j.cost,
    'performed_by_type',   j.performed_by_type,
    'performed_by_id',     j.performed_by_id,
    'performed_by_name',   j.performed_by_name,
    'metadata',            j.metadata,
    'tags',                j.tags,
    'scheduled_at',        j.scheduled_at,
    'executed_at',         j.executed_at,
    'completed_at',        j.completed_at,
    'status_changed_at',   j.status_changed_at,
    'created_at',          j.created_at,
    'updated_at',          j.updated_at
  ) INTO v_event
  FROM n_jtd j
  JOIN t_tenants t ON t.id = j.tenant_id
  WHERE j.id = p_jtd_id;

  IF v_event IS NULL THEN
    RETURN jsonb_build_object('error', 'JTD not found', 'id', p_jtd_id);
  END IF;

  -- ---- Status history timeline ----
  SELECT COALESCE(jsonb_agg(row_data ORDER BY created_at ASC), '[]'::jsonb)
  INTO v_history
  FROM (
    SELECT jsonb_build_object(
      'id',                sh.id,
      'from_status_code',  sh.from_status_code,
      'to_status_code',    sh.to_status_code,
      'is_valid',          sh.is_valid_transition,
      'performed_by_type', sh.performed_by_type,
      'performed_by_name', sh.performed_by_name,
      'reason',            sh.reason,
      'details',           sh.details,
      'duration_seconds',  sh.duration_seconds,
      'created_at',        sh.created_at
    ) AS row_data,
    sh.created_at
    FROM n_jtd_status_history sh
    WHERE sh.jtd_id = p_jtd_id
    ORDER BY sh.created_at ASC
  ) sub;

  RETURN jsonb_build_object(
    'event',          v_event,
    'status_history', v_history,
    'generated_at',   NOW()
  );
END;
$$;

COMMENT ON FUNCTION get_admin_jtd_event_detail IS
  'Admin: full JTD record + status history timeline for drill-down';


-- ============================================================================
-- 5. GET JTD WORKER HEALTH
-- Derives worker health from observable data: last processed JTD, queue age,
-- processing rate, error rate. No separate heartbeat table needed — the
-- existing n_jtd + PGMQ data tells the whole story.
-- ============================================================================
CREATE OR REPLACE FUNCTION get_admin_jtd_worker_health()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result              jsonb;
  v_last_executed       timestamptz;
  v_last_completed      timestamptz;
  v_currently_processing bigint;
  v_processed_1h        bigint;
  v_processed_24h       bigint;
  v_failed_1h           bigint;
  v_failed_24h          bigint;
  v_avg_duration_sec    numeric;
  v_queue_length        bigint;
  v_oldest_queue_sec    int;
  v_dlq_length          bigint;
  v_stuck_count         bigint;
  v_worker_status       text;
BEGIN
  -- ---- Last activity timestamps ----
  SELECT max(executed_at) INTO v_last_executed
  FROM n_jtd WHERE is_live = true AND executed_at IS NOT NULL;

  SELECT max(completed_at) INTO v_last_completed
  FROM n_jtd WHERE is_live = true AND completed_at IS NOT NULL;

  -- ---- Currently in processing ----
  SELECT count(*) INTO v_currently_processing
  FROM n_jtd
  WHERE status_code = 'processing' AND is_live = true;

  -- ---- Throughput: processed in last 1h / 24h ----
  SELECT count(*) INTO v_processed_1h
  FROM n_jtd
  WHERE is_live = true
    AND status_code IN ('sent','delivered','read')
    AND completed_at >= NOW() - INTERVAL '1 hour';

  SELECT count(*) INTO v_processed_24h
  FROM n_jtd
  WHERE is_live = true
    AND status_code IN ('sent','delivered','read')
    AND completed_at >= NOW() - INTERVAL '24 hours';

  -- ---- Failures in last 1h / 24h ----
  SELECT count(*) INTO v_failed_1h
  FROM n_jtd
  WHERE is_live = true
    AND status_code = 'failed'
    AND updated_at >= NOW() - INTERVAL '1 hour';

  SELECT count(*) INTO v_failed_24h
  FROM n_jtd
  WHERE is_live = true
    AND status_code = 'failed'
    AND updated_at >= NOW() - INTERVAL '24 hours';

  -- ---- Avg processing duration (last 100 completed) ----
  SELECT round(avg(EXTRACT(EPOCH FROM (completed_at - executed_at))), 2)
  INTO v_avg_duration_sec
  FROM (
    SELECT completed_at, executed_at
    FROM n_jtd
    WHERE is_live = true
      AND completed_at IS NOT NULL
      AND executed_at  IS NOT NULL
    ORDER BY completed_at DESC
    LIMIT 100
  ) recent;

  -- ---- Queue state ----
  SELECT count(*) INTO v_queue_length FROM pgmq.q_jtd_queue;

  SELECT EXTRACT(EPOCH FROM (NOW() - MIN(enqueued_at)))::int
  INTO v_oldest_queue_sec FROM pgmq.q_jtd_queue;

  SELECT count(*) INTO v_dlq_length FROM pgmq.q_jtd_dlq;

  -- ---- Stuck items: processing for > 5 minutes ----
  SELECT count(*) INTO v_stuck_count
  FROM n_jtd
  WHERE status_code = 'processing'
    AND is_live = true
    AND status_changed_at < NOW() - INTERVAL '5 minutes';

  -- ---- Derive worker status ----
  v_worker_status := CASE
    WHEN v_last_executed IS NULL THEN 'unknown'
    WHEN v_last_executed < NOW() - INTERVAL '10 minutes'
         AND v_queue_length > 0 THEN 'stalled'
    WHEN v_stuck_count > 0 THEN 'degraded'
    WHEN v_failed_1h > v_processed_1h AND v_processed_1h > 0 THEN 'degraded'
    WHEN v_queue_length = 0 AND v_currently_processing = 0 THEN 'idle'
    ELSE 'healthy'
  END;

  -- ---- Assemble ----
  v_result := jsonb_build_object(
    'status', v_worker_status,
    'last_executed_at',   v_last_executed,
    'last_completed_at',  v_last_completed,
    'currently_processing', COALESCE(v_currently_processing, 0),
    'stuck_count',          COALESCE(v_stuck_count, 0),
    'throughput', jsonb_build_object(
      'last_1h',  COALESCE(v_processed_1h, 0),
      'last_24h', COALESCE(v_processed_24h, 0),
      'avg_duration_sec', COALESCE(v_avg_duration_sec, 0)
    ),
    'errors', jsonb_build_object(
      'last_1h',  COALESCE(v_failed_1h, 0),
      'last_24h', COALESCE(v_failed_24h, 0),
      'error_rate_1h', CASE
        WHEN (COALESCE(v_processed_1h,0) + COALESCE(v_failed_1h,0)) > 0
        THEN round(100.0 * v_failed_1h / (v_processed_1h + v_failed_1h), 1)
        ELSE 0
      END
    ),
    'queue', jsonb_build_object(
      'length',         COALESCE(v_queue_length, 0),
      'oldest_age_sec', v_oldest_queue_sec,
      'dlq_length',     COALESCE(v_dlq_length, 0)
    ),
    'generated_at', NOW()
  );

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION get_admin_jtd_worker_health IS
  'Admin: worker health derived from queue state, throughput, and error rates';


-- ============================================================================
-- END OF MIGRATION
-- ============================================================================
