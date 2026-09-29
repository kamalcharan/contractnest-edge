-- ============================================================================
-- 040 · VaNi on their site — tenant-level bubble, grounded chat, lead capture
-- ============================================================================
-- Owner (2026-09-29): "what is not there — ChatBot… VaNi — how it can be
-- activated into other website" → playground stop 3. VaNi is TENANT-level,
-- not storefront-level: one script tag (data-vani="vn-…") puts her on every
-- page of their site. She answers from the published packages and the FAQ the
-- tenant writes on the Extend page, offers the right package card, and takes a
-- name + mobile → a lead (migration 039). Gated on vani_is_enabled(): the
-- storefronts and checkout work without VaNi; the chat does not.
--
--   t_vani_site_config    one row per tenant: site_key, greeting, handoff,
--                         capture mode, allowed domains, which storefronts,
--                         counters (chats · answered · leads · handoffs)
--   t_vani_site_sessions  one row per conversation (messages appended)
--   vani_site_get_config / vani_site_update_config      (management)
--   vani_site_resolve(key)                              (public; key = vn-… or sf-…)
--   vani_site_chat_log(key, session, …)                 (public, called by the API after it answered)
--   vani_site_capture(key, session, contact)            (public → lead_capture kind 'vani')
--   jtd_notify_lead_captured(tenant, interest)          (email to the tenant; template provider id NULL until registered)
-- The API answers: FAQ first (token overlap), then the VaNi LLM with the
-- packages + FAQ as the only ground truth, else a deterministic hand-off.
-- ============================================================================

-- ── 1. tables ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.t_vani_site_config (
  tenant_id        uuid PRIMARY KEY,
  site_key         text NOT NULL UNIQUE,
  enabled          boolean NOT NULL DEFAULT true,
  greeting         text,
  handoff_mode     text NOT NULL DEFAULT 'capture' CHECK (handoff_mode IN ('capture','whatsapp')),
  handoff_phone    text,
  capture_mode     text NOT NULL DEFAULT 'interest' CHECK (capture_mode IN ('interest','first','never')),
  allowed_domains  text[] NOT NULL DEFAULT '{}',
  storefront_ids   uuid[] NOT NULL DEFAULT '{}',        -- empty = every active storefront
  chats_count      integer NOT NULL DEFAULT 0,
  answered_count   integer NOT NULL DEFAULT 0,
  leads_count      integer NOT NULL DEFAULT 0,
  handoff_count    integer NOT NULL DEFAULT 0,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.t_vani_site_config ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.t_vani_site_sessions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL,
  site_key         text NOT NULL,
  storefront_key   text,
  page_url         text,
  messages         jsonb NOT NULL DEFAULT '[]'::jsonb,
  turns            integer NOT NULL DEFAULT 0,
  answered         integer NOT NULL DEFAULT 0,
  offered_family   uuid,
  captured         boolean NOT NULL DEFAULT false,
  contact_id       uuid,
  interest_id      uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  last_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_vani_site_sessions_tenant ON public.t_vani_site_sessions (tenant_id, created_at DESC);
ALTER TABLE public.t_vani_site_sessions ENABLE ROW LEVEL SECURITY;

-- ── 2. helpers ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_vani_site_seller(p_tenant_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT jsonb_build_object('name', COALESCE(NULLIF(tp.business_name, ''), tn.name), 'logo_url', tp.logo_url,
                            'primary_color', tp.primary_color, 'city', tp.city,
                            'whatsapp', NULLIF(regexp_replace(COALESCE(tp.business_whatsapp, tp.business_phone, ''), '[^0-9]', '', 'g'), ''))
  FROM public.t_tenants tn LEFT JOIN public.t_tenant_profiles tp ON tp.tenant_id = tn.id WHERE tn.id = p_tenant_id LIMIT 1
$fn$;

-- the tenant's config row, created on first touch with a fresh site key
CREATE OR REPLACE FUNCTION public.fn_vani_site_ensure(p_tenant_id uuid)
RETURNS public.t_vani_site_config LANGUAGE plpgsql AS $fn$
DECLARE v_row public.t_vani_site_config; v_seller text;
BEGIN
  SELECT * INTO v_row FROM public.t_vani_site_config WHERE tenant_id = p_tenant_id;
  IF v_row.tenant_id IS NULL THEN
    v_seller := COALESCE(public.fn_vani_site_seller(p_tenant_id)->>'name', 'us');
    INSERT INTO public.t_vani_site_config (tenant_id, site_key, greeting)
    VALUES (p_tenant_id, 'vn-' || left(md5(gen_random_uuid()::text || clock_timestamp()::text), 20),
            'Hi, I''m VaNi for ' || v_seller || '. Ask me about our packages.')
    ON CONFLICT (tenant_id) DO NOTHING;
    SELECT * INTO v_row FROM public.t_vani_site_config WHERE tenant_id = p_tenant_id;
  END IF;
  RETURN v_row;
END;
$fn$;

-- hostnames only: lower-case, protocol/path/port stripped, blanks dropped, ≤ 20
CREATE OR REPLACE FUNCTION public.fn_vani_site_domains(p_in jsonb)
RETURNS text[] LANGUAGE sql IMMUTABLE AS $fn$
  SELECT COALESCE((
    SELECT array_agg(d ORDER BY ord) FROM (
      SELECT DISTINCT ON (d) d, ord FROM (
        SELECT lower(regexp_replace(regexp_replace(btrim(x), '^[a-z]+://', '', 'i'), '[/:?#].*$', '')) AS d, ord
        FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_in) = 'array' THEN p_in ELSE '[]'::jsonb END) WITH ORDINALITY AS t(x, ord)
      ) y WHERE d ~ '^[a-z0-9.-]+\.[a-z]{2,}$' OR d = 'localhost' ORDER BY d, ord
    ) z WHERE ord <= 20), '{}'::text[])
$fn$;

CREATE OR REPLACE FUNCTION public.fn_vani_site_config_json(p_row public.t_vani_site_config)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT jsonb_build_object(
    'site_key', p_row.site_key, 'enabled', p_row.enabled, 'greeting', p_row.greeting,
    'handoff_mode', p_row.handoff_mode, 'handoff_phone', p_row.handoff_phone, 'capture_mode', p_row.capture_mode,
    'allowed_domains', to_jsonb(p_row.allowed_domains), 'storefront_ids', to_jsonb(p_row.storefront_ids),
    'counters', jsonb_build_object('chats', p_row.chats_count, 'answered', p_row.answered_count,
                                   'leads', p_row.leads_count, 'handoffs', p_row.handoff_count),
    'updated_at', p_row.updated_at)
$fn$;

-- ── 3. management ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.vani_site_get_config(p_tenant_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_row public.t_vani_site_config;
BEGIN
  v_row := public.fn_vani_site_ensure(p_tenant_id);
  RETURN jsonb_build_object('success', true,
    'config', public.fn_vani_site_config_json(v_row),
    'vani_enabled', public.vani_is_enabled(p_tenant_id),
    'seller', public.fn_vani_site_seller(p_tenant_id),
    'month', (SELECT jsonb_build_object('chats', count(*), 'answered', COALESCE(sum(answered), 0), 'leads', count(*) FILTER (WHERE captured))
              FROM public.t_vani_site_sessions s WHERE s.tenant_id = p_tenant_id
                AND s.created_at >= date_trunc('month', now() AT TIME ZONE 'Asia/Kolkata') AT TIME ZONE 'Asia/Kolkata'),
    'storefronts', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', tp.id, 'name', tp.name, 'storefront_key', tp.storefront_key, 'is_active', tp.is_active) ORDER BY tp.created_at)
                             FROM public.t_touchpoints tp WHERE tp.tenant_id = p_tenant_id AND NOT (tp.config ? 'merged_into')), '[]'::jsonb));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.vani_site_update_config(p_tenant_id uuid, p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_row public.t_vani_site_config; v_ids uuid[]; v_phone text;
BEGIN
  v_row := public.fn_vani_site_ensure(p_tenant_id);
  IF p_patch ? 'greeting' THEN v_row.greeting := NULLIF(left(btrim(p_patch->>'greeting'), 300), ''); END IF;
  IF p_patch ? 'handoff_mode' AND p_patch->>'handoff_mode' IN ('capture','whatsapp') THEN v_row.handoff_mode := p_patch->>'handoff_mode'; END IF;
  IF p_patch ? 'handoff_phone' THEN
    v_phone := NULLIF(regexp_replace(COALESCE(p_patch->>'handoff_phone', ''), '[^0-9]', '', 'g'), '');
    IF v_phone IS NOT NULL AND (length(v_phone) < 10 OR length(v_phone) > 15) THEN
      RETURN jsonb_build_object('success', false, 'error', 'Enter a valid WhatsApp number', 'error_code', 'VALIDATION_ERROR');
    END IF;
    v_row.handoff_phone := v_phone;
  END IF;
  IF p_patch ? 'capture_mode' AND p_patch->>'capture_mode' IN ('interest','first','never') THEN v_row.capture_mode := p_patch->>'capture_mode'; END IF;
  IF p_patch ? 'allowed_domains' THEN v_row.allowed_domains := public.fn_vani_site_domains(p_patch->'allowed_domains'); END IF;
  IF p_patch ? 'storefront_ids' THEN
    SELECT COALESCE(array_agg(tp.id), '{}') INTO v_ids FROM public.t_touchpoints tp
    WHERE tp.tenant_id = p_tenant_id AND NOT (tp.config ? 'merged_into')
      AND tp.id IN (SELECT NULLIF(x, '')::uuid FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_patch->'storefront_ids') = 'array' THEN p_patch->'storefront_ids' ELSE '[]'::jsonb END) x WHERE x ~ '^[0-9a-f-]{36}$');
    v_row.storefront_ids := v_ids;
  END IF;
  IF p_patch ? 'enabled' THEN v_row.enabled := COALESCE((p_patch->>'enabled')::boolean, v_row.enabled); END IF;
  IF v_row.handoff_mode = 'whatsapp' AND v_row.handoff_phone IS NULL THEN
    v_row.handoff_phone := NULLIF(public.fn_vani_site_seller(p_tenant_id)->>'whatsapp', '');
    IF v_row.handoff_phone IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'Add a WhatsApp number for the hand-off', 'error_code', 'VALIDATION_ERROR');
    END IF;
  END IF;
  UPDATE public.t_vani_site_config SET greeting = v_row.greeting, handoff_mode = v_row.handoff_mode, handoff_phone = v_row.handoff_phone,
    capture_mode = v_row.capture_mode, allowed_domains = v_row.allowed_domains, storefront_ids = v_row.storefront_ids,
    enabled = v_row.enabled, updated_at = now()
  WHERE tenant_id = p_tenant_id RETURNING * INTO v_row;
  RETURN jsonb_build_object('success', true, 'config', public.fn_vani_site_config_json(v_row));
END;
$fn$;

-- ── 4. public: what the chat needs ──────────────────────────────────────────
-- p_key is the tenant's site key (vn-…) or a storefront key (sf-…, the package
-- page's "Ask VaNi"); p_storefront_key scopes the packages to one storefront.
CREATE OR REPLACE FUNCTION public.vani_site_resolve(p_key text, p_storefront_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_cfg public.t_vani_site_config; v_tp public.t_touchpoints; v_tenant uuid; v_scope text; v_pkgs jsonb; v_faq jsonb; v_style jsonb; v_seller jsonb;
BEGIN
  IF p_key LIKE 'sf-%' THEN
    v_tp := public.fn_storefront_by_key(p_key);
    IF v_tp.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'NOT_FOUND'); END IF;
    v_tenant := v_tp.tenant_id; v_scope := v_tp.storefront_key;
    v_cfg := public.fn_vani_site_ensure(v_tenant);
  ELSE
    SELECT * INTO v_cfg FROM public.t_vani_site_config WHERE site_key = p_key;
    IF v_cfg.tenant_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'NOT_FOUND'); END IF;
    v_tenant := v_cfg.tenant_id;
    IF NULLIF(p_storefront_key, '') IS NOT NULL THEN
      v_tp := public.fn_storefront_by_key(p_storefront_key);
      IF v_tp.id IS NOT NULL AND v_tp.tenant_id = v_tenant THEN v_scope := v_tp.storefront_key; ELSE v_tp := NULL; END IF;
    END IF;
  END IF;

  -- packages: the scoped storefront, else every active storefront (or the chosen ones), one card per family
  WITH sfs AS (
    SELECT tp.* FROM public.t_touchpoints tp
    WHERE tp.tenant_id = v_tenant AND tp.is_active AND NOT (tp.config ? 'merged_into')
      AND (v_scope IS NULL OR tp.storefront_key = v_scope)
      AND (v_scope IS NOT NULL OR array_length(v_cfg.storefront_ids, 1) IS NULL OR tp.id = ANY (v_cfg.storefront_ids))
    ORDER BY tp.created_at
  ), fams AS (
    SELECT DISTINCT ON (f) f, s.storefront_key, s.created_at, ord
    FROM sfs s, unnest(s.template_ids) WITH ORDINALITY AS u(f, ord)
    ORDER BY f, s.created_at, ord
  )
  SELECT COALESCE(jsonb_agg(pkg || jsonb_build_object('storefront_key', fm.storefront_key) ORDER BY fm.created_at, fm.ord), '[]'::jsonb),
         (SELECT COALESCE(jsonb_agg(e) FILTER (WHERE e IS NOT NULL), '[]'::jsonb) FROM sfs s2, jsonb_array_elements(s2.faq) e)
  INTO v_pkgs, v_faq
  FROM fams fm, LATERAL (SELECT public.fn_storefront_package_json(fm.f) AS pkg) p WHERE p.pkg IS NOT NULL;

  SELECT card_style INTO v_style FROM public.t_touchpoints tp WHERE tp.tenant_id = v_tenant AND tp.is_active AND NOT (tp.config ? 'merged_into')
    AND (v_scope IS NULL OR tp.storefront_key = v_scope) ORDER BY (tp.storefront_key = v_scope) DESC NULLS LAST, tp.created_at LIMIT 1;
  v_seller := public.fn_vani_site_seller(v_tenant);

  RETURN jsonb_build_object('success', true,
    'site_key', v_cfg.site_key, 'tenant_id', v_tenant, 'storefront_key', v_scope,
    'seller', v_seller - 'whatsapp',
    'greeting', COALESCE(v_cfg.greeting, 'Hi, I''m VaNi for ' || COALESCE(v_seller->>'name', 'us') || '. Ask me about our packages.'),
    'handoff', jsonb_build_object('mode', v_cfg.handoff_mode, 'phone', CASE WHEN v_cfg.handoff_mode = 'whatsapp' THEN COALESCE(v_cfg.handoff_phone, v_seller->>'whatsapp') END),
    'capture_mode', v_cfg.capture_mode,
    'allowed_domains', to_jsonb(v_cfg.allowed_domains),
    'enabled', v_cfg.enabled,
    'vani_enabled', public.vani_is_enabled(v_tenant),
    'card_style', public.fn_storefront_card_style(v_tenant, COALESCE(v_style, '{}'::jsonb), NULL),
    'packages', COALESCE(v_pkgs, '[]'::jsonb),
    'faq', COALESCE(v_faq, '[]'::jsonb));
END;
$fn$;

-- one turn: the visitor's message and what VaNi answered (the API decides the answer)
CREATE OR REPLACE FUNCTION public.vani_site_chat_log(p_key text, p_session_id uuid, p_storefront_key text, p_page_url text, p_visitor text, p_assistant jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_res jsonb; v_tenant uuid; v_site text; v_s public.t_vani_site_sessions; v_fam uuid; v_answered boolean; v_handoff boolean; v_sf public.t_touchpoints;
BEGIN
  v_res := public.vani_site_resolve(p_key, p_storefront_key);
  IF NOT (v_res->>'success')::boolean THEN RETURN v_res; END IF;
  v_tenant := (v_res->>'tenant_id')::uuid; v_site := v_res->>'site_key';
  v_answered := COALESCE((p_assistant->>'answered')::boolean, false);
  v_handoff := COALESCE((p_assistant->>'handoff')::boolean, false);
  BEGIN v_fam := NULLIF(p_assistant->>'package_family', '')::uuid; EXCEPTION WHEN OTHERS THEN v_fam := NULL; END;

  IF p_session_id IS NOT NULL THEN
    SELECT * INTO v_s FROM public.t_vani_site_sessions WHERE id = p_session_id AND tenant_id = v_tenant FOR UPDATE;
  END IF;
  IF v_s.id IS NULL THEN
    INSERT INTO public.t_vani_site_sessions (tenant_id, site_key, storefront_key, page_url)
    VALUES (v_tenant, v_site, v_res->>'storefront_key', left(p_page_url, 500)) RETURNING * INTO v_s;
    UPDATE public.t_vani_site_config SET chats_count = chats_count + 1, updated_at = now() WHERE tenant_id = v_tenant;
    IF v_res->>'storefront_key' IS NOT NULL THEN
      UPDATE public.t_touchpoints SET chats_count = chats_count + 1 WHERE storefront_key = v_res->>'storefront_key';
    END IF;
  END IF;

  UPDATE public.t_vani_site_sessions
  SET messages = messages || jsonb_build_array(
        jsonb_build_object('role', 'user', 'text', left(p_visitor, 1000), 'at', now()),
        jsonb_build_object('role', 'assistant', 'text', left(p_assistant->>'text', 2000), 'package_family', v_fam,
                           'answered', v_answered, 'handoff', v_handoff, 'source', p_assistant->>'source', 'at', now())),
      turns = turns + 1, answered = answered + CASE WHEN v_answered THEN 1 ELSE 0 END,
      offered_family = COALESCE(v_fam, offered_family), last_at = now()
  WHERE id = v_s.id RETURNING * INTO v_s;
  UPDATE public.t_vani_site_config SET answered_count = answered_count + CASE WHEN v_answered THEN 1 ELSE 0 END,
                                       handoff_count = handoff_count + CASE WHEN v_handoff THEN 1 ELSE 0 END
  WHERE tenant_id = v_tenant;

  RETURN jsonb_build_object('success', true, 'session_id', v_s.id, 'turns', v_s.turns, 'captured', v_s.captured);
END;
$fn$;

-- ── 5. the tenant hears about it (email; template provider id NULL until registered) ─
INSERT INTO public.n_jtd_source_types (code, name, description, default_event_type, source_table, source_id_field, default_channels, is_active)
VALUES ('lead_captured', 'Lead captured', 'VaNi (or the storefront) captured a lead on the tenant''s site; tells the tenant. source_id = the interest row.',
        'notification', 't_contact_interests', 'id', ARRAY['email']::varchar[], true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO public.n_jtd_templates (tenant_id, template_key, name, description, channel_code, source_type_code,
    subject, content, content_html, variables, provider_template_id, version, is_active, created_by, updated_by)
SELECT NULL, 'lead_captured_email', 'Lead Captured Email',
    'Tells the tenant that VaNi captured a lead on their site: who, what they asked, which package',
    'email', 'lead_captured',
    'New lead: {{lead_name}} asked about {{package_name}}',
    'Hi {{seller_name}}, VaNi just captured a lead on your site. {{lead_name}} ({{lead_phone}} {{lead_email}}) asked: "{{question}}" — interested in {{package_name}}. Open your leads: {{leads_link}}',
    '<!DOCTYPE html><html><head><meta charset="utf-8"><title>New lead — {{lead_name}}</title></head>'
    '<body style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,sans-serif;line-height:1.6;color:#333;margin:0;padding:0;background:#f5f5f5;">'
    '<div style="max-width:600px;margin:0 auto;background:#fff;">'
    '<div style="background:linear-gradient(135deg,#ff6b2b,#ff8f5a);color:#fff;padding:28px;text-align:center;"><h1 style="margin:0;font-size:22px;">New lead from your site</h1><p style="margin:8px 0 0;opacity:.9;font-size:14px;">captured by VaNi</p></div>'
    '<div style="padding:32px 40px;"><p style="margin:0 0 18px;">Hi <strong>{{seller_name}}</strong>,</p>'
    '<p style="margin:0 0 22px;"><strong>{{lead_name}}</strong> left their details on your site.</p>'
    '<table style="width:100%;border-collapse:collapse;font-size:14px;border:1px solid #e5e7eb;border-radius:8px;">'
    '<tr><td style="padding:8px 14px;color:#6b7280;">Mobile</td><td style="padding:8px 14px;text-align:right;font-weight:600;">{{lead_phone}}</td></tr>'
    '<tr><td style="padding:8px 14px;color:#6b7280;">Email</td><td style="padding:8px 14px;text-align:right;">{{lead_email}}</td></tr>'
    '<tr><td style="padding:8px 14px;color:#6b7280;">Interested in</td><td style="padding:8px 14px;text-align:right;font-weight:600;">{{package_name}}</td></tr>'
    '<tr><td style="padding:8px 14px;color:#6b7280;vertical-align:top;">They asked</td><td style="padding:8px 14px;text-align:right;font-style:italic;">{{question}}</td></tr></table>'
    '<div style="text-align:center;margin:30px 0 8px;"><a href="{{leads_link}}" style="background:#ff6b2b;color:#fff;padding:13px 32px;text-decoration:none;border-radius:8px;display:inline-block;font-weight:600;">Open leads</a></div></div>'
    '<div style="background:#f9fafb;padding:18px;text-align:center;border-top:1px solid #e5e7eb;"><p style="margin:0;font-size:11px;color:#9ca3af;">Powered by ContractNest</p></div></div></body></html>',
    '["seller_name","lead_name","lead_phone","lead_email","package_name","question","leads_link"]'::jsonb,
    NULL, 1, true, '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001'
WHERE NOT EXISTS (SELECT 1 FROM public.n_jtd_templates WHERE template_key = 'lead_captured_email' AND tenant_id IS NULL);

CREATE OR REPLACE FUNCTION public.jtd_notify_lead_captured(p_tenant_id uuid, p_interest_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_i RECORD; v_seller text; v_email text; v_source text; v_tpl RECORD; v_vars jsonb; v_id uuid; v_phone text; v_mail text;
BEGIN
  SELECT i.*, COALESCE(NULLIF(c.company_name, ''), c.name) AS lead_name, c.is_live AS c_live
  INTO v_i FROM public.t_contact_interests i JOIN public.t_contacts c ON c.id = i.contact_id
  WHERE i.id = p_interest_id AND i.tenant_id = p_tenant_id;
  IF v_i.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Interest not found'); END IF;

  SELECT COALESCE(NULLIF(tp.business_name, ''), t.name) INTO v_seller
  FROM public.t_tenants t LEFT JOIN public.t_tenant_profiles tp ON tp.tenant_id = t.id WHERE t.id = p_tenant_id LIMIT 1;
  SELECT NULLIF(tp.business_email, '') INTO v_email FROM public.t_tenant_profiles tp WHERE tp.tenant_id = p_tenant_id LIMIT 1;
  v_source := 'business_email';
  IF v_email IS NULL THEN
    SELECT NULLIF(u.email, '') INTO v_email FROM public.t_user_tenants ut JOIN auth.users u ON u.id = ut.user_id
    WHERE ut.tenant_id = p_tenant_id AND ut.status = 'active' ORDER BY ut.is_default DESC NULLS LAST, ut.created_at LIMIT 1;
    v_source := 'default_user';
  END IF;
  IF v_email IS NULL THEN RETURN jsonb_build_object('success', true, 'skipped', 'no_recipient'); END IF;

  SELECT id, template_key, provider_template_id INTO v_tpl FROM public.n_jtd_templates
  WHERE source_type_code = 'lead_captured' AND channel_code = 'email' AND is_active = true AND (tenant_id = p_tenant_id OR tenant_id IS NULL)
  ORDER BY (tenant_id IS NOT NULL) DESC LIMIT 1;
  IF v_tpl.id IS NULL OR NULLIF(v_tpl.provider_template_id, '') IS NULL THEN
    RETURN jsonb_build_object('success', true, 'skipped', 'no_provider_template', 'recipient', v_email, 'recipient_source', v_source);
  END IF;

  SELECT ch.value INTO v_phone FROM public.t_contact_channels ch WHERE ch.contact_id = v_i.contact_id AND ch.channel_type = 'mobile' ORDER BY ch.is_primary DESC LIMIT 1;
  SELECT ch.value INTO v_mail FROM public.t_contact_channels ch WHERE ch.contact_id = v_i.contact_id AND ch.channel_type = 'email' ORDER BY ch.is_primary DESC LIMIT 1;
  v_vars := jsonb_build_object('seller_name', v_seller, 'lead_name', v_i.lead_name, 'lead_phone', COALESCE(v_phone, '—'), 'lead_email', COALESCE(v_mail, ''),
                               'package_name', COALESCE(v_i.template_name, 'your packages'), 'question', COALESCE(left(v_i.question, 300), '—'),
                               'leads_link', 'https://www.contractnest.com/leads');
  INSERT INTO public.n_jtd (tenant_id, event_type_code, channel_code, source_type_code, source_id, source_ref,
      status_code, priority, recipient_name, recipient_contact,
      payload, template_id, template_key, template_variables, metadata, business_context,
      is_live, performed_by_type, performed_by_id, performed_by_name, created_by, updated_by)
  VALUES (p_tenant_id, 'notification', 'email', 'lead_captured', v_i.id, v_i.lead_name,
      'created', 5, v_seller, v_email,
      jsonb_build_object('recipient_data', jsonb_build_object('email', v_email, 'name', v_seller), 'template_data', v_vars),
      v_tpl.id, v_tpl.template_key, v_vars,
      jsonb_build_object('interest_id', v_i.id, 'contact_id', v_i.contact_id, 'recipient_source', v_source),
      jsonb_build_object('contact_id', v_i.contact_id, 'interest_id', v_i.id),
      COALESCE(v_i.is_live, true), 'system', '00000000-0000-0000-0000-000000000001', 'VaNi',
      '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001')
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('success', true, 'jtd_id', v_id, 'recipient', v_email, 'recipient_source', v_source);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$fn$;

-- ── 6. public: the visitor leaves a name and number → a lead ────────────────
CREATE OR REPLACE FUNCTION public.vani_site_capture(p_key text, p_session_id uuid, p_contact jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_res jsonb; v_tenant uuid; v_s public.t_vani_site_sessions; v_q text; v_lead jsonb; v_notify jsonb;
BEGIN
  v_res := public.vani_site_resolve(p_key, NULL);
  IF NOT (v_res->>'success')::boolean THEN RETURN v_res; END IF;
  v_tenant := (v_res->>'tenant_id')::uuid;
  SELECT * INTO v_s FROM public.t_vani_site_sessions WHERE id = p_session_id AND tenant_id = v_tenant FOR UPDATE;
  IF v_s.id IS NULL THEN
    -- a form submitted before any question: still a lead, on a fresh session
    INSERT INTO public.t_vani_site_sessions (tenant_id, site_key, storefront_key) VALUES (v_tenant, v_res->>'site_key', NULL) RETURNING * INTO v_s;
    UPDATE public.t_vani_site_config SET chats_count = chats_count + 1 WHERE tenant_id = v_tenant;
  END IF;
  SELECT string_agg(m->>'text', ' / ' ORDER BY ord) INTO v_q
  FROM (SELECT m, ord FROM jsonb_array_elements(v_s.messages) WITH ORDINALITY AS t(m, ord) WHERE m->>'role' = 'user' ORDER BY ord DESC LIMIT 3) x;
  v_lead := public.lead_capture(v_tenant, TRUE,
    jsonb_build_object('name', p_contact->>'name', 'company', p_contact->>'company', 'phone', p_contact->>'phone', 'email', p_contact->>'email'),
    jsonb_build_object('kind', 'vani', 'channel', 'vani', 'storefront_key', v_s.storefront_key, 'template_family', v_s.offered_family,
                       'question', v_q, 'metadata', jsonb_build_object('session_id', v_s.id, 'page_url', v_s.page_url)));
  IF NOT (v_lead->>'success')::boolean THEN RETURN v_lead; END IF;
  UPDATE public.t_vani_site_sessions SET captured = true, contact_id = (v_lead->>'contact_id')::uuid, interest_id = (v_lead->>'interest_id')::uuid, last_at = now()
  WHERE id = v_s.id;
  IF NOT v_s.captured THEN UPDATE public.t_vani_site_config SET leads_count = leads_count + 1 WHERE tenant_id = v_tenant; END IF;
  v_notify := public.jtd_notify_lead_captured(v_tenant, (v_lead->>'interest_id')::uuid);
  RETURN v_lead || jsonb_build_object('session_id', v_s.id, 'notified', v_notify);
END;
$fn$;

REVOKE ALL ON FUNCTION public.vani_site_chat_log(text, uuid, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.vani_site_capture(text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.vani_site_update_config(uuid, jsonb) FROM PUBLIC, anon, authenticated;
