-- Migration: bbb-foundation/010_tenant_seed_event_status_trigger.sql
-- ============================================================================
-- Guarantee every NEW tenant gets event-status config + transitions, on every
-- onboarding path, in both live and test.
--
-- Root cause: event-status seeding was only reachable via a manual endpoint, so
-- tenants onboarded through the VaNi flow ended up with zero
-- m_event_status_config / m_event_status_transitions rows. Their timeline cards
-- then had no valid status transitions and status changes errored.
--
-- Fix: seed at the DB layer, mirroring the existing trg_tenants_seed_vani_rules
-- trigger. An AFTER INSERT trigger on t_tenants calls seed_event_status_defaults
-- for the new tenant. Config is env-agnostic (no is_live column) so a single
-- seed covers both environments. Non-fatal (RAISE WARNING) so tenant creation
-- never fails because of seeding — matching the vani-rules trigger's behaviour.
--
-- Existing tenants are backfilled separately in 009_seed_event_status_all_tenants.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.trg_fn_seed_event_status_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
    BEGIN
        PERFORM seed_event_status_defaults(NEW.id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'seed_event_status_defaults failed for tenant %: %', NEW.id, SQLERRM;
    END;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_tenants_seed_event_status ON public.t_tenants;
CREATE TRIGGER trg_tenants_seed_event_status
  AFTER INSERT ON public.t_tenants
  FOR EACH ROW EXECUTE FUNCTION trg_fn_seed_event_status_defaults();
