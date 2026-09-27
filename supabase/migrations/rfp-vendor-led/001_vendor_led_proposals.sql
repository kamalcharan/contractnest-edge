-- Shared proposal representation is the existing ConfigurableBlock shape.
-- Never trust client totals, catalogue IDs, tax metadata or pricing config.
create or replace function public.rfp_validate_proposal_blocks(p_blocks jsonb,p_request jsonb,p_currency text)
returns jsonb language plpgsql set search_path='' as $$
declare b jsonb; r jsonb; clean jsonb:='[]'; cfg jsonb; qty numeric; price numeric; days numeric; amount numeric:=0; line numeric;
begin
 if jsonb_typeof(p_blocks) is distinct from 'array' or jsonb_array_length(p_blocks) not between 1 and 100 then raise exception 'Add between 1 and 100 proposal commitments'; end if;
 if (select count(distinct x->>'id') from jsonb_array_elements(p_blocks) x)<>jsonb_array_length(p_blocks) then raise exception 'Commitment IDs must be unique'; end if;
 for b in select value from jsonb_array_elements(p_blocks) loop
  if nullif(trim(b->>'name'),'') is null or length(b->>'name')>300 then raise exception 'Name each commitment (maximum 300 characters)'; end if;
  if coalesce(b->>'id','') not like 'proposal-%' or coalesce(b->>'categoryId','') not in ('service','spare','text') then raise exception 'Use manual service, spare, session or text commitments'; end if;
  if b->>'currency' is distinct from p_currency then raise exception 'Commitment currency does not match the request'; end if;
  qty:=(b->>'quantity')::numeric; price:=coalesce(b->'config'->>'customPrice',b->>'price')::numeric;
  if qty is null or qty<1 or qty>100000 or qty<>trunc(qty) then raise exception 'Enter a positive whole quantity'; end if;
  if price is null or price<0 or price>100000000000 or price::text in ('NaN','Infinity','-Infinity') then raise exception 'Enter a valid unit price'; end if;
  if b->>'categoryId'<>'text' and price=0 and not coalesce((b->'config'->>'complimentary')::boolean,false) then raise exception 'Set a price or explicitly mark the commitment complimentary'; end if;
  if coalesce(b->>'cycle','') not in ('prepaid','postpaid','monthly','fortnightly','quarterly','custom') then raise exception 'Choose a supported billing cycle'; end if;
  if b->>'cycle'='custom' and (coalesce((b->>'customCycleDays')::numeric,0)<1 or (b->>'customCycleDays')::numeric>36500) then raise exception 'Enter a valid custom billing interval'; end if;
  days:=(b->>'serviceCycleDays')::numeric;
  if days is not null and (days<1 or days>36500 or days<>trunc(days)) then raise exception 'Enter a valid service interval'; end if;
  if b#>>'{config,serviceCycles,anchorWeekday}' is not null and (b#>>'{config,serviceCycles,anchorWeekday}')::integer not between 0 and 6 then raise exception 'Choose a valid weekday'; end if;
  if nullif(b#>>'{config,serviceCycles,anchorDate}','') is not null then perform (b#>>'{config,serviceCycles,anchorDate}')::date; end if;
  if b#>>'{config,serviceCycles,gracePeriod}' is not null and (b#>>'{config,serviceCycles,gracePeriod}')::integer not between 0 and 36500 then raise exception 'Enter a valid grace period'; end if;
  if nullif(b->>'requirementId','') is not null and not exists(select 1 from jsonb_array_elements(p_request->'blocks') x where x->>'id'=b->>'requirementId') then raise exception 'Requirement mapping is invalid'; end if;
  if jsonb_array_length(coalesce(p_request->'coverage','[]'))>0 and not exists(select 1 from jsonb_array_elements(p_request->'coverage') x where x->>'id'=b->>'coverageTypeId') then raise exception 'Map every commitment to requested coverage'; end if;
  cfg:=jsonb_build_object('showDescription',coalesce((b#>>'{config,showDescription}')::boolean,true),'content',coalesce(b->>'description',''),'customPrice',price,'spareCategory',left(b#>>'{config,spareCategory}',40),
   'complimentary',coalesce((b->'config'->>'complimentary')::boolean,false),'billingOnly',coalesce((b->'config'->>'billingOnly')::boolean,false),
   'audience',case when b->'config'->>'audience'='group' then 'group' else 'individual' end,
   'serviceCycles',jsonb_strip_nulls(jsonb_build_object('enabled',days is not null,'days',days,'anchorWeekday',case when days is not null then (b#>>'{config,serviceCycles,anchorWeekday}')::integer end,'anchorDate',case when days is not null then nullif(b#>>'{config,serviceCycles,anchorDate}','') end,'gracePeriod',case when days is not null then (b#>>'{config,serviceCycles,gracePeriod}')::integer end)));
  line:=case when b->>'categoryId'='text' or (cfg->>'complimentary')::boolean then 0 else round(price*case when coalesce((b->>'unlimited')::boolean,false) then 1 else qty end,2) end;
  amount:=amount+line;
  clean:=clean||jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('id',b->>'id','name',trim(b->>'name'),'description',coalesce(b->>'description',''),
   'categoryId',b->>'categoryId','categoryName',case when cfg->>'audience'='group' then 'Group Session' when b->>'categoryId'='spare' then 'Spare Parts' when b->>'categoryId'='text' then 'Text' else 'Service' end,
   'categoryColor','#285f48','icon','FileText','isFlyBy',true,'flyByType',b->>'categoryId','quantity',qty,'price',price,'totalPrice',line,
   'unlimited',coalesce((b->>'unlimited')::boolean,false),'currency',p_currency,'cycle',b->>'cycle','customCycleDays',b->'customCycleDays',
   'serviceCycleDays',days,'requirementId',b->>'requirementId','coverageTypeId',b->>'coverageTypeId',
   'coverageTypeName',(select x->>'name' from jsonb_array_elements(coalesce(p_request->'coverage','[]')) x where x->>'id'=b->>'coverageTypeId' limit 1),'config',cfg)));
 end loop;
 for r in select value from jsonb_array_elements(p_request->'blocks') loop
  if not exists(select 1 from jsonb_array_elements(clean) x where x->>'requirementId'=r->>'id') then raise exception 'Respond to requirement: %',r->>'name'; end if;
 end loop;
 if amount<=0 then raise exception 'Proposal total must be positive'; end if;
 return jsonb_build_object('blocks',clean,'amount',amount);
end $$;
revoke all on function public.rfp_validate_proposal_blocks(jsonb,jsonb,text) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION public.rfp_submit_response(p_cnak text, p_secret text, p_response jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE normalized jsonb; submitted jsonb; c t_contracts%rowtype; v t_contract_vendors%rowtype; q jsonb; answer text; d jsonb; result jsonb; note text;
BEGIN
 SELECT c0.* INTO c FROM t_contracts c0 JOIN t_contract_vendors v0 ON v0.contract_id=c0.id
 WHERE c0.global_access_id=upper(trim(p_cnak)) AND v0.access_secret=p_secret AND length(p_secret)>=24 AND c0.is_active AND c0.metadata ? 'rfp_buyer_v1' FOR UPDATE OF c0;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid request link'; END IF;
 SELECT * INTO v FROM t_contract_vendors WHERE contract_id=c.id AND access_secret=p_secret FOR UPDATE;
 IF c.status NOT IN ('sent','quotes_received') OR c.response_deadline<=now() THEN RAISE EXCEPTION 'This request is closed for responses'; END IF;
 d:=c.metadata->'rfp_buyer_v1';
 IF octet_length(p_response::text)>100000 THEN RAISE EXCEPTION 'Response is too large'; END IF;
 IF NOT COALESCE((p_response->>'acceptTerms')::boolean,false) THEN RAISE EXCEPTION 'Confirm the participation terms'; END IF;
 IF NULLIF(trim(p_response->>'billingTerms'),'') IS NULL THEN RAISE EXCEPTION 'Describe your proposed billing terms'; END IF;
 FOR q IN SELECT value FROM jsonb_array_elements(d->'questions') LOOP
  answer:=trim(COALESCE(p_response->'answers'->>(q->>'id'),''));
  IF COALESCE((q->>'required')::boolean,false) AND answer='' THEN RAISE EXCEPTION 'Answer required: %',q->>'text'; END IF;
  IF answer<>'' AND q->>'type'='number' AND answer !~ '^-?[0-9]+([.][0-9]+)?$' THEN RAISE EXCEPTION 'Enter a number: %',q->>'text'; END IF;
  IF answer<>'' AND q->>'type'='yesno' AND answer NOT IN ('Yes','No') THEN RAISE EXCEPTION 'Select Yes or No: %',q->>'text'; END IF;
  IF answer<>'' AND q->>'type'='file' AND answer !~ '^https://[^[:space:]]+$' THEN RAISE EXCEPTION 'Provide an HTTPS document link: %',q->>'text'; END IF;
 END LOOP;
 submitted:=p_response;
 IF p_response ? 'blocks' OR p_response->>'schema'='2' THEN
 normalized:=public.rfp_validate_proposal_blocks(p_response->'blocks',d,c.currency);
 IF abs((p_response->>'amount')::numeric-(normalized->>'amount')::numeric)>0.009 THEN RAISE EXCEPTION 'Proposal total does not match commitment prices'; END IF;
 submitted:=jsonb_build_object('schema',2,'blocks',normalized->'blocks','amount',normalized->'amount','billingTerms',p_response->>'billingTerms','approach',p_response->>'approach','answers',p_response->'answers','acceptTerms',true);
 END IF;
 note:=COALESCE(p_response->>'approach','')||E'\n\nBilling terms: '||(p_response->>'billingTerms')||E'\n\nQuestionnaire: '||COALESCE((p_response->'answers')::text,'{}');
 IF (p_response->>'amount')::numeric IS NULL OR (p_response->>'amount')::numeric<=0 OR (p_response->>'amount')::numeric='NaN'::numeric THEN RAISE EXCEPTION 'Enter a positive quote amount'; END IF;
 UPDATE t_contract_vendors SET response_status='quoted',quoted_amount=(p_response->>'amount')::numeric,quote_currency=c.currency,quote_notes=note,responded_at=now() WHERE id=v.id;
 UPDATE t_contract_access SET status='responded',responded_at=now() WHERE contract_id=c.id AND secret_code=p_secret;
 INSERT INTO t_contract_history(contract_id,tenant_id,action,performed_by_type,performed_by_name,note)
 VALUES(c.id,c.tenant_id,'rfq_quoted','vendor',v.vendor_name,'Vendor submitted RFP proposal and questionnaire');
 IF c.status='sent' THEN
  result:=update_contract_status(c.id,c.tenant_id,'quotes_received',NULL,v.vendor_name,'vendor','First RFP proposal received',NULL);
  IF NOT COALESCE((result->>'success')::boolean,false) THEN RAISE EXCEPTION 'Could not record proposal status'; END IF;
 END IF;
 result:=jsonb_build_object('success',true,'response_status','quoted');
 UPDATE t_contracts SET metadata=jsonb_set(metadata,ARRAY['rfp_response_'||v.id::text],submitted) WHERE id=c.id;
 RETURN result;
END $function$;

CREATE OR REPLACE FUNCTION public.rfq_resolve_for_vendor(p_cnak text, p_secret text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_vendor   RECORD;
    v_contract RECORD;
    v_blocks   JSONB;
BEGIN
    IF p_cnak IS NULL OR p_secret IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Link is incomplete',
                                  'error_code', 'MISSING_CREDENTIALS');
    END IF;

    SELECT cv.*, c.id AS c_id
      INTO v_vendor
      FROM t_contract_vendors cv
      JOIN t_contracts c ON c.id = cv.contract_id
     WHERE c.global_access_id = UPPER(TRIM(p_cnak))
       AND cv.access_secret = p_secret
       AND c.record_type = 'rfq'
       AND c.is_active = true
     LIMIT 1;

    IF v_vendor IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'This request link is not valid',
                                  'error_code', 'INVALID_LINK');
    END IF;

    SELECT * INTO v_contract FROM t_contracts WHERE id = v_vendor.contract_id;

    IF v_contract.status IN ('cancelled')
       AND v_vendor.response_status <> 'accepted' THEN
        RETURN jsonb_build_object('success', false,
                                  'error', 'This request is closed',
                                  'error_code', 'RFQ_CLOSED',
                                  'status', v_contract.status);
    END IF;

    -- service_cycle_days / unlimited: the vendor previously saw only
    -- quantity + billing_cycle (a buyer-payment-terms concept that means
    -- nothing before a contract exists, and whose "prepaid"/"postpaid"
    -- values had no display label at all on the vendor page). The actual
    -- useful fact -- how often the visit repeats -- lives in
    -- custom_fields.config.serviceCycleDays and was never selected here.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',            b.id,
               'position',      b.position,
               'block_name',    b.block_name,
               'block_description', b.block_description,
               'category_name', b.category_name,
               'quantity',      b.quantity,
               'billing_cycle', b.billing_cycle,
               'service_cycle_days', (b.custom_fields #>> '{config,serviceCycleDays}')::int,
               'unlimited', COALESCE((b.custom_fields #>> '{config,unlimited}')::boolean, false)
           ) ORDER BY b.position), '[]'::JSONB)
      INTO v_blocks
      FROM t_contract_blocks b
     WHERE b.contract_id = v_contract.id;

    -- Buyer's own prices are NOT exposed. The vendor is quoting, not matching.

    UPDATE t_contract_vendors
       SET viewed_at = COALESCE(viewed_at, NOW())
     WHERE id = v_vendor.id;

    UPDATE t_contract_access
       SET link_clicked_at = COALESCE(link_clicked_at, NOW())
     WHERE contract_id = v_contract.id
       AND secret_code = p_secret;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'rfp', CASE WHEN v_contract.metadata ? 'rfp_buyer_v1' THEN (v_contract.metadata->'rfp_buyer_v1') - 'invites' - 'tenantId' - 'isLive' - CASE WHEN COALESCE((v_contract.metadata->'rfp_buyer_v1'->>'shareBudget')::boolean,false) THEN '_none_' ELSE 'budget' END ELSE NULL END,
            'rfq', jsonb_build_object(
                'id',                v_contract.id,
                'rfq_number',        v_contract.rfq_number,
                'name',              v_contract.name,
                'description',       v_contract.description,
                'status',            v_contract.status,
                'currency',          v_contract.currency,
                'start_date',        v_contract.start_date,
                'duration_value',    v_contract.duration_value,
                'duration_unit',     v_contract.duration_unit,
                'nomenclature_code', v_contract.nomenclature_code,
                'nomenclature_name', v_contract.nomenclature_name,
                'equipment_details', COALESCE(v_contract.equipment_details, '[]'::JSONB)
            ),
            'buyer', jsonb_build_object(
                'tenant_id', v_contract.tenant_id
            ),
            'blocks', v_blocks,
            'me', jsonb_build_object(
                'proposal', v_contract.metadata->('rfp_response_'||v_vendor.id::text),
                'vendor_id',        v_vendor.vendor_id,
                'vendor_name',      v_vendor.vendor_name,
                'vendor_company',   v_vendor.vendor_company,
                'response_status',  v_vendor.response_status,
                'quoted_amount',    v_vendor.quoted_amount,
                'quote_currency',   v_vendor.quote_currency,
                'quote_notes',      v_vendor.quote_notes,
                'quote_breakdown',  v_vendor.quote_breakdown,
                'quote_valid_until',v_vendor.quote_valid_until,
                'responded_at',     v_vendor.responded_at
            )
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'Failed to open request',
                              'details', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

insert into public.n_jtd_source_types(code,name,description,default_event_type,source_table,source_id_field,default_channels,is_active)
values('rfp_awarded','RFP award','Selected vendor outcome and agreement preparation','notification','t_contracts','id',array['email','whatsapp'],true),
('rfp_not_selected','RFP outcome','Thank participating vendors without exposing other proposals','notification','t_contracts','id',array['email','whatsapp'],true)
on conflict(code) do nothing;

-- Provider IDs are deliberately unset until the owner registers these templates.
insert into public.n_jtd_templates(tenant_id,template_key,name,channel_code,source_type_code,subject,content,content_html,variables,provider_template_id,is_live,is_active)
select null,s.code||'_'||ch,s.name||' '||ch,ch,s.code,s.subject,s.body,
 case when ch='email' then '<!doctype html><html><body style="font-family:Arial,sans-serif;color:#243b35;background:#f5f7f4;padding:24px"><table role="presentation" style="max-width:600px;margin:auto;background:white;padding:32px;border-radius:16px"><tr><td><h2>'||s.name||'</h2><p>Hello {{recipient_name}},</p><p>'||s.emailbody||'</p><p>{{request_info}}</p><p><a href="{{request_link}}" style="display:inline-block;background:#285f48;color:white;padding:14px 20px;text-decoration:none;border-radius:8px">View request</a></p><p>This link is private to you. Award does not activate a contract or confirm payment.</p></td></tr></table></body></html>' end,
 case when ch='email' then '["recipient_name","buyer_name","request_info","request_link"]'::jsonb else '["recipient_name","buyer_name","request_info"]'::jsonb end,null,true,true
from (values
 ('rfp_awarded','Your proposal has been selected','Proposal selected: {{request_info}}','Hello {{1}}, {{2}} has selected your proposal for {{3}}. Open your private request link to prepare the agreement. Award alone does not activate a contract or confirm payment.','{{buyer_name}} has selected your proposal. Open the request to prepare the agreement from your submitted commitments.'),
 ('rfp_not_selected','Thank you for your proposal','Request outcome: {{request_info}}','Hello {{1}}, thank you for participating in {{3}}. {{2}} has selected another proposal for this request. We appreciate your time and consideration.','Thank you for participating. {{buyer_name}} has selected another proposal for this request. We appreciate your time and consideration.')
)s(code,name,subject,body,emailbody) cross join unnest(array['email','whatsapp'])ch
where not exists(select 1 from public.n_jtd_templates t where t.tenant_id is null and t.source_type_code=s.code and t.channel_code=ch);
insert into public.n_jtd_templates(tenant_id,template_key,name,channel_code,source_type_code,subject,content,content_html,variables,provider_template_id,is_live,is_active)
select tenant.id,g.template_key,g.name,g.channel_code,g.source_type_code,g.subject,g.content,g.content_html,g.variables,g.provider_template_id,true,true
from public.t_tenants tenant cross join public.n_jtd_templates g where g.tenant_id is null and g.source_type_code in ('rfp_awarded','rfp_not_selected')
and not exists(select 1 from public.n_jtd_templates t where t.tenant_id=tenant.id and t.source_type_code=g.source_type_code and t.channel_code=g.channel_code)
on conflict do nothing;
create unique index if not exists uq_rfp_award_notice on public.n_jtd(source_id,recipient_id,channel_code,source_type_code)
where source_type_code in ('rfp_awarded','rfp_not_selected');

create or replace function public.rfp_queue_award_notices(p_id uuid,p_user uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.t_contracts%rowtype; v record; delivery record; vars jsonb; source text; output jsonb:='[]'; template public.n_jtd_templates%rowtype; existing public.n_jtd%rowtype; sender text; destinations integer;
begin
 select * into c from public.t_contracts where id=p_id for update;
 if not found or c.status<>'awarded' then raise exception 'Award the request first'; end if;
 if not exists(select 1 from public.t_user_tenants where user_id=p_user and tenant_id=c.tenant_id and status='active') then raise exception 'Workspace access denied'; end if;
 select name into sender from public.t_tenants where id=c.tenant_id;
 for v in select * from public.t_contract_vendors where contract_id=c.id loop
  source:=case when v.response_status='accepted' then 'rfp_awarded' else 'rfp_not_selected' end;
  destinations:=0;
  for delivery in select distinct on(j.channel_code) j.* from public.n_jtd j where j.source_id=c.id and j.source_type_code='rfp_invitation' and j.recipient_id=v.vendor_id and j.tenant_id=c.tenant_id and j.is_live=c.is_live order by j.channel_code,j.created_at desc loop
   destinations:=destinations+1;
   select * into existing from public.n_jtd where source_id=c.id and recipient_id=v.vendor_id and channel_code=delivery.channel_code and source_type_code=source;
   if found then output:=output||jsonb_build_array(jsonb_build_object('id',existing.id,'name',v.vendor_name,'channel',delivery.channel_code,'status',existing.status_code,'error',existing.error_message)); continue; end if;
   if exists(select 1 from public.n_jtd_tenant_config where tenant_id=c.tenant_id and is_live=c.is_live and not coalesce((channels_enabled->>delivery.channel_code)::boolean,false)) then
    output:=output||jsonb_build_array(jsonb_build_object('name',v.vendor_name,'channel',delivery.channel_code,'status','channel_disabled')); continue;
   end if;
   select * into template from public.n_jtd_templates where source_type_code=source and channel_code=delivery.channel_code and (tenant_id=c.tenant_id or tenant_id is null) order by (tenant_id is not null) desc limit 1;
   if not found or not template.is_active or nullif(template.provider_template_id,'') is null then
    output:=output||jsonb_build_array(jsonb_build_object('name',v.vendor_name,'channel',delivery.channel_code,'status','awaiting_template')); continue;
   end if;
   vars:=jsonb_build_object('recipient_name',v.vendor_name,'buyer_name',sender,'request_info',c.name||' ('||c.rfq_number||')','request_link','https://www.contractnest.com/quote/'||c.global_access_id||'/'||v.access_secret,'request_link_suffix',c.global_access_id||'/'||v.access_secret);
   insert into public.n_jtd(tenant_id,event_type_code,channel_code,source_type_code,source_id,contract_id,recipient_id,recipient_name,recipient_contact,status_code,priority,payload,template_key,template_variables,metadata,is_live,performed_by_type,performed_by_id,created_by)
   values(c.tenant_id,'notification',delivery.channel_code,source,c.id,c.id,v.vendor_id,v.vendor_name,delivery.recipient_contact,'created',5,
    jsonb_build_object('recipient_data',delivery.payload->'recipient_data','template_data',vars),source||'_'||delivery.channel_code,vars,jsonb_build_object('contract_id',c.id,'vendor_id',v.vendor_id),c.is_live,'user',p_user,p_user)
   returning * into existing;
   output:=output||jsonb_build_array(jsonb_build_object('id',existing.id,'name',v.vendor_name,'channel',delivery.channel_code,'status',existing.status_code));
  end loop;
  if destinations=0 then output:=output||jsonb_build_array(jsonb_build_object('name',v.vendor_name,'channel','none','status','no_invitation_destination')); end if;
 end loop;
 update public.t_contracts set metadata=metadata||jsonb_build_object('rfp_award_deliveries',output) where id=c.id;
 return output;
end $$;
revoke all on function public.rfp_queue_award_notices(uuid,uuid) from public,anon,authenticated,service_role;

create or replace function public.rfp_award_delivery(p_id uuid,p_tenant uuid,p_live boolean,p_retry boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.t_contracts%rowtype; output jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.t_user_tenants where user_id=auth.uid() and tenant_id=p_tenant and status='active') then raise exception 'Workspace access denied'; end if;
 select * into c from public.t_contracts where id=p_id and tenant_id=p_tenant and is_live=p_live and record_type='rfq' and is_active;
 if not found then raise exception 'Request not found'; end if;
 if p_retry then return public.rfp_queue_award_notices(p_id,auth.uid()); end if;
 select coalesce(jsonb_agg(case when item->>'id' is not null then item||jsonb_build_object('status',coalesce(j.status_code,item->>'status'),'error',j.error_message) else item end),'[]') into output
 from jsonb_array_elements(coalesce(c.metadata->'rfp_award_deliveries','[]')) item left join public.n_jtd j on j.id=(item->>'id')::uuid;
 return output;
end $$;
revoke all on function public.rfp_award_delivery(uuid,uuid,boolean,boolean) from public,anon;
grant execute on function public.rfp_award_delivery(uuid,uuid,boolean,boolean) to authenticated;

create or replace function public.rfp_create_agreement_draft(p_contract_id uuid,p_tenant_id uuid,p_user_id uuid,p_relationship text)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare r public.t_contracts%rowtype; v public.t_contract_vendors%rowtype; d jsonb; result jsonb; state jsonb; origin jsonb; coverage jsonb; equipment jsonb; commitments jsonb; linked uuid; buyer_name text;
begin
 select * into r from public.t_contracts where id=p_contract_id and is_active and record_type='rfq' for update;
 if not found or r.status<>'awarded' then raise exception 'Awarded request not found'; end if;
 if p_relationship not in ('client','vendor') then raise exception 'Invalid relationship'; end if;
 select name into buyer_name from public.t_tenants where id=r.tenant_id;
 linked := nullif(r.metadata->>'rfp_contract_draft_id','')::uuid;
 if linked is not null then
   if exists(select 1 from public.t_contracts where id=linked and tenant_id=p_tenant_id and is_live=r.is_live and is_active and record_type='contract') then
     return jsonb_build_object('success',true,'data',jsonb_build_object('id',linked,'existing',true));
   end if;
   return jsonb_build_object('success',false,'error_code','INVALID_STATE','error','An agreement is already linked in another workspace, or its draft is unavailable. Continue that agreement instead of creating a duplicate.');
 end if;
 select * into v from public.t_contract_vendors where contract_id=r.id and tenant_id=r.tenant_id and response_status='accepted';
 if not found or v.vendor_id is null or v.quoted_amount is null then
   return jsonb_build_object('success',false,'error_code','INVALID_STATE','error','The awarded vendor or quote is unavailable.');
 end if;
 d := r.metadata->'rfp_buyer_v1';
 if d is null then return jsonb_build_object('success',false,'error_code','INVALID_STATE','error','This action requires a structured RFP.'); end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',c->>'id','sub_category',case when c->>'family'='facility' then 'entity' else c->>'family' end,
   'resource_id',c->>'resourceId','resource_name',c->>'name','unit_count',c->'quantity')),'[]'::jsonb)
 into coverage from jsonb_array_elements(coalesce(d->'coverage','[]')) c;
 select coalesce(jsonb_agg(jsonb_build_object('id',c->>'id','asset_registry_id',c->'registryId','added_by_tenant_id',r.tenant_id,
   'added_by_role','buyer','resource_type',case when c->>'family'='facility' then 'entity' else 'equipment' end,
   'category_id',c->'resourceId','category_name',c->>'name','item_name',c->>'name','quantity',c->'quantity',
   'location',c->>'location','specifications',case when c->>'registryId' is null then '{"placeholder":true}'::jsonb else '{}'::jsonb end)),'[]'::jsonb)
 into equipment from jsonb_array_elements(coalesce(d->'coverage','[]')) c where c->>'family'<>'service';
 select coalesce(jsonb_agg(jsonb_build_object(
   'id','rfp-'||(b->>'id'),'name',b->>'name','description',coalesce(b->>'description',''),'icon','FileText',
   'categoryId',case when b->>'type'='session' then 'service' else b->>'type' end,
   'categoryName',case b->>'type' when 'session' then 'Group Session' when 'spare' then 'Spare Parts' when 'text' then 'Text' else 'Service' end,
   'categoryColor','#285c48','isFlyBy',true,'flyByType',case when b->>'type'='session' then 'service' else b->>'type' end,
   'quantity',b->'quantity','unlimited',coalesce(b->'unlimited','false'::jsonb),'price',0,'totalPrice',0,'currency',d->>'currency',
   'cycle','PrePaid','serviceCycleDays',b->'serviceCycleDays',
   'coverageTypeId',case when jsonb_array_length(coalesce(b->'coverageIds','[]'))=1 then b->'coverageIds'->>0 else null end,
   'config',jsonb_build_object('showDescription',true,'content',b->>'description','audience',case when b->>'type'='session' then 'group' else 'individual' end,
     'serviceCycles',jsonb_build_object('enabled',coalesce((b->>'serviceCycleDays')::numeric,0)>0,'days',b->'serviceCycleDays'))
 )),'[]'::jsonb) into commitments from jsonb_array_elements(coalesce(d->'blocks','[]')) b;
 if jsonb_typeof(r.metadata->('rfp_response_'||v.id::text)->'blocks')='array' then
   commitments := r.metadata->('rfp_response_'||v.id::text)->'blocks';
 end if;
 origin := jsonb_build_object('prepared_by',case when p_relationship='client' then 'vendor' else 'buyer' end,'request_id',r.id,'request_number',r.rfq_number,'vendor_id',v.vendor_id,'vendor_name',v.vendor_name,
   'quoted_amount',v.quoted_amount,'currency',r.currency,'request',d-'invites'-'tenantId'-'isLive'-'budget','response',r.metadata->('rfp_response_'||v.id::text));
 state := jsonb_build_object('path','scratch','wizardMode','contract','contractName',r.name,'description',coalesce(d->>'brief',r.description),
   'buyerId',case when p_relationship='vendor' then v.vendor_id else null end,'buyerName',case when p_relationship='vendor' then coalesce(v.vendor_company,v.vendor_name) else buyer_name end,'currency',r.currency,
   'startDate',r.start_date,'durationValue',r.duration_value,'durationUnit',coalesce(r.duration_unit,'months'),
   'nomenclatureId',d->'nomenclature'->>'id','nomenclatureName',d->'nomenclature'->>'label','nomenclatureGroup',d->'nomenclature'->>'group',
   'coverageTypes',coverage,'equipmentDetails',equipment,'selectedBlocks',commitments,'totalValue',v.quoted_amount,'baseSubtotal',v.quoted_amount,'grandTotal',v.quoted_amount,'acceptanceMethod',null);
 result := public.create_contract_transaction(jsonb_build_object('tenant_id',p_tenant_id,'created_by',p_user_id,'is_live',r.is_live,
   'record_type','contract','contract_type',p_relationship,'name',r.name,'description',coalesce(d->>'brief',r.description),
   'buyer_id',case when p_relationship='vendor' then v.vendor_id else null end,'buyer_tenant_id',case when p_relationship='client' then r.tenant_id else null end,'buyer_name',case when p_relationship='vendor' then coalesce(v.vendor_company,v.vendor_name) else buyer_name end,'currency',r.currency,'start_date',r.start_date,
   'duration_value',r.duration_value,'duration_unit',r.duration_unit,'nomenclature_id',r.nomenclature_id,
   'total_value',v.quoted_amount,'grand_total',v.quoted_amount,'coverage_types',coverage,'equipment_details',equipment,
   'metadata',jsonb_build_object('rfp_origin',origin,'wizard_state',state,'wizard_contract_type',p_relationship,
     'experience_chapter','agreement','experience_step','agreement','experience_version',3)),
   ('rfp-contract-'||r.id::text)::varchar);
 if not coalesce((result->>'success')::boolean,false) then raise exception 'Draft creation failed: %',coalesce(result->>'details',result->>'error'); end if;
 linked := (result->'data'->>'id')::uuid;
 update public.t_contracts set metadata=coalesce(metadata,'{}')||jsonb_build_object('rfp_contract_draft_id',linked,'rfp_contract_owner_tenant',p_tenant_id,'rfp_agreement_prepared_by',case when p_relationship='client' then 'vendor' else 'buyer' end),
   version=version+1,updated_at=now(),updated_by=p_user_id where id=r.id;
 return jsonb_build_object('success',true,'data',jsonb_build_object('id',linked,'existing',false));

end $function$;
revoke all on function public.rfp_create_agreement_draft(uuid,uuid,uuid,text) from public,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.rfp_buyer_action(p_action text, p_contract_id uuid, p_tenant_id uuid, p_user_id uuid, p_is_live boolean DEFAULT NULL::boolean, p_vendor_id uuid DEFAULT NULL::uuid, p_user_name text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 r public.t_contracts%rowtype;
 v public.t_contract_vendors%rowtype;
 d jsonb; result jsonb; state jsonb; origin jsonb;
 coverage jsonb; equipment jsonb; commitments jsonb; linked uuid;
begin
 if p_user_id is null or not exists (
   select 1 from public.t_user_tenants where user_id=p_user_id and tenant_id=p_tenant_id and status='active'
 ) then return jsonb_build_object('success',false,'error_code','FORBIDDEN','error','You do not have access to this workspace.'); end if;
 select * into r from public.t_contracts where id=p_contract_id and tenant_id=p_tenant_id and record_type='rfq' and is_active for update;
 if not found or (p_is_live is not null and r.is_live<>p_is_live) then
   return jsonb_build_object('success',false,'error_code','NOT_FOUND','error','Request not found in this workspace.');
 end if;
 if p_action='award' then
   if r.status='awarded' and exists(select 1 from public.t_contract_vendors where contract_id=r.id and vendor_id=p_vendor_id and response_status='accepted') then
     return jsonb_build_object('success',true,'data',jsonb_build_object('contract_id',r.id,'status','awarded','awarded_to',p_vendor_id));
   end if;
   if r.status<>'quotes_received' then return jsonb_build_object('success',false,'error_code','INVALID_STATE','error','This request is not open for an award.'); end if;
   result:=public.rfq_award(r.id,p_tenant_id,p_vendor_id,p_user_id,p_user_name,p_note);
   if coalesce((result->>'success')::boolean,false) then
     perform public.rfp_queue_award_notices(r.id,p_user_id);
   end if;
   return result;
 end if;
 if p_action<>'prepare_contract' or p_is_live is null then
   return jsonb_build_object('success',false,'error_code','INVALID_INPUT','error','Invalid action or workspace.');
 end if;
 if r.status<>'awarded' then return jsonb_build_object('success',false,'error_code','INVALID_STATE','error','Award a proposal before preparing its contract.'); end if;
 return public.rfp_create_agreement_draft(r.id,p_tenant_id,p_user_id,'vendor');
end $function$;
revoke all on function public.rfp_buyer_action(text,uuid,uuid,uuid,boolean,uuid,text,text) from public,anon,authenticated;
grant execute on function public.rfp_buyer_action(text,uuid,uuid,uuid,boolean,uuid,text,text) to service_role;

create or replace function public.rfp_vendor_prepare(p_cnak text,p_secret text,p_tenant uuid,p_live boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.t_contracts%rowtype; v public.t_contract_vendors%rowtype; account auth.users%rowtype; matches boolean;
begin
 if auth.uid() is null or not exists(select 1 from public.t_user_tenants where user_id=auth.uid() and tenant_id=p_tenant and status='active') then raise exception 'Choose a workspace you belong to'; end if;
 select c.* into r from public.t_contracts c join public.t_contract_vendors cv on cv.contract_id=c.id
 where c.global_access_id=upper(trim(p_cnak)) and cv.access_secret=p_secret and length(p_secret)>=24 and c.record_type='rfq' and c.is_active and c.is_live=p_live for update of c;
 if not found then raise exception 'Request not found in this live/test environment'; end if;
 select * into v from public.t_contract_vendors where contract_id=r.id and access_secret=p_secret;
 if r.status<>'awarded' or v.response_status<>'accepted' then raise exception 'Only the awarded vendor can prepare this agreement'; end if;
 if p_tenant=r.tenant_id then raise exception 'Choose the vendor workspace, not the requesting business workspace'; end if;
 select * into account from auth.users where id=auth.uid();
 matches:=account.email_confirmed_at is not null and lower(trim(account.email))=lower(trim(v.vendor_email));
 if not coalesce(matches,false) then
  select exists(select 1 from public.t_contact_channels ch where ch.contact_id=v.vendor_id and ch.channel_type='mobile' and account.phone_confirmed_at is not null
   and (regexp_replace(ch.value,'[^0-9]','','g')=regexp_replace(account.phone,'[^0-9]','','g')
    or (nullif(ch.country_code,'') is not null and regexp_replace(ch.country_code||ch.value,'[^0-9]','','g')=regexp_replace(account.phone,'[^0-9]','','g')))) into matches;
 end if;
 if not coalesce(matches,false) then raise exception 'Sign in with the verified email or mobile that received this invitation. The private link alone does not establish account ownership.'; end if;
 return public.rfp_create_agreement_draft(r.id,p_tenant,auth.uid(),'client');
end $$;
revoke all on function public.rfp_vendor_prepare(text,text,uuid,boolean) from public,anon;
grant execute on function public.rfp_vendor_prepare(text,text,uuid,boolean) to authenticated;

