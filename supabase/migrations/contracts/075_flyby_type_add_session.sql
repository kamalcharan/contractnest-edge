-- 075_flyby_type_add_session.sql
-- Extends t_contract_blocks.flyby_type CHECK constraint to allow 'session',
-- so Group Session can be a real FlyBy type (RFQ + Contract), not just a
-- catalog-only category. Owner decision: extend the constraint rather than
-- drop it — new types stay a cheap, safe migration; the guardrail against
-- typos/garbage values in this column is kept.
--
-- APPLIED LIVE to uwyqhzotluikawcboldr on 31 Jul 2026 via Supabase MCP
-- (mcp__Supabase__apply_migration). This file is the repo record of that
-- change — DO NOT re-apply if already present (idempotent DROP+ADD below is
-- safe to re-run, but unnecessary if already live).

ALTER TABLE t_contract_blocks
  DROP CONSTRAINT IF EXISTS t_contract_blocks_flyby_type_check;

ALTER TABLE t_contract_blocks
  ADD CONSTRAINT t_contract_blocks_flyby_type_check
  CHECK (flyby_type::text = ANY (ARRAY['service','spare','text','document','session']::text[]));
