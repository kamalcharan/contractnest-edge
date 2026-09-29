-- ============================================================================
-- 039 · Leads = contacts tagged 'lead' + what they were interested in
-- ============================================================================
-- Owner (2026-09-29): "Leads are nothing but Contacts with tag 'Lead' — a lead
-- in general or for a contract/template"; "RFQ is also a kind of lead — inside
-- push and outside requests". So:
--   · a lead is a t_contacts row carrying classification 'lead'
--   · t_contact_interests is the history: which package, from where (storefront
--     widget / link / VaNi / manual), what they asked, and the stage
--     new → contacted → converted | lost. Rows stay as history after conversion.
--   · "From your reach" = interests (storefront checkout started, VaNi capture,
--     manual);  "Asked you" = RFQs another tenant invited THIS tenant to
--     (matched by the invite's mobile/email against the tenant's own numbers
--     and its users' emails) — a lead with a specification attached.
--   · conversion is automatic: a contract created for the contact (any path —
--     storefront purchase, the wizard's "Send contract") converts the open
--     interests and swaps 'lead' for 'client'.
-- ============================================================================

-- ── 1. table ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.t_contact_interests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL,
  is_live          boolean NOT NULL DEFAULT true,
  contact_id       uuid NOT NULL REFERENCES public.t_contacts(id),
  kind             text NOT NULL CHECK (kind IN ('storefront','vani','manual')),
  channel          text,                              -- website | whatsapp | link | vani | manual
  storefront_id    uuid,
  storefront_key   text,
  template_family  uuid,
  template_name    text,
  stage            text NOT NULL DEFAULT 'new' CHECK (stage IN ('new','contacted','converted','lost')),
  question         text,                              -- what they asked (VaNi) / said
  note             text,                              -- the team's notes, appended
  contract_id      uuid,                              -- set on conversion
  metadata         jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  last_activity_at timestamptz NOT NULL DEFAULT now(),
  converted_at     timestamptz
);
CREATE INDEX IF NOT EXISTS ix_contact_interests_tenant ON public.t_contact_interests (tenant_id, is_live, stage, last_activity_at DESC);
CREATE INDEX IF NOT EXISTS ix_contact_interests_contact ON public.t_contact_interests (contact_id);
ALTER TABLE public.t_contact_interests ENABLE ROW LEVEL SECURITY;   -- service role only

-- ── 2. helpers ──────────────────────────────────────────────────────────────
-- The tenant's own reach: its business email/phones and its users' emails/mobiles.
CREATE OR REPLACE FUNCTION public.fn_tenant_identities(p_tenant_id uuid)
RETURNS TABLE (emails text[], phones text[]) LANGUAGE sql STABLE AS $fn$
  WITH tp AS (SELECT * FROM public.t_tenant_profiles WHERE tenant_id = p_tenant_id),
       us AS (SELECT up.email, up.mobile_number FROM public.t_user_tenants ut
              JOIN public.t_user_profiles up ON up.user_id = ut.user_id
              WHERE ut.tenant_id = p_tenant_id AND ut.status = 'active')
  SELECT
    COALESCE((SELECT array_agg(DISTINCT lower(e)) FROM (
        SELECT business_email AS e FROM tp UNION ALL SELECT email FROM us) x WHERE NULLIF(btrim(e), '') IS NOT NULL), '{}'),
    COALESCE((SELECT array_agg(DISTINCT right(regexp_replace(p, '[^0-9]', '', 'g'), 10)) FROM (
        SELECT business_phone AS p FROM tp UNION ALL SELECT business_whatsapp FROM tp UNION ALL SELECT mobile_number FROM us) x
        WHERE length(regexp_replace(COALESCE(p, ''), '[^0-9]', '', 'g')) >= 10), '{}')
$fn$;

-- Find a contact in the tenant's book by mobile (last 10 digits) then email.
CREATE OR REPLACE FUNCTION public.fn_find_contact_by_reach(p_tenant_id uuid, p_is_live boolean, p_phone text, p_email text)
RETURNS uuid LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_id uuid; v_phone text := public.fn_storefront_phone(p_phone); v_email text := NULLIF(lower(btrim(p_email)), '');
BEGIN
  IF v_phone IS NOT NULL AND length(v_phone) >= 10 THEN
    SELECT c.id INTO v_id FROM public.t_contacts c JOIN public.t_contact_channels ch ON ch.contact_id = c.id
    WHERE c.tenant_id = p_tenant_id AND c.is_live = p_is_live AND c.is_active = TRUE AND c.status <> 'archived'
      AND ch.channel_type = 'mobile' AND right(regexp_replace(ch.value, '[^0-9]', '', 'g'), 10) = right(v_phone, 10)
    ORDER BY c.created_at LIMIT 1;
  END IF;
  IF v_id IS NULL AND v_email IS NOT NULL THEN
    SELECT c.id INTO v_id FROM public.t_contacts c JOIN public.t_contact_channels ch ON ch.contact_id = c.id
    WHERE c.tenant_id = p_tenant_id AND c.is_live = p_is_live AND c.is_active = TRUE AND c.status <> 'archived'
      AND ch.channel_type = 'email' AND lower(ch.value) = v_email
    ORDER BY c.created_at LIMIT 1;
  END IF;
  RETURN v_id;
END;
$fn$;

-- ── 3. the writer: capture a lead (contact + interest) ──────────────────────
-- p_contact  {name, company, phone, email, phone_verified}
-- p_interest {kind, channel, storefront_key, template_family, template_name, question, note, metadata}
CREATE OR REPLACE FUNCTION public.lead_capture(p_tenant_id uuid, p_is_live boolean, p_contact jsonb, p_interest jsonb, p_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
  v_name text := NULLIF(btrim(p_contact->>'name'), '');
  v_company text := NULLIF(btrim(p_contact->>'company'), '');
  v_email text := NULLIF(lower(btrim(p_contact->>'email')), '');
  v_phone text := public.fn_storefront_phone(p_contact->>'phone');
  v_phone_raw text := NULLIF(regexp_replace(COALESCE(p_contact->>'phone', ''), '[^0-9+]', '', 'g'), '');
  v_kind text := COALESCE(NULLIF(p_interest->>'kind', ''), 'manual');
  v_contact uuid; v_new_contact boolean := false; v_new_interest boolean := false;
  v_seq jsonb; v_tp public.t_touchpoints; v_fam uuid; v_tpl_name text; v_int public.t_contact_interests;
  v_question text := NULLIF(left(btrim(p_interest->>'question'), 1000), '');
  v_note text := NULLIF(left(btrim(p_interest->>'note'), 1000), '');
BEGIN
  IF v_kind NOT IN ('storefront','vani','manual') THEN v_kind := 'manual'; END IF;
  IF v_name IS NULL AND v_company IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'A name is required', 'error_code', 'VALIDATION_ERROR');
  END IF;
  IF v_phone IS NULL AND v_email IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'A mobile number or email is required', 'error_code', 'VALIDATION_ERROR');
  END IF;

  -- storefront + package context (optional)
  IF NULLIF(p_interest->>'storefront_key', '') IS NOT NULL THEN
    v_tp := public.fn_storefront_by_key(p_interest->>'storefront_key');
    IF v_tp.id IS NOT NULL AND v_tp.tenant_id <> p_tenant_id THEN v_tp := NULL; END IF;
  END IF;
  IF NULLIF(p_interest->>'template_family', '') IS NOT NULL THEN
    BEGIN v_fam := public.fn_template_family((p_interest->>'template_family')::uuid); EXCEPTION WHEN OTHERS THEN v_fam := NULL; END;
  END IF;
  IF v_fam IS NOT NULL THEN
    v_tpl_name := (public.fn_storefront_package_json(v_fam))->>'name';
  END IF;
  v_tpl_name := COALESCE(v_tpl_name, NULLIF(btrim(p_interest->>'template_name'), ''));

  -- contact: reuse by verified reach, else create as a lead
  v_contact := public.fn_find_contact_by_reach(p_tenant_id, p_is_live, v_phone, v_email);
  IF v_contact IS NULL THEN
    v_seq := public.get_next_formatted_sequence('CONTACT', p_tenant_id, p_is_live);
    IF v_company IS NOT NULL THEN
      INSERT INTO public.t_contacts (tenant_id, is_live, type, name, company_name, contact_number, classifications, status, is_active, is_seed, source, notes)
      VALUES (p_tenant_id, p_is_live, 'corporate', NULL, v_company, v_seq->>'formatted', '["lead"]'::jsonb, 'active', TRUE, FALSE, v_kind,
              CASE WHEN v_name IS NOT NULL THEN 'Contact: ' || v_name END)
      RETURNING id INTO v_contact;
    ELSE
      INSERT INTO public.t_contacts (tenant_id, is_live, type, name, company_name, contact_number, classifications, status, is_active, is_seed, source)
      VALUES (p_tenant_id, p_is_live, 'individual', v_name, NULL, v_seq->>'formatted', '["lead"]'::jsonb, 'active', TRUE, FALSE, v_kind)
      RETURNING id INTO v_contact;
    END IF;
    IF v_phone IS NOT NULL THEN
      INSERT INTO public.t_contact_channels (contact_id, channel_type, value, is_primary, is_verified)
      VALUES (v_contact, 'mobile', COALESCE(v_phone_raw, v_phone), TRUE, COALESCE((p_contact->>'phone_verified')::boolean, FALSE));
    END IF;
    IF v_email IS NOT NULL THEN
      INSERT INTO public.t_contact_channels (contact_id, channel_type, value, is_primary) VALUES (v_contact, 'email', v_email, v_phone IS NULL);
    END IF;
    v_new_contact := true;
  ELSE
    -- an existing contact that shows interest is a lead unless it is already a client
    UPDATE public.t_contacts
    SET classifications = CASE WHEN classifications ? 'client' OR classifications ? 'lead' THEN classifications
                               ELSE COALESCE(classifications, '[]'::jsonb) || '["lead"]'::jsonb END,
        updated_at = now()
    WHERE id = v_contact;
  END IF;

  -- interest: fold into an open one for the same package within 30 days, else a new row
  SELECT * INTO v_int FROM public.t_contact_interests
  WHERE tenant_id = p_tenant_id AND contact_id = v_contact AND stage IN ('new','contacted')
    AND kind = v_kind AND template_family IS NOT DISTINCT FROM v_fam
    AND last_activity_at > now() - interval '30 days'
  ORDER BY last_activity_at DESC LIMIT 1 FOR UPDATE;
  IF v_int.id IS NULL THEN
    INSERT INTO public.t_contact_interests (tenant_id, is_live, contact_id, kind, channel, storefront_id, storefront_key,
                                            template_family, template_name, question, note, metadata)
    VALUES (p_tenant_id, p_is_live, v_contact, v_kind, NULLIF(p_interest->>'channel', ''), v_tp.id, v_tp.storefront_key,
            v_fam, v_tpl_name, v_question, v_note, COALESCE(p_interest->'metadata', '{}'::jsonb))
    RETURNING * INTO v_int;
    v_new_interest := true;
    IF v_tp.id IS NOT NULL THEN UPDATE public.t_touchpoints SET leads_count = leads_count + 1 WHERE id = v_tp.id; END IF;
  ELSE
    UPDATE public.t_contact_interests
    SET last_activity_at = now(), updated_at = now(),
        question = CASE WHEN v_question IS NULL THEN question WHEN question IS NULL THEN v_question ELSE question || E'\n' || v_question END,
        note     = CASE WHEN v_note IS NULL THEN note WHEN note IS NULL THEN v_note ELSE note || E'\n' || v_note END,
        metadata = metadata || COALESCE(p_interest->'metadata', '{}'::jsonb)
    WHERE id = v_int.id RETURNING * INTO v_int;
  END IF;

  RETURN jsonb_build_object('success', true, 'contact_id', v_contact, 'interest_id', v_int.id,
                            'is_new_contact', v_new_contact, 'is_new_interest', v_new_interest, 'stage', v_int.stage);
END;
$fn$;

-- ── 4. stage tool ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.lead_set_stage(p_tenant_id uuid, p_interest_id uuid, p_stage text, p_note text DEFAULT NULL, p_actor_name text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_int public.t_contact_interests; v_line text;
BEGIN
  SELECT * INTO v_int FROM public.t_contact_interests WHERE id = p_interest_id AND tenant_id = p_tenant_id FOR UPDATE;
  IF v_int.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Lead not found', 'error_code', 'NOT_FOUND'); END IF;
  IF p_stage IS NOT NULL AND p_stage NOT IN ('new','contacted','converted','lost') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unknown stage', 'error_code', 'VALIDATION_ERROR');
  END IF;
  IF NULLIF(btrim(p_note), '') IS NOT NULL THEN
    v_line := to_char(now() AT TIME ZONE 'Asia/Kolkata', 'DD Mon HH24:MI') || COALESCE(' · ' || p_actor_name, '') || ': ' || left(btrim(p_note), 1000);
  END IF;
  UPDATE public.t_contact_interests
  SET stage = COALESCE(p_stage, stage),
      note = CASE WHEN v_line IS NULL THEN note WHEN note IS NULL THEN v_line ELSE note || E'\n' || v_line END,
      last_activity_at = now(), updated_at = now(),
      converted_at = CASE WHEN p_stage = 'converted' THEN COALESCE(converted_at, now()) ELSE converted_at END
  WHERE id = v_int.id RETURNING * INTO v_int;
  RETURN jsonb_build_object('success', true, 'interest', to_jsonb(v_int));
END;
$fn$;

-- ── 5. conversion: a contract for the contact converts the open interests ───
CREATE OR REPLACE FUNCTION public.lead_convert_interests(p_tenant_id uuid, p_contact_id uuid, p_template_family uuid, p_contract_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_n integer;
BEGIN
  IF p_contact_id IS NULL THEN RETURN 0; END IF;
  WITH u AS (
    UPDATE public.t_contact_interests
    SET stage = 'converted', contract_id = p_contract_id, converted_at = now(), last_activity_at = now(), updated_at = now()
    WHERE tenant_id = p_tenant_id AND contact_id = p_contact_id AND stage IN ('new','contacted')
      AND (p_template_family IS NULL OR template_family IS NULL OR template_family = p_template_family)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM u;
  -- once there is a contract, the contact is a client; 'lead' comes off
  UPDATE public.t_contacts
  SET classifications = (SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) FROM jsonb_array_elements(COALESCE(classifications, '[]'::jsonb) || '["client"]'::jsonb) x
                          WHERE x <> '"lead"'::jsonb) , updated_at = now()
  WHERE id = p_contact_id AND (classifications ? 'lead' OR NOT (classifications ? 'client'));
  -- de-duplicate 'client' if it was already there
  UPDATE public.t_contacts
  SET classifications = (SELECT COALESCE(jsonb_agg(DISTINCT x), '[]'::jsonb) FROM jsonb_array_elements(classifications) x)
  WHERE id = p_contact_id;
  RETURN v_n;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.trg_contract_converts_lead()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_fam uuid;
BEGIN
  IF NEW.record_type = 'contract' AND NEW.buyer_id IS NOT NULL THEN
    BEGIN
      v_fam := NULLIF(NEW.metadata->>'template_family', '')::uuid;
    EXCEPTION WHEN OTHERS THEN v_fam := NULL;
    END;
    BEGIN
      PERFORM public.lead_convert_interests(NEW.tenant_id, NEW.buyer_id, v_fam, NEW.id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'lead conversion skipped for contract %: %', NEW.id, SQLERRM;  -- never block a contract
    END;
  END IF;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS trg_contract_converts_lead ON public.t_contracts;
CREATE TRIGGER trg_contract_converts_lead AFTER INSERT ON public.t_contracts
  FOR EACH ROW WHEN (NEW.buyer_id IS NOT NULL) EXECUTE FUNCTION public.trg_contract_converts_lead();

-- ── 6. public: the checkout identifies the buyer once the phone is verified ─
-- Called by /buy/:key right after OTP verification, so a checkout that stops
-- there still leaves a named lead ("started, didn't buy").
CREATE OR REPLACE FUNCTION public.storefront_identify(p_key text, p_buyer jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_tp public.t_touchpoints; v_otp public.t_storefront_otp; v_phone text; v_fam uuid; v_res jsonb;
BEGIN
  v_tp := public.fn_storefront_by_key(p_key);
  IF v_tp.id IS NULL OR NOT public.fn_storefront_entitled(v_tp.tenant_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'NOT_FOUND');
  END IF;
  v_phone := public.fn_storefront_phone(p_buyer->>'phone');
  SELECT * INTO v_otp FROM public.t_storefront_otp
  WHERE verify_token = NULLIF(p_buyer->>'otp_token', '') AND verified_at > now() - interval '30 minutes';
  IF v_otp.id IS NULL OR v_phone IS NULL OR right(v_otp.phone, 10) <> right(v_phone, 10) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Verify your mobile number first', 'error_code', 'PHONE_NOT_VERIFIED');
  END IF;
  BEGIN v_fam := public.fn_template_family(NULLIF(p_buyer->>'template_id', '')::uuid); EXCEPTION WHEN OTHERS THEN v_fam := NULL; END;
  IF v_fam IS NULL OR NOT (v_fam = ANY (v_tp.template_ids)) THEN v_fam := v_tp.template_ids[1]; END IF;
  v_res := public.lead_capture(v_tp.tenant_id, TRUE,
    jsonb_build_object('name', p_buyer->>'name', 'company', p_buyer->>'company', 'phone', p_buyer->>'phone', 'email', p_buyer->>'email', 'phone_verified', true),
    jsonb_build_object('kind', 'storefront', 'channel', COALESCE(NULLIF(p_buyer->>'channel', ''), 'website'),
                       'storefront_key', v_tp.storefront_key, 'template_family', v_fam, 'note', 'Started checkout'));
  RETURN v_res;
END;
$fn$;
REVOKE ALL ON FUNCTION public.storefront_identify(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lead_capture(uuid, boolean, jsonb, jsonb, jsonb) FROM PUBLIC, anon, authenticated;

-- ── 7. the reader ───────────────────────────────────────────────────────────
-- p_tab 'reach' → one row per contact with its interests; 'asked' → RFQs sent to this tenant.
CREATE OR REPLACE FUNCTION public.get_leads(p_tenant_id uuid, p_is_live boolean, p_tab text DEFAULT 'reach', p_stage text DEFAULT NULL,
                                            p_q text DEFAULT NULL, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE AS $fn$
DECLARE v_q text := NULLIF(lower(btrim(p_q)), ''); v_rows jsonb; v_counts jsonb; v_asked jsonb; v_asked_counts jsonb; v_emails text[]; v_phones text[]; v_lim int := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
  SELECT emails, phones INTO v_emails, v_phones FROM public.fn_tenant_identities(p_tenant_id);

  -- ── reach ──
  WITH per_contact AS (
    SELECT c.id AS contact_id,
           COALESCE(NULLIF(c.company_name, ''), c.name) AS display_name,
           c.name, c.company_name, c.type, c.classifications, c.contact_number,
           (SELECT ch.value FROM public.t_contact_channels ch WHERE ch.contact_id = c.id AND ch.channel_type = 'mobile' ORDER BY ch.is_primary DESC, ch.created_at LIMIT 1) AS mobile,
           (SELECT ch.value FROM public.t_contact_channels ch WHERE ch.contact_id = c.id AND ch.channel_type = 'email' ORDER BY ch.is_primary DESC, ch.created_at LIMIT 1) AS email,
           jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'channel', i.channel, 'storefront_key', i.storefront_key,
                     'template_family', i.template_family, 'template_name', i.template_name, 'stage', i.stage,
                     'question', i.question, 'note', i.note, 'contract_id', i.contract_id,
                     'contract_number', (SELECT k.contract_number FROM public.t_contracts k WHERE k.id = i.contract_id),
                     'created_at', i.created_at, 'last_activity_at', i.last_activity_at, 'converted_at', i.converted_at)
                     ORDER BY i.last_activity_at DESC) AS interests,
           max(i.last_activity_at) AS last_activity_at,
           CASE WHEN bool_or(i.stage = 'contacted') THEN 'contacted'
                WHEN bool_or(i.stage = 'new') THEN 'new'
                WHEN bool_or(i.stage = 'converted') THEN 'converted' ELSE 'lost' END AS stage,
           string_agg(coalesce(i.template_name, ''), ' ') AS tnames
    FROM public.t_contact_interests i JOIN public.t_contacts c ON c.id = i.contact_id
    WHERE i.tenant_id = p_tenant_id AND i.is_live = p_is_live
    GROUP BY c.id
  ), filtered AS (
    SELECT * FROM per_contact p
    WHERE (v_q IS NULL OR lower(COALESCE(p.display_name, '')) LIKE '%' || v_q || '%' OR lower(COALESCE(p.name, '')) LIKE '%' || v_q || '%'
           OR lower(COALESCE(p.mobile, '')) LIKE '%' || v_q || '%' OR lower(COALESCE(p.email, '')) LIKE '%' || v_q || '%'
           OR lower(p.tnames) LIKE '%' || v_q || '%')
  )
  SELECT jsonb_build_object('all', count(*), 'new', count(*) FILTER (WHERE stage = 'new'), 'contacted', count(*) FILTER (WHERE stage = 'contacted'),
                            'converted', count(*) FILTER (WHERE stage = 'converted'), 'lost', count(*) FILTER (WHERE stage = 'lost')),
         (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'contact', jsonb_build_object('id', f.contact_id, 'name', f.display_name, 'person', CASE WHEN f.company_name IS NOT NULL THEN f.name END,
                                          'type', f.type, 'classifications', f.classifications, 'contact_number', f.contact_number, 'mobile', f.mobile, 'email', f.email),
            'stage', f.stage, 'last_activity_at', f.last_activity_at, 'interests', f.interests) ORDER BY f.last_activity_at DESC), '[]'::jsonb)
          FROM (SELECT * FROM filtered x
                WHERE (p_stage IS NULL OR p_stage = '' OR p_stage = 'all' OR x.stage = p_stage)
                ORDER BY x.last_activity_at DESC LIMIT v_lim OFFSET GREATEST(COALESCE(p_offset, 0), 0)) f)
  INTO v_counts, v_rows FROM filtered;

  -- ── asked: RFQs another tenant sent to us ──
  WITH inv AS (
    SELECT v.id AS vendor_row_id, v.contract_id, v.vendor_id, v.vendor_name, v.vendor_email, v.response_status, v.responded_at,
           v.quoted_amount, v.quote_currency, v.access_secret, v.created_at AS asked_at, v.viewed_at,
           c.tenant_id AS buyer_tenant_id, c.rfq_number, c.name AS title, c.status AS rfq_status, c.global_access_id AS cnak,
           c.metadata->'rfp_buyer_v1' AS rfp, c.created_at AS rfq_created_at
    FROM public.t_contract_vendors v JOIN public.t_contracts c ON c.id = v.contract_id
    WHERE c.record_type = 'rfq' AND c.tenant_id <> p_tenant_id AND COALESCE(c.is_live, true) = p_is_live
      AND (
        (v.vendor_email IS NOT NULL AND lower(v.vendor_email) = ANY (v_emails))
        OR EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(c.metadata->'rfp_buyer_v1'->'invites', '[]'::jsonb)) x
                   WHERE NULLIF(x->>'contactId', '')::uuid = v.vendor_id
                     AND (right(regexp_replace(COALESCE(x->>'mobile', ''), '[^0-9]', '', 'g'), 10) = ANY (v_phones)
                          OR (NULLIF(lower(x->>'email'), '') IS NOT NULL AND lower(x->>'email') = ANY (v_emails))))
      )
  ), shaped AS (
    SELECT i.*,
           (SELECT COALESCE(NULLIF(tp.business_name, ''), t.name) FROM public.t_tenants t LEFT JOIN public.t_tenant_profiles tp ON tp.tenant_id = t.id WHERE t.id = i.buyer_tenant_id LIMIT 1) AS buyer_name,
           CASE WHEN i.response_status IN ('quoted','accepted','declined','rejected') OR i.rfq_status IN ('awarded','converted_to_contract','closed','cancelled')
                THEN CASE WHEN i.response_status = 'accepted' THEN 'awarded' WHEN i.response_status = 'quoted' THEN 'quoted'
                          WHEN i.response_status IN ('declined','rejected') THEN 'declined' ELSE 'closed' END
                ELSE 'open' END AS state,
           NULLIF(i.rfp->>'deadline', '') AS deadline, NULLIF(i.rfp->>'deadlineTime', '') AS deadline_time,
           jsonb_array_length(COALESCE(i.rfp->'blocks', '[]'::jsonb)) AS blocks_count,
           NULLIF(i.rfp->>'location', '') AS location
    FROM inv i
  )
  SELECT jsonb_build_object('all', count(*), 'open', count(*) FILTER (WHERE state = 'open'), 'quoted', count(*) FILTER (WHERE state = 'quoted'),
                            'awarded', count(*) FILTER (WHERE state = 'awarded'), 'closed', count(*) FILTER (WHERE state IN ('declined','closed'))),
         COALESCE(jsonb_agg(jsonb_build_object(
           'rfq_id', s.contract_id, 'rfq_number', s.rfq_number, 'title', s.title, 'buyer_name', s.buyer_name, 'buyer_tenant_id', s.buyer_tenant_id,
           'state', s.state, 'response_status', s.response_status, 'rfq_status', s.rfq_status,
           'deadline', s.deadline, 'deadline_time', s.deadline_time, 'blocks_count', s.blocks_count, 'location', s.location,
           'quoted_amount', s.quoted_amount, 'quote_currency', s.quote_currency, 'responded_at', s.responded_at, 'viewed_at', s.viewed_at,
           'asked_at', s.asked_at, 'quote_path', CASE WHEN s.cnak IS NOT NULL AND s.access_secret IS NOT NULL THEN '/quote/' || s.cnak || '/' || s.access_secret END)
           ORDER BY (s.state = 'open') DESC, s.asked_at DESC) FILTER (WHERE v_q IS NULL OR lower(COALESCE(s.title, '')) LIKE '%' || v_q || '%' OR lower(COALESCE(s.buyer_name, '')) LIKE '%' || v_q || '%' OR lower(COALESCE(s.rfq_number, '')) LIKE '%' || v_q || '%'), '[]'::jsonb)
  INTO v_asked_counts, v_asked FROM shaped s;

  RETURN jsonb_build_object('success', true,
    'reach', jsonb_build_object('rows', v_rows, 'counts', v_counts),
    'asked', jsonb_build_object('rows', v_asked, 'counts', v_asked_counts),
    'tab', COALESCE(p_tab, 'reach'));
END;
$fn$;
