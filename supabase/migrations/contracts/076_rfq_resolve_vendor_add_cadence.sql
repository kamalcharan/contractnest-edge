-- 076_rfq_resolve_vendor_add_cadence.sql
-- ALREADY APPLIED LIVE (project uwyqhzotluikawcboldr) — this file documents
-- the change in repo history, do not re-run as a "new" migration.
--
-- rfq_resolve_for_vendor's block SELECT only ever returned quantity +
-- billing_cycle. billing_cycle (prepaid/postpaid/monthly/...) is a
-- buyer-payment-terms concept — meaningless before a vendor is even chosen —
-- and the vendor-facing UI had no label for prepaid/postpaid at all, so it
-- printed the raw enum string. The thing a vendor actually needs to price
-- the work — how often the visit repeats — lives in
-- custom_fields.config.serviceCycleDays and was never selected here at all.
--
-- Adds service_cycle_days + unlimited to each block in the response.
-- Everything else in the function is byte-identical to the previous
-- definition (see 072_rfq_cycle.sql / prior state) — additive only.

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

    -- service_cycle_days / unlimited: see file header.
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
