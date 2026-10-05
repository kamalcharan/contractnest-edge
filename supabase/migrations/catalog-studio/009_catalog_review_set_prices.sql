-- ============================================================================
-- catalog-studio/009 — onboarding pricing review writes the PRICE LINE too,
-- in both environments, in one transaction.
-- ============================================================================
-- Before: Confirm on /onboarding/pricing-review PATCHed only m_cat_blocks.base_price
-- of the current environment. The contract wizard reads
-- config.pricingRecords[currency].amount first, so the reviewed price never
-- reached a contract, and the other environment kept the KT price.
--
-- catalog_review_set_prices(tenant, items jsonb [{block_id, amount}])
--   per item, the block is locked (FOR UPDATE) and:
--     base_price = amount; the pricing record in the block's currency gets
--     amount (one is added from the first record when missing);
--   its twin in the other environment (same tenant, seed template, name) gets
--   the same — ONLY while the twin still holds the price this block had
--   (an independently edited twin is left alone and reported).
--   → {success, updated, mirrored, skipped_twins, refused[]}
-- Callable by the server or a member of the tenant (fn_catalog_tenant_guard, 008).
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_catalog_set_record_amount(p_config jsonb, p_currency text, p_amount numeric)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  WITH recs AS (
    SELECT coalesce(p_config->'pricingRecords', '[]'::jsonb) AS a
  )
  SELECT jsonb_set(coalesce(p_config, '{}'::jsonb), '{pricingRecords}',
    CASE
      WHEN EXISTS (SELECT 1 FROM recs, jsonb_array_elements(recs.a) r WHERE r->>'currency' = p_currency) THEN
        (SELECT jsonb_agg(CASE WHEN r->>'currency' = p_currency THEN r || jsonb_build_object('amount', p_amount) ELSE r END)
           FROM recs, jsonb_array_elements(recs.a) r)
      WHEN jsonb_array_length((SELECT a FROM recs)) > 0 THEN
        (SELECT a FROM recs) || jsonb_build_array(((SELECT a FROM recs)->0)
            || jsonb_build_object('id', (jsonb_array_length((SELECT a FROM recs)) + 1)::text, 'currency', p_currency, 'amount', p_amount))
      ELSE jsonb_build_array(jsonb_build_object('id', '1', 'currency', p_currency, 'amount', p_amount,
            'price_type', 'fixed', 'tax_inclusion', 'exclusive', 'taxes', '[]'::jsonb, 'is_active', true))
    END)
$$;

CREATE OR REPLACE FUNCTION catalog_review_set_prices(p_tenant uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  it jsonb; b record; v_amount numeric; v_old numeric;
  v_updated int := 0; v_mirrored int := 0; v_skipped int := 0; v_refused jsonb := '[]'::jsonb; n int;
BEGIN
  IF NOT fn_catalog_tenant_guard(p_tenant) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'forbidden');
  END IF;
  IF jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'bad_items');
  END IF;

  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_amount := (it->>'amount')::numeric;
    EXCEPTION WHEN others THEN v_amount := NULL;
    END;
    IF v_amount IS NULL OR v_amount < 0 OR (it->>'block_id') !~* '^[0-9a-f-]{36}$' THEN
      v_refused := v_refused || jsonb_build_object('block_id', it->>'block_id', 'reason', 'bad_item');
      CONTINUE;
    END IF;

    SELECT id, tenant_id, is_live, is_seed, name, resource_template_id, currency, base_price, config INTO b
      FROM m_cat_blocks WHERE id = (it->>'block_id')::uuid AND tenant_id = p_tenant FOR UPDATE;
    IF NOT FOUND THEN
      v_refused := v_refused || jsonb_build_object('block_id', it->>'block_id', 'reason', 'not_found');
      CONTINUE;
    END IF;
    v_old := b.base_price;

    UPDATE m_cat_blocks
       SET base_price = v_amount,
           config = fn_catalog_set_record_amount(config, b.currency, v_amount),
           updated_at = now()
     WHERE id = b.id;
    v_updated := v_updated + 1;

    IF b.is_seed AND b.resource_template_id IS NOT NULL THEN
      UPDATE m_cat_blocks t
         SET base_price = v_amount,
             config = fn_catalog_set_record_amount(t.config, t.currency, v_amount),
             updated_at = now()
       WHERE t.tenant_id = p_tenant AND t.is_seed AND t.is_live <> b.is_live
         AND t.resource_template_id = b.resource_template_id AND t.name = b.name
         AND t.currency IS NOT DISTINCT FROM b.currency
         AND t.base_price IS NOT DISTINCT FROM v_old;
      GET DIAGNOSTICS n = ROW_COUNT;
      IF n > 0 THEN v_mirrored := v_mirrored + n;
      ELSIF EXISTS (SELECT 1 FROM m_cat_blocks t WHERE t.tenant_id = p_tenant AND t.is_seed AND t.is_live <> b.is_live
                      AND t.resource_template_id = b.resource_template_id AND t.name = b.name) THEN
        v_skipped := v_skipped + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'updated', v_updated, 'mirrored', v_mirrored,
                            'skipped_twins', v_skipped, 'refused', v_refused);
END $$;

REVOKE ALL ON FUNCTION catalog_review_set_prices(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION catalog_review_set_prices(uuid, jsonb) TO authenticated, service_role;
