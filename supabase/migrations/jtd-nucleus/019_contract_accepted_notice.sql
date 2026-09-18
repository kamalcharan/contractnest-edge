-- ═══════════════════════════════════════════════════════════════════
-- jtd-nucleus/019_contract_accepted_notice.sql  (2026-09-17)
-- The seller learns that the buyer accepted.
--
-- FOUND ON CN-1010: respond_to_contract queued a bare pgmq message
-- {'source_type_code':'contract_accepted', …} with no jtd_id. The worker
-- fetches n_jtd by message.jtd_id → "invalid input syntax for type uuid:
-- undefined" → drops it. No n_jtd row, no template, no recipient — the
-- acceptance notice has never existed. (update_contract_status V1 sends the
-- same bare shape for contract_sent/accepted/expired/rfq_sent; left alone
-- here — those are the seller's own status changes.)
--
-- WHAT THIS DOES:
--  A) Global email template contract_accepted_email (source contract_accepted).
--     provider_template_id is NULL until the owner registers the MSG91 email
--     template — the worker's email handler refuses to send without one.
--  B) jtd_notify_contract_accepted(contract, tenant, responder_name):
--     recipient = tenant profile business_email → the contract creator's
--     profile email → the tenant's default active user; template = tenant
--     row, else global, and only when it carries a provider template id.
--     Inserts ONE n_jtd communication row (status 'created' → trg_jtd_enqueue
--     queues it → worker sends); otherwise returns a machine-readable
--     'skipped' reason and inserts nothing, so no failed rows pile up.
--     Carries contract_id so the History drawer / Audit tab / Register show it.
--  C) respond_to_contract: the bare pgmq.send block is replaced by a
--     guarded PERFORM of (B). Substitution into the live definition with a
--     post-check (048/059 pattern); acceptance can never fail on it.
-- Applied live 2026-09-17 (batch jtd-jobs-from-legacy-events) — source of
-- record; do not re-run.
-- OWNER ACTION: register an MSG91 email template with variables
--   seller_name, buyer_name, contract_title, contract_number, contract_value,
--   accepted_on, contract_link
-- then: UPDATE n_jtd_templates SET provider_template_id = '<msg91 id>'
--       WHERE template_key = 'contract_accepted_email' AND tenant_id IS NULL;
-- ═══════════════════════════════════════════════════════════════════

-- A) template
INSERT INTO n_jtd_templates (tenant_id, template_key, name, description, channel_code, source_type_code,
    subject, content, content_html, variables, provider_template_id, version, is_active, created_by, updated_by)
SELECT NULL, 'contract_accepted_email', 'Contract Accepted Email',
    'Tells the issuing party that the counterparty accepted the agreement through the review link',
    'email', 'contract_accepted',
    '{{buyer_name}} accepted {{contract_title}} ({{contract_number}})',
    'Hi {{seller_name}}, {{buyer_name}} has accepted "{{contract_title}}" ({{contract_number}}) worth {{contract_value}} on {{accepted_on}}. The agreement is now active. Open it: {{contract_link}}',
    '<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Contract accepted — {{contract_title}}</title></head>'
    '<body style="font-family: -apple-system, BlinkMacSystemFont, ''Segoe UI'', Roboto, sans-serif; line-height: 1.6; color: #333; margin: 0; padding: 0; background-color: #f5f5f5;">'
    '<div style="max-width: 600px; margin: 0 auto; background-color: #ffffff;">'
    '<div style="background: linear-gradient(135deg, #059669, #10B981); color: white; padding: 30px; text-align: center;"><h1 style="margin: 0; font-size: 22px;">Contract accepted</h1><p style="margin: 8px 0 0; opacity: 0.9; font-size: 14px;">{{buyer_name}}</p></div>'
    '<div style="padding: 36px 40px;"><p style="margin: 0 0 20px;">Hi <strong>{{seller_name}}</strong>,</p>'
    '<p style="margin: 0 0 24px;"><strong>{{buyer_name}}</strong> has accepted your agreement. It is now active.</p>'
    '<div style="border: 1px solid #e5e7eb; border-radius: 8px; overflow: hidden; margin: 0 0 28px;"><div style="background-color: #f9fafb; padding: 14px 20px; border-bottom: 1px solid #e5e7eb;"><strong style="color: #111; font-size: 16px;">{{contract_title}}</strong></div>'
    '<div style="padding: 16px 20px;"><table style="width: 100%; border-collapse: collapse; font-size: 14px;">'
    '<tr><td style="padding: 6px 0; color: #6b7280;">Contract #</td><td style="padding: 6px 0; text-align: right; font-weight: 600;">{{contract_number}}</td></tr>'
    '<tr><td style="padding: 6px 0; color: #6b7280;">Value</td><td style="padding: 6px 0; text-align: right; font-weight: 600; color: #059669;">{{contract_value}}</td></tr>'
    '<tr><td style="padding: 6px 0; color: #6b7280;">Accepted on</td><td style="padding: 6px 0; text-align: right;">{{accepted_on}}</td></tr>'
    '</table></div></div>'
    '<div style="text-align: center; margin: 32px 0;"><a href="{{contract_link}}" style="background: linear-gradient(135deg, #059669, #10B981); color: white; padding: 14px 36px; text-decoration: none; border-radius: 8px; display: inline-block; font-weight: 600; font-size: 15px;">Open contract</a></div>'
    '<p style="font-size: 12px; color: #9ca3af; margin: 0 0 4px;">If the button doesn''t work, copy this link:</p><p style="font-size: 12px; color: #059669; word-break: break-all; margin: 0;">{{contract_link}}</p></div>'
    '<div style="background-color: #f9fafb; padding: 20px; text-align: center; border-top: 1px solid #e5e7eb;"><p style="margin: 0; font-size: 11px; color: #9ca3af;">Powered by ContractNest</p></div></div></body></html>',
    '["seller_name","buyer_name","contract_title","contract_number","contract_value","accepted_on","contract_link"]'::jsonb,
    NULL, 1, true,
    '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001'
WHERE NOT EXISTS (SELECT 1 FROM n_jtd_templates WHERE template_key = 'contract_accepted_email' AND tenant_id IS NULL);

-- B) the notice
CREATE OR REPLACE FUNCTION public.jtd_notify_contract_accepted(p_contract_id uuid, p_tenant_id uuid, p_responder_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_c          RECORD;
    v_seller     text;
    v_email      text;
    v_source     text;
    v_tpl        RECORD;
    v_buyer      text;
    v_value      text;
    v_link       text;
    v_vars       jsonb;
    v_id         uuid;
BEGIN
    SELECT c.id, c.tenant_id, c.name, c.contract_number, c.grand_total, c.currency, c.buyer_name, c.buyer_company,
           c.created_by, c.is_live, c.accepted_at
    INTO v_c
    FROM t_contracts c
    WHERE c.id = p_contract_id AND c.tenant_id = p_tenant_id;
    IF v_c.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Contract not found');
    END IF;

    -- Seller display name: business profile, else tenant name.
    SELECT COALESCE(NULLIF(tp.business_name, ''), t.name) INTO v_seller
    FROM t_tenants t LEFT JOIN t_tenant_profiles tp ON tp.tenant_id = t.id
    WHERE t.id = p_tenant_id LIMIT 1;

    -- Recipient: business email → creator's profile email → default active user.
    SELECT NULLIF(tp.business_email, '') INTO v_email FROM t_tenant_profiles tp WHERE tp.tenant_id = p_tenant_id LIMIT 1;
    v_source := 'business_email';
    IF v_email IS NULL THEN
        SELECT NULLIF(up.email, '') INTO v_email FROM t_user_profiles up
        WHERE (up.id = v_c.created_by OR up.user_id = v_c.created_by) AND up.email IS NOT NULL LIMIT 1;
        v_source := 'creator';
    END IF;
    IF v_email IS NULL THEN
        SELECT NULLIF(u.email, '') INTO v_email
        FROM t_user_tenants ut JOIN auth.users u ON u.id = ut.user_id
        WHERE ut.tenant_id = p_tenant_id AND ut.status = 'active'
        ORDER BY ut.is_default DESC NULLS LAST, ut.created_at LIMIT 1;
        v_source := 'default_user';
    END IF;
    IF v_email IS NULL THEN
        RETURN jsonb_build_object('success', true, 'skipped', 'no_recipient');
    END IF;

    -- Template: tenant row, else global; must carry a provider template id.
    SELECT id, template_key, provider_template_id INTO v_tpl
    FROM n_jtd_templates
    WHERE source_type_code = 'contract_accepted' AND channel_code = 'email' AND is_active = true
      AND (tenant_id = p_tenant_id OR tenant_id IS NULL)
    ORDER BY (tenant_id IS NOT NULL) DESC LIMIT 1;
    IF v_tpl.id IS NULL OR NULLIF(v_tpl.provider_template_id, '') IS NULL THEN
        RETURN jsonb_build_object('success', true, 'skipped', 'no_provider_template',
                                  'recipient', v_email, 'recipient_source', v_source);
    END IF;

    v_buyer := COALESCE(NULLIF(p_responder_name, ''), NULLIF(v_c.buyer_company, ''), NULLIF(v_c.buyer_name, ''), 'The other party');
    v_value := COALESCE(v_c.currency, 'INR') || ' ' || to_char(COALESCE(v_c.grand_total, 0), 'FM9,99,99,99,990.00');
    v_link  := 'https://www.contractnest.com/contracts/' || v_c.id::text;
    v_vars  := jsonb_build_object(
        'seller_name', v_seller,
        'buyer_name', v_buyer,
        'contract_title', COALESCE(v_c.name, v_c.contract_number),
        'contract_number', v_c.contract_number,
        'contract_value', v_value,
        'accepted_on', to_char(COALESCE(v_c.accepted_at, now()) AT TIME ZONE 'Asia/Kolkata', 'DD Mon YYYY, HH24:MI'),
        'contract_link', v_link);

    INSERT INTO n_jtd (tenant_id, event_type_code, channel_code, source_type_code, source_id, source_ref,
        contract_id, status_code, priority, recipient_name, recipient_contact,
        payload, template_id, template_key, template_variables, metadata, business_context,
        is_live, performed_by_type, performed_by_id, performed_by_name, created_by, updated_by)
    VALUES (p_tenant_id, 'notification', 'email', 'contract_accepted', v_c.id, v_c.contract_number,
        v_c.id, 'created', 5, v_seller, v_email,
        jsonb_build_object('recipient_data', jsonb_build_object('email', v_email, 'name', v_seller),
                           'template_data', v_vars),
        v_tpl.id, v_tpl.template_key, v_vars,
        jsonb_build_object('contract_id', v_c.id, 'contract_number', v_c.contract_number,
                           'accepted_by', v_buyer, 'recipient_source', v_source),
        jsonb_build_object('contract_id', v_c.id),
        COALESCE(v_c.is_live, true), 'system', '00000000-0000-0000-0000-000000000001', 'VaNi',
        '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001')
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'jtd_id', v_id, 'recipient', v_email, 'recipient_source', v_source);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- C) respond_to_contract: replace the bare pgmq.send block.
DO $$
DECLARE
  v_def   text;
  v_start integer;
  v_end   integer;
  v_head  text := $h$BEGIN
                PERFORM pgmq.send('jtd_queue', jsonb_build_object(
                    'source_type_code', 'contract_accepted',$h$;
  v_tail  text := $t$RAISE NOTICE 'JTD queue failed for contract % (public accept): %', v_contract.id, SQLERRM;
            END;$t$;
  v_new   text := $n$BEGIN
                -- jtd-nucleus/019: a real n_jtd row (email to the seller),
                -- enqueued by trg_jtd_enqueue — never a bare queue message.
                PERFORM jtd_notify_contract_accepted(v_contract.id, v_access.tenant_id,
                    COALESCE(p_responder_name, v_access.accessor_name));
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'contract_accepted notice failed for contract % (public accept): %', v_contract.id, SQLERRM;
            END;$n$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'respond_to_contract';
  IF v_def IS NULL THEN RAISE EXCEPTION '019: respond_to_contract not found'; END IF;
  IF position('jtd_notify_contract_accepted' IN v_def) > 0 THEN RAISE NOTICE '019: already applied'; RETURN; END IF;
  v_start := position(v_head IN v_def);
  IF v_start = 0 THEN RAISE EXCEPTION '019: head anchor not found'; END IF;
  v_end := position(v_tail IN substr(v_def, v_start));
  IF v_end = 0 THEN RAISE EXCEPTION '019: tail anchor not found'; END IF;
  v_end := v_start + v_end - 1 + length(v_tail);
  v_def := substr(v_def, 1, v_start - 1) || v_new || substr(v_def, v_end);
  EXECUTE v_def;
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'respond_to_contract';
  IF position('jtd_notify_contract_accepted' IN v_def) = 0 OR position('pgmq.send' IN v_def) > 0 THEN
    RAISE EXCEPTION '019: rewrite did not land';
  END IF;
END $$;
