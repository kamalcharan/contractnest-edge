-- ============================================================================
-- Admin JTD Management RPC Functions — Release 2 (Actions)
-- Purpose: Allow platform admins to retry, cancel, force-complete events,
--          and manage the Dead Letter Queue (list, requeue, purge).
-- Prereq:  001_admin_jtd_rpcs.sql (R1 Observability)
-- ============================================================================


-- ============================================================================
-- 1. ADMIN RETRY JTD EVENT
-- Re-queues a failed event: resets retry_count, clears error fields,
-- updates status to 'queued', and re-enqueues the PGMQ message.
-- ============================================================================
CREATE OR REPLACE FUNCTION admin_retry_jtd_event(
  p_jtd_id     uuid,
  p_admin_name text,
  p_reason     text DEFAULT 'Admin manual retry'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event       record;
  v_message     jsonb;
BEGIN
  -- Lock the row to prevent concurrent modifications
  SELECT id, tenant_id, status_code, event_type_code, channel_code,
         source_type_code, priority, recipient_contact, scheduled_at,
         is_live, created_at
  INTO v_event
  FROM n_jtd
  WHERE id = p_jtd_id AND is_live = true
  FOR UPDATE;

  IF v_event IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'JTD event not found');
  END IF;

  IF v_event.status_code != 'failed' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Cannot retry event in status "%s". Only "failed" events can be retried.', v_event.status_code)
    );
  END IF;

  -- Update the event: reset to queued
  UPDATE n_jtd
  SET status_code        = 'queued',
      retry_count        = 0,
      error_message      = NULL,
      error_code         = NULL,
      execution_result   = NULL,
      provider_response  = NULL,
      next_retry_at      = NULL,
      completed_at       = NULL,
      executed_at        = NULL,
      performed_by_type  = 'admin',
      performed_by_name  = p_admin_name,
      transition_note    = p_reason,
      updated_at         = NOW(),
      updated_by         = NULL
  WHERE id = p_jtd_id;

  -- Build PGMQ message and enqueue
  v_message := jsonb_build_object(
    'jtd_id',             v_event.id,
    'tenant_id',          v_event.tenant_id,
    'event_type_code',    v_event.event_type_code,
    'channel_code',       v_event.channel_code,
    'source_type_code',   v_event.source_type_code,
    'priority',           v_event.priority,
    'scheduled_at',       v_event.scheduled_at,
    'recipient_contact',  v_event.recipient_contact,
    'is_live',            v_event.is_live,
    'created_at',         v_event.created_at,
    'retried_by_admin',   true
  );

  PERFORM pgmq.send('jtd_queue', v_message);

  RETURN jsonb_build_object(
    'success',     true,
    'event_id',    p_jtd_id,
    'from_status', 'failed',
    'to_status',   'queued',
    'message',     'Event re-queued for processing'
  );
END;
$$;

COMMENT ON FUNCTION admin_retry_jtd_event IS
  'Admin R2: retry a failed JTD event — resets and re-enqueues to PGMQ';


-- ============================================================================
-- 2. ADMIN CANCEL JTD EVENT
-- Cancels a pending/queued/scheduled event. Sets status to 'cancelled'.
-- ============================================================================
CREATE OR REPLACE FUNCTION admin_cancel_jtd_event(
  p_jtd_id     uuid,
  p_admin_name text,
  p_reason     text DEFAULT 'Admin manual cancellation'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event record;
BEGIN
  SELECT id, status_code
  INTO v_event
  FROM n_jtd
  WHERE id = p_jtd_id AND is_live = true
  FOR UPDATE;

  IF v_event IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'JTD event not found');
  END IF;

  IF v_event.status_code NOT IN ('created', 'pending', 'queued', 'scheduled') THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Cannot cancel event in status "%s". Only created/pending/queued/scheduled events can be cancelled.', v_event.status_code)
    );
  END IF;

  UPDATE n_jtd
  SET status_code       = 'cancelled',
      completed_at      = NOW(),
      performed_by_type = 'admin',
      performed_by_name = p_admin_name,
      transition_note   = p_reason,
      updated_at        = NOW()
  WHERE id = p_jtd_id;

  RETURN jsonb_build_object(
    'success',     true,
    'event_id',    p_jtd_id,
    'from_status', v_event.status_code,
    'to_status',   'cancelled',
    'message',     'Event cancelled'
  );
END;
$$;

COMMENT ON FUNCTION admin_cancel_jtd_event IS
  'Admin R2: cancel a pending/queued/scheduled JTD event';


-- ============================================================================
-- 3. ADMIN FORCE COMPLETE JTD EVENT
-- Admin override for stuck processing events. Sets status to 'sent' or 'failed'.
-- ============================================================================
CREATE OR REPLACE FUNCTION admin_force_complete_jtd_event(
  p_jtd_id        uuid,
  p_admin_name    text,
  p_target_status text,
  p_reason        text DEFAULT 'Admin force complete'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event record;
BEGIN
  IF p_target_status NOT IN ('sent', 'failed') THEN
    RETURN jsonb_build_object('success', false, 'error', 'target_status must be "sent" or "failed"');
  END IF;

  SELECT id, status_code
  INTO v_event
  FROM n_jtd
  WHERE id = p_jtd_id AND is_live = true
  FOR UPDATE;

  IF v_event IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'JTD event not found');
  END IF;

  IF v_event.status_code != 'processing' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Cannot force-complete event in status "%s". Only "processing" events can be force-completed.', v_event.status_code)
    );
  END IF;

  UPDATE n_jtd
  SET status_code       = p_target_status,
      completed_at      = NOW(),
      performed_by_type = 'admin',
      performed_by_name = p_admin_name,
      transition_note   = format('Admin force complete: %s', p_reason),
      updated_at        = NOW()
  WHERE id = p_jtd_id;

  RETURN jsonb_build_object(
    'success',     true,
    'event_id',    p_jtd_id,
    'from_status', 'processing',
    'to_status',   p_target_status,
    'message',     format('Event force-completed as %s', p_target_status)
  );
END;
$$;

COMMENT ON FUNCTION admin_force_complete_jtd_event IS
  'Admin R2: force-complete a stuck processing event as sent or failed';


-- ============================================================================
-- 4. ADMIN LIST DLQ MESSAGES
-- Paginated list of dead-letter queue messages with JTD context.
-- ============================================================================
CREATE OR REPLACE FUNCTION admin_list_dlq_messages(
  p_page  int DEFAULT 1,
  p_limit int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offset   int;
  v_total    bigint;
  v_messages jsonb;
BEGIN
  v_offset := (p_page - 1) * p_limit;

  SELECT count(*) INTO v_total FROM pgmq.q_jtd_dlq;

  SELECT COALESCE(jsonb_agg(row_data), '[]'::jsonb) INTO v_messages
  FROM (
    SELECT jsonb_build_object(
      'msg_id',       d.msg_id,
      'read_ct',      d.read_ct,
      'enqueued_at',  d.enqueued_at,
      'vt',           d.vt,
      'jtd_id',       d.message->>'jtd_id',
      'tenant_id',    d.message->>'tenant_id',
      'tenant_name',  COALESCE(t.name, 'Unknown'),
      'event_type',   d.message->>'event_type_code',
      'channel',      d.message->>'channel_code',
      'priority',     d.message->>'priority',
      'error_message', COALESCE(j.error_message, ''),
      'status_code',  COALESCE(j.status_code, ''),
      'recipient',    COALESCE(j.recipient_name, j.recipient_contact, ''),
      'age_seconds',  EXTRACT(EPOCH FROM (NOW() - d.enqueued_at))::int
    ) AS row_data
    FROM pgmq.q_jtd_dlq d
    LEFT JOIN n_jtd j ON j.id = (d.message->>'jtd_id')::uuid
    LEFT JOIN t_tenants t ON t.id = (d.message->>'tenant_id')::uuid
    ORDER BY d.enqueued_at DESC
    LIMIT p_limit
    OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object(
    'messages',   v_messages,
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

COMMENT ON FUNCTION admin_list_dlq_messages IS
  'Admin R2: paginated DLQ message list with JTD event context';


-- ============================================================================
-- 5. ADMIN REQUEUE DLQ MESSAGE
-- Moves a single message from DLQ back to the main queue.
-- ============================================================================
CREATE OR REPLACE FUNCTION admin_requeue_dlq_message(
  p_msg_id     bigint,
  p_admin_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_message  jsonb;
  v_jtd_id   uuid;
BEGIN
  -- Read the DLQ message
  SELECT message INTO v_message
  FROM pgmq.q_jtd_dlq
  WHERE msg_id = p_msg_id;

  IF v_message IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'DLQ message not found');
  END IF;

  v_jtd_id := (v_message->>'jtd_id')::uuid;

  -- Delete from DLQ
  PERFORM pgmq.delete('jtd_dlq', p_msg_id);

  -- Re-enqueue to main queue with admin flag
  PERFORM pgmq.send('jtd_queue', v_message || jsonb_build_object('requeued_by_admin', true));

  -- Update JTD status if the event exists
  IF v_jtd_id IS NOT NULL THEN
    UPDATE n_jtd
    SET status_code       = 'queued',
        retry_count       = 0,
        error_message     = NULL,
        error_code        = NULL,
        completed_at      = NULL,
        executed_at       = NULL,
        performed_by_type = 'admin',
        performed_by_name = p_admin_name,
        transition_note   = 'Requeued from DLQ by admin',
        updated_at        = NOW()
    WHERE id = v_jtd_id AND is_live = true;
  END IF;

  RETURN jsonb_build_object(
    'success',  true,
    'msg_id',   p_msg_id,
    'jtd_id',   v_jtd_id,
    'message',  'Message requeued from DLQ to main queue'
  );
END;
$$;

COMMENT ON FUNCTION admin_requeue_dlq_message IS
  'Admin R2: move a single DLQ message back to the main processing queue';


-- ============================================================================
-- 6. ADMIN PURGE DLQ
-- Deletes ALL messages from the dead-letter queue.
-- ============================================================================
CREATE OR REPLACE FUNCTION admin_purge_dlq(
  p_admin_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count bigint;
BEGIN
  SELECT count(*) INTO v_count FROM pgmq.q_jtd_dlq;

  IF v_count = 0 THEN
    RETURN jsonb_build_object('success', true, 'purged_count', 0, 'message', 'DLQ is already empty');
  END IF;

  DELETE FROM pgmq.q_jtd_dlq;

  RETURN jsonb_build_object(
    'success',       true,
    'purged_count',  v_count,
    'purged_by',     p_admin_name,
    'message',       format('Purged %s messages from DLQ', v_count)
  );
END;
$$;

COMMENT ON FUNCTION admin_purge_dlq IS
  'Admin R2: purge all messages from the dead-letter queue';


-- ============================================================================
-- END OF R2 MIGRATION
-- ============================================================================
