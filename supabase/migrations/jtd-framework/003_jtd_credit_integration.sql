-- ============================================================================
-- Migration: 003_jtd_credit_integration.sql
-- Purpose: Add 'no_credits' status and release mechanism for JTD framework
-- Created: January 2025
-- Related: JTD-Addendum-CreditIntegration.md
-- ============================================================================

-- ============================================================================
-- 1. ADD 'no_credits' STATUS TO JTD STATUSES
-- ============================================================================

-- Insert 'no_credits' status for notification event type
INSERT INTO n_jtd_statuses (
    event_type_code,
    code,
    name,
    status_type,
    description,
    display_order,
    is_active,
    created_at,
    updated_at
)
VALUES (
    'notification',
    'no_credits',
    'No Credits',
    'waiting',
    'Notification blocked due to insufficient credits. Will be sent when credits are topped up.',
    15,
    TRUE,
    NOW(),
    NOW()
)
ON CONFLICT (event_type_code, code) DO NOTHING;

-- Insert 'no_credits' status for reminder event type
INSERT INTO n_jtd_statuses (
    event_type_code,
    code,
    name,
    status_type,
    description,
    display_order,
    is_active,
    created_at,
    updated_at
)
VALUES (
    'reminder',
    'no_credits',
    'No Credits',
    'waiting',
    'Reminder blocked due to insufficient credits.',
    15,
    TRUE,
    NOW(),
    NOW()
)
ON CONFLICT (event_type_code, code) DO NOTHING;

-- Insert 'expired' status for notification (for 7-day expiry)
INSERT INTO n_jtd_statuses (
    event_type_code,
    code,
    name,
    status_type,
    description,
    display_order,
    is_terminal,
    is_active,
    created_at,
    updated_at
)
VALUES (
    'notification',
    'expired',
    'Expired',
    'terminal',
    'Notification expired after waiting too long for credits.',
    99,
    TRUE,
    TRUE,
    NOW(),
    NOW()
)
ON CONFLICT (event_type_code, code) DO NOTHING;

-- Insert 'expired' status for reminder
INSERT INTO n_jtd_statuses (
    event_type_code,
    code,
    name,
    status_type,
    description,
    display_order,
    is_terminal,
    is_active,
    created_at,
    updated_at
)
VALUES (
    'reminder',
    'expired',
    'Expired',
    'terminal',
    'Reminder expired after waiting too long for credits.',
    99,
    TRUE,
    TRUE,
    NOW(),
    NOW()
)
ON CONFLICT (event_type_code, code) DO NOTHING;

-- ============================================================================
-- 2. ADD STATUS FLOWS (using status IDs)
-- ============================================================================

-- Helper function to insert status flow by codes
CREATE OR REPLACE FUNCTION insert_status_flow_by_codes(
    p_event_type_code TEXT,
    p_from_status_code TEXT,
    p_to_status_code TEXT
) RETURNS VOID AS $$
DECLARE
    v_from_id UUID;
    v_to_id UUID;
BEGIN
    -- Get from status ID
    SELECT id INTO v_from_id
    FROM n_jtd_statuses
    WHERE event_type_code = p_event_type_code AND code = p_from_status_code;

    -- Get to status ID
    SELECT id INTO v_to_id
    FROM n_jtd_statuses
    WHERE event_type_code = p_event_type_code AND code = p_to_status_code;

    -- Insert if both statuses exist
    IF v_from_id IS NOT NULL AND v_to_id IS NOT NULL THEN
        INSERT INTO n_jtd_status_flows (event_type_code, from_status_id, to_status_id, is_active)
        VALUES (p_event_type_code, v_from_id, v_to_id, TRUE)
        ON CONFLICT (event_type_code, from_status_id, to_status_id) DO NOTHING;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- created → no_credits (when no credits available at creation)
SELECT insert_status_flow_by_codes('notification', 'created', 'no_credits');
SELECT insert_status_flow_by_codes('reminder', 'created', 'no_credits');

-- no_credits → pending (when credits topped up, JTD released)
SELECT insert_status_flow_by_codes('notification', 'no_credits', 'pending');
SELECT insert_status_flow_by_codes('reminder', 'no_credits', 'pending');

-- no_credits → expired (after 7 days)
SELECT insert_status_flow_by_codes('notification', 'no_credits', 'expired');
SELECT insert_status_flow_by_codes('reminder', 'no_credits', 'expired');

-- Clean up helper function
DROP FUNCTION IF EXISTS insert_status_flow_by_codes(TEXT, TEXT, TEXT);

-- ============================================================================
-- 3. CREATE INDEXES FOR no_credits QUERIES
-- ============================================================================

-- Index for efficient release queries (find JTDs to release when credits topped up)
CREATE INDEX IF NOT EXISTS idx_jtd_no_credits_release
ON n_jtd (tenant_id, channel_code, created_at)
WHERE status_code = 'no_credits';

-- Index for expiry job (find JTDs older than 7 days)
CREATE INDEX IF NOT EXISTS idx_jtd_no_credits_expiry
ON n_jtd (created_at)
WHERE status_code = 'no_credits';

-- ============================================================================
-- 4. RPC FUNCTION: release_waiting_jtds
-- ============================================================================
-- Called when credits are topped up to release blocked JTDs

CREATE OR REPLACE FUNCTION release_waiting_jtds(
    p_tenant_id UUID,
    p_channel TEXT,              -- 'whatsapp', 'sms', 'email', or 'all'
    p_max_release INTEGER DEFAULT 100  -- Safety limit per call
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_available INTEGER;
    v_released INTEGER := 0;
    v_jtd RECORD;
    v_channels TEXT[];
    v_current_channel TEXT;
BEGIN
    -- Validate inputs
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    -- Determine which channels to release
    IF p_channel = 'all' OR p_channel IS NULL THEN
        v_channels := ARRAY['whatsapp', 'sms', 'email'];
    ELSE
        v_channels := ARRAY[p_channel];
    END IF;

    -- Process each channel
    FOREACH v_current_channel IN ARRAY v_channels
    LOOP
        -- Exit if we've released max
        IF v_released >= p_max_release THEN
            EXIT;
        END IF;

        -- Get available credits for this channel (including pooled)
        SELECT COALESCE(SUM(
            CASE WHEN channel = v_current_channel OR channel IS NULL
            THEN balance - COALESCE(reserved, 0)
            END
        ), 0)
        INTO v_available
        FROM t_bm_credit_balance
        WHERE tenant_id = p_tenant_id
          AND credit_type = 'notification'
          AND (expires_at IS NULL OR expires_at > NOW());

        -- Skip if no credits available
        IF v_available <= 0 THEN
            CONTINUE;
        END IF;

        -- Release JTDs up to available credits (FIFO order)
        FOR v_jtd IN
            SELECT id, event_type_code, source_type_code, recipient_contact
            FROM n_jtd
            WHERE tenant_id = p_tenant_id
              AND channel_code = v_current_channel
              AND status_code = 'no_credits'
            ORDER BY created_at ASC  -- FIFO: oldest first
            LIMIT LEAST(v_available, p_max_release - v_released)
        LOOP
            -- Update status to pending
            UPDATE n_jtd
            SET status_code = 'pending',
                updated_at = NOW()
            WHERE id = v_jtd.id;

            -- Record status change in history
            INSERT INTO n_jtd_status_history (
                jtd_id,
                from_status_code,
                to_status_code,
                performed_by_type,
                performed_by_name,
                transition_note,
                status_started_at
            )
            VALUES (
                v_jtd.id,
                'no_credits',
                'pending',
                'system',
                'Credit Topup Release',
                'Released after credit topup',
                NOW()
            );

            -- Add to PGMQ queue for processing (if PGMQ is available)
            BEGIN
                PERFORM pgmq.send('jtd_queue', jsonb_build_object(
                    'jtd_id', v_jtd.id,
                    'tenant_id', p_tenant_id,
                    'channel_code', v_current_channel,
                    'event_type_code', v_jtd.event_type_code,
                    'source_type_code', v_jtd.source_type_code,
                    'released_from_no_credits', true
                ));
            EXCEPTION WHEN OTHERS THEN
                -- PGMQ might not be available, log but continue
                RAISE NOTICE 'Could not queue JTD %: %', v_jtd.id, SQLERRM;
            END;

            v_released := v_released + 1;

            -- Stop if max reached
            IF v_released >= p_max_release THEN
                EXIT;
            END IF;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'released_count', v_released,
        'tenant_id', p_tenant_id,
        'channels', v_channels,
        'max_release', p_max_release
    );
END;
$$;

-- ============================================================================
-- 5. TRIGGER: Auto-release JTDs when credits are added
-- ============================================================================

CREATE OR REPLACE FUNCTION trg_fn_release_jtds_on_credit_topup()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_channel TEXT;
BEGIN
    -- Only trigger on balance increase (new credit or topup)
    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.balance > COALESCE(OLD.balance, 0)) THEN
        -- Determine channel to release
        v_channel := COALESCE(NEW.channel, 'all');

        -- Release waiting JTDs (async would be better, but this works for now)
        PERFORM release_waiting_jtds(NEW.tenant_id, v_channel, 50);
    END IF;

    RETURN NEW;
END;
$$;

-- Create trigger on credit balance (only if table exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 't_bm_credit_balance') THEN
        DROP TRIGGER IF EXISTS trg_credit_topup_release_jtds ON t_bm_credit_balance;
        CREATE TRIGGER trg_credit_topup_release_jtds
        AFTER INSERT OR UPDATE ON t_bm_credit_balance
        FOR EACH ROW
        EXECUTE FUNCTION trg_fn_release_jtds_on_credit_topup();
        RAISE NOTICE 'Created trigger trg_credit_topup_release_jtds on t_bm_credit_balance';
    ELSE
        RAISE NOTICE 't_bm_credit_balance table not found - trigger not created';
    END IF;
END;
$$;

-- ============================================================================
-- 6. RPC FUNCTION: expire_no_credits_jtds
-- ============================================================================
-- Called by cron job to expire JTDs older than 7 days

CREATE OR REPLACE FUNCTION expire_no_credits_jtds(
    p_expiry_days INTEGER DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_expired_count INTEGER;
    v_cutoff_date TIMESTAMPTZ;
BEGIN
    v_cutoff_date := NOW() - (p_expiry_days || ' days')::INTERVAL;

    -- Update status to expired
    WITH expired AS (
        UPDATE n_jtd
        SET status_code = 'expired',
            updated_at = NOW(),
            error_message = 'Expired after ' || p_expiry_days || ' days without credits'
        WHERE status_code = 'no_credits'
          AND created_at < v_cutoff_date
        RETURNING id, tenant_id
    )
    SELECT COUNT(*) INTO v_expired_count FROM expired;

    -- Log to status history
    INSERT INTO n_jtd_status_history (
        jtd_id,
        from_status_code,
        to_status_code,
        performed_by_type,
        performed_by_name,
        transition_note,
        status_started_at
    )
    SELECT
        id,
        'no_credits',
        'expired',
        'system',
        'Expiry Cron Job',
        'Expired after ' || p_expiry_days || ' days without credits',
        NOW()
    FROM n_jtd
    WHERE status_code = 'expired'
      AND updated_at >= NOW() - INTERVAL '1 minute';

    RETURN jsonb_build_object(
        'success', true,
        'expired_count', v_expired_count,
        'cutoff_date', v_cutoff_date,
        'expiry_days', p_expiry_days
    );
END;
$$;

-- ============================================================================
-- 7. CRON JOB: Expire no_credits JTDs daily
-- ============================================================================
-- Note: Requires pg_cron extension to be enabled

DO $outer$
BEGIN
    -- Check if pg_cron extension exists
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        -- Schedule daily job at 2 AM to expire old no_credits JTDs
        PERFORM cron.schedule(
            'expire-no-credits-jtds',
            '0 2 * * *',  -- Daily at 2 AM
            'SELECT expire_no_credits_jtds(7)'
        );
        RAISE NOTICE 'Cron job expire-no-credits-jtds scheduled';
    ELSE
        RAISE NOTICE 'pg_cron extension not found. Please schedule expire_no_credits_jtds() manually or enable pg_cron.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule cron job: %. Please schedule manually.', SQLERRM;
END;
$outer$;

-- ============================================================================
-- 8. RPC FUNCTION: Get count of waiting JTDs
-- ============================================================================
-- Useful for UI to show "X messages waiting for credits"

CREATE OR REPLACE FUNCTION get_waiting_jtd_count(
    p_tenant_id UUID,
    p_channel TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_counts RECORD;
BEGIN
    SELECT
        COUNT(*) FILTER (WHERE channel_code = 'whatsapp') AS whatsapp,
        COUNT(*) FILTER (WHERE channel_code = 'sms') AS sms,
        COUNT(*) FILTER (WHERE channel_code = 'email') AS email,
        COUNT(*) AS total
    INTO v_counts
    FROM n_jtd
    WHERE tenant_id = p_tenant_id
      AND status_code = 'no_credits'
      AND (p_channel IS NULL OR channel_code = p_channel);

    RETURN jsonb_build_object(
        'success', true,
        'tenant_id', p_tenant_id,
        'waiting', jsonb_build_object(
            'whatsapp', v_counts.whatsapp,
            'sms', v_counts.sms,
            'email', v_counts.email,
            'total', v_counts.total
        )
    );
END;
$$;

-- ============================================================================
-- 9. COMMENTS
-- ============================================================================

COMMENT ON FUNCTION release_waiting_jtds IS 'Release JTDs with no_credits status when credits are topped up. FIFO order.';
COMMENT ON FUNCTION expire_no_credits_jtds IS 'Expire JTDs that have been waiting for credits longer than specified days.';
COMMENT ON FUNCTION get_waiting_jtd_count IS 'Get count of JTDs waiting for credits by channel.';
