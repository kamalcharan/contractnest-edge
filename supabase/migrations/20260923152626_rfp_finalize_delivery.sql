-- RFP finalization uses existing contract/vendor/access/JTD tables.
-- Authenticated buyer endpoints check membership; public response is capability-scoped.
CREATE OR REPLACE FUNCTION public.rfp_delivery_receipt(p_id uuid,p_tenant uuid,p_live boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE c t_contracts%rowtype;
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM t_user_tenants WHERE user_id=auth.uid() AND tenant_id=p_tenant AND status='active') THEN RAISE EXCEPTION 'Workspace access denied'; END IF;
 SELECT * INTO c FROM t_contracts WHERE id=p_id AND tenant_id=p_tenant AND is_live=p_live AND is_active AND metadata ? 'rfp_buyer_v1';
 IF NOT FOUND THEN RAISE EXCEPTION 'Request not found'; END IF;
 RETURN jsonb_build_object('id',c.id,'number',c.rfq_number,'status',c.status,'cnak',c.global_access_id,'sentAt',c.sent_at,
 'disabledChannels',COALESCE((SELECT jsonb_agg(k.key) FROM n_jtd_tenant_config cfg CROSS JOIN LATERAL jsonb_each(cfg.channels_enabled) k WHERE cfg.tenant_id=p_tenant AND cfg.is_live=p_live AND k.key IN ('email','whatsapp') AND k.value='false'::jsonb),'[]'::jsonb),
 'deliveries',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',j.id,'name',j.recipient_name,'channel',j.channel_code,'status',j.status_code,'error',j.error_message) ORDER BY j.created_at,j.channel_code) FROM n_jtd j WHERE j.tenant_id=p_tenant AND j.is_live=p_live AND j.source_id=p_id AND j.source_type_code='rfp_invitation'),'[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.rfp_delivery_receipt(uuid,uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rfp_delivery_receipt(uuid,uuid,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.rfp_finalize(p_id uuid,p_tenant uuid,p_live boolean,p_version integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE c t_contracts%rowtype; d jsonb; v jsonb; ct t_contacts%rowtype; ch record; cv record; r jsonb; vars jsonb;
 sender text; suffix text; destination text; channel text; deadline timestamptz; mail text; mobile text; dial text; sent integer;
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM t_user_tenants WHERE user_id=auth.uid() AND tenant_id=p_tenant AND status='active') THEN RAISE EXCEPTION 'Workspace access denied'; END IF;
 SELECT * INTO c FROM t_contracts WHERE id=p_id AND tenant_id=p_tenant AND is_live=p_live AND is_active AND record_type='rfq' FOR UPDATE;
 IF NOT FOUND OR NOT(c.metadata ? 'rfp_buyer_v1') THEN RAISE EXCEPTION 'Request not found'; END IF;
 -- A repeated click/retry returns the original result, never new invitations.
 IF c.status<>'draft' THEN RETURN rfp_delivery_receipt(p_id,p_tenant,p_live); END IF;
 IF p_version IS NULL OR c.version<>p_version THEN RAISE EXCEPTION 'Request changed. Reopen it before sending.'; END IF;
 d:=c.metadata->'rfp_buyer_v1';
 IF NULLIF(trim(d->>'title'),'') IS NULL OR NULLIF(trim(d->>'terms'),'') IS NULL OR jsonb_array_length(d->'coverage')<1 OR jsonb_array_length(d->'blocks')<1 OR jsonb_array_length(d->'invites')<1 THEN RAISE EXCEPTION 'Complete the request and select vendors before sending'; END IF;
 deadline:=((d->>'deadline')||'T'||(d->>'deadlineTime')||':00+05:30')::timestamptz;
 IF deadline IS NULL OR deadline<=now() THEN RAISE EXCEPTION 'The response deadline must be in the future'; END IF;
 SELECT COALESCE(NULLIF(p.business_name,''),t.name) INTO sender FROM t_tenants t LEFT JOIN t_tenant_profiles p ON p.tenant_id=t.id WHERE t.id=p_tenant LIMIT 1;
 IF NULLIF(sender,'') IS NULL THEN RAISE EXCEPTION 'Set your business name before sending'; END IF;
 IF EXISTS(SELECT 1 FROM n_jtd_tenant_config WHERE tenant_id=p_tenant AND is_live=p_live AND NOT is_active) THEN RAISE EXCEPTION 'Messaging is disabled for this workspace'; END IF;
 IF EXISTS(SELECT 1 FROM t_contract_vendors WHERE contract_id=p_id) THEN RAISE EXCEPTION 'Draft already has legacy recipients. Review before sending.'; END IF;
 FOR v IN SELECT value FROM jsonb_array_elements(d->'invites') LOOP
  SELECT * INTO ct FROM t_contacts WHERE id=(v->>'contactId')::uuid AND tenant_id=p_tenant AND is_live=p_live AND status='active' AND classifications @> '["vendor"]'::jsonb;
  IF NOT FOUND THEN RAISE EXCEPTION 'A selected vendor is no longer active in this workspace'; END IF;
  SELECT value INTO mail FROM t_contact_channels WHERE contact_id=ct.id AND channel_type='email' AND value ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' ORDER BY is_primary DESC LIMIT 1;
  INSERT INTO t_contract_vendors(contract_id,tenant_id,vendor_id,vendor_name,vendor_company,vendor_email,response_status,access_secret)
  VALUES(p_id,p_tenant,ct.id,COALESCE(NULLIF(ct.company_name,''),ct.name),ct.company_name,mail,'pending',replace(gen_random_uuid()::text,'-',''));
 END LOOP;
 UPDATE t_contracts SET response_deadline=deadline,metadata=metadata||jsonb_build_object('rfp_release_stage','finalized','rfp_finalized_at',now()) WHERE id=p_id;
 r:=update_contract_status(p_id,p_tenant,'sent',auth.uid(),NULL,'user','RFP finalized and vendor invitations queued',p_version);
 IF NOT COALESCE((r->>'success')::boolean,false) THEN RAISE EXCEPTION '%',COALESCE(r->>'error','Could not finalize request'); END IF;
 SELECT * INTO c FROM t_contracts WHERE id=p_id;
 FOR cv IN SELECT * FROM t_contract_vendors WHERE contract_id=p_id LOOP
  sent:=0; suffix:=c.global_access_id||'/'||cv.access_secret;
  FOR ch IN SELECT DISTINCT ON(channel_type) channel_type,value,country_code FROM t_contact_channels WHERE contact_id=cv.vendor_id AND channel_type IN ('email','mobile') ORDER BY channel_type,is_primary DESC LOOP
   channel:=CASE WHEN ch.channel_type='email' THEN 'email' ELSE 'whatsapp' END;
   destination:=trim(ch.value);
   IF channel='email' AND destination !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' THEN CONTINUE; END IF;
   IF channel='whatsapp' THEN
    mobile:=regexp_replace(destination,'[^0-9]','','g');
    dial:=COALESCE(('{"IN":"91","US":"1","GB":"44","AF":"93","AL":"355","DZ":"213","AD":"376","AO":"244","AG":"1268","AR":"54","AM":"374","AU":"61","AT":"43","AZ":"994","BS":"1242","BH":"973","BD":"880","BB":"1246","BY":"375","BE":"32","BZ":"501","BJ":"229","BT":"975","BO":"591","BA":"387","BW":"267","BR":"55","BN":"673","BG":"359","BF":"226","BI":"257","KH":"855","CM":"237","CA":"1","CV":"238","CF":"236","TD":"235","CL":"56","CN":"86","CO":"57","KM":"269","CD":"243","CG":"242","CR":"506","CI":"225","HR":"385","CU":"53","CY":"357","CZ":"420","DK":"45","DJ":"253","DM":"1767","DO":"1809","EC":"593","EG":"20","SV":"503","GQ":"240","ER":"291","EE":"372","ET":"251","FJ":"679","FI":"358","FR":"33","GA":"241","GM":"220","GE":"995","DE":"49","GH":"233","GR":"30","GD":"1473","GT":"502","GN":"224","GW":"245","GY":"592","HT":"509","HN":"504","HU":"36","IS":"354","ID":"62","IR":"98","IQ":"964","IE":"353","IL":"972","IT":"39","JM":"1876","JP":"81","JO":"962","KZ":"7","KE":"254","KI":"686","KP":"850","KR":"82","KW":"965","KG":"996","LA":"856","LV":"371","LB":"961","LS":"266","LR":"231","LY":"218","LI":"423","LT":"370","LU":"352","MK":"389","MG":"261","MW":"265","MY":"60","MV":"960","ML":"223","MT":"356","MH":"692","MR":"222","MU":"230","MX":"52","FM":"691","MD":"373","MC":"377","MN":"976","ME":"382","MA":"212","MZ":"258","MM":"95","NA":"264","NR":"674","NP":"977","NL":"31","NZ":"64","NI":"505","NE":"227","NG":"234","NO":"47","OM":"968","PK":"92","PW":"680","PS":"970","PA":"507","PG":"675","PY":"595","PE":"51","PH":"63","PL":"48","PT":"351","QA":"974","RO":"40","RU":"7","RW":"250","KN":"1869","LC":"1758","VC":"1784","WS":"685","SM":"378","ST":"239","SA":"966","SN":"221","RS":"381","SC":"248","SL":"232","SG":"65","SK":"421","SI":"386","SB":"677","SO":"252","ZA":"27","SS":"211","ES":"34","LK":"94","SD":"249","SR":"597","SE":"46","CH":"41","SY":"963","TW":"886","TJ":"992","TZ":"255","TH":"66","TL":"670","TG":"228","TO":"676","TT":"1868","TN":"216","TR":"90","TM":"993","TV":"688","UG":"256","UA":"380","AE":"971","UY":"598","UZ":"998","VU":"678","VA":"379","VE":"58","VN":"84","YE":"967","ZM":"260","ZW":"263"}'::jsonb)->>ch.country_code,CASE WHEN ch.country_code ~ '^[+]?[0-9]{1,4}$' THEN regexp_replace(ch.country_code,'[^0-9]','','g') END);
    IF destination LIKE '+%' AND dial IS NOT NULL AND mobile LIKE dial||'%' THEN destination:=mobile;
    ELSIF destination LIKE '+%' THEN CONTINUE;
    ELSIF dial IS NOT NULL THEN destination:=dial||mobile;
    ELSE CONTINUE; END IF;
    IF destination !~ '^[1-9][0-9]{6,14}$' THEN CONTINUE; END IF;
   END IF;
   IF EXISTS(SELECT 1 FROM n_jtd_tenant_config WHERE tenant_id=p_tenant AND is_live=p_live AND NOT COALESCE((channels_enabled->>channel)::boolean,false)) THEN CONTINUE; END IF;
   IF NOT EXISTS(SELECT 1 FROM n_jtd_templates WHERE source_type_code='rfp_invitation' AND channel_code=channel AND is_active AND (tenant_id=p_tenant OR tenant_id IS NULL) AND NULLIF(provider_template_id,'') IS NOT NULL) THEN RAISE EXCEPTION 'RFP % template is not configured',channel; END IF;
   vars:=jsonb_build_object('recipient_name',cv.vendor_name,'buyer_name',sender,'request_title',d->>'title','request_number',c.rfq_number,'request_info',(d->>'title')||' ('||c.rfq_number||')','response_deadline',to_char(deadline AT TIME ZONE 'Asia/Kolkata','DD Mon YYYY HH24:MI')||' IST','request_link','https://www.contractnest.com/quote/'||suffix,'request_link_suffix',suffix);
   INSERT INTO n_jtd(tenant_id,event_type_code,channel_code,source_type_code,source_id,recipient_id,recipient_name,recipient_contact,status_code,priority,payload,template_key,template_variables,metadata,is_live,performed_by_id,created_by)
   VALUES(p_tenant,'notification',channel,'rfp_invitation',p_id,cv.vendor_id,cv.vendor_name,destination,'created',5,jsonb_build_object('recipient_data',jsonb_build_object('name',cv.vendor_name,'email',CASE WHEN channel='email' THEN destination END,'mobile',CASE WHEN channel='whatsapp' THEN destination END,'country_code',CASE WHEN channel='whatsapp' THEN dial END),'template_data',vars),'rfp_invitation_'||channel,vars,jsonb_build_object('contract_id',p_id,'vendor_id',cv.vendor_id),p_live,auth.uid(),auth.uid());
   sent:=sent+1;
  END LOOP;
  IF sent=0 THEN RAISE EXCEPTION '% has no valid enabled email or WhatsApp channel. Check Contacts and messaging settings.',cv.vendor_name; END IF;
 END LOOP;
 RETURN rfp_delivery_receipt(p_id,p_tenant,p_live);
END $$;
REVOKE ALL ON FUNCTION public.rfp_finalize(uuid,uuid,boolean,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rfp_finalize(uuid,uuid,boolean,integer) TO authenticated;

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

    IF v_contract.status IN ('cancelled', 'awarded', 'converted_to_contract')
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
$function$
;
CREATE OR REPLACE FUNCTION public.rfp_submit_response(p_cnak text, p_secret text, p_response jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE c t_contracts%rowtype; v t_contract_vendors%rowtype; q jsonb; answer text; d jsonb; result jsonb; note text;
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
 UPDATE t_contracts SET metadata=jsonb_set(metadata,ARRAY['rfp_response_'||v.id::text],p_response) WHERE id=c.id;
 RETURN result;
END $function$
;
REVOKE ALL ON FUNCTION public.rfp_submit_response(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rfp_submit_response(text,text,jsonb) TO anon,authenticated;
CREATE OR REPLACE FUNCTION public.rfq_submit_quote(p_cnak text, p_secret text, p_quoted_amount numeric DEFAULT NULL::numeric, p_quote_notes text DEFAULT NULL::text, p_breakdown jsonb DEFAULT NULL::jsonb, p_valid_until date DEFAULT NULL::date, p_decline boolean DEFAULT false, p_decline_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_vendor        RECORD;
    v_contract      RECORD;
    v_amount        NUMERIC;
    v_quoted_count  INT;
BEGIN
    IF p_cnak IS NULL OR p_secret IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Link is incomplete',
                                  'error_code', 'MISSING_CREDENTIALS');
    END IF;

    -- Lock the vendor row so two submits from the same phone cannot interleave
    SELECT cv.* INTO v_vendor
      FROM t_contract_vendors cv
      JOIN t_contracts c ON c.id = cv.contract_id
     WHERE c.global_access_id = UPPER(TRIM(p_cnak))
       AND cv.access_secret = p_secret
       AND c.record_type = 'rfq'
       AND c.is_active = true
     FOR UPDATE OF cv
     LIMIT 1;

    IF v_vendor IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'This request link is not valid',
                                  'error_code', 'INVALID_LINK');
    END IF;

    SELECT * INTO v_contract FROM t_contracts WHERE id = v_vendor.contract_id FOR UPDATE;

    IF v_contract.status NOT IN ('sent', 'quotes_received') THEN
        RETURN jsonb_build_object('success', false,
                                  'error', 'This request is no longer open for quotes',
                                  'error_code', 'RFQ_CLOSED',
                                  'status', v_contract.status);
    END IF;

    IF v_contract.metadata ? 'rfp_buyer_v1' AND NOT p_decline THEN
        RETURN jsonb_build_object('success',false,'error','Use the full RFP proposal form to include your answers and billing terms','error_code','RFQ_ERROR');
    END IF;

    -- Decline
    IF p_decline THEN
        UPDATE t_contract_vendors
           SET response_status = 'declined',
               decline_reason  = NULLIF(TRIM(COALESCE(p_decline_reason, '')), ''),
               responded_at    = NOW()
         WHERE id = v_vendor.id;

        INSERT INTO t_contract_history (
            contract_id, tenant_id, action, from_status, to_status,
            performed_by_type, performed_by_name, note
        ) VALUES (
            v_contract.id, v_contract.tenant_id, 'rfq_declined', NULL, NULL,
            'vendor', v_vendor.vendor_name,
            COALESCE(NULLIF(TRIM(COALESCE(p_decline_reason, '')), ''), 'Vendor declined to quote')
        );

        RETURN jsonb_build_object('success', true,
                                  'data', jsonb_build_object('response_status', 'declined'));
    END IF;

    -- Quote
    v_amount := p_quoted_amount;

    IF v_amount IS NULL AND p_breakdown IS NOT NULL
       AND jsonb_typeof(p_breakdown) = 'array' THEN
        SELECT SUM(COALESCE((e->>'total_price')::NUMERIC, 0))
          INTO v_amount
          FROM jsonb_array_elements(p_breakdown) e;
    END IF;

    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object('success', false,
                                  'error', 'Enter a quote amount, or price the individual items',
                                  'error_code', 'AMOUNT_REQUIRED');
    END IF;

    UPDATE t_contract_vendors
       SET response_status   = 'quoted',
           quoted_amount     = v_amount,
           quote_notes       = NULLIF(TRIM(COALESCE(p_quote_notes, '')), ''),
           quote_breakdown   = p_breakdown,
           quote_currency    = COALESCE(v_contract.currency, 'INR'),
           quote_valid_until = p_valid_until,
           decline_reason    = NULL,
           responded_at      = NOW()
     WHERE id = v_vendor.id;

    UPDATE t_contract_access
       SET status       = 'responded',
           responded_at = NOW()
     WHERE contract_id = v_contract.id
       AND secret_code = p_secret;

    INSERT INTO t_contract_history (
        contract_id, tenant_id, action, from_status, to_status,
        changes, performed_by_type, performed_by_name, note
    ) VALUES (
        v_contract.id, v_contract.tenant_id, 'rfq_quoted', NULL, NULL,
        jsonb_build_object('vendor_id', v_vendor.vendor_id, 'quoted_amount', v_amount),
        'vendor', v_vendor.vendor_name,
        format('Quoted %s %s', COALESCE(v_contract.currency, 'INR'), v_amount)
    );

    -- First quote moves the RFQ forward. Uses the same transition the state
    -- machine already validates, so nothing here invents a new status.
    SELECT COUNT(*) INTO v_quoted_count
      FROM t_contract_vendors
     WHERE contract_id = v_contract.id AND response_status = 'quoted';

    IF v_contract.status = 'sent' AND v_quoted_count > 0 THEN
        PERFORM update_contract_status(
            v_contract.id, v_contract.tenant_id, 'quotes_received',
            NULL, v_vendor.vendor_name, 'vendor',
            'First quote received', NULL
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'response_status', 'quoted',
            'quoted_amount',   v_amount,
            'currency',        COALESCE(v_contract.currency, 'INR'),
            'responded_at',    NOW()
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'Failed to submit quote',
                              'details', SQLERRM, 'error_code', SQLSTATE);
END;
$function$
;
