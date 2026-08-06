-- ============================================================================
-- 061_bbb_contract_end_31mar2027.sql — every BBB contract ends 31 Mar 2027
-- ============================================================================
-- ⚠️ ALREADY APPLIED TO LIVE on 6 Aug 2026. This file is the source of record.
--    DO NOT RE-RUN. It is not idempotent in the sense that matters: re-running
--    would re-snapshot into the backup tables (harmless) but the DELETE and
--    UPDATEs are all no-ops second time round, so a re-run is safe but pointless.
--
-- Owner rule: "all contracts end mar 31 2027 ... no contract will go post
-- march 31". Three violations existed:
--
--   46 contracts    end_date 2027-04-01  — one day over, no instalments affected
--   CN-1045 Ajay    end_date 2027-07-15  — 3 instalments in Apr/May/Jun 2027
--   CN-1046 Balaji  end_date 2027-07-11  — 3 instalments in Apr/May/Jun 2027
--   CN-1049 Pavan   end_date 2027-03-31  — already correct, untouched
--
-- WHY TRUNCATE RATHER THAN REPRICE
-- --------------------------------
-- Ajay and Balaji keep the monthly instalments they already have and simply
-- stop at March: 12 x 1,500 becomes 9 x 1,500, and the contract value follows
-- to 13,500. This deliberately does NOT decide the mid-year pro-rata basis,
-- which is still with the client (meetings-remaining x 750 vs months-remaining
-- x 1,500, and the unresolved 25-vs-26 meetings question). It removes
-- instalments that should never have been generated; it does not set a price.
-- If the client later lands on a different pro-rata figure, that is a separate
-- change on top of this one.
--
-- SAFETY
-- ------
-- All six deleted instalments were verified beforehand as status='scheduled',
-- amount_settled=0, invoice_id IS NULL. The DO block re-checks that invariant
-- and RAISEs rather than deleting if any instalment past the cut-off carries
-- money or an invoice — the failure mode being guarded against is destroying a
-- receipt. Two post-checks then assert the rule actually holds, because a
-- migration that silently half-applies is the failure mode this repo has been
-- bitten by before (see 058).
--
-- Full row images of contracts, events and invoices are snapshotted into
-- bak_20260806_bbb_* first, so any part of this is reversible.
--
-- RESULT (verified live)
--   49 / 49 contracts end 2027-03-31 · 0 instalments after that date
--   scheduled 876,000 -> 867,000 (-9,000, exactly the six deleted instalments)
--   receipted 313,500 -> 313,500 (unchanged — no paid money touched)
--   CN-1045 / CN-1046: contract 18,000 -> 13,500, invoice restated to 13,500,
--                      balance 12,000, status partially_paid
--   48 contracts modified, all within tenant BBB; nothing outside it touched.
-- ============================================================================

CREATE TABLE IF NOT EXISTS bak_20260806_bbb_contracts   AS SELECT * FROM t_contracts       WHERE false;
CREATE TABLE IF NOT EXISTS bak_20260806_bbb_events      AS SELECT * FROM t_contract_events WHERE false;
CREATE TABLE IF NOT EXISTS bak_20260806_bbb_invoices    AS SELECT * FROM t_invoices        WHERE false;

INSERT INTO bak_20260806_bbb_contracts
SELECT * FROM t_contracts
 WHERE tenant_id = 'dd194710-92b4-4110-80eb-0b492a0d2c1f' AND is_live AND status = 'active';

INSERT INTO bak_20260806_bbb_events
SELECT e.* FROM t_contract_events e JOIN t_contracts c ON c.id = e.contract_id
 WHERE c.tenant_id = 'dd194710-92b4-4110-80eb-0b492a0d2c1f' AND c.is_live AND c.status = 'active';

INSERT INTO bak_20260806_bbb_invoices
SELECT i.* FROM t_invoices i JOIN t_contracts c ON c.id = i.contract_id
 WHERE c.tenant_id = 'dd194710-92b4-4110-80eb-0b492a0d2c1f' AND i.is_live;

DO $mig$
DECLARE
  v_tenant uuid := 'dd194710-92b4-4110-80eb-0b492a0d2c1f';
  v_cut    date := date '2027-03-31';
  v_unsafe int;
  v_deleted int;
  v_dated  int;
BEGIN
  SELECT count(*) INTO v_unsafe
    FROM t_contract_events e JOIN t_contracts c ON c.id = e.contract_id
   WHERE c.tenant_id = v_tenant AND c.is_live AND c.status = 'active'
     AND e.event_type = 'billing' AND e.scheduled_date::date > v_cut
     AND (e.status = 'paid' OR coalesce(e.amount_settled, 0) > 0 OR e.invoice_id IS NOT NULL);
  IF v_unsafe > 0 THEN
    RAISE EXCEPTION 'ABORT: % instalment(s) after % are paid, settled or invoiced', v_unsafe, v_cut;
  END IF;

  DELETE FROM t_contract_events e
   USING t_contracts c
   WHERE c.id = e.contract_id AND c.tenant_id = v_tenant AND c.is_live AND c.status = 'active'
     AND e.event_type = 'billing' AND e.scheduled_date::date > v_cut;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  UPDATE t_contracts c
     SET total_value = s.total,
         grand_total = s.total - coalesce(c.discount_total, 0),
         updated_at  = now()
    FROM (SELECT e.contract_id, sum(e.amount) total
            FROM t_contract_events e WHERE e.event_type = 'billing' GROUP BY 1) s
   WHERE s.contract_id = c.id AND c.tenant_id = v_tenant AND c.is_live AND c.status = 'active'
     AND c.total_value IS DISTINCT FROM s.total;

  UPDATE t_invoices i
     SET amount       = c.total_value,
         total_amount = c.total_value,
         balance      = c.total_value - coalesce(i.amount_paid, 0),
         status       = CASE WHEN coalesce(i.amount_paid, 0) >= c.total_value THEN 'paid'
                             WHEN coalesce(i.amount_paid, 0) > 0             THEN 'partially_paid'
                             ELSE i.status END,
         updated_at   = now()
    FROM t_contracts c
   WHERE c.id = i.contract_id AND c.tenant_id = v_tenant AND i.is_live
     AND c.is_live AND c.status = 'active'
     AND i.total_amount IS DISTINCT FROM c.total_value;

  UPDATE t_contracts
     SET end_date = v_cut::timestamptz, updated_at = now()
   WHERE tenant_id = v_tenant AND is_live AND status = 'active'
     AND end_date::date <> v_cut;
  GET DIAGNOSTICS v_dated = ROW_COUNT;

  RAISE NOTICE 'deleted % instalment(s); re-dated % contract(s)', v_deleted, v_dated;

  IF EXISTS (SELECT 1 FROM t_contracts
              WHERE tenant_id = v_tenant AND is_live AND status = 'active'
                AND end_date::date <> v_cut) THEN
    RAISE EXCEPTION 'POST-CHECK FAILED: a contract still ends after %', v_cut;
  END IF;
  IF EXISTS (SELECT 1 FROM t_contract_events e JOIN t_contracts c ON c.id = e.contract_id
              WHERE c.tenant_id = v_tenant AND c.is_live AND c.status = 'active'
                AND e.event_type = 'billing' AND e.scheduled_date::date > v_cut) THEN
    RAISE EXCEPTION 'POST-CHECK FAILED: an instalment still falls after %', v_cut;
  END IF;
END
$mig$;

-- ── Rollback, if ever needed ────────────────────────────────────────────────
-- The backup tables hold complete pre-change row images:
--
--   INSERT INTO t_contract_events
--   SELECT * FROM bak_20260806_bbb_events b
--    WHERE NOT EXISTS (SELECT 1 FROM t_contract_events e WHERE e.id = b.id);
--
--   UPDATE t_contracts c SET total_value = b.total_value, grand_total = b.grand_total,
--          end_date = b.end_date
--     FROM bak_20260806_bbb_contracts b WHERE b.id = c.id;
--
--   UPDATE t_invoices i SET amount = b.amount, total_amount = b.total_amount,
--          balance = b.balance, status = b.status
--     FROM bak_20260806_bbb_invoices b WHERE b.id = i.id;
