-- ============================================================================
-- 063_bbb_record_billing_plan.sql — record each contract's payment frequency
-- ============================================================================
-- ⚠️ ALREADY APPLIED TO LIVE on 6 Aug 2026. Source of record.
--
-- WHY
-- ---
-- The Dues grid derived a contract's plan from the spacing of its instalments.
-- That worked until migration 062, which deliberately leaves every receipt
-- exactly as it was made. Consequences:
--
--   · A half-yearly member's history is the two 4,500 QUARTERLY instalments
--     they actually paid in April and June, then one 9,750 half-yearly
--     instalment in October. Average spacing says "quarterly".
--   · A fully-paid yearly member has four paid quarterly receipts and NO
--     forward instalment at all. Spacing says "quarterly" too.
--
-- So the grid read 24 monthly / 25 quarterly instead of 23 / 10 / 7 / 3. The
-- money was right throughout; only the label was wrong. Spacing cannot recover
-- this — the information genuinely is not in the events — so it has to be
-- stored.
--
-- WHY NOT billing_cycle_type
-- --------------------------
-- Because it does not mean what the name suggests. BillingCycleStep.tsx defines
-- it as `'unified' | 'mixed' | null` — unified billing versus a separate cycle
-- per block. 'mixed' is the CORRECT value for these contracts, and the Contract
-- Wizard and the contract document both read it that way. Writing 'monthly'
-- there would corrupt a live field to fix a label. (Some older rows elsewhere
-- do hold frequency-looking values, which is what made this trap look
-- inviting.)
--
-- metadata was empty ({}) on all 49 BBB contracts, so metadata.billing_plan is
-- an additive, uncontended home.
--
-- WHAT
-- ----
-- 1. Stamps metadata.billing_plan on the 43 restated contracts:
--    23 monthly · 10 quarterly · 7 halfyearly · 3 yearly.
--    The six excluded contracts are deliberately NOT stamped — the three
--    no-plan members and the three mid-year joiners, whose plans are still
--    open questions. They keep falling back to derivation, and now say so.
-- 2. gs_dues_matrix prefers the stored plan and exposes plan_source
--    ('recorded' | 'derived') so a caller can tell a stated plan from a guess.
--    The UI renders a derived plan with a trailing '?' and a tooltip.
--
-- Post-checks assert 43 rows were stamped AND that billing_cycle_type is still
-- 'mixed' on every contract — the specific damage this migration is designed
-- not to do.
--
-- VERIFIED LIVE
--   recorded: 23 monthly, 10 quarterly, 7 halfyearly, 3 yearly  (= 43)
--   derived:  CN-1045, CN-1046 (monthly) · CN-1024, CN-1026, CN-1047, CN-1049
--             (quarterly)                                       (= 6)
-- ============================================================================

DO $mig$
DECLARE v_tenant uuid := 'dd194710-92b4-4110-80eb-0b492a0d2c1f'; v_n int;
BEGIN
  CREATE TEMP TABLE _pp(cn text primary key, plan text) ON COMMIT DROP;
  INSERT INTO _pp VALUES
   ('CN-1001','monthly'),('CN-1002','monthly'),('CN-1004','monthly'),('CN-1010','monthly'),
   ('CN-1012','monthly'),('CN-1014','monthly'),('CN-1018','monthly'),('CN-1019','monthly'),
   ('CN-1020','monthly'),('CN-1022','monthly'),('CN-1025','monthly'),('CN-1027','monthly'),
   ('CN-1028','monthly'),('CN-1030','monthly'),('CN-1031','monthly'),('CN-1032','monthly'),
   ('CN-1034','monthly'),('CN-1037','monthly'),('CN-1038','monthly'),('CN-1039','monthly'),
   ('CN-1043','monthly'),('CN-1044','monthly'),('CN-1048','monthly'),
   ('CN-1003','quarterly'),('CN-1005','quarterly'),('CN-1007','quarterly'),('CN-1009','quarterly'),
   ('CN-1011','quarterly'),('CN-1016','quarterly'),('CN-1017','quarterly'),('CN-1021','quarterly'),
   ('CN-1023','quarterly'),('CN-1036','quarterly'),
   ('CN-1006','halfyearly'),('CN-1008','halfyearly'),('CN-1015','halfyearly'),('CN-1029','halfyearly'),
   ('CN-1035','halfyearly'),('CN-1041','halfyearly'),('CN-1042','halfyearly'),
   ('CN-1013','yearly'),('CN-1033','yearly'),('CN-1040','yearly');

  UPDATE t_contracts c
     SET metadata = coalesce(c.metadata,'{}'::jsonb) || jsonb_build_object('billing_plan', pp.plan),
         updated_at = now()
    FROM _pp pp
   WHERE c.contract_number = pp.cn AND c.tenant_id = v_tenant AND c.is_live AND c.status='active';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 43 THEN RAISE EXCEPTION 'POST-CHECK FAILED: stamped % contracts, expected 43', v_n; END IF;

  IF EXISTS (SELECT 1 FROM t_contracts WHERE tenant_id=v_tenant AND is_live AND status='active'
              AND billing_cycle_type IS DISTINCT FROM 'mixed') THEN
    RAISE EXCEPTION 'POST-CHECK FAILED: billing_cycle_type was altered';
  END IF;
END $mig$;

-- The gs_dues_matrix change that pairs with this lives in
-- 060_gs_dues_matrix.sql, which has been updated in place (it is a
-- CREATE OR REPLACE and 060 is the single source of record for that function).
-- Re-apply 060 to pick up the plan / plan_source resolution.
