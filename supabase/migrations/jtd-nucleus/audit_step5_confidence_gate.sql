-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/audit_step5_confidence_gate.sql
-- JTD Nucleus — Step 5 of 6: THE CONFIDENCE GATE (owner-approved plan)
--
-- READ-ONLY. Creates nothing, writes nothing, safe to run any time,
-- as many times as you like, on live or test. This script IS the
-- deliverable of Step 5: confidence comes from a re-runnable audit,
-- not from anyone's word.
--
-- WHAT IT AUDITS: every V2-era contract — defined structurally as any
-- contract that has JOB rows in n_jtd (channel_code IS NULL AND
-- contract_id IS NOT NULL). BBB has none, so BBB is naturally out of
-- scope; no tenant filter is needed or wanted (if a job row ever
-- appeared on another tenant, we WANT it audited).
--
-- RESULT SET 1 — one row per contract, one boolean column per check:
--   chk1_no_legacy       zero t_contract_events rows (a V2 contract
--                        must never have grown legacy events)
--   chk2_computed_null   computed_events consumed (NULL) — nothing
--                        left to double-materialize
--   chk3_sequences       per (block, event type): sequence numbers
--                        contiguous 1..N, count matches the rows' own
--                        total_occurrences, no duplicates
--   chk4_dates_in_term   every job date within [start_date, end_date]
--   chk5_money_gross     Σ payment-job amounts = contract grand_total
--                        = Σ invoice totals (non-cancelled), ±0.01
--   chk6_money_settled   Σ job amount_settled = Σ jtd allocations
--                        = Σ invoice amount_paid, ±0.01
--   chk7_status_honest   'paid' only when covered, 'partial_payment'
--                        only when 0 < settled < amount, 'scheduled'
--                        only when settled = 0
--   chk8_cnak            active contracts carry a t_contract_access
--                        grant (V1 mints at send/activation, so drafts
--                        and pending rows are exempt)
--   chk9_no_msg_leak     no job row shows messenger-machine damage
--                        (error fields, or a message-lifecycle status)
--   chk10_no_cancelled_receipts
--                        no cancelled/reversed receipt exists on the
--                        contract. NOT cosmetic: receipt-cancel is
--                        still V1-only (it reverses t_contract_events,
--                        not jobs) — if this check ever fails, that
--                        contract's job settlement is suspect and the
--                        cancel path must be built for jobs first.
--   verdict              PASS only when every check above is true
--
-- RESULT SET 2 — structural residue across the whole database (must
-- all be zero):
--   orphan jobs (contract gone), allocations aimed at message rows,
--   allocations with no target at all, duplicate job identities,
--   job rows on any tenant other than the known test tenants (signia)
--   — that last one is informational: it lists WHO, so an unexpected
--   tenant with jobs is seen, not assumed.
--
-- HOW TO READ IT: verdict='PASS' on every row of set 1 and zeros on
-- set 2 = the gate is green. Any FAIL: the diag_* columns on that row
-- say which numbers disagreed; fix, then RE-RUN THIS SAME FILE.
-- ═══════════════════════════════════════════════════════════════════

-- ────────────────────────────── RESULT SET 1 ──────────────────────────────
WITH jobs AS (
    SELECT *
    FROM n_jtd
    WHERE channel_code IS NULL
      AND contract_id IS NOT NULL
      AND COALESCE(is_active, true)
),
v2_contracts AS (
    SELECT DISTINCT j.contract_id
    FROM jobs j
),
-- chk3: sequence integrity per (contract, block, event type)
seq_per_block AS (
    SELECT
        j.contract_id,
        j.block_id,
        j.event_type_code,
        COUNT(*)                                   AS n_rows,
        COUNT(DISTINCT j.sequence_number)          AS n_distinct_seq,
        MIN(j.sequence_number)                     AS min_seq,
        MAX(j.sequence_number)                     AS max_seq,
        MAX(j.total_occurrences)                   AS declared_total
    FROM jobs j
    GROUP BY j.contract_id, j.block_id, j.event_type_code
),
seq_ok AS (
    SELECT
        contract_id,
        bool_and(
            n_rows = n_distinct_seq          -- no duplicate sequence numbers
            AND min_seq = 1                  -- starts at 1
            AND max_seq = n_rows             -- contiguous 1..N
            AND (declared_total IS NULL OR declared_total = n_rows)
        ) AS ok
    FROM seq_per_block
    GROUP BY contract_id
),
job_agg AS (
    SELECT
        j.contract_id,
        COUNT(*)                                                        AS jobs_total,
        COUNT(*) FILTER (WHERE j.event_type_code = 'service_visit')     AS jobs_service,
        COUNT(*) FILTER (WHERE j.event_type_code = 'payment')           AS jobs_payment,
        COALESCE(SUM(j.amount) FILTER (WHERE j.event_type_code = 'payment'), 0)         AS pay_sum,
        COALESCE(SUM(j.amount_settled) FILTER (WHERE j.event_type_code = 'payment'), 0) AS settled_sum,
        -- chk7: status honesty (0.005 tolerance, same as the engine)
        bool_and(
            CASE
                WHEN j.event_type_code <> 'payment' THEN true
                WHEN j.status_code = 'paid'
                    THEN COALESCE(j.amount_settled,0) >= COALESCE(j.amount,0) - 0.005
                WHEN j.status_code = 'partial_payment'
                    THEN COALESCE(j.amount_settled,0) > 0.005
                     AND COALESCE(j.amount_settled,0) <  COALESCE(j.amount,0) - 0.005
                WHEN j.status_code IN ('scheduled','due','overdue')
                    THEN COALESCE(j.amount_settled,0) <= 0.005
                ELSE true   -- terminal states (cancelled/bad_debt) judged by hand
            END
        ) AS status_honest,
        -- chk9: messenger-machine damage on a job row
        bool_and(
            j.error_message IS NULL
            AND j.error_code IS NULL
            AND j.status_code NOT IN ('created','queued','sent','delivered','read','failed')
        ) AS no_msg_leak
    FROM jobs j
    GROUP BY j.contract_id
),
date_ok AS (
    SELECT
        j.contract_id,
        bool_and(
            j.scheduled_at::date >= c.start_date::date
            AND (c.end_date IS NULL OR j.scheduled_at::date <= c.end_date::date)
        ) AS ok
    FROM jobs j
    JOIN t_contracts c ON c.id = j.contract_id
    GROUP BY j.contract_id
),
inv_agg AS (
    SELECT
        i.contract_id,
        COALESCE(SUM(i.total_amount) FILTER (WHERE i.status NOT IN ('cancelled')), 0) AS inv_total,
        COALESCE(SUM(i.amount_paid)  FILTER (WHERE i.status NOT IN ('cancelled')), 0) AS inv_paid,
        COUNT(*) FILTER (WHERE i.status = 'cancelled')                                AS inv_cancelled
    FROM t_invoices i
    WHERE i.contract_id IN (SELECT contract_id FROM v2_contracts)
    GROUP BY i.contract_id
),
alloc_agg AS (
    SELECT
        a.contract_id,
        COALESCE(SUM(a.amount) FILTER (WHERE a.jtd_id IS NOT NULL), 0)            AS alloc_jtd_sum,
        COUNT(*)  FILTER (WHERE a.contract_event_id IS NOT NULL)                  AS alloc_legacy_rows
    FROM t_invoice_receipt_allocations a
    WHERE a.contract_id IN (SELECT contract_id FROM v2_contracts)
    GROUP BY a.contract_id
),
-- chk10: any receipt on the contract in a cancelled/reversed state.
-- Column-agnostic on purpose: to_jsonb(r) ->> 'status' returns NULL
-- when the receipts table has no such column (instead of erroring),
-- so this predicate works whatever the schema calls its cancel flag —
-- it matches the common names and stays quiet otherwise.
receipt_agg AS (
    SELECT
        r.contract_id,
        COUNT(*)                    AS receipts,
        COALESCE(SUM(r.amount), 0)  AS receipts_sum,
        COUNT(*) FILTER (
            WHERE lower(COALESCE((to_jsonb(r) ->> 'status'), '')) IN ('cancelled','canceled','reversed','void','voided')
               OR COALESCE((to_jsonb(r) ->> 'is_cancelled')::boolean, false)
        ) AS receipts_cancelled
    FROM t_invoice_receipts r
    WHERE r.contract_id IN (SELECT contract_id FROM v2_contracts)
    GROUP BY r.contract_id
),
legacy_cnt AS (
    SELECT e.contract_id, COUNT(*) AS n
    FROM t_contract_events e
    WHERE e.contract_id IN (SELECT contract_id FROM v2_contracts)
    GROUP BY e.contract_id
),
cnak AS (
    SELECT a.contract_id, COUNT(*) AS grants
    FROM t_contract_access a
    WHERE a.contract_id IN (SELECT contract_id FROM v2_contracts)
    GROUP BY a.contract_id
)
SELECT
    c.contract_number,
    CASE WHEN c.is_live THEN 'live' ELSE 'test' END                       AS env,
    c.status,
    ja.jobs_service,
    ja.jobs_payment,
    -- the checks
    COALESCE(lc.n, 0) = 0                                                 AS chk1_no_legacy,
    c.computed_events IS NULL                                             AS chk2_computed_null,
    COALESCE(so.ok, false)                                                AS chk3_sequences,
    COALESCE(dk.ok, false)                                                AS chk4_dates_in_term,
    (abs(ja.pay_sum - COALESCE(c.grand_total, 0)) <= 0.01
     AND abs(ja.pay_sum - COALESCE(ia.inv_total, 0)) <= 0.01)             AS chk5_money_gross,
    (abs(ja.settled_sum - COALESCE(aa.alloc_jtd_sum, 0)) <= 0.01
     AND abs(ja.settled_sum - COALESCE(ia.inv_paid, 0)) <= 0.01)          AS chk6_money_settled,
    ja.status_honest                                                      AS chk7_status_honest,
    (c.status <> 'active' OR COALESCE(ck.grants, 0) > 0)                  AS chk8_cnak,
    ja.no_msg_leak                                                        AS chk9_no_msg_leak,
    (COALESCE(ra.receipts_cancelled, 0) = 0
     AND COALESCE(ia.inv_cancelled, 0) = 0
     AND COALESCE(aa.alloc_legacy_rows, 0) = 0)                           AS chk10_no_v1_only_paths,
    -- the verdict
    CASE WHEN
        COALESCE(lc.n, 0) = 0
        AND c.computed_events IS NULL
        AND COALESCE(so.ok, false)
        AND COALESCE(dk.ok, false)
        AND abs(ja.pay_sum - COALESCE(c.grand_total, 0)) <= 0.01
        AND abs(ja.pay_sum - COALESCE(ia.inv_total, 0)) <= 0.01
        AND abs(ja.settled_sum - COALESCE(aa.alloc_jtd_sum, 0)) <= 0.01
        AND abs(ja.settled_sum - COALESCE(ia.inv_paid, 0)) <= 0.01
        AND ja.status_honest
        AND (c.status <> 'active' OR COALESCE(ck.grants, 0) > 0)
        AND ja.no_msg_leak
        AND COALESCE(ra.receipts_cancelled, 0) = 0
        AND COALESCE(ia.inv_cancelled, 0) = 0
        AND COALESCE(aa.alloc_legacy_rows, 0) = 0
    THEN 'PASS' ELSE 'FAIL' END                                           AS verdict,
    -- diagnostics (read these only on a FAIL)
    ja.pay_sum::text                                                      AS diag_pay_sum,
    COALESCE(c.grand_total, 0)::text                                      AS diag_grand_total,
    COALESCE(ia.inv_total, 0)::text                                       AS diag_inv_total,
    ja.settled_sum::text                                                  AS diag_settled,
    COALESCE(aa.alloc_jtd_sum, 0)::text                                   AS diag_alloc_jtd,
    COALESCE(ia.inv_paid, 0)::text                                        AS diag_inv_paid,
    COALESCE(ra.receipts_sum, 0)::text                                    AS diag_receipts_sum,
    COALESCE(lc.n, 0)                                                     AS diag_legacy_rows
FROM v2_contracts v
JOIN t_contracts c        ON c.id = v.contract_id
JOIN job_agg ja           ON ja.contract_id = v.contract_id
LEFT JOIN seq_ok so       ON so.contract_id = v.contract_id
LEFT JOIN date_ok dk      ON dk.contract_id = v.contract_id
LEFT JOIN inv_agg ia      ON ia.contract_id = v.contract_id
LEFT JOIN alloc_agg aa    ON aa.contract_id = v.contract_id
LEFT JOIN receipt_agg ra  ON ra.contract_id = v.contract_id
LEFT JOIN legacy_cnt lc   ON lc.contract_id = v.contract_id
LEFT JOIN cnak ck         ON ck.contract_id = v.contract_id
ORDER BY c.contract_number;

-- ────────────────────────────── RESULT SET 2 ──────────────────────────────
-- Structural residue across the WHOLE database. Every count must be 0.
SELECT 'orphan_jobs (contract row gone)' AS residue_check, COUNT(*) AS n
FROM n_jtd j
WHERE j.channel_code IS NULL AND j.contract_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM t_contracts c WHERE c.id = j.contract_id)
UNION ALL
SELECT 'allocations aimed at MESSAGE rows', COUNT(*)
FROM t_invoice_receipt_allocations a
JOIN n_jtd j ON j.id = a.jtd_id
WHERE j.channel_code IS NOT NULL
UNION ALL
SELECT 'allocations with no target at all', COUNT(*)
FROM t_invoice_receipt_allocations a
WHERE a.jtd_id IS NULL AND a.contract_event_id IS NULL
UNION ALL
SELECT 'duplicate job identity (contract+block+type+seq)', COUNT(*)
FROM (
    SELECT contract_id, block_id, event_type_code, sequence_number
    FROM n_jtd
    WHERE channel_code IS NULL AND contract_id IS NOT NULL
      AND COALESCE(is_active, true)
    GROUP BY contract_id, block_id, event_type_code, sequence_number
    HAVING COUNT(*) > 1
) d
UNION ALL
SELECT 'job rows carrying a channel (contradiction)', COUNT(*)
FROM n_jtd
WHERE contract_id IS NOT NULL AND channel_code IS NOT NULL;

-- ────────────────────────────── RESULT SET 3 ──────────────────────────────
-- WHO has jobs — informational, so an unexpected tenant is SEEN.
SELECT t.name AS tenant, j.is_live, COUNT(DISTINCT j.contract_id) AS contracts, COUNT(*) AS job_rows
FROM n_jtd j
JOIN t_tenants t ON t.id = j.tenant_id
WHERE j.channel_code IS NULL AND j.contract_id IS NOT NULL
GROUP BY t.name, j.is_live
ORDER BY t.name;
