-- ============================================================================
-- Migration: Stage 0 Runtime Loop — 001 Dispatch Tracking Columns
-- ============================================================================
-- Purpose: Idempotency + linkage columns for the contract-event scanner.
--   - t_contract_events: track the reminder JTD dispatched for an event and
--     the invoice generated/linked for a billing event (never double-send).
--   - t_invoices: link an invoice back to the billing event that produced it,
--     and track the last payment_due reminder dispatched for it.
-- Depends on: contracts/012 (t_contract_events), contracts/005 (t_invoices),
--             jtd-framework/001 (n_jtd)
-- Safe to re-run: Yes (IF NOT EXISTS everywhere)
-- Applied by: OWNER (Supabase SQL editor / psql) — project uwyqhzotluikawcboldr
-- ============================================================================

-- ─────────────────────────────────────────────
-- t_contract_events: dispatch tracking
-- ─────────────────────────────────────────────
ALTER TABLE t_contract_events
    ADD COLUMN IF NOT EXISTS reminder_jtd_id        UUID REFERENCES n_jtd(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS reminder_dispatched_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS invoice_id             UUID REFERENCES t_invoices(id) ON DELETE SET NULL;

COMMENT ON COLUMN t_contract_events.reminder_jtd_id IS
    'n_jtd row enqueued by the scanner for this event (service_reminder). NULL + reminder_dispatched_at set = processed but nothing sendable (no contact).';
COMMENT ON COLUMN t_contract_events.reminder_dispatched_at IS
    'When the scanner processed this event for reminders. Non-NULL = never re-dispatch (idempotency guard).';
COMMENT ON COLUMN t_contract_events.invoice_id IS
    'Invoice generated from (or linked to) this billing event by the scanner. Non-NULL = never re-invoice.';

-- ─────────────────────────────────────────────
-- t_invoices: event linkage + reminder tracking
-- ─────────────────────────────────────────────
ALTER TABLE t_invoices
    ADD COLUMN IF NOT EXISTS contract_event_id   UUID REFERENCES t_contract_events(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS last_reminder_jtd_id UUID REFERENCES n_jtd(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS last_reminder_at     TIMESTAMPTZ;

COMMENT ON COLUMN t_invoices.contract_event_id IS
    'Billing event (t_contract_events) this invoice was auto-created from. NULL = contract-level invoice (activation lump-sum or manual).';
COMMENT ON COLUMN t_invoices.last_reminder_jtd_id IS
    'Most recent payment_due n_jtd dispatched for this invoice (scanner or manual send-reminder).';
COMMENT ON COLUMN t_invoices.last_reminder_at IS
    'When the last payment_due reminder was dispatched. Scanner sends at most one automatic reminder per invoice (dunning ladder = VaNi stage).';

-- ─────────────────────────────────────────────
-- Indexes
-- ─────────────────────────────────────────────
-- Hard idempotency: at most ONE active invoice per billing event,
-- even under concurrent scanner runs.
CREATE UNIQUE INDEX IF NOT EXISTS uq_invoices_contract_event
    ON t_invoices (contract_event_id)
    WHERE contract_event_id IS NOT NULL AND is_active = true;

-- Scanner sweep: events by status + date
CREATE INDEX IF NOT EXISTS idx_events_scanner_sweep
    ON t_contract_events (status, scheduled_date)
    WHERE is_active = true;

-- Scanner payment-reminder sweep: open invoices not yet reminded
CREATE INDEX IF NOT EXISTS idx_invoices_reminder_scan
    ON t_invoices (due_date)
    WHERE status IN ('unpaid', 'partially_paid') AND last_reminder_at IS NULL AND is_active = true;
