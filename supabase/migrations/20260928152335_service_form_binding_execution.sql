-- Sprint 2: enforce registry prerequisites at every service-start entry point.
CREATE OR REPLACE FUNCTION public.service_start_metadata_problem(p_tenant uuid,p_event uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public AS $$
DECLARE problem text;
BEGIN
 SELECT string_agg(format('%s: %s', a.asset_name, d.label), '; ' ORDER BY a.asset_name,d.label) INTO problem
 FROM public.t_contract_event_assets a
 JOIN public.t_client_asset_registry r ON r.id::text=a.asset_ref AND r.tenant_id=a.tenant_id AND r.is_active
 JOIN LATERAL (
  SELECT DISTINCT ON (x.attribute_key) x.attribute_key,x.label,x.required_stage
  FROM public.m_asset_attribute_definitions x
  WHERE x.is_active AND x.resource_type_id=r.resource_type_id
   AND (x.tenant_id IS NULL OR x.tenant_id=r.tenant_id)
   AND (x.template_id IS NULL OR x.template_id=r.template_id)
   AND (x.asset_type_id IS NULL OR x.asset_type_id=r.asset_type_id)
  ORDER BY x.attribute_key,
   ((x.asset_type_id IS NOT NULL)::int*4+(x.template_id IS NOT NULL)::int*2+(x.tenant_id IS NOT NULL)::int) DESC,x.id
 ) d ON true
 WHERE a.tenant_id=p_tenant AND a.event_id=p_event AND a.is_active
   AND a.status<>'blocked_placeholder' AND d.required_stage='service_start'
   AND (r.specifications->d.attribute_key IS NULL OR r.specifications->d.attribute_key='null'::jsonb
     OR (jsonb_typeof(r.specifications->d.attribute_key)='string' AND btrim(r.specifications->>d.attribute_key)=''));
 RETURN CASE WHEN problem IS NULL THEN NULL ELSE 'Complete equipment metadata before starting: '||problem END;
END $$;
REVOKE ALL ON FUNCTION public.service_start_metadata_problem(uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.guard_service_start_equipment()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE blocked boolean := false; issue text; event_id uuid; tenant_id uuid;
BEGIN
 IF TG_TABLE_NAME='t_contract_events' THEN
  IF NEW.event_type<>'service' OR NEW.status<>'in_progress' THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' AND OLD.status='in_progress' THEN RETURN NEW; END IF;
  event_id:=NEW.id;
  tenant_id:=NEW.tenant_id;
  SELECT EXISTS(SELECT 1 FROM public.t_contract_event_assets a
    WHERE a.event_id=event_id AND a.tenant_id=NEW.tenant_id AND a.status='blocked_placeholder') INTO blocked;
 ELSIF TG_TABLE_NAME='t_service_ticket_events' THEN
  event_id:=NEW.event_id;
  SELECT t.tenant_id INTO tenant_id FROM public.t_service_tickets t WHERE t.id=NEW.ticket_id;
  SELECT EXISTS(SELECT 1 FROM public.t_service_tickets t
    JOIN public.t_contract_event_assets a ON a.event_id=event_id AND a.tenant_id=t.tenant_id
    WHERE t.id=NEW.ticket_id AND t.status='in_progress' AND a.status='blocked_placeholder') INTO blocked;
  IF NOT EXISTS(SELECT 1 FROM public.t_service_tickets t WHERE t.id=NEW.ticket_id AND t.status='in_progress') THEN RETURN NEW; END IF;
 ELSE
  IF NEW.status<>'in_progress' THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' AND OLD.status='in_progress' THEN RETURN NEW; END IF;
  SELECT EXISTS(SELECT 1 FROM public.t_service_ticket_events te
    JOIN public.t_contract_event_assets a ON a.event_id=te.event_id AND a.tenant_id=NEW.tenant_id
    WHERE te.ticket_id=NEW.id AND a.status='blocked_placeholder') INTO blocked;
  IF blocked THEN RAISE EXCEPTION 'Attach the required equipment in contract coverage before starting this service.' USING ERRCODE='23514'; END IF;
  FOR event_id IN SELECT te.event_id FROM public.t_service_ticket_events te WHERE te.ticket_id=NEW.id LOOP
   issue:=public.service_start_metadata_problem(NEW.tenant_id,event_id);
   IF issue IS NOT NULL THEN RAISE EXCEPTION '%',issue USING ERRCODE='23514'; END IF;
  END LOOP;
  RETURN NEW;
 END IF;
 IF blocked THEN RAISE EXCEPTION 'Attach the required equipment in contract coverage before starting this service.' USING ERRCODE='23514'; END IF;
 issue:=public.service_start_metadata_problem(tenant_id,event_id);
 IF issue IS NOT NULL THEN RAISE EXCEPTION '%',issue USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_service_start_equipment() FROM PUBLIC,anon,authenticated;

-- One server-owned context for read-only form fields and submission snapshots.
-- Only the service role may call it; the Edge handler verifies tenant membership.
CREATE OR REPLACE FUNCTION public.service_form_execution_context(
 p_tenant uuid,p_event uuid,p_event_asset uuid,p_template uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public AS $$
DECLARE ev public.t_contract_events%ROWTYPE; ea public.t_contract_event_assets%ROWTYPE;
 asset public.t_client_asset_registry%ROWTYPE; ticket public.t_service_tickets%ROWTYPE;
 schema jsonb; section jsonb; field jsonb; binding jsonb; key text; source text; value jsonb;
 registry_json jsonb; service_json jsonb; specs jsonb:='{}'::jsonb; bound jsonb:='{}'::jsonb;
 asset_snapshot jsonb; missing jsonb:='[]'::jsonb;
BEGIN
 SELECT * INTO ev FROM public.t_contract_events WHERE id=p_event AND tenant_id=p_tenant AND event_type='service';
 IF NOT FOUND THEN RAISE EXCEPTION 'Service not found in this workspace' USING ERRCODE='23514'; END IF;
 SELECT t.schema INTO schema FROM public.m_form_templates t WHERE t.id=p_template;
 IF schema IS NULL THEN RAISE EXCEPTION 'Configured form not found' USING ERRCODE='23514'; END IF;
 IF p_event_asset IS NOT NULL THEN
  SELECT * INTO ea FROM public.t_contract_event_assets
   WHERE id=p_event_asset AND tenant_id=p_tenant AND event_id=p_event AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Equipment does not belong to this visit' USING ERRCODE='23514'; END IF;
  IF ea.status='blocked_placeholder' THEN RAISE EXCEPTION 'Attach the actual equipment before recording evidence' USING ERRCODE='23514'; END IF;
  SELECT * INTO asset FROM public.t_client_asset_registry
   WHERE id::text=ea.asset_ref AND tenant_id=p_tenant AND is_active;
  IF FOUND THEN
   registry_json:=to_jsonb(asset);
   WITH effective AS (
    SELECT DISTINCT ON (d.attribute_key) d.attribute_key,d.label,d.required_stage
    FROM public.m_asset_attribute_definitions d
    WHERE d.is_active AND d.resource_type_id=asset.resource_type_id
     AND (d.tenant_id IS NULL OR d.tenant_id=p_tenant)
     AND (d.template_id IS NULL OR d.template_id=asset.template_id)
     AND (d.asset_type_id IS NULL OR d.asset_type_id=asset.asset_type_id)
    ORDER BY d.attribute_key,
     ((d.asset_type_id IS NOT NULL)::int*4+(d.template_id IS NOT NULL)::int*2+(d.tenant_id IS NOT NULL)::int) DESC,d.id
   )
   SELECT coalesce(jsonb_object_agg(attribute_key,coalesce(asset.specifications->attribute_key,'null'::jsonb)),'{}'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('key',attribute_key,'label',label)) FILTER (
      WHERE required_stage='form_submit' AND
       (asset.specifications->attribute_key IS NULL OR asset.specifications->attribute_key='null'::jsonb OR
        (jsonb_typeof(asset.specifications->attribute_key)='string' AND btrim(asset.specifications->>attribute_key)=''))
    ),'[]'::jsonb)
    INTO specs,missing FROM effective;
   asset_snapshot:=jsonb_build_object(
    'id',asset.id,'resource_type_id',asset.resource_type_id,'asset_type_id',asset.asset_type_id,
    'template_id',asset.template_id,'registry_updated_at',asset.updated_at,'name',asset.name,
    'code',asset.code,'serial_number',asset.serial_number,'make',asset.make,'model',asset.model,
    'location',asset.location,'area_sqft',asset.area_sqft,'capacity',asset.capacity,
    'specifications',specs);
  END IF;
 END IF;
 SELECT t.* INTO ticket FROM public.t_service_tickets t
  JOIN public.t_service_ticket_events te ON te.ticket_id=t.id AND te.event_id=p_event
  WHERE t.tenant_id=p_tenant ORDER BY t.created_at DESC LIMIT 1;
 service_json:=jsonb_build_object('contract_id',ev.contract_id,'event_id',ev.id,
  'ticket_id',ticket.id,'ticket_number',ticket.ticket_number,'visit_number',ev.sequence_number,
  'scheduled_date',ev.scheduled_date,'started_at',ticket.started_at,
  'technician_id',ticket.assigned_to,'technician_name',ticket.assigned_to_name);
 FOR section IN SELECT * FROM jsonb_array_elements(coalesce(schema->'sections','[]'::jsonb)) LOOP
  FOR field IN SELECT * FROM jsonb_array_elements(coalesce(section->'fields','[]'::jsonb)) LOOP
   binding:=field->'binding'; source:=coalesce(binding->>'source','response'); key:=binding->>'key';
   IF source='response' THEN CONTINUE; END IF;
   IF field->>'id' IS NULL THEN RAISE EXCEPTION 'Bound form field has no ID' USING ERRCODE='23514'; END IF;
   IF source IN ('registry','specification') AND registry_json IS NULL THEN
    RAISE EXCEPTION 'Attach a registered asset before filling this form' USING ERRCODE='23514';
   END IF;
   IF source='registry' THEN
    IF key NOT IN ('id','name','code','serial_number','make','model','location','resource_type_id','asset_type_id','template_id','area_sqft','capacity') THEN
     RAISE EXCEPTION 'Unknown registry binding: %',key USING ERRCODE='23514'; END IF;
    value:=registry_json->key;
   ELSIF source='specification' THEN
    IF NOT specs ? key THEN RAISE EXCEPTION 'Unknown specification binding: %',key USING ERRCODE='23514'; END IF;
    value:=specs->key;
   ELSIF source='service' THEN
    IF key NOT IN ('contract_id','event_id','ticket_id','ticket_number','visit_number','scheduled_date','started_at','technician_id','technician_name') THEN
     RAISE EXCEPTION 'Unknown service binding: %',key USING ERRCODE='23514'; END IF;
    value:=service_json->key;
   ELSE RAISE EXCEPTION 'Unknown form binding source' USING ERRCODE='23514';
   END IF;
   bound:=bound||jsonb_build_object(field->>'id',coalesce(value,'null'::jsonb));
  END LOOP;
 END LOOP;
 RETURN jsonb_build_object('values',bound,'asset_snapshot',asset_snapshot,
  'service_snapshot',service_json,'missing_form_metadata',missing);
END $$;
REVOKE ALL ON FUNCTION public.service_form_execution_context(uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.service_form_execution_context(uuid,uuid,uuid,uuid) TO service_role;

-- Bound fields are not technician responses. The submission guard validates
-- their server-resolved values separately; completion keeps checking answers.
CREATE OR REPLACE FUNCTION public.service_form_errors(p_schema jsonb,p_answers jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
DECLARE section jsonb; field jsonb; answer_value jsonb; label text; typ text;
BEGIN
 FOR section IN SELECT * FROM jsonb_array_elements(COALESCE(p_schema->'sections','[]')) LOOP
  FOR field IN SELECT * FROM jsonb_array_elements(COALESCE(section->'fields','[]')) LOOP
   typ:=field->>'type'; label:=field->>'label'; answer_value:=p_answers->(field->>'id');
   IF typ='heading' OR COALESCE(field#>>'{binding,source}','response')<>'response' THEN CONTINUE; END IF;
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

CREATE OR REPLACE FUNCTION public.guard_service_form_submission()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE schema jsonb; template_version integer; context jsonb; section jsonb; field jsonb; source text;
 field_id text; value jsonb; problem text;
BEGIN
 IF TG_OP='UPDATE' THEN
  IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR NEW.contract_id IS DISTINCT FROM OLD.contract_id
   OR NEW.service_event_id IS DISTINCT FROM OLD.service_event_id OR NEW.event_asset_id IS DISTINCT FROM OLD.event_asset_id
   OR NEW.form_template_id IS DISTINCT FROM OLD.form_template_id OR NEW.form_template_version IS DISTINCT FROM OLD.form_template_version THEN
   RAISE EXCEPTION 'A form report cannot be moved to another service, asset or template' USING ERRCODE='23514';
  END IF;
 END IF;
 IF TG_OP='UPDATE' AND OLD.status IN ('submitted','approved') AND OLD.form_schema_snapshot IS NOT NULL THEN
  IF NEW.status='draft' OR NEW.submitted_at IS DISTINCT FROM OLD.submitted_at THEN
   RAISE EXCEPTION 'Submitted evidence cannot return to draft' USING ERRCODE='23514';
  END IF;
  IF NEW.responses IS DISTINCT FROM OLD.responses OR NEW.form_template_id IS DISTINCT FROM OLD.form_template_id
    OR NEW.service_event_id IS DISTINCT FROM OLD.service_event_id OR NEW.event_asset_id IS DISTINCT FROM OLD.event_asset_id
    OR NEW.asset_metadata_snapshot IS DISTINCT FROM OLD.asset_metadata_snapshot
    OR NEW.service_context_snapshot IS DISTINCT FROM OLD.service_context_snapshot
    OR NEW.form_schema_snapshot IS DISTINCT FROM OLD.form_schema_snapshot THEN
   RAISE EXCEPTION 'Submitted evidence is read-only. Open a new report for a correction.' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
 END IF;
 SELECT t.schema,t.version INTO schema,template_version FROM public.m_form_templates t WHERE t.id=NEW.form_template_id;
 IF schema IS NULL THEN RAISE EXCEPTION 'Configured form not found' USING ERRCODE='23514'; END IF;
 IF NEW.form_template_version<>template_version THEN
  RAISE EXCEPTION 'This form version has changed. Open a new report.' USING ERRCODE='23514'; END IF;
 context:=public.service_form_execution_context(NEW.tenant_id,NEW.service_event_id,NEW.event_asset_id,NEW.form_template_id);
 IF NEW.contract_id::text IS DISTINCT FROM context#>>'{service_snapshot,contract_id}' THEN
  RAISE EXCEPTION 'This form belongs to another contract' USING ERRCODE='23514'; END IF;
 FOR section IN SELECT * FROM jsonb_array_elements(coalesce(schema->'sections','[]'::jsonb)) LOOP
  FOR field IN SELECT * FROM jsonb_array_elements(coalesce(section->'fields','[]'::jsonb)) LOOP
   source:=coalesce(field#>>'{binding,source}','response');
   IF source='response' THEN CONTINUE; END IF;
   field_id:=field->>'id'; value:=context->'values'->field_id;
   IF NEW.responses ? field_id THEN RAISE EXCEPTION '% is supplied by the registry or service and cannot be edited here',field->>'label' USING ERRCODE='23514'; END IF;
   IF NEW.status IN ('submitted','approved') AND
      (coalesce((field->>'required')::boolean,false) OR coalesce((field#>>'{validation,required}')::boolean,false))
      AND (value IS NULL OR value='null'::jsonb OR (jsonb_typeof(value)='string' AND btrim(value#>>'{}')='')) THEN
    RAISE EXCEPTION '% is missing from the registry or service details',field->>'label' USING ERRCODE='23514';
   END IF;
  END LOOP;
 END LOOP;
 IF NEW.status IN ('submitted','approved') THEN
  IF jsonb_array_length(context->'missing_form_metadata')>0 THEN
   RAISE EXCEPTION 'Complete equipment metadata before submitting: %',
    (context#>>'{missing_form_metadata,0,label}') USING ERRCODE='23514';
  END IF;
  problem:=public.service_form_errors(schema,NEW.responses);
  IF problem IS NOT NULL THEN RAISE EXCEPTION '%',problem USING ERRCODE='23514'; END IF;
  IF TG_OP='INSERT' THEN
   NEW.asset_metadata_snapshot:=context->'asset_snapshot';
   NEW.service_context_snapshot:=(context->'service_snapshot')||jsonb_build_object('bound_values',context->'values');
   NEW.form_schema_snapshot:=schema;
  ELSIF OLD.status NOT IN ('submitted','approved') THEN
   NEW.asset_metadata_snapshot:=context->'asset_snapshot';
   NEW.service_context_snapshot:=(context->'service_snapshot')||jsonb_build_object('bound_values',context->'values');
   NEW.form_schema_snapshot:=schema;
  END IF;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_service_form_submission() FROM PUBLIC,anon,authenticated;
