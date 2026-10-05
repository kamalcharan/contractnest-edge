-- ============================================================================
-- catalog-studio/010 — re-stamp a tenant's SEEDED catalog with its currency +
-- chosen taxes (the same rules as a new seed, catalogPricingService / 008).
-- ============================================================================
-- catalog_apply_taxes(tenant, rate_ids uuid[] | NULL)
--   rate_ids NULL = the tax master's default rate; [] = no tax.
--   For every is_seed block of the tenant (both environments):
--     pricing records → only the business-currency record (a block with none
--       gets one at 0 + config.kt_currency_missing), each carrying the taxes
--       {id,name,rate} and the display mode's inclusion;
--     variantPricingRecords → same stamp, other currencies dropped;
--     currency / base_price / tax_rate columns follow.
--   Custom (non-seed) blocks are never touched; nor are contracts — a contract
--   keeps the prices and taxes it was made with.
--   → {success, blocks, tax}
--
-- One-off use (owner, 2026-10-04: "only test tenants"): crane elevators,
-- signia, valuenotes — see the DO block at the end.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_catalog_stamp_records(p_records jsonb, p_currency text, p_taxes jsonb, p_inclusion text, p_keep_amount boolean)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_agg(
           r || jsonb_build_object('currency', p_currency, 'taxes', p_taxes, 'tax_inclusion', p_inclusion,
                                   'amount', CASE WHEN p_keep_amount THEN coalesce(r->'amount', '0'::jsonb) ELSE '0'::jsonb END)
           ORDER BY ord), '[]'::jsonb)
    FROM jsonb_array_elements(coalesce(p_records, '[]'::jsonb)) WITH ORDINALITY AS e(r, ord)
$$;

CREATE OR REPLACE FUNCTION catalog_apply_taxes(p_tenant uuid, p_rate_ids uuid[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tax jsonb; v_cur text; v_taxes jsonb; v_incl text; v_total numeric;
  b record; v_own jsonb; v_missing boolean; v_cfg jsonb; v_vars jsonb; n int := 0;
BEGIN
  v_tax := fn_resolve_catalog_tax(p_tenant, p_rate_ids);
  IF NOT coalesce((v_tax->>'success')::boolean, false) THEN
    RETURN jsonb_build_object('success', false, 'reason', v_tax->>'reason');
  END IF;
  IF jsonb_array_length(coalesce(v_tax->'unknown_ids', '[]'::jsonb)) > 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'unknown_rate', 'unknown_ids', v_tax->'unknown_ids');
  END IF;
  v_cur := v_tax->>'currency'; v_taxes := v_tax->'taxes'; v_incl := v_tax->>'inclusion'; v_total := (v_tax->>'total')::numeric;

  FOR b IN SELECT id, config, variant_pricing FROM m_cat_blocks
            WHERE tenant_id = p_tenant AND is_seed IS TRUE FOR UPDATE LOOP
    v_cfg := coalesce(b.config, '{}'::jsonb);
    SELECT coalesce(jsonb_agg(r ORDER BY ord), '[]'::jsonb) INTO v_own
      FROM jsonb_array_elements(coalesce(v_cfg->'pricingRecords', '[]'::jsonb)) WITH ORDINALITY e(r, ord)
     WHERE r->>'currency' = v_cur;
    v_missing := jsonb_array_length(v_own) = 0;
    IF v_missing THEN
      v_own := jsonb_build_array(jsonb_build_object('id', '1', 'price_type', 'fixed', 'is_active', true));
    END IF;
    v_own := fn_catalog_stamp_records(jsonb_build_array(v_own->0), v_cur, v_taxes, v_incl, NOT v_missing);
    v_cfg := jsonb_set(v_cfg, '{pricingRecords}', v_own);

    IF jsonb_typeof(v_cfg->'variantPricingRecords') = 'array' THEN
      SELECT coalesce(jsonb_agg(
               r || jsonb_build_object('taxes', v_taxes, 'tax_inclusion', v_incl, 'currency', v_cur,
                                       'amount', CASE WHEN r->>'currency' = v_cur THEN coalesce(r->'amount', '0'::jsonb) ELSE '0'::jsonb END)
               ORDER BY ord), '[]'::jsonb) INTO v_vars
        FROM jsonb_array_elements(v_cfg->'variantPricingRecords') WITH ORDINALITY e(r, ord);
      v_cfg := jsonb_set(v_cfg, '{variantPricingRecords}', v_vars);
    END IF;
    IF v_missing THEN v_cfg := v_cfg || jsonb_build_object('kt_currency_missing', true); END IF;

    UPDATE m_cat_blocks
       SET config = v_cfg,
           currency = v_cur,
           base_price = (v_own->0->>'amount')::numeric,
           tax_rate = v_total,
           updated_at = now()
     WHERE id = b.id;
    n := n + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'blocks', n, 'tax', v_tax);
END $$;

REVOKE ALL ON FUNCTION catalog_apply_taxes(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION catalog_apply_taxes(uuid, uuid[]) TO authenticated, service_role;

-- One-off (owner, 2026-10-04 — test tenants only). Already applied live.
--   signia            → its two active rates (CGST 9 + SGST 9 = 18%)
--   crane elevators   → no rates set up yet → no tax (re-run after creating rates)
--   valuenotes        → no rates set up yet → no tax
DO $$
DECLARE s uuid := (SELECT id FROM t_tenants WHERE name = 'signia');
BEGIN
  PERFORM catalog_apply_taxes(s, (SELECT array_agg(id) FROM t_tax_rates WHERE tenant_id = s AND is_active));
  PERFORM catalog_apply_taxes((SELECT id FROM t_tenants WHERE name = 'crane elevators'), NULL);
  PERFORM catalog_apply_taxes((SELECT id FROM t_tenants WHERE name = 'valuenotes'), NULL);
END $$;
