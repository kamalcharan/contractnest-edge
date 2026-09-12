-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/005_step3fix_sweeper_ignores_jobs.sql
-- JTD Nucleus — Step 3 trap cleanup (owner-approved "fix it", 2026-08-18)
--
-- FOUND ON CN-1005 (first job contract to live past a cron minute):
-- jtd_enqueue_scheduled sweeps ANY row with status_code='scheduled' AND
-- scheduled_at <= NOW() into the dispatch queue — no channel filter. It
-- grabbed CN-1005's 4 due-today JOB rows (channel NULL — jobs, not
-- messages) and the worker failed them ("No template found for
-- payment_scheduled/null", "Blocked: service_scheduled disabled").
-- The tenant's channel gates blocked any real send THIS time; with
-- channels enabled and a template present, a job could have gone out
-- as a message. "A job is not a message" must be structural, not a
-- side effect of tenant config.
--
-- FIX (one line): the sweeper's WHERE gains
--     AND channel_code IS NOT NULL
-- SAFETY PROOF (queried live before writing): every one of the 445
-- messenger rows in n_jtd carries a channel; the ONLY channel-less
-- rows are the 28 job rows. The guard changes behavior for zero
-- existing messages, ever.
--
-- REPAIR: CN-1005's 4 wrongly-failed job rows go back to 'scheduled'
-- with error fields cleared. The BEFORE-UPDATE status trigger logs the
-- failed→scheduled move in n_jtd_status_history — audit preserved.
--
-- Method: verified-anchor prosrc substitution (aborts if the live
-- function drifted; post-check confirms). Idempotent both halves.
-- APPLIED LIVE 2026-08-18 — this file is the source-of-record copy.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1: guard the sweeper ────────────────────────────────────────────
DO $do$
DECLARE
    v_def    TEXT;
    v_anchor TEXT;
    v_insert TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'jtd_enqueue_scheduled'
      AND pronamespace = 'public'::regnamespace;

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'jtd_enqueue_scheduled not found — nothing to modify';
    END IF;

    IF position('channel_code IS NOT NULL' in v_def) > 0 THEN
        RAISE NOTICE 'sweeper already guarded — skipping';
        RETURN;
    END IF;

    v_anchor := 'AND scheduled_at <= NOW()' || E'\r\n' ||
                '          AND scheduled_at IS NOT NULL';

    IF (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 THEN
        RAISE EXCEPTION 'anchor not found exactly once — live function has drifted; aborting (nothing changed)';
    END IF;

    v_insert := v_anchor || E'\r\n' ||
                '          -- JTD Nucleus (2026-08-18): job rows (channel NULL) are' || E'\r\n' ||
                '          -- commitments, not messages — the dispatch sweeper must' || E'\r\n' ||
                '          -- never pick them up. Zero messenger rows are channel-less' || E'\r\n' ||
                '          -- (verified live before this change).' || E'\r\n' ||
                '          AND channel_code IS NOT NULL';

    v_def := replace(v_def, v_anchor, v_insert);
    EXECUTE v_def;

    SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc
    WHERE proname = 'jtd_enqueue_scheduled'
      AND pronamespace = 'public'::regnamespace;

    IF position('channel_code IS NOT NULL' in v_def) = 0 THEN
        RAISE EXCEPTION 'post-check FAILED: guard not present after apply';
    END IF;

    RAISE NOTICE 'sweeper guard installed and verified';
END
$do$;

-- ── 2: repair the 4 wrongly-failed job rows (CN-1005) ───────────────
UPDATE public.n_jtd
SET status_code       = 'scheduled',
    error_message     = NULL,
    error_code        = NULL,
    executed_at       = NULL,
    retry_count       = 0,
    transition_note   = 'JTD Nucleus 005: repaired — dispatch sweeper wrongly picked channel-less job rows'
WHERE channel_code IS NULL
  AND contract_id IS NOT NULL
  AND status_code = 'failed';
