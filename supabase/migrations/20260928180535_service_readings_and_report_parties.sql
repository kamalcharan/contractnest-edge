-- Version generated reading forms without rewriting historical submission
-- snapshots. Real measurements outside a normal range are valid evidence.
DO $$
DECLARE form_row record; section_row jsonb; field_row jsonb; checkpoint record;
 new_sections jsonb; new_fields jsonb; new_schema jsonb; final_field jsonb;
 form_count integer; draft_count integer;
BEGIN
 SELECT count(*) INTO form_count FROM public.m_form_templates t WHERE EXISTS (
  SELECT 1 FROM jsonb_array_elements(t.schema->'sections') s WHERE s->>'id' LIKE 'read_%'
   AND EXISTS (SELECT 1 FROM jsonb_array_elements(s->'fields') f WHERE f->>'type'='number' AND f->>'id' LIKE 'cp_%' AND NOT (f ? 'reading_stage')));
 IF form_count <> 25 THEN RAISE EXCEPTION 'Expected 25 generated reading forms; found %',form_count; END IF;
 SELECT count(*) INTO draft_count FROM public.m_form_submissions sub
 JOIN public.m_form_templates t ON t.id=sub.form_template_id
 WHERE sub.status='draft' AND EXISTS (
  SELECT 1 FROM jsonb_array_elements(t.schema->'sections') s WHERE s->>'id' LIKE 'read_%');
 IF draft_count>0 THEN RAISE EXCEPTION 'Reading forms have drafts; migrate them before versioning'; END IF;
 IF EXISTS (SELECT 1 FROM public.m_form_submissions sub JOIN public.m_form_templates t ON t.id=sub.form_template_id
  WHERE sub.status IN ('submitted','approved') AND sub.form_schema_snapshot IS NULL AND EXISTS (
   SELECT 1 FROM jsonb_array_elements(t.schema->'sections') s WHERE s->>'id' LIKE 'read_%')) THEN
  RAISE EXCEPTION 'A historical reading report has no schema snapshot'; END IF;

 FOR form_row IN SELECT id,version,schema FROM public.m_form_templates t WHERE EXISTS (
  SELECT 1 FROM jsonb_array_elements(t.schema->'sections') s WHERE s->>'id' LIKE 'read_%'
   AND EXISTS (SELECT 1 FROM jsonb_array_elements(s->'fields') f WHERE f->>'type'='number' AND f->>'id' LIKE 'cp_%' AND NOT (f ? 'reading_stage'))) LOOP
  new_sections:='[]'::jsonb;
  FOR section_row IN SELECT * FROM jsonb_array_elements(form_row.schema->'sections') LOOP
   IF section_row->>'id' NOT LIKE 'read_%' THEN new_sections:=new_sections||jsonb_build_array(section_row); CONTINUE; END IF;
   new_fields:='[]'::jsonb;
   FOR field_row IN SELECT * FROM jsonb_array_elements(section_row->'fields') LOOP
    IF field_row->>'type'<>'number' OR field_row->>'id' NOT LIKE 'cp_%' OR field_row ? 'reading_stage' THEN
     new_fields:=new_fields||jsonb_build_array(field_row); CONTINUE;
    END IF;
    SELECT cp.id,cp.name,cp.unit,cp.normal_min,cp.normal_max INTO checkpoint
      FROM public.m_equipment_checkpoints cp WHERE cp.id::text=substring(field_row->>'id' from 4);
    IF checkpoint.id IS NULL THEN RAISE EXCEPTION 'Missing checkpoint for field %',field_row->>'id'; END IF;
    final_field:=(field_row - 'validation') || jsonb_build_object(
     'label',checkpoint.name||' - Final reading'||CASE WHEN checkpoint.unit IS NULL THEN '' ELSE ' ('||checkpoint.unit||')' END,
     'validation',jsonb_build_object('required',true),'reading_stage','final',
     'reading_range',jsonb_build_object('normal_min',checkpoint.normal_min,'normal_max',checkpoint.normal_max,'unit',checkpoint.unit));
    new_fields:=new_fields||jsonb_build_array(
      final_field||jsonb_build_object('id',(field_row->>'id')||'_before',
       'label',checkpoint.name||' - Before service'||CASE WHEN checkpoint.unit IS NULL THEN '' ELSE ' ('||checkpoint.unit||')' END,
       'validation',jsonb_build_object('required',false),'reading_stage','before'),final_field);
   END LOOP;
   new_sections:=new_sections||jsonb_build_array(jsonb_set(section_row,'{fields}',new_fields));
  END LOOP;
  new_schema:=jsonb_set(jsonb_set(form_row.schema,'{sections}',new_sections),'{version}',to_jsonb(form_row.version+1),true);
  UPDATE public.m_form_templates SET schema=new_schema,version=form_row.version+1,updated_at=now() WHERE id=form_row.id;
 END LOOP;
END $$;

-- The one remaining manual equipment-identity form has no mappings or
-- submissions. Bind its metadata to the registry/service, not technician input.
DO $$
DECLARE target record; section_row jsonb; field_row jsonb; fields jsonb; sections jsonb;
 binding_key text; binding_source text;
BEGIN
 SELECT id,version,schema INTO target FROM public.m_form_templates
 WHERE name='Calibration Report' AND source='manual' AND status='approved'
   AND schema#>>'{sections,0,id}'='equipment_info';
 IF target.id IS NULL THEN RAISE EXCEPTION 'Calibration Report template not found'; END IF;
 IF EXISTS(SELECT 1 FROM public.m_form_submissions WHERE form_template_id=target.id)
    OR EXISTS(SELECT 1 FROM public.m_form_template_mappings WHERE form_template_id=target.id) THEN
  RAISE EXCEPTION 'Calibration Report has live references; review migration separately'; END IF;
 sections:='[]'::jsonb;
 FOR section_row IN SELECT * FROM jsonb_array_elements(target.schema->'sections') LOOP
  fields:='[]'::jsonb;
  FOR field_row IN SELECT * FROM jsonb_array_elements(section_row->'fields') LOOP
   binding_key:=CASE field_row->>'id' WHEN 'equipment_name' THEN 'name'
      WHEN 'serial_number' THEN 'serial_number' WHEN 'manufacturer' THEN 'make'
      WHEN 'model_number' THEN 'model' WHEN 'technician_name' THEN 'technician_name' END;
   IF binding_key IS NOT NULL THEN
    binding_source:=CASE WHEN field_row->>'id'='technician_name' THEN 'service' ELSE 'registry' END;
    field_row:=(field_row - 'required')||jsonb_build_object('required',false,
      'binding',jsonb_build_object('source',binding_source,'key',binding_key));
   END IF;
   fields:=fields||jsonb_build_array(field_row);
  END LOOP;
  sections:=sections||jsonb_build_array(jsonb_set(section_row,'{fields}',fields));
 END LOOP;
 UPDATE public.m_form_templates SET schema=jsonb_set(jsonb_set(target.schema,'{sections}',sections),'{version}',to_jsonb(target.version+1),true),
   version=target.version+1,updated_at=now() WHERE id=target.id;
END $$;

-- This trigger runs after service_form_submission_guard (alphabetical trigger
-- order), so it snapshots parties alongside the already captured form and
-- asset context. Existing submitted reports remain untouched.
CREATE OR REPLACE FUNCTION public.snapshot_service_report_parties()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
DECLARE parties jsonb;
BEGIN
 IF NEW.status NOT IN ('submitted','approved') OR
    (TG_OP='UPDATE' AND OLD.status IN ('submitted','approved')) THEN RETURN NEW; END IF;
 IF NEW.service_context_snapshot IS NULL THEN
  RAISE EXCEPTION 'Service context must be captured before parties' USING ERRCODE='23514'; END IF;
 SELECT jsonb_build_object(
   'contract_number',c.contract_number,
   'seller_tenant_id',coalesce(c.seller_id,c.tenant_id),
   'seller_name',seller.name,
   'buyer_tenant_id',c.buyer_tenant_id,
   'buyer_name',coalesce(nullif(c.buyer_company,''),nullif(buyer.name,''),nullif(c.buyer_name,'')),
   'buyer_contact_name',c.buyer_name,
   'buyer_email',c.buyer_email,'buyer_phone',c.buyer_phone)
 INTO parties FROM public.t_contracts c
 LEFT JOIN public.t_tenants seller ON seller.id=coalesce(c.seller_id,c.tenant_id)
 LEFT JOIN public.t_tenants buyer ON buyer.id=c.buyer_tenant_id
 WHERE c.id=NEW.contract_id;
 IF parties IS NULL THEN RAISE EXCEPTION 'Contract party details unavailable' USING ERRCODE='23514'; END IF;
 NEW.service_context_snapshot:=NEW.service_context_snapshot||jsonb_build_object('parties',parties);
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.snapshot_service_report_parties() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS service_form_submission_party_snapshot ON public.m_form_submissions;
CREATE TRIGGER service_form_submission_party_snapshot BEFORE INSERT OR UPDATE ON public.m_form_submissions
 FOR EACH ROW EXECUTE FUNCTION public.snapshot_service_report_parties();
