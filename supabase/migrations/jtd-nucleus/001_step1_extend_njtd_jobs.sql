-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/001_step1_extend_njtd_jobs.sql
-- JTD Nucleus — Step 1 of 6 (owner-approved 2026-08-18)
--
-- PURPOSE: make n_jtd able to HOLD a job (visit / payment), per
-- ClaudeDocumentation/JTD/JTD-Framework.md §1 ("When a contract is
-- created with 12 monthly services, JTD automatically creates 12
-- service_visit records") and §5.2. ADDITIVE ONLY:
--   · no existing table is altered except by ADD COLUMN (nullable or
--     defaulted) — every existing row remains byte-identical reads
--   · no function, trigger, view, or screen is touched
--   · event types NOT added — 'service_visit' and 'payment' have
--     existed in n_jtd_event_types since the Dec-2025 framework seed
--   · one master row added: source type 'payment_scheduled' (the
--     framework defined service_scheduled but never its payment twin)
--
-- Verified before writing (2026-08-18, live):
--   · zero implicit-column INSERTs into n_jtd or
--     t_invoice_receipt_allocations anywhere in pg_proc — the one
--     breakage class of additive columns does not exist here
--   · contract-view RPCs read n_jtd not at all (reads_jtd = false)
--   · dispatch triggers act only on status_code='created' — future
--     job rows (born 'scheduled'/'due') never enter the message queue
--
-- GOLDEN RULE: V1 untouched. Jobs are written only by V2 siblings
-- (Step 2+). Until then these columns are empty shelves.
-- Rollback: ALTER TABLE ... DROP COLUMN (nothing will reference them
-- until Step 2); DELETE the one master row.
-- ═══════════════════════════════════════════════════════════════════

-- 1 ── n_jtd: the 22 job columns (mirrors t_contract_events column-for-
--      column; the job's DATE uses the EXISTING scheduled_at column)
ALTER TABLE public.n_jtd
  ADD COLUMN IF NOT EXISTS contract_id            uuid,
  ADD COLUMN IF NOT EXISTS block_id               text,
  ADD COLUMN IF NOT EXISTS block_name             text,
  ADD COLUMN IF NOT EXISTS category_id            text,
  ADD COLUMN IF NOT EXISTS billing_sub_type       text,
  ADD COLUMN IF NOT EXISTS billing_cycle_label    text,
  ADD COLUMN IF NOT EXISTS sequence_number        integer,
  ADD COLUMN IF NOT EXISTS total_occurrences      integer,
  ADD COLUMN IF NOT EXISTS original_date          timestamptz,
  ADD COLUMN IF NOT EXISTS amount                 numeric,
  ADD COLUMN IF NOT EXISTS currency               text,
  ADD COLUMN IF NOT EXISTS assigned_to            uuid,
  ADD COLUMN IF NOT EXISTS assigned_to_name       text,
  ADD COLUMN IF NOT EXISTS notes                  text,
  ADD COLUMN IF NOT EXISTS version                integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS is_active              boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS task_id                text,
  ADD COLUMN IF NOT EXISTS reminder_jtd_id        uuid,
  ADD COLUMN IF NOT EXISTS reminder_dispatched_at timestamptz,
  ADD COLUMN IF NOT EXISTS invoice_id             uuid,
  ADD COLUMN IF NOT EXISTS amount_settled         numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS audience               text;

COMMENT ON COLUMN public.n_jtd.contract_id IS
'Job rows only (JTD Nucleus Step 1): the contract this job belongs to. NULL on message rows. A job row is channel_code IS NULL AND contract_id IS NOT NULL.';

-- 2 ── allocations: V2 settlements reference job rows via a NEW
--      nullable column; the V1 FK (contract_event_id) is untouched
ALTER TABLE public.t_invoice_receipt_allocations
  ADD COLUMN IF NOT EXISTS jtd_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_alloc_jtd'
      AND conrelid = 'public.t_invoice_receipt_allocations'::regclass
  ) THEN
    ALTER TABLE public.t_invoice_receipt_allocations
      ADD CONSTRAINT fk_alloc_jtd FOREIGN KEY (jtd_id)
      REFERENCES public.n_jtd(id);
  END IF;
END $$;

-- 3 ── vocabulary: ONE master row (framework-consistent naming; shape
--      copied from the live service_scheduled row — only code/name are
--      NOT NULL, verified against information_schema before writing)
INSERT INTO public.n_jtd_source_types
  (code, name, description, default_event_type, source_table, source_id_field, default_channels, is_active)
VALUES
  ('payment_scheduled', 'Payment Scheduled',
   'Payment commitment born from a contract — a job row, not a message (JTD Nucleus)',
   'payment', 't_contracts', 'id', '{}'::text[], true)
ON CONFLICT (code) DO NOTHING;

-- 4 ── indexes matching how job queries will run (partial: message rows
--      excluded, so the reminder pipeline's writes stay index-cheap)
CREATE INDEX IF NOT EXISTS idx_n_jtd_contract_jobs
  ON public.n_jtd (contract_id, event_type_code)
  WHERE contract_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_n_jtd_tenant_job_sched
  ON public.n_jtd (tenant_id, scheduled_at)
  WHERE contract_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_alloc_jtd
  ON public.t_invoice_receipt_allocations (jtd_id)
  WHERE jtd_id IS NOT NULL;
