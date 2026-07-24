-- Fix: every group-session/check-in function computed "today" from bare
-- current_date, which is the DATABASE's timezone (UTC) — not the tenant's
-- local day. Discovered live during BBB's go-live: at 00:28 IST on 25 Jul
-- 2026, current_date was still '2026-07-24' (UTC doesn't roll to the 25th
-- until 05:30 IST), so gs_resolve_checkin reported "no session today, next
-- session 25 Jul" even though it already WAS 25 Jul in India and today's
-- Saturday Cadence occurrence existed and was checkin-able.
--
-- Fix: every "today" comparison across the check-in/attendance/dashboard
-- surface now uses (now() at time zone 'Asia/Kolkata')::date instead of
-- current_date. Applied by pulling each function's live definition and
-- substituting the expression in place — guarantees byte-for-byte parity
-- with everything else in each function body, no manual retyping.
--
-- NOTE: 'Asia/Kolkata' is hardcoded — there is no per-tenant timezone
-- column yet (checked: t_tenants / t_tenant_profiles have none). Fine for
-- now (every tenant observed this session is India-based), but this needs
-- to become tenant-configurable before the platform serves other regions.
-- Flagged in CLAUDE.md.

DO $do$
DECLARE
  v_sig text;
  v_def text;
  v_new_def text;
BEGIN
  FOR v_sig IN
    SELECT unnest(ARRAY[
      'gs_resolve_checkin(text)',
      'gs_submit_checkin(text,uuid,text,text,text,jsonb,jsonb,uuid,integer,text)',
      'gs_checkin_guest(text,text,text,text,text,text,jsonb,uuid,integer,text)',
      'gs_checkin_substitute(text,uuid,text,text,text,jsonb,uuid,integer,text)',
      'gs_checkin_form(text)',
      'gs_dash_occurrences(uuid,uuid,boolean)',
      'gs_dash_sessions(uuid,boolean)',
      'gs_member_block(uuid,uuid,uuid,boolean)',
      'gs_dash_roster(uuid,uuid,boolean)',
      'gs_occurrence_attendance(uuid,uuid)',
      'gs_generate_schedule(uuid,uuid,boolean,date,date)',
      'gs_schedule_assign_default(uuid,uuid,boolean,uuid,text,uuid,text)',
      'gs_confirm_declaration(uuid,uuid,boolean,uuid)'
    ])
  LOOP
    SELECT pg_get_functiondef(('public.' || v_sig)::regprocedure) INTO v_def;
    v_new_def := regexp_replace(v_def, '\mcurrent_date\M', '(now() at time zone ''Asia/Kolkata'')::date', 'gi');
    EXECUTE v_new_def;
    RAISE NOTICE 'Updated %', v_sig;
  END LOOP;
END $do$;
