-- ═══════════════════════════════════════════════════════════════════
-- contracts/079_contracts_list_seller_fields.sql  (2026-09-17)
-- The buyer side of a claimed contract knows who the seller is.
--
-- FOUND ON CN-1010 (signia → buyer): after a successful claim the buyer's
-- list still read "Provider details in contract" + "Contact link missing".
-- get_contracts_list emitted no seller fields at all; the UI (experience
-- list model.ts + ContactClassificationBadge) reads seller_company /
-- seller_name / seller_contact_id for rows the tenant does not own.
--
-- WHAT THIS DOES (additive, flat list branch only — the grouped-by-buyer
-- branch is the seller's own revenue view): three fields per row, NULL on
-- rows the caller owns, otherwise
--   seller_company / seller_name = the owner tenant's business_name, else
--                                  its tenant name
--   seller_contact_id = the caller tenant's contact sourced from the owner
--                       tenant (what claim_contract_by_cnak creates),
--                       preferring the one tagged with this contract's CNAK
-- Applied live 2026-09-17 (batch buyer-side-seller-fields) — source of
-- record; do not re-run. Anchor rewrite with post-check (048/059 pattern).
-- ═══════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_def    text;
  v_anchor text := $a$''response_deadline'', c.response_deadline,$a$;
  v_new    text := $n$''response_deadline'', c.response_deadline,
                         ''seller_company'', CASE WHEN c.tenant_id = ' || quote_literal(p_tenant_id::text) || ' THEN NULL ELSE (SELECT COALESCE(NULLIF(tp.business_name, ''''), t.name) FROM t_tenants t LEFT JOIN t_tenant_profiles tp ON tp.tenant_id = t.id WHERE t.id = c.tenant_id LIMIT 1) END,
                         ''seller_name'', CASE WHEN c.tenant_id = ' || quote_literal(p_tenant_id::text) || ' THEN NULL ELSE (SELECT COALESCE(NULLIF(tp.business_name, ''''), t.name) FROM t_tenants t LEFT JOIN t_tenant_profiles tp ON tp.tenant_id = t.id WHERE t.id = c.tenant_id LIMIT 1) END,
                         ''seller_contact_id'', CASE WHEN c.tenant_id = ' || quote_literal(p_tenant_id::text) || ' THEN NULL ELSE (SELECT ct.id FROM t_contacts ct WHERE ct.tenant_id = ' || quote_literal(p_tenant_id::text) || ' AND ct.source_tenant_id = c.tenant_id AND ct.is_active = true AND ct.is_live = c.is_live ORDER BY (ct.source_cnak = c.global_access_id) DESC NULLS LAST, ct.created_at LIMIT 1) END,$n$;
  v_n      integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_contracts_list';
  IF v_def IS NULL THEN RAISE EXCEPTION '079: get_contracts_list not found'; END IF;
  IF position('seller_contact_id' IN v_def) > 0 THEN RAISE NOTICE '079: already applied'; RETURN; END IF;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  IF v_n <> 1 THEN RAISE EXCEPTION '079: expected exactly one anchor, found %', v_n; END IF;
  v_def := replace(v_def, v_anchor, v_new);
  EXECUTE v_def;
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_contracts_list';
  IF position('seller_contact_id' IN v_def) = 0 THEN RAISE EXCEPTION '079: rewrite did not land'; END IF;
END $$;
