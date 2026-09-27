-- Only the authenticated API calls this service-role RPC. It verifies actual membership.
create or replace function public.rfp_buyer_action(
 p_action text, p_contract_id uuid, p_tenant_id uuid, p_user_id uuid,
 p_is_live boolean default null, p_vendor_id uuid default null,
 p_user_name text default null, p_note text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
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
   return public.rfq_award(r.id,p_tenant_id,p_vendor_id,p_user_id,p_user_name,p_note);
 end if;
 if p_action<>'prepare_contract' or p_is_live is null then
   return jsonb_build_object('success',false,'error_code','INVALID_INPUT','error','Invalid action or workspace.');
 end if;
 if r.status<>'awarded' then return jsonb_build_object('success',false,'error_code','INVALID_STATE','error','Award a proposal before preparing its contract.'); end if;
 linked := nullif(r.metadata->>'rfp_contract_draft_id','')::uuid;
 if linked is not null then
   if exists(select 1 from public.t_contracts where id=linked and tenant_id=p_tenant_id and is_live=r.is_live and is_active and record_type='contract') then
     return jsonb_build_object('success',true,'data',jsonb_build_object('id',linked,'existing',true));
   end if;
   return jsonb_build_object('success',false,'error_code','INVALID_STATE','error','The linked contract is unavailable. Restore it before preparing another.');
 end if;
 select * into v from public.t_contract_vendors where contract_id=r.id and tenant_id=p_tenant_id and response_status='accepted';
 if not found or v.vendor_id is null or v.quoted_amount is null then
   return jsonb_build_object('success',false,'error_code','INVALID_STATE','error','The awarded vendor or quote is unavailable.');
 end if;
 d := r.metadata->'rfp_buyer_v1';
 if d is null then return jsonb_build_object('success',false,'error_code','INVALID_STATE','error','This action requires a structured RFP.'); end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',c->>'id','sub_category',case when c->>'family'='facility' then 'entity' else c->>'family' end,
   'resource_id',c->>'resourceId','resource_name',c->>'name','unit_count',c->'quantity')),'[]'::jsonb)
 into coverage from jsonb_array_elements(coalesce(d->'coverage','[]')) c;
 select coalesce(jsonb_agg(jsonb_build_object('id',c->>'id','asset_registry_id',c->'registryId','added_by_tenant_id',p_tenant_id,
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
 origin := jsonb_build_object('request_id',r.id,'request_number',r.rfq_number,'vendor_id',v.vendor_id,'vendor_name',v.vendor_name,
   'quoted_amount',v.quoted_amount,'currency',r.currency,'request',d-'invites'-'tenantId'-'isLive'-'budget','response',r.metadata->('rfp_response_'||v.id::text));
 state := jsonb_build_object('path','scratch','wizardMode','contract','contractName',r.name,'description',coalesce(d->>'brief',r.description),
   'buyerId',v.vendor_id,'buyerName',coalesce(v.vendor_company,v.vendor_name),'currency',r.currency,
   'startDate',r.start_date,'durationValue',r.duration_value,'durationUnit',coalesce(r.duration_unit,'months'),
   'nomenclatureId',d->'nomenclature'->>'id','nomenclatureName',d->'nomenclature'->>'label','nomenclatureGroup',d->'nomenclature'->>'group',
   'coverageTypes',coverage,'equipmentDetails',equipment,'selectedBlocks',commitments,'acceptanceMethod',null);
 result := public.create_contract_transaction(jsonb_build_object('tenant_id',p_tenant_id,'created_by',p_user_id,'is_live',r.is_live,
   'record_type','contract','contract_type','vendor','name',r.name,'description',coalesce(d->>'brief',r.description),
   'buyer_id',v.vendor_id,'buyer_name',coalesce(v.vendor_company,v.vendor_name),'currency',r.currency,'start_date',r.start_date,
   'duration_value',r.duration_value,'duration_unit',r.duration_unit,'nomenclature_id',r.nomenclature_id,
   'metadata',jsonb_build_object('rfp_origin',origin,'wizard_state',state,'wizard_contract_type','vendor',
     'experience_chapter','agreement','experience_step','agreement','experience_version',3)),
   ('rfp-contract-'||r.id::text)::varchar);
 if not coalesce((result->>'success')::boolean,false) then raise exception 'Draft creation failed: %',coalesce(result->>'details',result->>'error'); end if;
 linked := (result->'data'->>'id')::uuid;
 update public.t_contracts set metadata=coalesce(metadata,'{}')||jsonb_build_object('rfp_contract_draft_id',linked),
   version=version+1,updated_at=now(),updated_by=p_user_id where id=r.id;
 return jsonb_build_object('success',true,'data',jsonb_build_object('id',linked,'existing',false));
end $$;
revoke all on function public.rfp_buyer_action(text,uuid,uuid,uuid,boolean,uuid,text,text) from public,anon,authenticated;
grant execute on function public.rfp_buyer_action(text,uuid,uuid,uuid,boolean,uuid,text,text) to service_role;
