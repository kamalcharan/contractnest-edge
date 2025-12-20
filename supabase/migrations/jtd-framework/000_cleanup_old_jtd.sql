-- 000_cleanup_old_jtd.sql
-- CLEANUP SCRIPT: Drop all old JTD tables before creating new ones
-- RUN THIS FIRST before running 001_create_jtd_master_tables.sql
-- ============================================================

-- ============================================================
-- DROP OLD TABLES (if they exist)
-- ============================================================

-- Drop in reverse dependency order
DROP TABLE IF EXISTS public.n_jtd_history CASCADE;
DROP TABLE IF EXISTS public.n_jtd_status_history CASCADE;
DROP TABLE IF EXISTS public.n_jtd CASCADE;
DROP TABLE IF EXISTS public.n_jtd_templates CASCADE;
DROP TABLE IF EXISTS public.n_jtd_tenant_source_config CASCADE;
DROP TABLE IF EXISTS public.n_jtd_tenant_config CASCADE;
DROP TABLE IF EXISTS public.n_jtd_source_types CASCADE;
DROP TABLE IF EXISTS public.n_jtd_status_flows CASCADE;
DROP TABLE IF EXISTS public.n_jtd_statuses CASCADE;
DROP TABLE IF EXISTS public.n_jtd_channels CASCADE;
DROP TABLE IF EXISTS public.n_jtd_event_types CASCADE;
DROP TABLE IF EXISTS public.n_system_actors CASCADE;

-- Drop old events table if it exists (from previous implementation)
DROP TABLE IF EXISTS public.n_events CASCADE;
DROP TABLE IF EXISTS public.n_event_status_history CASCADE;
DROP TABLE IF EXISTS public.n_event_templates CASCADE;

-- ============================================================
-- DROP OLD FUNCTIONS (if they exist)
-- ============================================================

DROP FUNCTION IF EXISTS public.jtd_set_updated_at() CASCADE;
DROP FUNCTION IF EXISTS public.jtd_log_status_change() CASCADE;
DROP FUNCTION IF EXISTS public.jtd_log_creation() CASCADE;
DROP FUNCTION IF EXISTS public.jtd_validate_transition(VARCHAR, VARCHAR, VARCHAR) CASCADE;
DROP FUNCTION IF EXISTS public.jtd_get_status_duration_summary(UUID) CASCADE;

-- ============================================================
-- DROP PGMQ QUEUE (if exists)
-- ============================================================

-- Note: PGMQ queues are managed by extension
-- If you need to recreate the queue, run:
-- SELECT pgmq.drop_queue('jtd_queue');

DO $$
BEGIN
    -- Try to drop the queue if PGMQ is installed
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgmq') THEN
        PERFORM pgmq.drop_queue('jtd_queue');
        RAISE NOTICE 'Dropped jtd_queue';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not drop jtd_queue (may not exist): %', SQLERRM;
END $$;

-- ============================================================
-- VERIFICATION
-- ============================================================

DO $$
DECLARE
    table_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO table_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name LIKE 'n_jtd%';

    IF table_count = 0 THEN
        RAISE NOTICE '✅ All JTD tables dropped successfully';
    ELSE
        RAISE NOTICE '⚠️ Some JTD tables still exist: %', table_count;
    END IF;
END $$;

-- ============================================================
-- NOW RUN:
-- 001_create_jtd_master_tables.sql
-- 002_seed_master_data.sql
-- 003_setup_pgmq.sql
-- 004_rls_policies.sql
-- 005_seed_invitation_templates.sql
-- ============================================================
