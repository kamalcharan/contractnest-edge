-- Evidence submission is not completion. Existing API remains the authority
-- for authentication; these guards also protect alternate completion paths.
CREATE OR REPLACE FUNCTION public.service_form_errors(p_schema jsonb,p_answers jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
DECLARE section jsonb; field jsonb; answer_value jsonb; label text; typ text;
BEGIN
 FOR section IN SELECT * FROM jsonb_array_elements(COALESCE(p_schema->'sections','[]')) LOOP
  FOR field IN SELECT * FROM jsonb_array_elements(COALESCE(section->'fields','[]')) LOOP
   typ:=field->>'type'; label:=field->>'label'; answer_value:=p_answers->(field->>'id');
   IF typ='heading' THEN CONTINUE; END IF;
   IF typ NOT IN ('text','textarea','number','date','select','radio','checkpoint','multi_select','checkbox','email','tel') THEN RETURN label||': unsupported field configuration'; END IF;
   IF typ='checkpoint' AND COALESCE(jsonb_array_length(field->'options'),0)=0 THEN field:=field||'{"options":[{"value":"good"},{"value":"warn"},{"value":"bad"}]}'::jsonb; END IF;
   IF answer_value IS NULL OR answer_value='null'::jsonb OR (jsonb_typeof(answer_value)='string' AND btrim(answer_value#>>'{}')='') OR answer_value='[]'::jsonb THEN
    IF COALESCE((field->>'required')::boolean,false) OR COALESCE((field#>>'{validation,required}')::boolean,false) THEN RETURN label||' is required'; END IF;
    CONTINUE;
   END IF;
   IF typ='checkbox' AND jsonb_typeof(answer_value)<>'boolean' THEN RETURN label||': invalid checkbox value'; END IF;
   IF typ='number' THEN
    IF (answer_value#>>'{}') !~ '^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$' THEN RETURN label||': invalid number'; END IF;
    IF field#>>'{validation,min}' IS NOT NULL AND (answer_value#>>'{}')::numeric < (field#>>'{validation,min}')::numeric THEN RETURN label||': below minimum'; END IF;
    IF field#>>'{validation,max}' IS NOT NULL AND (answer_value#>>'{}')::numeric > (field#>>'{validation,max}')::numeric THEN RETURN label||': above maximum'; END IF;
   END IF;
   IF typ IN ('select','radio','checkpoint') AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(field->'options') o WHERE o->'value'=answer_value) THEN RETURN label||': invalid option'; END IF;
   IF typ='multi_select' THEN
    IF jsonb_typeof(answer_value)<>'array' THEN RETURN label||': select configured options'; END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(answer_value) v WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(field->'options') o WHERE o->'value'=v)) THEN RETURN label||': invalid option'; END IF;
   END IF;
  END LOOP;
 END LOOP;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.service_form_errors(jsonb,jsonb) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.service_completion_problem(p_tenant uuid,p_event uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE e record; a record; m record; s record; problem text; schema jsonb;
BEGIN
 SELECT * INTO e FROM t_contract_events WHERE id=p_event AND tenant_id=p_tenant;
 IF NOT FOUND OR e.event_type<>'service' THEN RETURN NULL; END IF;
 FOR a IN SELECT id,status,evidence_id FROM t_contract_event_assets WHERE event_id=p_event AND tenant_id=p_tenant AND is_active
 UNION ALL SELECT NULL::uuid,'open',NULL::uuid WHERE NOT EXISTS(SELECT 1 FROM t_contract_event_assets WHERE event_id=p_event AND tenant_id=p_tenant AND is_active)
 LOOP
  IF a.status='blocked_placeholder' THEN RETURN 'Attach the actual equipment before completing this visit.'; END IF;
  FOR m IN SELECT * FROM m_form_template_mappings fm WHERE tenant_id=p_tenant AND contract_id=e.contract_id AND status='active'
   AND (effective_from IS NULL OR effective_from<=e.scheduled_date::date) AND (effective_to IS NULL OR effective_to>=e.scheduled_date::date)
   AND (contract_block_id::text=e.block_id::text OR (contract_block_id IS NULL AND NOT EXISTS(SELECT 1 FROM m_form_template_mappings b WHERE b.tenant_id=p_tenant AND b.contract_id=e.contract_id AND b.status='active' AND b.contract_block_id::text=e.block_id::text AND (b.effective_from IS NULL OR b.effective_from<=e.scheduled_date::date) AND (b.effective_to IS NULL OR b.effective_to>=e.scheduled_date::date))))
  LOOP
   SELECT * INTO s FROM m_form_submissions WHERE tenant_id=p_tenant AND service_event_id=p_event AND event_asset_id IS NOT DISTINCT FROM a.id AND form_template_id=m.form_template_id ORDER BY updated_at DESC LIMIT 1;
   IF s.id IS NULL OR s.status NOT IN ('submitted','approved') THEN
    IF m.is_mandatory THEN RETURN 'Record all required service outcomes before completing.'; ELSE CONTINUE; END IF;
   END IF;
   SELECT t.schema INTO schema FROM m_form_templates t WHERE id=m.form_template_id;
   problem:=service_form_errors(schema,s.responses);
   IF problem IS NOT NULL THEN RETURN problem; END IF;
   IF s.responses->>'work_status' IN ('partial','not_done') OR s.responses->>'asset_condition'='critical' OR s.responses->>'overall_status' IN ('fail','conditional') OR s.responses->>'pass_overall' IN ('fail','conditional') THEN RETURN 'The recorded outcome needs follow-up. Keep this service open.'; END IF;
   IF m.require_upload AND a.evidence_id IS NULL AND NOT EXISTS(SELECT 1 FROM t_contract_evidence ce WHERE ce.owner_tenant_id=p_tenant AND ce.event_id=p_event AND ce.form_submission_id=s.id AND ce.confirmed_at IS NOT NULL AND ce.deleted_at IS NULL) THEN RETURN 'Required equipment evidence upload is missing.'; END IF;
  END LOOP;
 END LOOP;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.service_completion_problem(uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.guard_explicit_service_completion()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE problem text; event_id uuid;
BEGIN
 IF NEW.status='completed' AND OLD.status IS DISTINCT FROM NEW.status THEN
  IF TG_TABLE_NAME='t_contract_events' THEN
   problem:=service_completion_problem(NEW.tenant_id,NEW.id);
   IF problem IS NOT NULL THEN RAISE EXCEPTION '%',problem; END IF;
   IF NEW.event_type='service' THEN
    UPDATE t_contract_event_assets a SET status='proven',proven_at=COALESCE(proven_at,now()),updated_at=now(),
     form_submission_id=COALESCE((SELECT s.id FROM m_form_submissions s WHERE s.tenant_id=NEW.tenant_id AND s.service_event_id=NEW.id AND s.event_asset_id=a.id AND s.status IN ('submitted','approved') ORDER BY s.updated_at DESC LIMIT 1),a.form_submission_id)
    WHERE a.tenant_id=NEW.tenant_id AND a.event_id=NEW.id AND a.is_active AND a.status<>'blocked_placeholder';
   END IF;
  ELSE
   FOR event_id IN SELECT te.event_id FROM t_service_ticket_events te JOIN t_contract_events e ON e.id=te.event_id AND e.tenant_id=NEW.tenant_id WHERE te.ticket_id=NEW.id AND e.status<>'cancelled' LOOP
    problem:=service_completion_problem(NEW.tenant_id,event_id);
    IF problem IS NOT NULL THEN RAISE EXCEPTION '%',problem; END IF;
   END LOOP;
  END IF;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_explicit_service_completion() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS service_completion_guard ON public.t_contract_events;
CREATE TRIGGER service_completion_guard BEFORE UPDATE OF status ON public.t_contract_events FOR EACH ROW EXECUTE FUNCTION public.guard_explicit_service_completion();
DROP TRIGGER IF EXISTS service_completion_guard ON public.t_service_tickets;
CREATE TRIGGER service_completion_guard BEFORE UPDATE OF status ON public.t_service_tickets FOR EACH ROW EXECUTE FUNCTION public.guard_explicit_service_completion();

CREATE OR REPLACE FUNCTION public.guard_service_form_submission()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE schema jsonb; problem text;
BEGIN
 IF NEW.status IN ('submitted','approved') THEN
  SELECT t.schema INTO schema FROM m_form_templates t WHERE t.id=NEW.form_template_id;
  IF schema IS NULL THEN RAISE EXCEPTION 'Configured form not found'; END IF;
  problem:=service_form_errors(schema,NEW.responses);
  IF problem IS NOT NULL THEN RAISE EXCEPTION '%',problem; END IF;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_service_form_submission() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS service_form_submission_guard ON public.m_form_submissions;
CREATE TRIGGER service_form_submission_guard BEFORE INSERT OR UPDATE ON public.m_form_submissions FOR EACH ROW EXECUTE FUNCTION public.guard_service_form_submission();
