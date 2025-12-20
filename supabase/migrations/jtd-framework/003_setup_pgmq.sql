-- ============================================================
-- Migration: 003_setup_pgmq
-- Description: Setup PGMQ queue for JTD async processing
-- Author: Claude
-- Date: 2025-12-17
-- Prereq: PGMQ extension already activated
-- ============================================================

-- ============================================================
-- 1. CREATE JTD QUEUE
-- ============================================================

-- Create the main JTD queue
SELECT pgmq.create('jtd_queue');

-- Create a dead letter queue for failed messages
SELECT pgmq.create('jtd_dlq');

-- ============================================================
-- 2. TRIGGER FUNCTION: Enqueue JTD on Insert
-- ============================================================

CREATE OR REPLACE FUNCTION public.jtd_enqueue_on_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_message JSONB;
BEGIN
    -- Only enqueue if status is 'created' (initial state)
    IF NEW.status_code = 'created' THEN
        -- Build message payload
        v_message := jsonb_build_object(
            'jtd_id', NEW.id,
            'tenant_id', NEW.tenant_id,
            'event_type_code', NEW.event_type_code,
            'channel_code', NEW.channel_code,
            'source_type_code', NEW.source_type_code,
            'priority', NEW.priority,
            'scheduled_at', NEW.scheduled_at,
            'recipient_contact', NEW.recipient_contact,
            'is_live', NEW.is_live,
            'created_at', NEW.created_at
        );

        -- Send to queue
        PERFORM pgmq.send('jtd_queue', v_message);

        -- Update status to 'pending' (queued)
        NEW.status_code := 'pending';
        NEW.status_changed_at := NOW();
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.jtd_enqueue_on_insert IS 'Automatically enqueue JTD to PGMQ on insert';

-- ============================================================
-- 3. CREATE TRIGGER
-- ============================================================

DROP TRIGGER IF EXISTS trg_jtd_enqueue ON public.n_jtd;

CREATE TRIGGER trg_jtd_enqueue
    BEFORE INSERT ON public.n_jtd
    FOR EACH ROW
    EXECUTE FUNCTION public.jtd_enqueue_on_insert();

-- ============================================================
-- 4. HELPER FUNCTIONS FOR QUEUE OPERATIONS
-- ============================================================

-- Function to read messages from queue (for Edge Function)
CREATE OR REPLACE FUNCTION public.jtd_read_queue(
    p_batch_size INT DEFAULT 10,
    p_visibility_timeout INT DEFAULT 30
)
RETURNS TABLE (
    msg_id BIGINT,
    read_ct INT,
    enqueued_at TIMESTAMP WITH TIME ZONE,
    vt TIMESTAMP WITH TIME ZONE,
    message JSONB
) AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM pgmq.read('jtd_queue', p_visibility_timeout, p_batch_size);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.jtd_read_queue IS 'Read batch of JTD messages from queue';

-- Function to delete message after successful processing
CREATE OR REPLACE FUNCTION public.jtd_delete_message(p_msg_id BIGINT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN pgmq.delete('jtd_queue', p_msg_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.jtd_delete_message IS 'Delete processed message from queue';

-- Function to archive message (move to DLQ after max retries)
CREATE OR REPLACE FUNCTION public.jtd_archive_to_dlq(
    p_msg_id BIGINT,
    p_original_message JSONB,
    p_error_message TEXT
)
RETURNS VOID AS $$
DECLARE
    v_dlq_message JSONB;
BEGIN
    -- Build DLQ message with error info
    v_dlq_message := p_original_message || jsonb_build_object(
        'original_msg_id', p_msg_id,
        'error_message', p_error_message,
        'archived_at', NOW()
    );

    -- Send to DLQ
    PERFORM pgmq.send('jtd_dlq', v_dlq_message);

    -- Delete from main queue
    PERFORM pgmq.delete('jtd_queue', p_msg_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.jtd_archive_to_dlq IS 'Move failed message to dead letter queue';

-- Function to get queue metrics
CREATE OR REPLACE FUNCTION public.jtd_queue_metrics()
RETURNS TABLE (
    queue_name TEXT,
    queue_length BIGINT,
    newest_msg_age_sec INT,
    oldest_msg_age_sec INT,
    total_messages BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        'jtd_queue'::TEXT,
        (SELECT count(*) FROM pgmq.q_jtd_queue)::BIGINT,
        EXTRACT(EPOCH FROM (NOW() - (SELECT MAX(enqueued_at) FROM pgmq.q_jtd_queue)))::INT,
        EXTRACT(EPOCH FROM (NOW() - (SELECT MIN(enqueued_at) FROM pgmq.q_jtd_queue)))::INT,
        (SELECT count(*) FROM pgmq.q_jtd_queue)::BIGINT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.jtd_queue_metrics IS 'Get JTD queue metrics for monitoring';

-- ============================================================
-- 5. SCHEDULED JOB SUPPORT (for future cron processing)
-- ============================================================

-- Function to enqueue scheduled JTDs that are due
CREATE OR REPLACE FUNCTION public.jtd_enqueue_scheduled()
RETURNS INT AS $$
DECLARE
    v_count INT := 0;
    v_jtd RECORD;
    v_message JSONB;
BEGIN
    -- Find JTDs that are scheduled and due
    FOR v_jtd IN
        SELECT * FROM public.n_jtd
        WHERE status_code = 'scheduled'
          AND scheduled_at <= NOW()
          AND scheduled_at IS NOT NULL
        ORDER BY priority DESC, scheduled_at ASC
        LIMIT 100
        FOR UPDATE SKIP LOCKED
    LOOP
        -- Build message
        v_message := jsonb_build_object(
            'jtd_id', v_jtd.id,
            'tenant_id', v_jtd.tenant_id,
            'event_type_code', v_jtd.event_type_code,
            'channel_code', v_jtd.channel_code,
            'source_type_code', v_jtd.source_type_code,
            'priority', v_jtd.priority,
            'scheduled_at', v_jtd.scheduled_at,
            'recipient_contact', v_jtd.recipient_contact,
            'is_live', v_jtd.is_live,
            'created_at', v_jtd.created_at
        );

        -- Send to queue
        PERFORM pgmq.send('jtd_queue', v_message);

        -- Update status
        UPDATE public.n_jtd
        SET status_code = 'pending',
            status_changed_at = NOW()
        WHERE id = v_jtd.id;

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.jtd_enqueue_scheduled IS 'Enqueue scheduled JTDs that are due for processing';

-- ============================================================
-- END OF MIGRATION
-- ============================================================
