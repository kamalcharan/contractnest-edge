-- ============================================================================
-- 066_member_history_declaration_created_at.sql
-- gs_member_history: tell the caller WHEN each declaration was made
-- ============================================================================
-- ⚠️ ALREADY APPLIED TO LIVE on 6 Aug 2026. Source of record — do not re-run
-- (it returns early if the field is already emitted, but there is no reason to).
--
-- WHY
-- ---
-- The check-in page has always received the member's payment declarations and
-- has never been able to use them, because it could not tell a payment declared
-- five minutes ago from one declared last month: the payload carried
-- billing_event_id, status, upi_reference and amount, and ORDERED BY created_at
-- without ever emitting it.
--
-- That single field is what makes "you already recorded this today" possible.
-- It is the only change here.
--
-- WHAT IT ENABLES
-- ---------------
-- Members re-declare — they tap through twice, or come back unsure whether the
-- first attempt registered. Live evidence: Dr Srinivas Medepalli produced THREE
-- declarations against the same instalment (Monthly 5/12) inside four minutes on
-- 25 Jul, two of which the chair confirmed. The instalment itself did not
-- over-settle (₹1,500 due, ₹1,500 settled), so no money is mis-posted, but the
-- chair had to untangle it by hand and one confirmation is unverified.
--
-- Migration 052 added partial unique indexes for this, but they are scoped to
-- status = 'pending' and they discard the second row SILENTLY via ON CONFLICT
-- DO NOTHING — the member is told nothing and assumes it worked. The warning
-- this field enables is the part that was missing.
--
-- METHOD
-- ------
-- Substitute into the live definition rather than retyping it (the 048/064/065
-- approach). Signature read from pg_get_function_arguments — it carries
-- defaults and CREATE OR REPLACE refuses to drop them. Rewrite asserted
-- afterwards, because a substitution whose literal does not match is a SILENT
-- no-op; migration 058 lost two of four rewrites exactly that way.
-- ============================================================================
DO $mig$
DECLARE
  v_src  text;
  v_args text;
  v_from text := E'''upi_reference'', upi_reference, ''amount'', amount)';
  v_to   text := E'''upi_reference'', upi_reference, ''amount'', amount, ''created_at'', created_at)';
BEGIN
  SELECT prosrc, pg_get_function_arguments(oid)
    INTO v_src, v_args
    FROM pg_proc WHERE proname = 'gs_member_history';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'gs_member_history not found';
  END IF;
  IF position('''created_at'', created_at' in v_src) > 0 THEN
    RAISE NOTICE 'created_at already emitted — nothing to do';
    RETURN;
  END IF;
  IF position(v_from in v_src) = 0 THEN
    RAISE EXCEPTION 'anchor not found — refusing to rewrite blind';
  END IF;

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION gs_member_history(%s) '
    'RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS %L',
    v_args, replace(v_src, v_from, v_to)
  );

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'gs_member_history';
  IF position('''created_at'', created_at' in v_src) = 0 THEN
    RAISE EXCEPTION 'rewrite did not land';
  END IF;
  RAISE NOTICE 'created_at added to gs_member_history declarations';
END
$mig$;

-- ── Verified against live immediately after applying ────────────────────────
--   gs_member_history for Dr Srinivas Medepalli now returns all three of his
--   25 Jul declarations with created_at — 02:03:40 (rejected), 02:06:27
--   (confirmed), 02:07:23 (confirmed) — all against billing_event_id
--   7e112d6c-1df2-4a74-afea-7365b9d68da6. Exactly the case the warning catches.
