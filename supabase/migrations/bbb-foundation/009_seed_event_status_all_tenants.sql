-- Migration: bbb-foundation/009_seed_event_status_all_tenants.sql
-- ============================================================================
-- Backfill event-status config + transitions for every tenant that is missing
-- it. Some tenants (onboarded via the VaNi flow) were never seeded with the
-- m_event_status_config / m_event_status_transitions rows, so their contract
-- timeline cards had no valid status transitions and status changes errored.
--
-- seed_event_status_defaults(tenant) is idempotent (ON CONFLICT DO NOTHING) and
-- copies from the tenant_id IS NULL template rows. Config is env-agnostic
-- (no is_live column) so one seed per tenant covers both live and test.
--
-- Safe to re-run: only tenants with zero config rows are seeded.
-- ============================================================================

DO $$
DECLARE t record; v_total int := 0;
BEGIN
  FOR t IN
    SELECT id FROM t_tenants tt
    WHERE NOT EXISTS (
      SELECT 1 FROM m_event_status_config c WHERE c.tenant_id = tt.id
    )
  LOOP
    PERFORM seed_event_status_defaults(t.id);
    v_total := v_total + 1;
  END LOOP;
  RAISE NOTICE 'seed_event_status_defaults applied to % tenant(s)', v_total;
END $$;
