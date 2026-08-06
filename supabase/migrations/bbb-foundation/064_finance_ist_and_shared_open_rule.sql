-- ============================================================================
-- 064_finance_ist_and_shared_open_rule.sql
-- Finance must reach the same conclusion by whatever path
-- ============================================================================
-- ⚠️ ALREADY APPLIED TO LIVE on 6 Aug 2026. Source of record.
--
-- Two independent reasons Finance and the Dues grid could report different
-- amounts owed for the same tenant. Both closed here.
--
-- ── PART A: "today" was UTC in the finance read models ──────────────────────
-- get_tenant_receivables, get_tenant_payables, get_contact_cockpit_summary and
-- get_vani_briefing all decided overdue-ness with bare CURRENT_DATE — the
-- DATABASE's date, which is UTC. India is UTC+5:30, so between 00:00 and 05:30
-- IST every one of them still believes it is yesterday: an instalment due today
-- reads as not-yet-overdue and ageing buckets sit a day behind. gs_dues_matrix
-- already used IST, so the two surfaces disagreed for five and a half hours a
-- day, every day.
--
-- The same defect migration 048 fixed across the check-in surface. CLAUDE.md
-- recorded then that other RPCs using bare current_date had never been audited.
-- These four are the first found — 42 occurrences between them.
--
-- METHOD: substitute into the live definition rather than retyping it. These
-- are long functions and retyping is how a second bug gets introduced while
-- fixing the first. The failure mode of substitution is a SILENT no-op when the
-- literal does not match (migration 058 lost two of four rewrites exactly that
-- way), so this asserts afterwards that zero occurrences remain.
--
-- VERIFIED: applied while UTC and IST dates agreed, so output had to be
-- unchanged — and was. Receivables still reported open 604,500, overdue
-- 102,000, 46 contracts. (Hash comparison is useless here: the payload carries
-- an `as_of` timestamp that moves on every call.)
--
-- ── PART B: two different definitions of "open" ─────────────────────────────
-- Finance computed what is owed as:
--     unsettled   = amount - amount_settled       (cancelled/skipped/waived = 0)
--     unallocated = invoice cash received but never posted to an instalment
--     open        = unsettled, less unallocated applied FIFO by due date
--
-- gs_dues_matrix computed it as "the full amount of any event whose status is
-- not paid". That is a cruder rule and differs in two real cases:
--   · a PARTIALLY settled instalment — the grid showed the whole amount as owed
--   · cash sitting on the contract-level invoice that was never attributed to
--     an instalment — Finance credits it, the grid did not
-- Neither case exists in BBB's data today, which is precisely why the two
-- agreed and why the divergence would have surfaced later, as a discrepancy
-- nobody could explain.
--
-- gs_dues_matrix now applies Finance's arithmetic exactly. The definition lives
-- in one place conceptually even though it is written twice; if it changes,
-- both must change, and the reconciliation query at the foot of this file is
-- the check that they still agree.
--
-- Note the ordering matters: PART A had to land first, because with the grid on
-- IST and Finance on UTC the reconciliation below would fail every night
-- regardless of PART B.
--
-- VERIFIED LIVE, both paths:
--     open     604,500 = 604,500  ✓
--     overdue  102,000 = 102,000  ✓
--     and the grid still balances: 313,500 paid + 102,000 due + 502,500 future
--     = 918,000 scheduled
-- ============================================================================

-- ── PART A ─────────────────────────────────────────────────────────────────
DO $mig$
DECLARE r record; v_src text; v_left int;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('get_tenant_receivables','get_tenant_payables',
                         'get_contact_cockpit_summary','get_vani_briefing')
  LOOP
    v_src := pg_get_functiondef(r.oid);
    IF position('CURRENT_DATE' in v_src) = 0 THEN
      RAISE EXCEPTION 'ABORT: % contains no CURRENT_DATE — definition not as expected', r.proname;
    END IF;
    v_src := replace(v_src, 'CURRENT_DATE', '(now() at time zone ''Asia/Kolkata'')::date');
    EXECUTE v_src;
    RAISE NOTICE 'rewrote %', r.proname;
  END LOOP;

  SELECT count(*) INTO v_left
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public'
     AND p.proname IN ('get_tenant_receivables','get_tenant_payables',
                       'get_contact_cockpit_summary','get_vani_briefing')
     AND p.prosrc LIKE '%CURRENT_DATE%';
  IF v_left > 0 THEN
    RAISE EXCEPTION 'POST-CHECK FAILED: % function(s) still contain CURRENT_DATE', v_left;
  END IF;
END
$mig$;

-- ── PART B ─────────────────────────────────────────────────────────────────
-- The gs_dues_matrix rewrite lives in 060_gs_dues_matrix.sql, which is the
-- single source of record for that function and has been updated in place
-- (it is a CREATE OR REPLACE). Re-apply 060 to pick up the shared open rule.

-- ── RECONCILIATION CHECK ───────────────────────────────────────────────────
-- Run this whenever either definition is touched. It must return true, true.
--
--   with fin as (select get_tenant_receivables('<tenant>', true) j),
--        dues as (select gs_dues_matrix('<tenant>','<block>', true) j),
--        f as (select coalesce(sum((e->>'open_amount')::numeric),0) open,
--                     coalesce(sum((e->>'open_amount')::numeric)
--                              filter (where (e->>'days_overdue')::int > 0),0) overdue
--                from fin, jsonb_array_elements(j->'events') e),
--        d as (select sum((r->>'due_total')::numeric) due,
--                     sum((r->>'future_total')::numeric) fut
--                from dues, jsonb_array_elements(j->'rows') r)
--   select f.open = (d.due + d.fut) as open_agrees,
--          f.overdue = d.due        as arrears_agrees
--     from f, d;
--
-- One difference is EXPECTED and correct: Finance returns fewer contracts,
-- because a contract with nothing left to collect has no place in a
-- receivables ledger. The Dues grid keeps it, fully green. The AMOUNTS agree;
-- the row counts are not meant to.
