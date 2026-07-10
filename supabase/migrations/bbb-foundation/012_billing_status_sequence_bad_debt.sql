-- Migration: bbb-foundation/012_billing_status_sequence_bad_debt.sql
-- ============================================================================
-- Simplify the billing status sequence and add Bad Debt. All tenants + template.
--
-- The billing lifecycle carried an "invoicing" sub-sequence
-- (Invoice Generated -> Sent -> Payment Pending) that nothing automated ever
-- set — invoices are auto-generated ONCE at the contract level, so offering
-- "Invoice Generated" per billing due was meaningless noise.
--
-- New sequence (money-driven):
--   Scheduled -> Due -> Overdue   (auto by scanner, or manual)
--   Partial Payment -> Paid       (automatic, from receipts — never hand-set)
--   Cancelled / Waived / Bad Debt (manual terminal write-offs)
--
-- Manual dropdown transitions after this migration:
--   scheduled       -> due, cancelled
--   due             -> overdue, cancelled, bad_debt, waived
--   overdue         -> cancelled, bad_debt, waived
--   partial_payment -> cancelled, bad_debt, waived
-- (Paid/Partial are set by record_invoice_payment_with_allocations directly,
--  bypassing transition validation, so no manual "-> paid" is offered.)
--
-- Idempotent; NULL-safe across the tenant_id-IS-NULL template row.
-- ============================================================================

-- 1) Reset any billing event stranded in a removed sub-state.
UPDATE t_contract_events
SET status = CASE
      WHEN scheduled_date::date > current_date THEN 'scheduled'
      WHEN scheduled_date::date < current_date THEN 'overdue'
      ELSE 'due' END,
    version = version + 1,
    updated_at = now()
WHERE event_type='billing' AND is_active=true
  AND status IN ('invoice_generated','sent','payment_pending');

-- 2) Deactivate the invoicing sub-states.
UPDATE m_event_status_config
SET is_active=false, updated_at=now()
WHERE event_type='billing'
  AND status_code IN ('invoice_generated','sent','payment_pending');

-- 3) Add Bad Debt (terminal) for every tenant + the template.
INSERT INTO m_event_status_config
  (tenant_id, event_type, status_code, display_name, description,
   hex_color, icon_name, display_order, is_initial, is_terminal, is_active, source)
SELECT t.tid, 'billing', 'bad_debt', 'Bad Debt',
       'Uncollectible — written off as bad debt',
       '#7F1D1D', 'Ban', 11, false, true, true, 'system'
FROM (SELECT DISTINCT tenant_id AS tid FROM m_event_status_config WHERE event_type='billing') t
WHERE NOT EXISTS (
  SELECT 1 FROM m_event_status_config c2
  WHERE c2.event_type='billing' AND c2.status_code='bad_debt'
    AND c2.tenant_id IS NOT DISTINCT FROM t.tid
);

-- 4a) Remove invoicing sub-flow transitions and any manual "-> paid".
DELETE FROM m_event_status_transitions
WHERE event_type='billing'
  AND ( from_status IN ('invoice_generated','sent','payment_pending')
     OR to_status   IN ('invoice_generated','sent','payment_pending')
     OR to_status = 'paid' );

-- 4b) Add write-off off-ramps for every tenant + template.
WITH tids AS (SELECT DISTINCT tenant_id AS tid FROM m_event_status_transitions WHERE event_type='billing'),
pairs(fs, ts) AS (VALUES
  ('due','bad_debt'), ('due','waived'),
  ('overdue','bad_debt'),
  ('partial_payment','cancelled'), ('partial_payment','bad_debt'), ('partial_payment','waived'))
INSERT INTO m_event_status_transitions
  (tenant_id, event_type, from_status, to_status, requires_reason, requires_evidence, is_active)
SELECT t.tid, 'billing', p.fs, p.ts, false, false, true
FROM tids t CROSS JOIN pairs p
WHERE NOT EXISTS (
  SELECT 1 FROM m_event_status_transitions x
  WHERE x.event_type='billing' AND x.from_status=p.fs AND x.to_status=p.ts
    AND x.tenant_id IS NOT DISTINCT FROM t.tid
);

-- NOTE: seed_event_status_defaults still copies from the template, so the
-- deactivated sub-states will not be re-seeded active and Bad Debt WILL be
-- seeded for future tenants (the template rows are updated above).
