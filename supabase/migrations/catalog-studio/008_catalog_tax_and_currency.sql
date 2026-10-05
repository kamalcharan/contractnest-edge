-- ============================================================================
-- catalog-studio/008 — business currency + ONE catalog tax lookup
-- ============================================================================
-- Before: seeding hard-coded INR, copied every KT currency (signia INR+EUR+USD)
-- and stamped a flat tax_rate (invented 18% when nothing was set up) with EMPTY
-- per-record taxes[]. The contract wizard reads the records, so seeded blocks
-- were billed at 0% while the composer charged the flat 18.
--
-- The tax master (t_tax_settings / t_tax_rates) is NOT changed. WHICH taxes a
-- new catalog item carries is chosen where it is seeded (onboarding Tax screen,
-- VaNi Seeding) and passed in as rate ids; this file only looks them up.
--
--   t_tenant_profiles.default_currency       business currency (column default INR)
--   fn_tenant_currency(tenant)               → the tenant's currency
--   set_tenant_currency(tenant, code)        ^[A-Z]{3}$
--   fn_resolve_catalog_tax(tenant, ids[])    → {display_mode, inclusion, taxes[{id,name,rate}],
--                                               total, source, currency, unknown_ids[]}
--        display_mode no_tax   → no taxes                         (source 'no_tax')
--        ids given ([] = none) → those active rates of the tenant (source 'chosen')
--        ids NULL              → the default rate (settings, else is_default) (source 'default')
--        nothing set up        → no taxes, never a made-up rate    (source 'none')
-- Callable by the server (service role) or by a member of the tenant.
-- ============================================================================

ALTER TABLE t_tenant_profiles ADD COLUMN IF NOT EXISTS default_currency varchar(3) NOT NULL DEFAULT 'INR';

-- Membership guard: service role (no auth.uid()) passes; a user must belong to the tenant.
CREATE OR REPLACE FUNCTION fn_catalog_tenant_guard(p_tenant uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p_tenant IS NOT NULL AND (auth.uid() IS NULL OR user_belongs_to_tenant(p_tenant))
$$;

-- The fallback reads the column default so INR lives in ONE place.
CREATE OR REPLACE FUNCTION fn_tenant_currency(p_tenant uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v text;
BEGIN
  SELECT nullif(trim(default_currency), '') INTO v FROM t_tenant_profiles WHERE tenant_id = p_tenant;
  IF v IS NULL THEN
    SELECT substring(column_default FROM '''([A-Z]{3})''') INTO v
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 't_tenant_profiles' AND column_name = 'default_currency';
  END IF;
  RETURN upper(v);
END $$;

CREATE OR REPLACE FUNCTION set_tenant_currency(p_tenant uuid, p_currency text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v text := upper(trim(coalesce(p_currency, '')));
BEGIN
  IF NOT fn_catalog_tenant_guard(p_tenant) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'forbidden', 'message', 'Not a member of this tenant');
  END IF;
  IF v !~ '^[A-Z]{3}$' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'invalid_currency', 'message', 'Currency must be a 3-letter code');
  END IF;
  UPDATE t_tenant_profiles SET default_currency = v, updated_at = now() WHERE tenant_id = p_tenant;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'no_profile', 'message', 'Save your business profile first');
  END IF;
  RETURN jsonb_build_object('success', true, 'currency', v);
END $$;

CREATE OR REPLACE FUNCTION fn_resolve_catalog_tax(p_tenant uuid, p_rate_ids uuid[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_mode text; v_default uuid; v_taxes jsonb; v_source text; v_unknown jsonb := '[]'::jsonb;
BEGIN
  IF NOT fn_catalog_tenant_guard(p_tenant) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'forbidden');
  END IF;
  SELECT display_mode, default_tax_rate_id INTO v_mode, v_default FROM t_tax_settings WHERE tenant_id = p_tenant;
  v_mode := coalesce(v_mode, 'excluding_tax');

  IF v_mode = 'no_tax' THEN
    v_taxes := '[]'::jsonb; v_source := 'no_tax';
  ELSIF p_rate_ids IS NOT NULL THEN
    SELECT jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'rate', r.rate) ORDER BY r.sequence_no, r.name)
      INTO v_taxes FROM t_tax_rates r
     WHERE r.tenant_id = p_tenant AND r.is_active AND r.id = ANY(p_rate_ids);
    SELECT coalesce(jsonb_agg(i), '[]'::jsonb) INTO v_unknown FROM unnest(p_rate_ids) i
     WHERE NOT EXISTS (SELECT 1 FROM t_tax_rates r WHERE r.id = i AND r.tenant_id = p_tenant AND r.is_active);
    v_taxes := coalesce(v_taxes, '[]'::jsonb); v_source := 'chosen';
  ELSE
    SELECT jsonb_build_array(jsonb_build_object('id', r.id, 'name', r.name, 'rate', r.rate))
      INTO v_taxes FROM t_tax_rates r
     WHERE r.tenant_id = p_tenant AND r.is_active
       AND (r.id = v_default OR (v_default IS NULL AND r.is_default))
     LIMIT 1;
    v_source := CASE WHEN v_taxes IS NULL THEN 'none' ELSE 'default' END;
    v_taxes := coalesce(v_taxes, '[]'::jsonb);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'display_mode', v_mode,
    'inclusion', CASE WHEN v_mode = 'including_tax' THEN 'inclusive' ELSE 'exclusive' END,
    'taxes', v_taxes,
    'total', coalesce((SELECT sum((t->>'rate')::numeric) FROM jsonb_array_elements(v_taxes) t), 0),
    'source', v_source,
    'currency', fn_tenant_currency(p_tenant),
    'unknown_ids', v_unknown
  );
END $$;

REVOKE ALL ON FUNCTION fn_catalog_tenant_guard(uuid)              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION set_tenant_currency(uuid, text)            FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION fn_resolve_catalog_tax(uuid, uuid[])       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION fn_tenant_currency(uuid)                   FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_catalog_tenant_guard(uuid)           TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION set_tenant_currency(uuid, text)         TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION fn_resolve_catalog_tax(uuid, uuid[])    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION fn_tenant_currency(uuid)                TO authenticated, service_role;
