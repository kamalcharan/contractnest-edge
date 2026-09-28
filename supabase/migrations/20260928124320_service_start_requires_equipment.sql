-- Starting work requires actual coverage, independently of which UI/API starts it.
-- Existing tickets are retained; this migration does not change customer data.
CREATE OR REPLACE FUNCTION public.guard_service_start_equipment()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE blocked boolean := false;
BEGIN
 IF TG_TABLE_NAME='t_contract_events' THEN
  IF NEW.event_type<>'service' OR NEW.status<>'in_progress' THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' AND OLD.status='in_progress' THEN RETURN NEW; END IF;
  SELECT EXISTS(SELECT 1 FROM public.t_contract_event_assets a
    WHERE a.event_id=NEW.id AND a.tenant_id=NEW.tenant_id AND a.status='blocked_placeholder') INTO blocked;
 ELSIF TG_TABLE_NAME='t_service_ticket_events' THEN
  SELECT EXISTS(SELECT 1 FROM public.t_service_tickets t
    JOIN public.t_contract_event_assets a ON a.event_id=NEW.event_id AND a.tenant_id=t.tenant_id
    WHERE t.id=NEW.ticket_id AND t.status='in_progress' AND a.status='blocked_placeholder') INTO blocked;
 ELSE
  IF NEW.status<>'in_progress' THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' AND OLD.status='in_progress' THEN RETURN NEW; END IF;
  SELECT EXISTS(SELECT 1 FROM public.t_service_ticket_events te
    JOIN public.t_contract_event_assets a ON a.event_id=te.event_id AND a.tenant_id=NEW.tenant_id
    WHERE te.ticket_id=NEW.id AND a.status='blocked_placeholder') INTO blocked;
 END IF;
 IF blocked THEN RAISE EXCEPTION 'Attach the required equipment in contract coverage before starting this service.' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_service_start_equipment() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER service_event_start_equipment BEFORE INSERT OR UPDATE OF status ON public.t_contract_events
 FOR EACH ROW EXECUTE FUNCTION public.guard_service_start_equipment();
CREATE TRIGGER service_ticket_start_equipment BEFORE INSERT OR UPDATE OF status ON public.t_service_tickets
 FOR EACH ROW EXECUTE FUNCTION public.guard_service_start_equipment();
CREATE TRIGGER service_ticket_link_equipment BEFORE INSERT OR UPDATE OF event_id,ticket_id ON public.t_service_ticket_events
 FOR EACH ROW EXECUTE FUNCTION public.guard_service_start_equipment();
