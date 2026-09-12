-- ═══════════════════════════════════════════════════════════════════
-- jtd-cutover/audit_dual_read_check.sql — READ-ONLY, re-runnable daily
-- Soak-window watchdog: every migrated contract's events table and jobs
-- table must tell the same story. A DRIFT row means a V1 writer mutated
-- events after the copy (expected until Phase 3 repoints writers) or a
-- V2 writer settled a job (payment on migrated contract) — the verdict
-- names what moved. Baseline 2026-09-01: 23/23 ok.
-- After BBB's Phase 1 the same query covers BBB automatically.
-- ═══════════════════════════════════════════════════════════════════

SELECT c.contract_number AS cn, t.name AS tenant, c.is_live,
       ev.n   AS event_rows,    jb.n   AS job_rows,
       ev.amt AS event_amt,     jb.amt AS job_amt,
       ev.set AS event_settled, jb.set AS job_settled,
       ev.statuses AS event_statuses, jb.statuses AS job_statuses,
       CASE WHEN ev.n <> jb.n THEN 'DRIFT: row count'
            WHEN ev.amt <> jb.amt THEN 'DRIFT: amounts'
            WHEN ev.set <> jb.set THEN 'DRIFT: settled'
            WHEN ev.statuses <> jb.statuses THEN 'DRIFT: statuses'
            ELSE 'ok' END AS verdict
FROM t_contracts c
JOIN t_tenants t ON t.id = c.tenant_id
JOIN LATERAL (
    SELECT count(*) n, COALESCE(SUM(e.amount),0) amt, COALESCE(SUM(e.amount_settled),0) "set",
           string_agg(e.status || ':1', ',' ORDER BY e.status) statuses
    FROM t_contract_events e WHERE e.contract_id = c.id) ev ON true
JOIN LATERAL (
    SELECT count(*) n, COALESCE(SUM(j.amount),0) amt, COALESCE(SUM(j.amount_settled),0) "set",
           string_agg(j.status_code || ':1', ',' ORDER BY j.status_code) statuses
    FROM n_jtd j WHERE j.contract_id = c.id AND j.channel_code IS NULL) jb ON true
WHERE EXISTS (SELECT 1 FROM n_jtd j WHERE j.contract_id = c.id
              AND j.business_context->>'migration' = 'jtd-cutover/001')
ORDER BY (CASE WHEN ev.n <> jb.n OR ev.amt <> jb.amt OR ev.set <> jb.set
               OR ev.statuses <> jb.statuses THEN 0 ELSE 1 END),
         t.name, c.is_live DESC, c.contract_number;
