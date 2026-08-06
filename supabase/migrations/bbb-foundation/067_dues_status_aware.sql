-- ============================================================================
-- 067_dues_status_aware.sql
-- The dues grid must respect a written-off instalment
-- ============================================================================
-- ⚠️ ALREADY APPLIED TO LIVE on 6 Aug 2026. Source of record.
--
-- THE BUG
-- -------
-- gs_dues_matrix decided what was owed with `status <> 'paid'` — a DENYLIST.
-- Billing events also reach waived, cancelled, bad_debt and adjustment, all of
-- them terminal write-offs. Every one of those counted as money still due:
-- amber on the chair's grid, inside `due_total`, and — because the check-in
-- page quotes the same arrears — chased on the member's own phone for an amount
-- somebody had already written off.
--
-- Fixed by inverting it to an ALLOWLIST of the four statuses that genuinely
-- mean money outstanding: scheduled, due, overdue, partial_payment. The same
-- list the check-in page already used, so the two now agree by construction
-- rather than by coincidence.
--
-- Written-off amounts are not simply dropped — they are returned as
-- `written_off_total`, so the money reads as a decision somebody took rather
-- than as a hole in the numbers.
--
-- ALSO ADDED, for status marking from the dues grid
-- -------------------------------------------------
-- Each month cell now carries:
--   status   the representative status — earliest still-open instalment wins,
--            since that is the one needing action; if none is open, the real
--            terminal status (paid / waived / cancelled / bad_debt /
--            adjustment) so the UI can colour it from the tenant's own
--            m_event_status_config rather than a hardcoded palette
--   is_open  whether anything in the month is still owed
--   is_past  whether the month has come round yet
--   events   every instalment in the month with id, version, status, amount,
--            settled and date — a month can hold more than one, and a status
--            change has to target the right one rather than guess. version is
--            included because PATCH /api/contract-events/:id uses it for
--            optimistic concurrency.
--
-- VERIFIED (test environment, is_live=false, then reverted)
-- --------------------------------------------------------
-- Waiving one 7,500 instalment moved arrears 105,000 -> 97,500 and
-- written_off 0 -> 7,500. Reverted; both environments back to 105,000 / 0.
-- Live totals unchanged by the migration itself: 313,500 paid + 105,000 due
-- + 501,000 future = 919,500 scheduled. BBB currently holds no written-off
-- events at all, which is why this never surfaced.
--
-- NOTE: two UPDATEs to the same row from two CTEs of ONE statement do not both
-- apply — the second sees the pre-update snapshot and silently no-ops. The
-- revert above needed its own statement. Worth remembering for any
-- mutate-measure-restore check done this way.
-- ============================================================================

-- Full function definition as applied:
CREATE OR REPLACE FUNCTION gs_dues_matrix(
  p_tenant uuid, p_block uuid, p_is_live boolean, p_fy_start date DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_today  date := (now() at time zone 'Asia/Kolkata')::date;
  v_fy date; v_seed date; v_months jsonb; v_rows jsonb;
  -- The ONLY statuses that represent money still owed. An allowlist, not
  -- "anything that isn't paid": waived, cancelled, bad_debt and adjustment are
  -- all terminal write-offs, and counting them as due kept chasing members for
  -- amounts somebody had already written off.
  v_open text[] := ARRAY['scheduled','due','overdue','partial_payment'];
BEGIN
  IF p_fy_start IS NOT NULL THEN
    v_fy := date_trunc('month', p_fy_start)::date;
  ELSE
    SELECT min(e.scheduled_date)::date INTO v_seed
      FROM t_contract_blocks cb
      JOIN t_contracts c ON c.id = cb.contract_id
      JOIN t_contract_events e ON e.contract_id = c.id AND e.event_type = 'billing'
     WHERE cb.source_block_id = p_block AND c.tenant_id = p_tenant
       AND coalesce(c.is_live, true) = p_is_live AND c.status = 'active';
    v_seed := coalesce(v_seed, v_today);
    v_fy := make_date(extract(year from v_seed)::int - (CASE WHEN extract(month from v_seed) < 4 THEN 1 ELSE 0 END), 4, 1);
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
           'key', to_char(m,'YYYY-MM'), 'label', to_char(m,'Mon'),
           'year', extract(year from m)::int,
           'is_past', (m + interval '1 month - 1 day')::date < v_today
         ) ORDER BY m)
    INTO v_months
    FROM generate_series(v_fy, v_fy + interval '11 months', interval '1 month') AS m;

  SELECT coalesce(jsonb_agg(r ORDER BY r->>'name', r->>'start_date'), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object(
             'contact_id', m.buyer_id, 'name', m.buyer_name,
             'contract_id', m.contract_id, 'contract_number', m.contract_number,
             'contract_name', m.contract_name,
             'start_date', m.start_date, 'end_date', m.end_date,
             'currency', m.currency,
             'plan', m.plan, 'plan_source', m.plan_source, 'instalments', m.instalments,
             'contract_value', m.contract_value, 'discount', m.discount, 'net', m.net,
             'scheduled_total', m.scheduled_total, 'paid_total', m.paid_total,
             'due_total', m.due_total, 'future_total', m.future_total,
             'written_off_total', m.written_off_total,
             'beyond_total', m.beyond_total, 'beyond_count', m.beyond_count,
             'in_window', m.in_window, 'cells', m.cells
           ) AS r
      FROM (
        SELECT c.buyer_id, c.buyer_name, c.id AS contract_id, c.contract_number,
               c.name AS contract_name, c.start_date, c.end_date,
               coalesce(c.currency, 'INR')                AS currency,
               coalesce(c.total_value, 0)                 AS contract_value,
               coalesce(c.discount_total, 0)              AS discount,
               coalesce(c.grand_total, c.total_value, 0)  AS net,
               ev.instalments, ev.scheduled_total, ev.paid_total,
               ev.due_total, ev.future_total, ev.written_off_total,
               ev.beyond_total, ev.beyond_count, ev.cells,
               coalesce(nullif(c.metadata->>'billing_plan',''), ev.plan) AS plan,
               CASE WHEN nullif(c.metadata->>'billing_plan','') IS NOT NULL
                    THEN 'recorded' ELSE 'derived' END AS plan_source,
               (ev.cells <> '{}'::jsonb) AS in_window
          FROM t_contract_blocks cb
          JOIN t_contracts c ON c.id = cb.contract_id
          CROSS JOIN LATERAL (
            WITH be AS (
              SELECT e.id, e.scheduled_date::date AS d, coalesce(e.amount,0) AS amt,
                     coalesce(e.amount_settled,0) AS settled,
                     coalesce(e.status,'scheduled') AS st,
                     coalesce(e.version,1) AS ver,
                     (coalesce(e.status,'scheduled') = ANY(v_open)) AS is_open
                FROM t_contract_events e
               WHERE e.contract_id = c.id AND e.event_type = 'billing'
            ),
            agg AS (
              SELECT count(*)::int AS n, min(d) AS d0, max(d) AS d1,
                     coalesce(sum(amt),0) AS total,
                     coalesce(sum(amt) FILTER (WHERE st='paid'),0) AS paid,
                     -- Owed now: open AND past its due date.
                     coalesce(sum(greatest(0, amt - settled)) FILTER (WHERE is_open AND d <= v_today),0) AS due,
                     -- Not yet due: open AND still ahead.
                     coalesce(sum(greatest(0, amt - settled)) FILTER (WHERE is_open AND d >  v_today),0) AS future,
                     -- Written off: terminal, not paid. Reported so the money is
                     -- visible as a decision rather than just missing.
                     coalesce(sum(amt) FILTER (WHERE NOT is_open AND st <> 'paid'),0) AS written_off
                FROM be
            ),
            cel AS (
              SELECT coalesce(jsonb_object_agg(k,val),'{}'::jsonb) AS cells FROM (
                SELECT to_char(d,'YYYY-MM') AS k,
                       jsonb_build_object(
                         'amount', sum(amt),
                         'paid',   sum(settled),
                         'count',  count(*),
                         'status', coalesce(
                           (array_agg(st ORDER BY is_open DESC, d))[1], 'scheduled'),
                         'is_open', bool_or(is_open),
                         'is_past', min(d) <= v_today,
                         'events', jsonb_agg(jsonb_build_object(
                             'id', id, 'version', ver, 'status', st,
                             'amount', amt, 'settled', settled, 'date', d
                           ) ORDER BY d)
                       ) AS val
                  FROM be
                 WHERE d >= v_fy AND d < (v_fy + interval '12 months')::date
                 GROUP BY 1
              ) z
            ),
            byd AS (
              SELECT coalesce(sum(amt),0) AS amt, count(*)::int AS n
                FROM be WHERE d < v_fy OR d >= (v_fy + interval '12 months')::date
            )
            SELECT agg.n AS instalments, agg.total AS scheduled_total, agg.paid AS paid_total,
                   agg.due AS due_total, agg.future AS future_total,
                   agg.written_off AS written_off_total,
                   byd.amt AS beyond_total, byd.n AS beyond_count, cel.cells AS cells,
                   CASE WHEN agg.n IS NULL OR agg.n = 0 THEN 'none'
                        WHEN agg.n = 1 THEN 'yearly'
                        WHEN (agg.d1-agg.d0)::numeric/(agg.n-1) <= 45  THEN 'monthly'
                        WHEN (agg.d1-agg.d0)::numeric/(agg.n-1) <= 135 THEN 'quarterly'
                        WHEN (agg.d1-agg.d0)::numeric/(agg.n-1) <= 250 THEN 'halfyearly'
                        ELSE 'yearly' END AS plan
              FROM agg, cel, byd
          ) ev
         WHERE cb.source_block_id = p_block AND c.tenant_id = p_tenant
           AND coalesce(c.is_live, true) = p_is_live AND c.status = 'active'
      ) m
  ) s;

  RETURN jsonb_build_object('fy_start', v_fy, 'fy_end', (v_fy + interval '12 months - 1 day')::date,
    'today', v_today, 'months', coalesce(v_months,'[]'::jsonb), 'rows', v_rows);
END
$fn$;
