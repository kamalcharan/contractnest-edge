-- ============================================================================
-- Migration: Stage 0 Runtime Loop — 005 Cron: scanner schedule + JTD de-dupe
-- ============================================================================
-- Purpose:
--   1. De-duplicate the double jtd-worker cron (live jobids 1 & 3 both run
--      SELECT invoke_jtd_worker() every minute — audit finding P5/P6).
--      Keeps the LOWEST jobid, unschedules the rest. Robust against names
--      ('jtd-worker-cron' vs 'invoke-jtd-worker').
--   2. Schedule the contract-event scanner every 15 minutes.
-- Depends on: 004 (run_contract_event_scanner), pg_cron extension
-- Safe to re-run: Yes (re-schedule is guarded; de-dupe converges to 1 job)
-- Applied by: OWNER — project uwyqhzotluikawcboldr
-- ============================================================================

DO $$
DECLARE
    v_keep BIGINT;
    v_job  RECORD;
BEGIN
    -- ─────────────────────────────────────────
    -- 1. De-dupe jtd-worker cron jobs
    -- ─────────────────────────────────────────
    SELECT min(jobid) INTO v_keep
    FROM cron.job
    WHERE command ILIKE '%invoke_jtd_worker%';

    IF v_keep IS NOT NULL THEN
        FOR v_job IN
            SELECT jobid, jobname FROM cron.job
            WHERE command ILIKE '%invoke_jtd_worker%' AND jobid <> v_keep
        LOOP
            PERFORM cron.unschedule(v_job.jobid);
            RAISE NOTICE 'Unscheduled duplicate jtd-worker cron job % (%)', v_job.jobid, v_job.jobname;
        END LOOP;
        RAISE NOTICE 'jtd-worker cron: keeping jobid %', v_keep;
    ELSE
        RAISE WARNING 'No jtd-worker cron job found — JTD dispatch will not drain!';
    END IF;

    -- ─────────────────────────────────────────
    -- 2. Schedule the contract-event scanner (idempotent re-schedule)
    -- ─────────────────────────────────────────
    FOR v_job IN
        SELECT jobid FROM cron.job WHERE jobname = 'contract-event-scanner'
    LOOP
        PERFORM cron.unschedule(v_job.jobid);
    END LOOP;

    PERFORM cron.schedule(
        'contract-event-scanner',
        '*/15 * * * *',
        'SELECT run_contract_event_scanner();'
    );

    RAISE NOTICE 'Scheduled contract-event-scanner: every 15 minutes';
END;
$$;

-- Verify:
--   SELECT jobid, jobname, schedule, command, active FROM cron.job ORDER BY jobid;
-- Expected: exactly ONE job running invoke_jtd_worker(), plus
--           'contract-event-scanner' on */15.
-- Run results: SELECT * FROM cron.job_run_details
--              WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname='contract-event-scanner')
--              ORDER BY start_time DESC LIMIT 5;
