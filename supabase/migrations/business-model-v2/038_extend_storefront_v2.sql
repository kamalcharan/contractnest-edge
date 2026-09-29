-- ============================================================================
-- 038 · Extend storefront v2 — package-first storefronts
-- ============================================================================
-- Owner (2026-09-29): "storefront is package-first, channels are actions on it;
-- configurator plus a JS hook, not an SDK; Explore gets a package page; OTP on
-- checkout; brand colour from the profile." Built from the Extend playground.
--
-- What changes on t_touchpoints (the row IS the storefront now):
--   name            display name ("1 year HVAC template" / "Maintenance packages")
--   template_ids    the packages, stored as template FAMILY ids (root id) so a
--                   storefront follows the latest signed-off version instead of
--                   pinning one (signia's two rows pointed at v2 and v6 of the
--                   same template)
--   card_style      {view,label,color,shape,open} — applied everywhere the card
--                   renders (widget, package page, chat)
--   faq             [{q,a}] the seller writes; VaNi answers from it first
--   chats/leads/starts counters next to views/purchases
--   touchpoint_type 'storefront' on live rows; the per-channel duplicates are
--                   collapsed (oldest kept, others inactive with config.merged_into,
--                   their keys still resolve to the kept row)
--
-- Public surface (no auth, storefront key is the credential):
--   resolve_storefront(key, count)     the page/widget payload
--   storefront_mark_started(key)       checkout opened
--   storefront_otp_issue / _verify     phone OTP (API sends the code)
--   purchase_from_storefront(key, buyer) now needs a verified phone token and
--                                      takes template_id (which package)
-- Management: create_storefront, update_storefront, list_storefronts.
-- create_touchpoint / list_touchpoints stay for one release, unused by the API.
-- ============================================================================

-- ── 1. columns ──────────────────────────────────────────────────────────────
ALTER TABLE public.t_touchpoints
  ADD COLUMN IF NOT EXISTS name          text,
  ADD COLUMN IF NOT EXISTS template_ids  uuid[]  NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS card_style    jsonb   NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS faq           jsonb   NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS chats_count   integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS leads_count   integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS starts_count  integer NOT NULL DEFAULT 0;

ALTER TABLE public.t_touchpoints DROP CONSTRAINT IF EXISTS t_touchpoints_touchpoint_type_check;
ALTER TABLE public.t_touchpoints ADD CONSTRAINT t_touchpoints_touchpoint_type_check
  CHECK (touchpoint_type IN ('storefront','website','whatsapp','email'));
ALTER TABLE public.t_touchpoints DROP CONSTRAINT IF EXISTS t_touchpoints_tenant_id_template_id_touchpoint_type_key;

-- ── 2. helpers ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_template_family(p_template_id uuid)
RETURNS uuid LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE(parent_template_id, id) FROM public.t_cat_templates WHERE id = p_template_id
$fn$;

-- The version a storefront sells today: latest signed-off, active, live-first.
CREATE OR REPLACE FUNCTION public.fn_storefront_latest_template(p_family uuid)
RETURNS uuid LANGUAGE sql STABLE AS $fn$
  SELECT t.id FROM public.t_cat_templates t
  WHERE COALESCE(t.parent_template_id, t.id) = p_family
    AND t.is_active = TRUE AND t.settings->>'lifecycle' = 'signed_off'
  ORDER BY t.is_live DESC, t.is_latest DESC, t.version DESC
  LIMIT 1
$fn$;

CREATE OR REPLACE FUNCTION public.fn_storefront_entitled(p_tenant_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $fn$
  SELECT public.fn_touchpoint_entitled(p_tenant_id, 'website')
      OR public.fn_touchpoint_entitled(p_tenant_id, 'whatsapp')
$fn$;

-- Display-safe package object (no config, no wizard_state, no internal block ids).
CREATE OR REPLACE FUNCTION public.fn_storefront_package_json(p_family uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_tpl RECORD;
BEGIN
  SELECT * INTO v_tpl FROM public.t_cat_templates WHERE id = public.fn_storefront_latest_template(p_family);
  IF v_tpl.id IS NULL THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'id',          v_tpl.id,
    'family_id',   p_family,
    'name',        COALESCE(v_tpl.display_name, v_tpl.name),
    'description', v_tpl.description,
    'cover_image', v_tpl.cover_image,
    'currency',    COALESCE(v_tpl.currency, 'INR'),
    'price',       COALESCE(v_tpl.total, 0),
    'term',        jsonb_build_object('value', v_tpl.settings->'defaults'->'duration_value',
                                      'unit',  v_tpl.settings->'defaults'->>'duration_unit'),
    'lines', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'name',          b->'config_overrides'->>'name',
        'quantity',      COALESCE((b->'config_overrides'->>'quantity')::INT, 1),
        'unit_price',    COALESCE((b->'config_overrides'->>'unit_price')::NUMERIC, 0),
        'total_price',   COALESCE((b->'config_overrides'->>'total_price')::NUMERIC, 0),
        'billing_cycle', b->'config_overrides'->>'billing_cycle',
        'category',      b->'config_overrides'->>'category_id')
        ORDER BY COALESCE((b->>'order')::INT, 0))
      FROM jsonb_array_elements(COALESCE(v_tpl.blocks, '[]'::jsonb)) b
      WHERE COALESCE(b->'config_overrides'->>'category_id','') NOT IN ('metering')
    ), '[]'::jsonb));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.fn_storefront_packages(p_families uuid[])
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE(jsonb_agg(pkg ORDER BY ord), '[]'::jsonb)
  FROM (SELECT public.fn_storefront_package_json(f) AS pkg, ord
        FROM unnest(p_families) WITH ORDINALITY AS u(f, ord)) x
  WHERE pkg IS NOT NULL
$fn$;

-- Card style: only known keys, only sane values; the tenant's brand colour is the default.
CREATE OR REPLACE FUNCTION public.fn_storefront_card_style(p_tenant_id uuid, p_current jsonb, p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v_brand text; v_out jsonb; v_view text; v_label text; v_color text; v_shape text; v_open text;
BEGIN
  SELECT NULLIF(btrim(primary_color), '') INTO v_brand FROM public.t_tenant_profiles WHERE tenant_id = p_tenant_id;
  IF v_brand IS NULL OR v_brand !~ '^#[0-9a-fA-F]{6}$' THEN v_brand := '#4F46E5'; END IF;
  v_out := jsonb_build_object('view','button','label','Buy now','color',v_brand,'shape','pill','open','overlay')
           || COALESCE(p_current, '{}'::jsonb);
  IF p_patch IS NOT NULL THEN
    v_view  := p_patch->>'view';  IF v_view  IN ('button','card','catalog','bubble') THEN v_out := v_out || jsonb_build_object('view', v_view); END IF;
    v_label := NULLIF(btrim(p_patch->>'label'), ''); IF v_label IS NOT NULL AND length(v_label) <= 40 THEN v_out := v_out || jsonb_build_object('label', v_label); END IF;
    v_color := p_patch->>'color'; IF v_color ~ '^#[0-9a-fA-F]{6}$' THEN v_out := v_out || jsonb_build_object('color', v_color); END IF;
    v_shape := p_patch->>'shape'; IF v_shape IN ('pill','rounded','square') THEN v_out := v_out || jsonb_build_object('shape', v_shape); END IF;
    v_open  := p_patch->>'open';  IF v_open  IN ('overlay','tab') THEN v_out := v_out || jsonb_build_object('open', v_open); END IF;
  END IF;
  RETURN v_out;
END;
$fn$;

-- FAQ: array of {q,a}, trimmed, at most 20 rows of 300 chars each; anything else dropped.
CREATE OR REPLACE FUNCTION public.fn_storefront_faq(p_faq jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $fn$
  SELECT COALESCE((
    SELECT jsonb_agg(jsonb_build_object('q', left(btrim(e->>'q'), 300), 'a', left(btrim(e->>'a'), 300)) ORDER BY ord)
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_faq) = 'array' THEN p_faq ELSE '[]'::jsonb END) WITH ORDINALITY AS x(e, ord)
    WHERE NULLIF(btrim(e->>'q'), '') IS NOT NULL AND NULLIF(btrim(e->>'a'), '') IS NOT NULL AND ord <= 20
  ), '[]'::jsonb)
$fn$;

-- One storefront row for the management surface.
CREATE OR REPLACE FUNCTION public.fn_storefront_row_json(p_row public.t_touchpoints)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT jsonb_build_object(
    'id',             p_row.id,
    'storefront_key', p_row.storefront_key,
    'name',           p_row.name,
    'is_active',      p_row.is_active,
    'template_ids',   to_jsonb(p_row.template_ids),
    'packages',       public.fn_storefront_packages(p_row.template_ids),
    'card_style',     public.fn_storefront_card_style(p_row.tenant_id, p_row.card_style, NULL),
    'faq',            p_row.faq,
    'counters',       jsonb_build_object('views', p_row.views_count, 'chats', p_row.chats_count,
                                         'leads', p_row.leads_count, 'starts', p_row.starts_count,
                                         'purchases', p_row.purchases_count),
    'created_at',     p_row.created_at,
    'updated_at',     p_row.updated_at)
$fn$;

-- Validates and normalises a package list to family ids. Raises with a code on failure.
CREATE OR REPLACE FUNCTION public.fn_storefront_normalise_templates(p_tenant_id uuid, p_template_ids uuid[])
RETURNS uuid[] LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_id uuid; v_fam uuid; v_out uuid[] := '{}';
BEGIN
  IF p_template_ids IS NULL OR array_length(p_template_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Pick at least one package' USING ERRCODE = 'P0001', DETAIL = 'VALIDATION_ERROR';
  END IF;
  IF array_length(p_template_ids, 1) > 12 THEN
    RAISE EXCEPTION 'A storefront holds at most 12 packages' USING ERRCODE = 'P0001', DETAIL = 'VALIDATION_ERROR';
  END IF;
  FOREACH v_id IN ARRAY p_template_ids LOOP
    SELECT COALESCE(parent_template_id, id) INTO v_fam FROM public.t_cat_templates WHERE id = v_id AND tenant_id = p_tenant_id;
    IF v_fam IS NULL THEN
      RAISE EXCEPTION 'Template not found' USING ERRCODE = 'P0001', DETAIL = 'TEMPLATE_NOT_FOUND';
    END IF;
    IF public.fn_storefront_latest_template(v_fam) IS NULL THEN
      RAISE EXCEPTION 'Template is not published (sign it off first)' USING ERRCODE = 'P0001', DETAIL = 'TEMPLATE_NOT_PUBLISHABLE';
    END IF;
    IF NOT (v_fam = ANY (v_out)) THEN v_out := v_out || v_fam; END IF;
  END LOOP;
  RETURN v_out;
END;
$fn$;

-- ── 3. backfill: template families, names, collapse per-channel duplicates ──
UPDATE public.t_touchpoints tp
SET template_ids = ARRAY[public.fn_template_family(tp.template_id)]
WHERE tp.template_ids = '{}';

UPDATE public.t_touchpoints tp
SET name = (SELECT COALESCE(t.display_name, t.name) FROM public.t_cat_templates t WHERE t.id = tp.template_id)
WHERE tp.name IS NULL;

WITH ranked AS (
  SELECT tp.id,
         row_number()  OVER (PARTITION BY tp.tenant_id, tp.template_ids[1] ORDER BY tp.created_at, tp.id) AS rn,
         first_value(tp.id) OVER (PARTITION BY tp.tenant_id, tp.template_ids[1] ORDER BY tp.created_at, tp.id) AS keep_id
  FROM public.t_touchpoints tp
  WHERE NOT (tp.config ? 'merged_into'))
UPDATE public.t_touchpoints tp
SET is_active = FALSE,
    config    = tp.config || jsonb_build_object('merged_into', r.keep_id, 'merged_at', now()),
    updated_at = now()
FROM ranked r WHERE r.id = tp.id AND r.rn > 1;

UPDATE public.t_touchpoints k
SET views_count = k.views_count + s.v, purchases_count = k.purchases_count + s.p, updated_at = now()
FROM (SELECT (config->>'merged_into')::uuid AS keep_id, SUM(views_count) AS v, SUM(purchases_count) AS p
      FROM public.t_touchpoints WHERE config ? 'merged_into' AND NOT (config ? 'merged_counted') GROUP BY 1) s
WHERE s.keep_id = k.id;
UPDATE public.t_touchpoints SET config = config || '{"merged_counted": true}'::jsonb WHERE config ? 'merged_into' AND NOT (config ? 'merged_counted');

UPDATE public.t_touchpoints SET touchpoint_type = 'storefront', updated_at = now()
WHERE NOT (config ? 'merged_into') AND touchpoint_type <> 'storefront';

-- ── 4. management RPCs ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_storefront(
  p_tenant_id uuid, p_template_ids uuid[], p_name text DEFAULT NULL,
  p_card_style jsonb DEFAULT '{}'::jsonb, p_user_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_fams uuid[]; v_row public.t_touchpoints; v_key text; v_name text; v_detail text;
BEGIN
  IF NOT public.fn_storefront_entitled(p_tenant_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Website or WhatsApp is not enabled on your account', 'error_code', 'TOUCHPOINT_NOT_ENTITLED');
  END IF;
  BEGIN
    v_fams := public.fn_storefront_normalise_templates(p_tenant_id, p_template_ids);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', COALESCE(NULLIF(v_detail, ''), 'VALIDATION_ERROR'));
  END;
  v_name := NULLIF(left(btrim(p_name), 120), '');
  IF v_name IS NULL THEN
    v_name := CASE WHEN array_length(v_fams, 1) = 1
              THEN (public.fn_storefront_package_json(v_fams[1]))->>'name' ELSE 'Packages' END;
  END IF;
  v_key := 'sf-' || md5(gen_random_uuid()::text || gen_random_uuid()::text || clock_timestamp()::text);
  INSERT INTO public.t_touchpoints (tenant_id, template_id, template_ids, touchpoint_type, storefront_key, name, card_style, created_by)
  VALUES (p_tenant_id, v_fams[1], v_fams, 'storefront', v_key, v_name,
          public.fn_storefront_card_style(p_tenant_id, '{}'::jsonb, p_card_style), p_user_id)
  RETURNING * INTO v_row;
  RETURN jsonb_build_object('success', true, 'storefront', public.fn_storefront_row_json(v_row));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.update_storefront(p_tenant_id uuid, p_storefront_id uuid, p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_row public.t_touchpoints; v_fams uuid[]; v_ids uuid[]; v_detail text;
BEGIN
  SELECT * INTO v_row FROM public.t_touchpoints WHERE id = p_storefront_id AND tenant_id = p_tenant_id FOR UPDATE;
  IF v_row.id IS NULL OR (v_row.config ? 'merged_into') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Storefront not found', 'error_code', 'NOT_FOUND');
  END IF;
  IF p_patch ? 'template_ids' THEN
    BEGIN
      SELECT array_agg(x::uuid) INTO v_ids FROM jsonb_array_elements_text(p_patch->'template_ids') x;
      v_fams := public.fn_storefront_normalise_templates(p_tenant_id, v_ids);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
      RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', COALESCE(NULLIF(v_detail, ''), 'VALIDATION_ERROR'));
    END;
    v_row.template_ids := v_fams; v_row.template_id := v_fams[1];
  END IF;
  IF p_patch ? 'name' THEN v_row.name := COALESCE(NULLIF(left(btrim(p_patch->>'name'), 120), ''), v_row.name); END IF;
  IF p_patch ? 'card_style' THEN v_row.card_style := public.fn_storefront_card_style(p_tenant_id, v_row.card_style, p_patch->'card_style'); END IF;
  IF p_patch ? 'faq' THEN v_row.faq := public.fn_storefront_faq(p_patch->'faq'); END IF;
  IF p_patch ? 'is_active' THEN v_row.is_active := COALESCE((p_patch->>'is_active')::boolean, v_row.is_active); END IF;
  UPDATE public.t_touchpoints SET
    template_ids = v_row.template_ids, template_id = v_row.template_id, name = v_row.name,
    card_style = v_row.card_style, faq = v_row.faq, is_active = v_row.is_active, updated_at = now()
  WHERE id = v_row.id RETURNING * INTO v_row;
  RETURN jsonb_build_object('success', true, 'storefront', public.fn_storefront_row_json(v_row));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.list_storefronts(p_tenant_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER STABLE AS $fn$
BEGIN
  RETURN jsonb_build_object(
    'success', true,
    'storefronts', COALESCE((
      SELECT jsonb_agg(public.fn_storefront_row_json(tp) ORDER BY tp.created_at DESC)
      FROM public.t_touchpoints tp
      WHERE tp.tenant_id = p_tenant_id AND NOT (tp.config ? 'merged_into')), '[]'::jsonb),
    'channels', jsonb_build_object(
      'website',  public.fn_touchpoint_entitled(p_tenant_id, 'website'),
      'whatsapp', public.fn_touchpoint_entitled(p_tenant_id, 'whatsapp')),
    'vani_enabled', public.vani_is_enabled(p_tenant_id));
END;
$fn$;

-- ── 5. public RPCs ──────────────────────────────────────────────────────────
-- Finds the live row for a key, following a merged (per-channel) key to its keeper.
CREATE OR REPLACE FUNCTION public.fn_storefront_by_key(p_key text)
RETURNS public.t_touchpoints LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_row public.t_touchpoints;
BEGIN
  SELECT * INTO v_row FROM public.t_touchpoints WHERE storefront_key = p_key;
  IF v_row.id IS NOT NULL AND (v_row.config ? 'merged_into') THEN
    SELECT * INTO v_row FROM public.t_touchpoints WHERE id = (v_row.config->>'merged_into')::uuid;
  END IF;
  IF v_row.id IS NULL OR NOT v_row.is_active THEN RETURN NULL; END IF;
  RETURN v_row;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.resolve_storefront(p_key text, p_count boolean DEFAULT TRUE)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_tp public.t_touchpoints; v_pkgs jsonb; v_seller jsonb;
BEGIN
  v_tp := public.fn_storefront_by_key(p_key);
  IF v_tp.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'NOT_FOUND');
  END IF;
  IF NOT public.fn_storefront_entitled(v_tp.tenant_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'NOT_ENTITLED');
  END IF;
  v_pkgs := public.fn_storefront_packages(v_tp.template_ids);
  IF jsonb_array_length(v_pkgs) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'TEMPLATE_GONE');
  END IF;
  SELECT jsonb_build_object(
           'name',            COALESCE(NULLIF(tp.business_name, ''), tn.name),
           'logo_url',        tp.logo_url,
           'primary_color',   tp.primary_color,
           'secondary_color', tp.secondary_color,
           'city',            tp.city)
  INTO v_seller
  FROM public.t_tenants tn LEFT JOIN public.t_tenant_profiles tp ON tp.tenant_id = tn.id
  WHERE tn.id = v_tp.tenant_id LIMIT 1;
  IF p_count THEN UPDATE public.t_touchpoints SET views_count = views_count + 1 WHERE id = v_tp.id; END IF;
  RETURN jsonb_build_object('success', true, 'storefront', jsonb_build_object(
    'key',          v_tp.storefront_key,
    'name',         v_tp.name,
    'seller',       v_seller,
    'card_style',   public.fn_storefront_card_style(v_tp.tenant_id, v_tp.card_style, NULL),
    'faq',          v_tp.faq,
    'packages',     v_pkgs,
    'vani_enabled', public.vani_is_enabled(v_tp.tenant_id),
    -- kept for the old buy page shape: the first package
    'seller_name',  v_seller->>'name',
    'template',     v_pkgs->0));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.storefront_mark_started(p_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_tp public.t_touchpoints;
BEGIN
  v_tp := public.fn_storefront_by_key(p_key);
  IF v_tp.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error_code', 'NOT_FOUND'); END IF;
  UPDATE public.t_touchpoints SET starts_count = starts_count + 1 WHERE id = v_tp.id;
  RETURN jsonb_build_object('success', true);
END;
$fn$;

-- ── 6. OTP ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.t_storefront_otp (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  storefront_key text NOT NULL,
  phone          text NOT NULL,                 -- digits only, as dialled
  code_hash      text NOT NULL,
  attempts       integer NOT NULL DEFAULT 0,
  expires_at     timestamptz NOT NULL,
  verified_at    timestamptz,
  verify_token   text,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_storefront_otp_phone ON public.t_storefront_otp (phone, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_storefront_otp_token ON public.t_storefront_otp (verify_token) WHERE verify_token IS NOT NULL;
ALTER TABLE public.t_storefront_otp ENABLE ROW LEVEL SECURITY;   -- service role only

CREATE OR REPLACE FUNCTION public.fn_storefront_phone(p_raw text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT NULLIF(regexp_replace(COALESCE(p_raw, ''), '[^0-9]', '', 'g'), '')
$fn$;

-- Issues a code. The API sends it; the code is returned ONLY to the API.
CREATE OR REPLACE FUNCTION public.storefront_otp_issue(p_key text, p_phone text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_tp public.t_touchpoints; v_phone text; v_code text; v_id uuid; v_recent int;
BEGIN
  v_tp := public.fn_storefront_by_key(p_key);
  IF v_tp.id IS NULL OR NOT public.fn_storefront_entitled(v_tp.tenant_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'NOT_FOUND');
  END IF;
  v_phone := public.fn_storefront_phone(p_phone);
  IF v_phone IS NULL OR length(v_phone) < 10 OR length(v_phone) > 15 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Enter a valid mobile number', 'error_code', 'VALIDATION_ERROR');
  END IF;
  SELECT count(*) INTO v_recent FROM public.t_storefront_otp WHERE phone = v_phone AND created_at > now() - interval '10 minutes';
  IF v_recent >= 3 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Too many codes sent. Try again in a few minutes.', 'error_code', 'RATE_LIMITED');
  END IF;
  v_code := lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
  INSERT INTO public.t_storefront_otp (storefront_key, phone, code_hash, expires_at)
  VALUES (v_tp.storefront_key, v_phone, md5(v_code || v_phone), now() + interval '10 minutes')
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('success', true, 'otp_id', v_id, 'code', v_code, 'phone', v_phone, 'expires_in', 600);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.storefront_otp_verify(p_otp_id uuid, p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_row public.t_storefront_otp; v_token text;
BEGIN
  SELECT * INTO v_row FROM public.t_storefront_otp WHERE id = p_otp_id FOR UPDATE;
  IF v_row.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Code not found. Request a new one.', 'error_code', 'OTP_NOT_FOUND'); END IF;
  IF v_row.verified_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'verified', true, 'phone', v_row.phone, 'verify_token', v_row.verify_token);
  END IF;
  IF v_row.expires_at < now() THEN RETURN jsonb_build_object('success', false, 'error', 'Code expired. Request a new one.', 'error_code', 'OTP_EXPIRED'); END IF;
  IF v_row.attempts >= 5 THEN RETURN jsonb_build_object('success', false, 'error', 'Too many tries. Request a new code.', 'error_code', 'OTP_LOCKED'); END IF;
  IF md5(COALESCE(btrim(p_code), '') || v_row.phone) <> v_row.code_hash THEN
    UPDATE public.t_storefront_otp SET attempts = attempts + 1 WHERE id = v_row.id;
    RETURN jsonb_build_object('success', false, 'error', 'That code is not right', 'error_code', 'OTP_INVALID', 'attempts_left', 4 - v_row.attempts);
  END IF;
  v_token := md5(gen_random_uuid()::text || clock_timestamp()::text) || md5(gen_random_uuid()::text);
  UPDATE public.t_storefront_otp SET verified_at = now(), verify_token = v_token WHERE id = v_row.id;
  RETURN jsonb_build_object('success', true, 'verified', true, 'phone', v_row.phone, 'verify_token', v_token);
END;
$fn$;

-- ── 7. purchase: which package, verified phone, contact reuse by phone ──────
CREATE OR REPLACE FUNCTION public.purchase_from_storefront(p_key text, p_buyer jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
  v_tp      public.t_touchpoints;
  v_tpl     RECORD;
  v_fam     uuid;
  v_name    TEXT; v_company TEXT; v_email TEXT; v_phone TEXT; v_phone_raw TEXT;
  v_otp     public.t_storefront_otp;
  v_contact UUID;
  v_seq     JSONB;
  v_blocks  JSONB := '[]'::JSONB;
  v_block   JSONB;
  v_payload JSONB;
  v_result  JSONB;
  v_contract UUID;
  v_status  JSONB;
  v_cnak    TEXT; v_secret TEXT;
BEGIN
  v_tp := public.fn_storefront_by_key(p_key);
  IF v_tp.id IS NULL OR NOT public.fn_storefront_entitled(v_tp.tenant_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'NOT_FOUND');
  END IF;

  -- which package: template_id may be a family id or any version id; default the first
  IF NULLIF(p_buyer->>'template_id', '') IS NULL THEN
    v_fam := v_tp.template_ids[1];
  ELSE
    BEGIN
      v_fam := public.fn_template_family((p_buyer->>'template_id')::uuid);
    EXCEPTION WHEN OTHERS THEN v_fam := NULL;
    END;
  END IF;
  IF v_fam IS NULL OR NOT (v_fam = ANY (v_tp.template_ids)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'That package is not on this storefront', 'error_code', 'VALIDATION_ERROR');
  END IF;
  SELECT * INTO v_tpl FROM public.t_cat_templates WHERE id = public.fn_storefront_latest_template(v_fam);
  IF v_tpl.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'This link is not available', 'error_code', 'TEMPLATE_GONE');
  END IF;

  v_name    := NULLIF(btrim(p_buyer->>'name'), '');
  v_company := NULLIF(btrim(p_buyer->>'company'), '');
  v_email   := NULLIF(lower(btrim(p_buyer->>'email')), '');
  v_phone   := public.fn_storefront_phone(p_buyer->>'phone');
  v_phone_raw := NULLIF(regexp_replace(COALESCE(p_buyer->>'phone',''), '[^0-9+]', '', 'g'), '');
  IF v_name IS NULL OR v_phone IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Name and mobile number are required', 'error_code', 'VALIDATION_ERROR');
  END IF;

  -- the phone must have been verified for this checkout (token from storefront_otp_verify);
  -- compared on the last 10 digits so '+91 98765 43210' and '9876543210' are the same number
  SELECT * INTO v_otp FROM public.t_storefront_otp
  WHERE verify_token = NULLIF(p_buyer->>'otp_token', '') AND verified_at > now() - interval '30 minutes';
  IF v_otp.id IS NULL OR right(v_otp.phone, 10) <> right(v_phone, 10) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Verify your mobile number first', 'error_code', 'PHONE_NOT_VERIFIED');
  END IF;

  -- reuse an existing contact in the seller's book: verified phone first (last 10 digits), then email
  SELECT c.id INTO v_contact
  FROM public.t_contacts c JOIN public.t_contact_channels ch ON ch.contact_id = c.id
  WHERE c.tenant_id = v_tp.tenant_id AND c.is_live = TRUE AND c.is_active = TRUE
    AND ch.channel_type = 'mobile' AND right(regexp_replace(ch.value, '[^0-9]', '', 'g'), 10) = right(v_phone, 10)
  ORDER BY c.created_at LIMIT 1;
  IF v_contact IS NULL AND v_email IS NOT NULL THEN
    SELECT c.id INTO v_contact
    FROM public.t_contacts c JOIN public.t_contact_channels ch ON ch.contact_id = c.id
    WHERE c.tenant_id = v_tp.tenant_id AND c.is_live = TRUE AND c.is_active = TRUE
      AND ch.channel_type = 'email' AND lower(ch.value) = v_email
    ORDER BY c.created_at LIMIT 1;
  END IF;

  IF v_contact IS NULL THEN
    v_seq := public.get_next_formatted_sequence('CONTACT', v_tp.tenant_id, TRUE);
    IF v_company IS NOT NULL THEN
      INSERT INTO public.t_contacts (tenant_id, is_live, type, name, company_name, contact_number, classifications, status, is_active, is_seed, source)
      VALUES (v_tp.tenant_id, TRUE, 'corporate', NULL, v_company, v_seq->>'formatted', '["client"]'::JSONB, 'active', TRUE, FALSE, 'storefront')
      RETURNING id INTO v_contact;
    ELSE
      INSERT INTO public.t_contacts (tenant_id, is_live, type, name, company_name, contact_number, classifications, status, is_active, is_seed, source)
      VALUES (v_tp.tenant_id, TRUE, 'individual', v_name, NULL, v_seq->>'formatted', '["client"]'::JSONB, 'active', TRUE, FALSE, 'storefront')
      RETURNING id INTO v_contact;
    END IF;
    INSERT INTO public.t_contact_channels (contact_id, channel_type, value, is_primary, is_verified)
    VALUES (v_contact, 'mobile', v_phone_raw, TRUE, TRUE);
    IF v_email IS NOT NULL THEN
      INSERT INTO public.t_contact_channels (contact_id, channel_type, value, is_primary) VALUES (v_contact, 'email', v_email, FALSE);
    END IF;
  ELSE
    -- an existing contact that bought again is a client, whatever it was before
    UPDATE public.t_contacts SET classifications = CASE WHEN classifications ? 'client' THEN classifications ELSE classifications || '["client"]'::jsonb END,
                                 updated_at = now()
    WHERE id = v_contact;
  END IF;

  FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_tpl.blocks, '[]'::JSONB)) LOOP
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'position',        COALESCE((v_block->>'order')::INT, 0),
      'source_type',     'catalog',
      'source_block_id', v_block->>'block_id',
      'block_name',      v_block->'config_overrides'->>'name',
      'category_id',     v_block->'config_overrides'->>'category_id',
      'category_name',   v_block->'config_overrides'->>'category_name',
      'unit_price',      COALESCE((v_block->'config_overrides'->>'unit_price')::NUMERIC, 0),
      'quantity',        COALESCE((v_block->'config_overrides'->>'quantity')::INT, 1),
      'billing_cycle',   COALESCE(v_block->'config_overrides'->>'billing_cycle', 'prepaid'),
      'total_price',     COALESCE((v_block->'config_overrides'->>'total_price')::NUMERIC, 0),
      'custom_fields',   jsonb_build_object(
                            'config',   COALESCE(v_block->'config_overrides'->'config', '{}'::JSONB),
                            'currency', COALESCE(v_tpl.currency, 'INR'),
                            'notes',    'Storefront: ' || COALESCE(v_tpl.display_name, v_tpl.name))));
  END LOOP;

  v_payload := jsonb_build_object(
    'tenant_id',         v_tp.tenant_id,
    'is_live',           TRUE,
    'record_type',       'contract',
    'contract_type',     'client',
    'name',              COALESCE(v_tpl.display_name, v_tpl.name),
    'buyer_id',          v_contact,
    'buyer_name',        v_name,
    'buyer_email',       v_email,
    'buyer_phone',       v_phone_raw,
    'buyer_company',     v_company,
    'currency',          COALESCE(v_tpl.currency, 'INR'),
    'duration_value',    COALESCE((v_tpl.settings->'defaults'->>'duration_value')::INT, 1),
    'duration_unit',     COALESCE(v_tpl.settings->'defaults'->>'duration_unit', 'months'),
    'start_date',        now(),
    'acceptance_method', 'manual',
    'nomenclature_id',   v_tpl.settings->'defaults'->>'nomenclature_id',
    'billing_cycle_type',COALESCE(v_tpl.settings->'defaults'->>'billing_cycle_type', 'unified'),
    'grand_total',       COALESCE(v_tpl.total, 0),
    'total_value',       COALESCE(v_tpl.total, 0),
    'tax_total',         0,
    'discount_total',    0,
    'blocks',            v_blocks,
    'performed_by_type', 'user',
    'metadata',          jsonb_build_object(
                            'source',          'storefront_purchase',
                            'storefront_key',  v_tp.storefront_key,
                            'storefront_id',   v_tp.id,
                            'template_id',     v_tpl.id,
                            'template_family', v_fam,
                            'phone_verified',  TRUE));

  v_result := public.create_contract_transaction(v_payload, NULL);
  IF NOT COALESCE((v_result->>'success')::BOOLEAN, FALSE) THEN
    RETURN jsonb_build_object('success', false, 'error', COALESCE(v_result->>'error', 'Could not create the order'), 'error_code', 'CONTRACT_CREATE_FAILED', 'detail', v_result);
  END IF;
  v_contract := (v_result->'data'->>'id')::UUID;

  v_status := public.update_contract_status(v_contract, v_tp.tenant_id, 'pending_acceptance', NULL, v_name, 'system', 'Storefront purchase');
  IF NOT COALESCE((v_status->>'success')::BOOLEAN, FALSE) THEN
    RETURN jsonb_build_object('success', false, 'error', COALESCE(v_status->>'error', 'Could not prepare the order for review'), 'error_code', 'STATUS_TRANSITION_FAILED', 'detail', v_status);
  END IF;

  SELECT global_access_id INTO v_cnak FROM public.t_contracts WHERE id = v_contract;
  SELECT secret_code INTO v_secret FROM public.t_contract_access WHERE contract_id = v_contract ORDER BY created_at DESC LIMIT 1;

  UPDATE public.t_touchpoints SET purchases_count = purchases_count + 1 WHERE id = v_tp.id;

  RETURN jsonb_build_object(
    'success', true,
    'contract_id', v_contract,
    'contract_number', v_result->'data'->>'contract_number',
    'contact_id', v_contact,
    'cnak', v_cnak, 'secret', v_secret,
    'review_path', CASE WHEN v_cnak IS NOT NULL AND v_secret IS NOT NULL
                        THEN '/contracts/review?cnak=' || v_cnak || '&secret=' || v_secret ELSE NULL END);
END;
$fn$;

-- ── 8. grants (service role calls everything through the API) ───────────────
REVOKE ALL ON FUNCTION public.storefront_otp_issue(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.storefront_otp_verify(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.purchase_from_storefront(text, jsonb) FROM PUBLIC, anon, authenticated;
