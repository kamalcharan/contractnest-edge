-- ============================================================================
-- business-model-v2/043 — the buyer's pay-page link for an invoice
-- ============================================================================
-- fn_invoice_pay_access(tenant, invoice) → {ok, cnak, secret, contract_id, is_live}
-- The contract's active, unexpired buyer grant (client role first, newest
-- first). The API turns it into <app>/contract-review?cnak=…&secret=… and puts
-- it in the payment-request message, so the buyer lands on the pay page
-- (UPI ID, bank QR, Razorpay when set up, "I've paid") — 042.
-- Refuses {ok:false, reason}: forbidden · invoice_not_found · no_contract · no_grant.
-- Member-guarded (fn_catalog_tenant_guard, catalog-studio/008).
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_invoice_pay_access(p_tenant uuid, p_invoice uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_inv record; v_acc record;
BEGIN
  IF NOT fn_catalog_tenant_guard(p_tenant) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT id, contract_id, COALESCE(is_live, true) AS is_live INTO v_inv
    FROM t_invoices WHERE id = p_invoice AND tenant_id = p_tenant;
  IF v_inv.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invoice_not_found'); END IF;
  IF v_inv.contract_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_contract'); END IF;
  SELECT global_access_id, secret_code INTO v_acc
    FROM t_contract_access
   WHERE contract_id = v_inv.contract_id AND tenant_id = p_tenant AND is_active
     AND COALESCE(expires_at, now() + interval '1 day') > now()
     AND global_access_id IS NOT NULL AND secret_code IS NOT NULL
   ORDER BY (accessor_role = 'client') DESC NULLS LAST, created_at DESC
   LIMIT 1;
  IF v_acc.global_access_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_grant'); END IF;
  RETURN jsonb_build_object('ok', true, 'cnak', v_acc.global_access_id, 'secret', v_acc.secret_code,
                            'contract_id', v_inv.contract_id, 'is_live', v_inv.is_live);
END $$;
REVOKE ALL ON FUNCTION fn_invoice_pay_access(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_invoice_pay_access(uuid, uuid) TO authenticated, service_role;
