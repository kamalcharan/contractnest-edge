-- ============================================================================
-- 060_gs_dues_matrix.sql — dues matrix read model for the Group Sessions dashboard
-- ============================================================================
-- Powers Operations → Group Sessions → Dues: one row per active contract, one
-- column per month of the financial year, showing what each instalment is worth
-- and whether it has been paid.
--
-- READ-ONLY. Creates one new function and touches nothing that already exists.
--
-- WHY A NEW RPC RATHER THAN REUSING gs_dash_roster
-- ------------------------------------------------
-- gs_dash_roster answers "who is in this group and did they turn up". It carries
-- a single boolean `dues_pending`. The dues matrix is a different question — the
-- month-by-month money grid — and needs the whole billing-event ledger per
-- member, so it gets its own read model rather than bloating the roster payload
-- that every drill-down already fetches.
--
-- ONE ROW PER CONTRACT, NOT PER CONTACT
-- -------------------------------------
-- Every active contract carrying this block (t_contract_blocks.source_block_id).
--
-- This deliberately differs from gs_dash_roster, which uses
-- DISTINCT ON (buyer_id). That is right for a roster — "who is in the room" is
-- a question about people. It is wrong for money: a contact legitimately holds
-- TWO active contracts at renewal, the outgoing one ending 31 Mar and the
-- incoming one starting 1 Apr, and collapsing to one row silently discards a
-- whole year of dues. Contract granularity also matches how Finance
-- (get_tenant_receivables) groups, so the two surfaces count the same things.
--
-- in_window says whether a contract has any instalment inside the 12-month
-- view. A renewal signed for next year is active but contributes nothing to
-- this year's position; it is returned flagged rather than filtered away, so
-- the caller can account for it instead of wondering where it went.
--
-- THE FINANCIAL-YEAR WINDOW
-- -------------------------
-- Columns run April → March. The window is derived from the earliest billing
-- event across the roster (so it follows the data rather than the wall clock),
-- and can be pinned by the caller via p_fy_start.
--
-- Mid-year joiners keep their OWN schedule — a member who joined in July simply
-- has empty cells before July, and any instalment falling past the window's
-- March is reported in `beyond_total` / `beyond_count` rather than silently
-- dropped. A grid that quietly loses a member's last two instalments would be
-- worse than no grid at all.
--
-- "TODAY" IS IST
-- --------------
-- (now() at time zone 'Asia/Kolkata')::date, never bare current_date — same
-- correction as migration 048. Between 00:00 and 05:30 IST the database's own
-- date is still yesterday, which would mark a due instalment as "future".
-- ============================================================================

CREATE OR REPLACE FUNCTION gs_dues_matrix(
  p_tenant   uuid,
  p_block    uuid,
  p_is_live  boolean,
  p_fy_start date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today  date := (now() at time zone 'Asia/Kolkata')::date;
  v_fy     date;
  v_seed   date;
  v_months jsonb;
  v_rows   jsonb;
BEGIN
  -- ── Resolve the 12-month window ──────────────────────────────────────────
  IF p_fy_start IS NOT NULL THEN
    v_fy := date_trunc('month', p_fy_start)::date;
  ELSE
    SELECT min(e.scheduled_date)::date
      INTO v_seed
      FROM t_contract_blocks cb
      JOIN t_contracts c ON c.id = cb.contract_id
      JOIN t_contract_events e ON e.contract_id = c.id AND e.event_type = 'billing'
     WHERE cb.source_block_id = p_block
       AND c.tenant_id = p_tenant
       AND coalesce(c.is_live, true) = p_is_live
       AND c.status = 'active';

    v_seed := coalesce(v_seed, v_today);
    -- April–March: a January date belongs to the FY that opened last April.
    v_fy := make_date(
      extract(year from v_seed)::int - (CASE WHEN extract(month from v_seed) < 4 THEN 1 ELSE 0 END),
      4, 1
    );
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
           'key',   to_char(m, 'YYYY-MM'),
           'label', to_char(m, 'Mon'),
           'year',  extract(year from m)::int,
           'is_past', (m + interval '1 month - 1 day')::date < v_today
         ) ORDER BY m)
    INTO v_months
    FROM generate_series(v_fy, v_fy + interval '11 months', interval '1 month') AS m;

  -- ── One row per CONTRACT (see header) ────────────────────────────────────
  SELECT coalesce(jsonb_agg(r ORDER BY r->>'name', r->>'start_date'), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT jsonb_build_object(
               'contact_id',      m.buyer_id,
               'name',            m.buyer_name,
               'contract_id',     m.contract_id,
               'contract_number', m.contract_number,
               'contract_name',   m.contract_name,
               'start_date',      m.start_date,
               'end_date',        m.end_date,
               'currency',        m.currency,
               'plan',            m.plan,
               'plan_source',     m.plan_source,
               'instalments',     m.instalments,
               'contract_value',  m.contract_value,
               'discount',        m.discount,
               'net',             m.net,
               'scheduled_total', m.scheduled_total,
               'paid_total',      m.paid_total,
               'due_total',       m.due_total,
               'future_total',    m.future_total,
               'beyond_total',    m.beyond_total,
               'beyond_count',    m.beyond_count,
               'in_window',       m.in_window,
               'cells',           m.cells
             ) AS r
        FROM (
          SELECT c.buyer_id,
                 c.buyer_name,
                 c.id              AS contract_id,
                 c.contract_number,
                 c.name            AS contract_name,
                 c.start_date,
                 c.end_date,
                 -- Currency is the CONTRACT's, carried per row rather than
                 -- assumed for the tenant: t_contracts.currency is per contract
                 -- and the UI must not print ₹ against a contract booked in
                 -- anything else.
                 coalesce(c.currency, 'INR')                   AS currency,
                 coalesce(c.total_value, 0)                    AS contract_value,
                 coalesce(c.discount_total, 0)                 AS discount,
                 coalesce(c.grand_total, c.total_value, 0)     AS net,
                 ev.instalments,
                 -- Stored plan wins; spacing is only the fallback. Since 062
                 -- keeps every receipt as it was made, a member who changed
                 -- plan mid-year has receipts in the OLD cadence, so spacing
                 -- reports the old plan (or, for a fully-paid yearly member
                 -- with no forward instalment, nothing usable at all).
                 coalesce(nullif(c.metadata->>'billing_plan',''), ev.plan) AS plan,
                 CASE WHEN nullif(c.metadata->>'billing_plan','') IS NOT NULL
                      THEN 'recorded' ELSE 'derived' END AS plan_source,
                 ev.scheduled_total,
                 ev.paid_total,
                 ev.due_total,
                 ev.future_total,
                 ev.beyond_total,
                 ev.beyond_count,
                 ev.cells,
                 (ev.cells <> '{}'::jsonb) AS in_window
            FROM t_contract_blocks cb
            JOIN t_contracts c ON c.id = cb.contract_id
            CROSS JOIN LATERAL (
              -- ── OPEN AMOUNT: the SAME rule get_tenant_receivables applies ──
            -- Finance and this grid must never disagree about what is owed, so
            -- the arithmetic is deliberately identical rather than merely
            -- similar:
            --   unsettled   = amount - amount_settled (cancelled / skipped /
            --                 waived count as nothing owed)
            --   unallocated = invoice cash received that has NOT been posted
            --                 against any instalment
            --   open        = unsettled, less the unallocated cash applied
            --                 FIFO by due date
            -- The unallocated term is what a naive "status <> paid" rule misses:
            -- money can land on the contract-level invoice without ever being
            -- attributed to an instalment, and it is still paid.
            WITH be AS (
              SELECT e.id, e.scheduled_date::date AS d,
                     coalesce(e.amount,0) AS amt,
                     coalesce(e.amount_settled,0) AS settled,
                     coalesce(e.status,'scheduled') AS st,
                     CASE WHEN coalesce(e.status,'') IN ('cancelled','skipped','waived') THEN 0
                          ELSE greatest(0, coalesce(e.amount,0) - coalesce(e.amount_settled,0)) END AS unsettled
                FROM t_contract_events e
               WHERE e.contract_id = c.id AND e.event_type='billing'
                 AND coalesce(e.is_active,true)
            ),
            unalloc AS (
              SELECT greatest(0,
                       coalesce((SELECT sum(i.amount_paid) FROM t_invoices i
                                  WHERE i.contract_id=c.id AND coalesce(i.is_live,true)=p_is_live
                                    AND coalesce(i.is_active,true) AND coalesce(i.status,'') <> 'draft'),0)
                     - coalesce((SELECT sum(x.settled) FROM be x),0)) AS u
            ),
            fifo AS (
              SELECT be.*,
                     coalesce(sum(be.unsettled) OVER (ORDER BY be.d, be.id
                              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS cum_before
                FROM be
            ),
            calc AS (
              SELECT f.*, u.u AS unallocated,
                     greatest(0, f.unsettled - greatest(0, u.u - f.cum_before)) AS open_amt
                FROM fifo f CROSS JOIN unalloc u
            ),
            agg AS (
              SELECT count(*)::int AS n, min(d) AS d0, max(d) AS d1,
                     coalesce(sum(amt),0) AS total,
                     coalesce(sum(amt - open_amt),0) AS paid,
                     coalesce(sum(open_amt) FILTER (WHERE d <= v_today),0) AS due,
                     coalesce(sum(open_amt) FILTER (WHERE d >  v_today),0) AS future
                FROM calc),
            cel AS (
              SELECT coalesce(jsonb_object_agg(k,val),'{}'::jsonb) AS cells FROM (
                SELECT to_char(d,'YYYY-MM') AS k,
                       jsonb_build_object(
                         'amount', sum(amt), 'paid', sum(amt - open_amt), 'count', count(*),
                         'status', CASE WHEN sum(open_amt) = 0        THEN 'paid'
                                        WHEN sum(open_amt) < sum(amt) THEN 'partial'
                                        WHEN min(d) <= v_today        THEN 'due'
                                        ELSE 'future' END) AS val
                  FROM calc WHERE d >= v_fy AND d < (v_fy + interval '12 months')::date
                 GROUP BY 1) z),
            byd AS (
              SELECT coalesce(sum(amt),0) AS amt, count(*)::int AS n
                FROM calc WHERE d < v_fy OR d >= (v_fy + interval '12 months')::date)
            SELECT agg.n AS instalments, agg.total AS scheduled_total, agg.paid AS paid_total,
                   agg.due AS due_total, agg.future AS future_total,
                   byd.amt AS beyond_total, byd.n AS beyond_count, cel.cells AS cells,
                   CASE WHEN agg.n IS NULL OR agg.n = 0 THEN 'none'
                        WHEN agg.n = 1 THEN 'yearly'
                        WHEN (agg.d1-agg.d0)::numeric/(agg.n-1) <= 45  THEN 'monthly'
                        WHEN (agg.d1-agg.d0)::numeric/(agg.n-1) <= 135 THEN 'quarterly'
                        WHEN (agg.d1-agg.d0)::numeric/(agg.n-1) <= 250 THEN 'halfyearly'
                        ELSE 'yearly' END AS plan
              FROM agg, cel, byd
            ) ev
           WHERE cb.source_block_id = p_block
             AND c.tenant_id = p_tenant
             AND coalesce(c.is_live, true) = p_is_live
             AND c.status = 'active'
        ) m
    ) s;

  RETURN jsonb_build_object(
    'fy_start', v_fy,
    'fy_end',   (v_fy + interval '12 months - 1 day')::date,
    'today',    v_today,
    'months',   coalesce(v_months, '[]'::jsonb),
    'rows',     v_rows
  );
END
$$;

COMMENT ON FUNCTION gs_dues_matrix(uuid, uuid, boolean, date) IS
  'Dues matrix for a group-session block: per member, per month of the April-March '
  'financial year, instalment amount + paid/due/future status. Read-only. '
  'One row per active contract carrying the block - NOT per contact, since a '
  'contact holds two during a renewal overlap. Instalments outside the window '
  'are reported in beyond_total/beyond_count and contracts with nothing in it '
  'are flagged in_window=false; neither is ever dropped.';

GRANT EXECUTE ON FUNCTION gs_dues_matrix(uuid, uuid, boolean, date) TO service_role;
