-- ═══════════════════════════════════════════════════════════════
-- Migration 063: Backfill tax_breakdown on the 27 pre-existing invoices
-- REPORT-FIRST, OWNER-GATED — per CONTRACTNEST_SPRINT_SPEC.md program
-- rule #3 ("DB completeness is the acceptance bar") and the standing
-- data-repair convention (report SELECT reviewed → owner approves →
-- apply). Do NOT run the UPDATE below until the SELECT report has
-- been reviewed and approved.
-- ═══════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
-- STEP 1 — REPORT (read-only). Run this first and review the
-- output. It shows exactly what tax_breakdown WOULD be set to for
-- every active invoice that doesn't have one yet, sourced from its
-- contract's CURRENT tax_breakdown.
--
-- Pre-verified safe (2026-07-19 live check): 0 of these invoices
-- have total_amount != contract.grand_total, and 0 have tax_amount=0
-- while their contract has tax_total>0 — i.e. no known drift between
-- invoice and contract since these invoices were issued.
-- ─────────────────────────────────────────────────────────────
SELECT
    i.id AS invoice_id,
    i.invoice_number,
    i.tax_amount AS invoice_tax_amount,
    c.tax_total AS contract_tax_total,
    c.tax_breakdown AS would_be_set_to
FROM t_invoices i
JOIN t_contracts c ON c.id = i.contract_id
WHERE i.is_active = true
  AND (i.tax_breakdown IS NULL OR i.tax_breakdown = '[]'::jsonb)
ORDER BY i.created_at;

-- ─────────────────────────────────────────────────────────────
-- STEP 2 — APPLY (only after reviewing Step 1's output and getting
-- explicit go-ahead). Idempotent — safe to re-run; only touches rows
-- still missing a breakdown. Does NOT touch amount/tax_amount/
-- total_amount/balance/amount_paid/status — those are unchanged.
-- ─────────────────────────────────────────────────────────────
-- UPDATE t_invoices i
-- SET tax_breakdown = c.tax_breakdown,
--     updated_at = now()
-- FROM t_contracts c
-- WHERE c.id = i.contract_id
--   AND i.is_active = true
--   AND (i.tax_breakdown IS NULL OR i.tax_breakdown = '[]'::jsonb);
