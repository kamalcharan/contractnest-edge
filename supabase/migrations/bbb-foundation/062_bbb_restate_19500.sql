-- ============================================================================
-- 062_bbb_restate_19500.sql — BBB fee restructure: net-only 18,000 -> 19,500 gross
-- ============================================================================
-- ⚠️ ALREADY APPLIED TO LIVE on 6 Aug 2026. Source of record. DO NOT RE-RUN —
--    it is not idempotent: a second run would delete the rebuilt unpaid tail
--    and re-insert it, which is harmless in outcome but pointless, and the
--    receipt-alignment guard would then be checking against already-restated
--    data rather than the original.
--
-- WHAT THIS FIXES
-- ---------------
-- BBB's circular prices 26 meetings at 750 = 19,500 list, with a discount that
-- normalises every payment frequency to the same net. The contracts were booked
-- at the NET as if it were the list price: total_value = grand_total = 18,000,
-- discount_type/value/total all NULL. The 19,500 gross and the concession were
-- invisible in the system, and the instalments did not carry the uplift the
-- circular describes.
--
--   Plan         Instalments                              Sum      Discount  Gross
--   Monthly      1500 x10, 2250 Oct, 2250 Dec             19,500   0         19,500
--   Quarterly    4500 Apr, 4500 Jul, 5000 Oct, 5125 Feb   19,125   375       19,500
--   Half-yearly  9000 Apr, 9750 Oct                       18,750   750       19,500
--   Yearly       18,000 Apr                               18,000   1,500     19,500
--
-- The 5000/5125 split for quarterly Q3/Q4 is deliberately round rather than
-- 5062.50 twice, because members sometimes pay cash.
--
-- SCOPE — 43 of 49 contracts
-- --------------------------
--   23 monthly · 10 quarterly · 7 half-yearly · 3 yearly
--   EXCLUDED, on the owner's instruction:
--     CN-1024 Narendra (Patron), CN-1026 Nishikant, CN-1047 Jagannadha
--       (Bhushana) — "leave it", no plan assigned. Untouched at 18,000.
--     CN-1045 Ajay, CN-1046 Balaji, CN-1049 Pavan — mid-year joiners whose
--       pro-rata basis is still with the client. Untouched at 13,500 / 13,500 /
--       12,000 as left by migration 061.
--
-- THE INVARIANT: NO RECEIPTED RUPEE MOVES
-- ---------------------------------------
-- Events with status='paid' are never touched — not their amount, date, status
-- or billing_cycle_label. Only the unpaid tail is deleted and rebuilt, and the
-- rebuild skips whatever prefix of the new schedule the receipts already cover.
-- Verified before writing that every one of the 43 members' receipted total
-- lands exactly on an instalment boundary of their new plan; the migration
-- re-checks that and aborts rather than stranding a part-paid instalment.
--
-- A consequence worth knowing: a member who moved plan keeps the receipts they
-- actually made. A half-yearly member who paid two 4,500 quarterly instalments
-- in April and June shows exactly that, then a 9,750 half-yearly instalment in
-- October. That is the truth of what happened, and it is why paid rows keep
-- their original billing_cycle_label.
--
-- SIDE EFFECT: quarterly dates come off the day-count drift
-- --------------------------------------------------------
-- The rebuilt quarterly tail lands on 1 Oct and 1 Feb instead of the drifted
-- 28 Sep / 27 Dec the derivation engine produced. This is a DATA fix for BBB
-- only — the engine still generates drifted dates for every new contract on
-- every tenant (see CLAUDE.md).
--
-- TWO FAILED ATTEMPTS BEFORE THIS ONE, both caught by their own guards:
--   1. discount_type='fixed' violated t_contracts_discount_type_check, which
--      allows only 'percent' | 'amount'. Whole DO block rolled back.
--   2. block_id for the new rows was read from a surviving event AFTER the
--      delete. A member who has paid NOTHING has every event deleted, so the
--      lookup found no row and silently inserted no instalments for them —
--      CN-1014 Sonali. Only the instalments-vs-grand_total post-check caught
--      it. The template is now snapshotted into _ctx BEFORE the delete.
--   The lesson both times: assert, never assume the write landed.
--
-- RESULT (verified live, all 49 contracts)
--   gross 931,500 · discount 13,500 · net 918,000 · instalments 918,000
--   receipted 313,500 — UNCHANGED · in arrears 102,000 · not yet due 502,500
--   313,500 + 102,000 + 502,500 = 918,000 ✓
--   Zero contracts where instalments <> grand_total; zero invoice mismatches.
--   73 uplift instalments created (2250 / 5000 / 5125 / 9750).
--
-- Backups from migration 061 (bak_20260806_bbb_*) still hold the pre-19,500
-- row images, since 061 ran earlier the same day and nothing else wrote in
-- between. Rollback notes are at the foot of 061.
-- ============================================================================

DO $mig$
DECLARE
  v_tenant uuid := 'dd194710-92b4-4110-80eb-0b492a0d2c1f';
  v_today  date := (now() at time zone 'Asia/Kolkata')::date;
  v_bad int; v_paid_before numeric; v_paid_after numeric; v_ins int; v_del int;
BEGIN
  SELECT coalesce(sum(e.amount) FILTER (WHERE e.status='paid'),0) INTO v_paid_before
    FROM t_contract_events e JOIN t_contracts c ON c.id=e.contract_id
   WHERE c.tenant_id=v_tenant AND c.is_live AND c.status='active' AND e.event_type='billing';

  CREATE TEMP TABLE _plan(cn text primary key, p text, disc numeric) ON COMMIT DROP;
  INSERT INTO _plan VALUES
   ('CN-1001','m',0),('CN-1002','m',0),('CN-1004','m',0),('CN-1010','m',0),('CN-1012','m',0),
   ('CN-1014','m',0),('CN-1018','m',0),('CN-1019','m',0),('CN-1020','m',0),('CN-1022','m',0),
   ('CN-1025','m',0),('CN-1027','m',0),('CN-1028','m',0),('CN-1030','m',0),('CN-1031','m',0),
   ('CN-1032','m',0),('CN-1034','m',0),('CN-1037','m',0),('CN-1038','m',0),('CN-1039','m',0),
   ('CN-1043','m',0),('CN-1044','m',0),('CN-1048','m',0),
   ('CN-1003','q',375),('CN-1005','q',375),('CN-1007','q',375),('CN-1009','q',375),('CN-1011','q',375),
   ('CN-1016','q',375),('CN-1017','q',375),('CN-1021','q',375),('CN-1023','q',375),('CN-1036','q',375),
   ('CN-1006','h',750),('CN-1008','h',750),('CN-1015','h',750),('CN-1029','h',750),
   ('CN-1035','h',750),('CN-1041','h',750),('CN-1042','h',750),
   ('CN-1013','y',1500),('CN-1033','y',1500),('CN-1040','y',1500);

  CREATE TEMP TABLE _sched(p text, seq int, d date, amt numeric, lbl text) ON COMMIT DROP;
  INSERT INTO _sched VALUES
   ('m',1,'2026-04-01',1500,'Monthly'),('m',2,'2026-05-01',1500,'Monthly'),('m',3,'2026-06-01',1500,'Monthly'),
   ('m',4,'2026-07-01',1500,'Monthly'),('m',5,'2026-08-01',1500,'Monthly'),('m',6,'2026-09-01',1500,'Monthly'),
   ('m',7,'2026-10-01',2250,'Monthly'),('m',8,'2026-11-01',1500,'Monthly'),('m',9,'2026-12-01',2250,'Monthly'),
   ('m',10,'2027-01-01',1500,'Monthly'),('m',11,'2027-02-01',1500,'Monthly'),('m',12,'2027-03-01',1500,'Monthly'),
   ('q',1,'2026-04-01',4500,'Quarterly'),('q',2,'2026-07-01',4500,'Quarterly'),
   ('q',3,'2026-10-01',5000,'Quarterly'),('q',4,'2027-02-01',5125,'Quarterly'),
   ('h',1,'2026-04-01',9000,'Half-yearly'),('h',2,'2026-10-01',9750,'Half-yearly'),
   ('y',1,'2026-04-01',18000,'Yearly');

  -- Template + receipts snapshotted BEFORE the delete. Reading them afterwards
  -- is the trap: a member who has paid nothing has every event deleted, so a
  -- post-delete lookup finds no row to copy block_id from and silently inserts
  -- nothing for them.
  CREATE TEMP TABLE _ctx AS
  SELECT c.id contract_id, c.contract_number cn, pl.p, pl.disc,
         coalesce(c.currency,'INR') currency,
         coalesce(sum(e.amount) FILTER (WHERE e.status='paid'),0) paid_sum,
         (array_agg(e.block_id    ORDER BY e.scheduled_date))[1] block_id,
         (array_agg(e.block_name  ORDER BY e.scheduled_date))[1] block_name,
         (array_agg(e.category_id ORDER BY e.scheduled_date))[1] category_id
    FROM _plan pl
    JOIN t_contracts c ON c.contract_number=pl.cn AND c.tenant_id=v_tenant AND c.is_live AND c.status='active'
    JOIN t_contract_events e ON e.contract_id=c.id AND e.event_type='billing'
   GROUP BY c.id, c.contract_number, pl.p, pl.disc, c.currency;

  IF (SELECT count(*) FROM _ctx) <> 43 THEN
    RAISE EXCEPTION 'ABORT: context resolved % contracts, expected 43', (SELECT count(*) FROM _ctx);
  END IF;
  IF EXISTS (SELECT 1 FROM _ctx WHERE block_id IS NULL OR block_name IS NULL) THEN
    RAISE EXCEPTION 'ABORT: a contract has no billing-event template to copy from';
  END IF;

  SELECT count(*) INTO v_bad FROM _ctx x
   WHERE x.paid_sum <> 0
     AND NOT EXISTS (SELECT 1 FROM (SELECT p, sum(amt) OVER (PARTITION BY p ORDER BY seq) cum FROM _sched) s
                      WHERE s.p=x.p AND s.cum=x.paid_sum);
  IF v_bad > 0 THEN RAISE EXCEPTION 'ABORT: % contract(s) have receipts off an instalment boundary', v_bad; END IF;

  DELETE FROM t_contract_events e USING _ctx x
   WHERE e.contract_id=x.contract_id AND e.event_type='billing' AND e.status <> 'paid';
  GET DIAGNOSTICS v_del = ROW_COUNT;

  INSERT INTO t_contract_events (
    tenant_id, contract_id, block_id, block_name, category_id, event_type,
    billing_sub_type, billing_cycle_label, sequence_number, total_occurrences,
    scheduled_date, original_date, amount, currency, status, is_live, is_active,
    created_at, updated_at)
  SELECT v_tenant, x.contract_id, x.block_id, x.block_name, x.category_id, 'billing',
         'recurring', s.lbl||' '||s.seq||'/'||tot.n, s.seq, tot.n,
         s.d::timestamptz, s.d::timestamptz, s.amt, x.currency,
         CASE WHEN s.d <= v_today THEN 'overdue' ELSE 'scheduled' END,
         true, true, now(), now()
    FROM _ctx x
    JOIN _sched s ON s.p=x.p
    CROSS JOIN LATERAL (SELECT count(*)::int n FROM _sched z WHERE z.p=x.p) tot
   WHERE (SELECT sum(z.amt) FROM _sched z WHERE z.p=x.p AND z.seq <= s.seq) > x.paid_sum;
  GET DIAGNOSTICS v_ins = ROW_COUNT;

  -- discount_type is constrained to 'percent' | 'amount'. Monthly carries no
  -- concession at all, so it stays NULL rather than being recorded as a zero
  -- discount — "no discount" and "a discount of nothing" are different claims.
  UPDATE t_contracts c
     SET total_value = 19500,
         discount_type  = CASE WHEN x.disc > 0 THEN 'amount' ELSE NULL END,
         discount_value = CASE WHEN x.disc > 0 THEN x.disc  ELSE NULL END,
         discount_total = CASE WHEN x.disc > 0 THEN x.disc  ELSE NULL END,
         grand_total = 19500 - x.disc, updated_at = now()
    FROM _ctx x WHERE c.id = x.contract_id;

  UPDATE t_invoices i
     SET amount = c.grand_total, total_amount = c.grand_total,
         balance = c.grand_total - coalesce(i.amount_paid,0),
         status = CASE WHEN coalesce(i.amount_paid,0) >= c.grand_total THEN 'paid'
                       WHEN coalesce(i.amount_paid,0) > 0 THEN 'partially_paid'
                       ELSE 'unpaid' END,
         updated_at = now()
    FROM t_contracts c, _ctx x
   WHERE c.id=i.contract_id AND c.id=x.contract_id AND i.is_live;

  WITH ord AS (
    SELECT e.id, row_number() OVER (PARTITION BY e.contract_id ORDER BY e.scheduled_date) rn,
           count(*) OVER (PARTITION BY e.contract_id) tot
      FROM t_contract_events e JOIN _ctx x ON x.contract_id=e.contract_id
     WHERE e.event_type='billing')
  UPDATE t_contract_events e SET sequence_number = ord.rn, total_occurrences = ord.tot
    FROM ord WHERE ord.id = e.id;

  SELECT coalesce(sum(e.amount) FILTER (WHERE e.status='paid'),0) INTO v_paid_after
    FROM t_contract_events e JOIN t_contracts c ON c.id=e.contract_id
   WHERE c.tenant_id=v_tenant AND c.is_live AND c.status='active' AND e.event_type='billing';
  IF v_paid_after <> v_paid_before THEN
    RAISE EXCEPTION 'POST-CHECK FAILED: receipted total moved % -> %', v_paid_before, v_paid_after;
  END IF;

  SELECT count(*) INTO v_bad FROM _ctx x JOIN t_contracts c ON c.id=x.contract_id
    CROSS JOIN LATERAL (SELECT sum(e.amount) s FROM t_contract_events e
                         WHERE e.contract_id=c.id AND e.event_type='billing') t
   WHERE t.s IS DISTINCT FROM c.grand_total;
  IF v_bad > 0 THEN RAISE EXCEPTION 'POST-CHECK FAILED: % contract(s) where instalments <> grand_total', v_bad; END IF;

  IF EXISTS (SELECT 1 FROM t_contract_events e JOIN t_contracts c ON c.id=e.contract_id
              WHERE c.tenant_id=v_tenant AND c.is_live AND c.status='active'
                AND e.event_type='billing' AND e.scheduled_date::date > date '2027-03-31') THEN
    RAISE EXCEPTION 'POST-CHECK FAILED: an instalment falls after 31 Mar 2027';
  END IF;

  RAISE NOTICE 'deleted % unpaid, inserted %; receipts unchanged at %', v_del, v_ins, v_paid_after;
END
$mig$;
