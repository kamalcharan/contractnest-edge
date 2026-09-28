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
   AND (contract_block_id=e.block_id OR (contract_block_id IS NULL AND NOT EXISTS(SELECT 1 FROM m_form_template_mappings b WHERE b.tenant_id=p_tenant AND b.contract_id=e.contract_id AND b.status='active' AND b.contract_block_id=e.block_id AND (b.effective_from IS NULL OR b.effective_from<=e.scheduled_date::date) AND (b.effective_to IS NULL OR b.effective_to>=e.scheduled_date::date))))
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

-- These operations are called by the authenticated API with its server client.
-- Do not expose caller-supplied tenant/actor parameters directly to public roles.
CREATE OR REPLACE FUNCTION public.jtd_start_visit(p_tenant uuid, p_event_id uuid, p_actor_type text, p_actor_id uuid, p_actor_name text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_e public.t_contract_events; v_ref jsonb; v_t record; v_r jsonb; v_ticket uuid; v_ticket_no text; v_assignee uuid; v_assignee_name text;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  SELECT * INTO v_e FROM public.t_contract_events e WHERE e.id = p_event_id AND e.tenant_id = p_tenant AND e.event_type = 'service' AND COALESCE(e.is_active, true) FOR UPDATE;
  v_ref := public.jtd__visit_refusal(v_e);
  IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;
  SELECT t.id, t.ticket_number, t.status INTO v_t FROM public.t_service_ticket_events te JOIN public.t_service_tickets t ON t.id = te.ticket_id
   WHERE te.event_id = p_event_id AND t.tenant_id = p_tenant AND t.is_active AND t.status IN ('created','assigned','in_progress') ORDER BY t.created_at DESC LIMIT 1;
  IF v_t.id IS NOT NULL AND v_t.status = 'in_progress' AND v_e.status = 'in_progress' THEN
    RETURN jsonb_build_object('success', true, 'reason', 'visit_already_started', 'ticket_id', v_t.id, 'ticket_number', v_t.ticket_number);
  END IF;
  v_assignee := COALESCE(v_e.assigned_to, CASE WHEN p_actor_type = 'user' THEN p_actor_id END);
  v_assignee_name := COALESCE(v_e.assigned_to_name, CASE WHEN p_actor_type = 'user' THEN p_actor_name END);

  IF v_t.id IS NOT NULL THEN
    IF v_t.status <> 'in_progress' THEN
      v_r := public.update_service_ticket(v_t.id, p_tenant, jsonb_build_object('status', 'in_progress') || CASE WHEN p_note IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('notes', p_note) END, NULL, p_actor_id, p_actor_name);
      IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    END IF;
    v_ticket := v_t.id; v_ticket_no := v_t.ticket_number;
  ELSE
    v_r := public.create_service_ticket(p_tenant, v_e.contract_id, now(), v_assignee, v_assignee_name, p_note, ARRAY[p_event_id], p_actor_id, p_actor_name, COALESCE(v_e.is_live, true), NULL, true);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    v_ticket := (v_r->'data'->>'id')::uuid; v_ticket_no := v_r->'data'->>'ticket_number';
  END IF;
  IF v_e.status <> 'in_progress' THEN
    v_r := public.update_contract_event(p_event_id, p_tenant, jsonb_build_object('status', 'in_progress') || CASE WHEN v_e.assigned_to IS NULL AND v_assignee IS NOT NULL THEN jsonb_build_object('assigned_to', v_assignee, 'assigned_to_name', v_assignee_name) ELSE '{}'::jsonb END,
                                        v_e.version, p_actor_id, p_actor_name, COALESCE(p_note, 'Visit started from Ops · ' || v_ticket_no));
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
  END IF;
  PERFORM public.jtd__visit_note(p_tenant, p_event_id, 'visit_started', p_actor_type, p_actor_id, p_actor_name,
                                 jsonb_build_object('ticket_id', v_ticket, 'ticket_number', v_ticket_no), p_note, NULL, v_assignee, v_assignee_name, 'in_progress');
  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'ticket_id', v_ticket, 'ticket_number', v_ticket_no, 'assigned_to_name', v_assignee_name);
EXCEPTION WHEN raise_exception THEN
  IF left(SQLERRM, 5) = 'TOOL:' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', (substr(SQLERRM, 6)::jsonb)->>'error', 'code', COALESCE((substr(SQLERRM, 6)::jsonb)->>'code', (substr(SQLERRM, 6)::jsonb)->>'error_code'));
  END IF;
  RAISE;
END;
$function$;

CREATE OR REPLACE FUNCTION public.jtd_complete_visit(p_tenant uuid, p_event_id uuid, p_actor_type text, p_actor_id uuid, p_actor_name text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_e public.t_contract_events; v_ref jsonb; v_t record; v_r jsonb; v_ticket uuid; v_ticket_no text; v_version integer; v_assignee uuid; v_assignee_name text;
BEGIN
  IF p_actor_type NOT IN ('user','vani','system') OR p_actor_id IS NULL THEN RETURN jsonb_build_object('success', false, 'reason', 'actor_required'); END IF;
  SELECT * INTO v_e FROM public.t_contract_events e WHERE e.id = p_event_id AND e.tenant_id = p_tenant AND e.event_type = 'service' AND COALESCE(e.is_active, true) FOR UPDATE;
  v_ref := public.jtd__visit_refusal(v_e);
  IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;
  v_version := v_e.version;
  v_assignee := COALESCE(v_e.assigned_to, CASE WHEN p_actor_type = 'user' THEN p_actor_id END);
  v_assignee_name := COALESCE(v_e.assigned_to_name, CASE WHEN p_actor_type = 'user' THEN p_actor_name END);

  SELECT t.id, t.ticket_number, t.status INTO v_t FROM public.t_service_ticket_events te JOIN public.t_service_tickets t ON t.id = te.ticket_id
   WHERE te.event_id = p_event_id AND t.tenant_id = p_tenant AND t.is_active AND t.status IN ('created','assigned','in_progress') ORDER BY t.created_at DESC LIMIT 1;
  IF v_t.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'service_not_started', 'detail', 'Start the service before completing it.');
  END IF;
  v_ticket := v_t.id; v_ticket_no := v_t.ticket_number;
  IF v_e.status IN ('scheduled', 'due') THEN
    v_r := public.update_contract_event(p_event_id, p_tenant, jsonb_build_object('status', 'in_progress'), v_version, p_actor_id, p_actor_name, 'Visit done from Ops · ' || v_ticket_no);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
    v_version := v_version + 1;
  END IF;
  v_r := public.update_contract_event(p_event_id, p_tenant, jsonb_build_object('status', 'completed') || CASE WHEN p_notes IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('notes', p_notes) END,
                                      v_version, p_actor_id, p_actor_name, COALESCE(p_notes, 'Visit done from Ops · ' || v_ticket_no));
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
  -- A legacy ticket can contain several service events. Close only this event;
  -- close the parent ticket after every linked service is closed.
  IF NOT EXISTS(SELECT 1 FROM public.t_service_ticket_events te JOIN public.t_contract_events ce ON ce.id=te.event_id WHERE te.ticket_id=v_ticket AND ce.tenant_id=p_tenant AND COALESCE(ce.is_active,true) AND ce.status NOT IN ('completed','cancelled')) THEN
    v_r := public.update_service_ticket(v_ticket, p_tenant, jsonb_build_object('status', 'completed') || CASE WHEN p_notes IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('completion_notes', p_notes) END, NULL, p_actor_id, p_actor_name);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'TOOL:%', v_r::text USING ERRCODE = 'P0001'; END IF;
  END IF;
  PERFORM public.jtd__close_open_appointments(p_tenant, p_event_id, 'completed', p_actor_type, p_actor_id, p_actor_name, 'Visit done');  -- 022

  PERFORM public.jtd__visit_note(p_tenant, p_event_id, 'visit_completed', p_actor_type, p_actor_id, p_actor_name,
                                 jsonb_build_object('ticket_id', v_ticket, 'ticket_number', v_ticket_no), p_notes, NULL, v_assignee, v_assignee_name, 'completed');
  RETURN jsonb_build_object('success', true, 'event_id', p_event_id, 'ticket_id', v_ticket, 'ticket_number', v_ticket_no);
EXCEPTION WHEN raise_exception THEN
  IF left(SQLERRM, 5) = 'TOOL:' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'downstream_refused', 'detail', (substr(SQLERRM, 6)::jsonb)->>'error', 'code', COALESCE((substr(SQLERRM, 6)::jsonb)->>'code', (substr(SQLERRM, 6)::jsonb)->>'error_code'));
  END IF;
  RAISE;
END;
$function$;

CREATE OR REPLACE FUNCTION public.mark_event_asset_proven(p_tenant_id uuid, p_event_asset_id uuid, p_form_submission_id uuid DEFAULT NULL::uuid, p_evidence_id uuid DEFAULT NULL::uuid, p_proven_by uuid DEFAULT NULL::uuid, p_proven_by_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_asset          RECORD;
    v_evt_status     text;
    v_evt_version    int;
    v_evt_block_id   uuid;
    v_evt_source     text;
    v_require_upload boolean := false;
    v_remaining      int;
    v_event_completed boolean := false;
    v_event_result   jsonb;
    v_ticket         RECORD;
    v_tickets_completed uuid[] := '{}';
    v_open_ticket_events int;
BEGIN
    SELECT * INTO v_asset
    FROM t_contract_event_assets
    WHERE id = p_event_asset_id AND tenant_id = p_tenant_id AND is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Event asset not found', 'code', 'NOT_FOUND');
    END IF;
    IF v_asset.status = 'blocked_placeholder' THEN
        RETURN jsonb_build_object('success', false,
            'error', 'This slot is a placeholder — attach the real asset before proving',
            'code', 'ASSET_PLACEHOLDER');
    END IF;
    IF v_asset.status = 'proven' THEN
        RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
            'event_asset_id', v_asset.id, 'status', 'proven',
            'already_proven', true, 'proven_at', v_asset.proven_at));
    END IF;

    SELECT status, version, block_id, 'events' INTO v_evt_status, v_evt_version, v_evt_block_id, v_evt_source
    FROM t_contract_events
    WHERE id = v_asset.event_id AND tenant_id = p_tenant_id;
    IF NOT FOUND THEN
        -- jtd twin: block_id there is a composite text key, not a contract
        -- block uuid — leave v_evt_block_id NULL (contract-level mappings apply)
        SELECT status_code, version, NULL::uuid, 'jtd' INTO v_evt_status, v_evt_version, v_evt_block_id, v_evt_source
        FROM n_jtd
        WHERE id = v_asset.event_id AND tenant_id = p_tenant_id;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('success', false, 'error', 'Parent event not found', 'code', 'EVENT_NOT_FOUND');
        END IF;
    END IF;

    SELECT COALESCE(bool_or(m.require_upload), false) INTO v_require_upload
    FROM m_form_template_mappings m
    WHERE m.tenant_id = p_tenant_id
      AND m.contract_id = v_asset.contract_id
      AND m.status = 'active'
      AND ((v_evt_block_id IS NOT NULL AND m.contract_block_id = v_evt_block_id)
           OR (m.contract_block_id IS NULL AND (v_evt_block_id IS NULL OR NOT EXISTS (
                 SELECT 1 FROM m_form_template_mappings b
                 WHERE b.tenant_id = p_tenant_id AND b.contract_id = v_asset.contract_id
                   AND b.status = 'active' AND b.contract_block_id = v_evt_block_id))));

    IF v_require_upload AND p_evidence_id IS NULL THEN
        RETURN jsonb_build_object('success', false,
            'error', 'This service requires an upload (photo/document) before the asset can be marked proven',
            'code', 'UPLOAD_REQUIRED');
    END IF;

    IF p_form_submission_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM m_form_submissions s
        WHERE s.id = p_form_submission_id AND s.tenant_id = p_tenant_id
          AND s.service_event_id = v_asset.event_id
          AND s.event_asset_id = p_event_asset_id AND s.status IN ('submitted','approved')
          AND COALESCE(s.responses->>'work_status','completed') = 'completed'
          AND COALESCE(s.responses->>'asset_condition','good') <> 'critical'
    ) THEN
        RETURN jsonb_build_object('success', false,
            'error', 'form_submission_id does not belong to this asset', 'code', 'SUBMISSION_MISMATCH');
    END IF;

    UPDATE t_contract_event_assets
    SET status = 'proven',
        proven_at = now(),
        form_submission_id = COALESCE(p_form_submission_id, form_submission_id),
        evidence_id = COALESCE(p_evidence_id, evidence_id),
        updated_at = now()
    WHERE id = p_event_asset_id;

    INSERT INTO t_audit_log (tenant_id, entity_type, entity_id, contract_id,
        category, action, description, new_value, performed_by, performed_by_name)
    VALUES (p_tenant_id, 'event_asset', p_event_asset_id, v_asset.contract_id,
        'status', 'asset_proven',
        'Asset "' || COALESCE(v_asset.asset_name, v_asset.asset_ref) || '" proven',
        jsonb_build_object('event_id', v_asset.event_id,
            'form_submission_id', p_form_submission_id, 'evidence_id', p_evidence_id),
        p_proven_by, p_proven_by_name);

    SELECT count(*) INTO v_remaining
    FROM t_contract_event_assets
    WHERE event_id = v_asset.event_id AND tenant_id = p_tenant_id
      AND is_active = true AND status <> 'proven';

    -- Evidence is recorded without implicitly completing the visit or ticket.
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
        'event_asset_id', p_event_asset_id,
        'status', 'proven',
        'event_id', v_asset.event_id,
        'event_source', v_evt_source,
        'event_completed', v_event_completed,
        'event_update', CASE WHEN v_remaining = 0 THEN v_event_result ELSE NULL END,
        'tickets_completed', to_jsonb(v_tickets_completed),
        'remaining_assets', v_remaining));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false,
        'error', 'Failed to mark asset proven', 'details', SQLERRM, 'code', 'RPC_ERROR');
END;
$function$;


REVOKE ALL ON FUNCTION public.jtd_start_visit(uuid,uuid,text,uuid,text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jtd_complete_visit(uuid,uuid,text,uuid,text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.mark_event_asset_proven(uuid,uuid,uuid,uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jtd_start_visit(uuid,uuid,text,uuid,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.jtd_complete_visit(uuid,uuid,text,uuid,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_event_asset_proven(uuid,uuid,uuid,uuid,uuid,text) TO service_role;
