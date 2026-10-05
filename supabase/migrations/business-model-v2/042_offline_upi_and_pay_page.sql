-- ============================================================================
-- business-model-v2/042 — ONE offline-UPI truth + the pay page for any open
-- invoice (batch payment-request-framework, POA steps 3–4).
-- ============================================================================
-- Before: three readers of the tenant's UPI details, each different —
--   gs_checkin_payment_config   per env, merchant fields, no QR
--   get_public_offline_upi_config  QR, NO environment filter (a Test UPI row
--                               could be shown on a Live contract), no merchant
--   get_tenant_payment_config   per env, QR, no merchant fields
-- and fn_tenant_payment_options (041) checked UPI without the environment.
-- The buyer's pay page (get_public_contract_payment_context) only allowed a
-- contract awaiting "accept on payment"; an ACTIVE contract's open invoice had
-- no page to be paid on.
--
--   fn_tenant_offline_upi(tenant, is_live) → {configured, upi_id, payee_name,
--       qr_image_url, has_qr, org_id, mcc, is_merchant}   THE reader
--   gs_checkin_payment_config / get_public_offline_upi_config /
--   get_tenant_payment_config / fn_tenant_payment_options → delegate to it
--   (same keys as before, plus the missing ones; the public one now follows
--    the CONTRACT's environment).
--   get_public_contract_payment_context: also serves an accepted/active
--   contract that has an unpaid invoice (mode 'balance_due'); the original
--   accept-on-payment path is unchanged (mode 'acceptance'). Returns is_live.
--   declare_public_contract_payment needs no change (it calls the context).
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_tenant_offline_upi(p_tenant uuid, p_is_live boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_pub jsonb; v_org text; v_mcc text;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('configured', false); END IF;
  SELECT ti.credentials->'public' INTO v_pub
    FROM t_tenant_integrations ti
    JOIN t_integration_providers ip ON ip.id = ti.master_integration_id
   WHERE ip.name = 'offline_upi'
     AND ti.tenant_id = p_tenant::text
     AND ti.is_live = COALESCE(p_is_live, true)
     AND ti.is_active
   ORDER BY ti.updated_at DESC NULLS LAST
   LIMIT 1;
  IF v_pub IS NULL OR COALESCE(trim(v_pub->>'upi_id'), '') = '' THEN
    RETURN jsonb_build_object('configured', false);
  END IF;
  v_org := NULLIF(trim(COALESCE(v_pub->>'org_id', '')), '');
  v_mcc := NULLIF(trim(COALESCE(v_pub->>'mcc', '')), '');
  RETURN jsonb_build_object(
    'configured',   true,
    'upi_id',       trim(v_pub->>'upi_id'),
    'payee_name',   COALESCE(v_pub->>'payee_name', ''),
    'qr_image_url', NULLIF(COALESCE(v_pub->>'qr_image_url', ''), ''),
    'has_qr',       COALESCE(v_pub->>'qr_image_url', '') <> '',
    'org_id',       v_org,
    'mcc',          v_mcc,
    -- A merchant VPA (bank-registered, mcc ≠ 0000): GPay refuses a hand-built
    -- upi:// intent to it, so no "Open UPI app" button for these.
    'is_merchant',  v_org IS NOT NULL AND v_mcc IS NOT NULL AND v_mcc <> '0000'
  );
END $$;

CREATE OR REPLACE FUNCTION fn_tenant_payment_options(p_tenant_id uuid, p_is_live boolean DEFAULT true)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH gw AS (
    SELECT EXISTS (
      SELECT 1 FROM public.t_tenant_integrations ti
      JOIN public.t_integration_providers ip ON ip.id = ti.master_integration_id
      JOIN public.t_integration_types it ON it.id = ip.type_id
      WHERE ti.tenant_id = p_tenant_id::text AND it.name = 'payment_gateway' AND ip.name = 'razorpay'
        AND ti.is_active = TRUE AND ti.is_live = COALESCE(p_is_live, TRUE)) AS ok
  ), upi AS (
    SELECT COALESCE((public.fn_tenant_offline_upi(p_tenant_id, COALESCE(p_is_live, TRUE))->>'configured')::boolean, false) AS ok
  )
  SELECT jsonb_build_object('gateway', gw.ok, 'offline_upi', upi.ok, 'any', gw.ok OR upi.ok) FROM gw, upi;
$$;

CREATE OR REPLACE FUNCTION get_tenant_payment_config(p_tenant uuid, p_is_live boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_tenant IS NULL OR p_is_live IS NULL THEN
    RETURN jsonb_build_object('configured', false, 'reason', 'tenant_and_environment_required');
  END IF;
  RETURN fn_tenant_offline_upi(p_tenant, p_is_live);
END $$;

CREATE OR REPLACE FUNCTION gs_checkin_payment_config(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_tok public.t_group_session_tokens; v_cfg jsonb;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token = p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  v_cfg := fn_tenant_offline_upi(v_tok.tenant_id, COALESCE(v_tok.is_live, true));
  RETURN jsonb_build_object('ok', true) || v_cfg;
END $$;

CREATE OR REPLACE FUNCTION get_public_offline_upi_config(p_cnak character varying, p_secret_code character varying)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_access record; v_live boolean;
BEGIN
  SELECT * INTO v_access FROM t_contract_access
   WHERE global_access_id = p_cnak AND secret_code = p_secret_code AND is_active = true;
  IF v_access IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid access code');
  END IF;
  -- The CONTRACT's environment: a Test UPI row is never shown on a Live contract.
  SELECT COALESCE(c.is_live, true) INTO v_live FROM t_contracts c WHERE c.id = v_access.contract_id;
  RETURN jsonb_build_object('success', true) || fn_tenant_offline_upi(v_access.tenant_id, COALESCE(v_live, true));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END $$;

CREATE OR REPLACE FUNCTION get_public_contract_payment_context(p_cnak character varying, p_secret_code character varying)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_access   record;
  v_contract record;
  v_invoice  record;
  v_mode     text;
BEGIN
  IF p_cnak IS NULL OR p_secret_code IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'CNAK and secret code are required');
  END IF;

  SELECT * INTO v_access FROM t_contract_access
   WHERE global_access_id = p_cnak AND secret_code = p_secret_code AND is_active = true;
  IF v_access IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid access code');
  END IF;
  IF v_access.expires_at IS NOT NULL AND v_access.expires_at < NOW() THEN
    RETURN jsonb_build_object('success', false, 'error', 'This access link has expired');
  END IF;

  SELECT * INTO v_contract FROM t_contracts WHERE id = v_access.contract_id AND is_active = true;
  IF v_contract IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Contract not found');
  END IF;

  IF v_contract.acceptance_method = 'payment'
     AND v_contract.status IN ('draft', 'pending_acceptance', 'sent', 'viewed') THEN
    -- Original path: paying IS accepting.
    IF COALESCE(v_contract.grand_total, 0) <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'This contract has nothing to pay');
    END IF;
    -- Idempotent: no-ops if an invoice already exists for this contract.
    PERFORM generate_contract_invoices(v_contract.id, v_contract.tenant_id, NULL);
    v_mode := 'acceptance';
  ELSIF v_contract.acceptance_method = 'payment' OR v_contract.status IN ('active', 'completed', 'expired', 'suspended', 'on_hold') THEN
    -- Balance due on an agreed contract — the payment-request link lands here.
    v_mode := 'balance_due';
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'This contract does not require online payment', 'error_code', 'NOT_PAYABLE');
  END IF;

  SELECT * INTO v_invoice FROM t_invoices
   WHERE contract_id = v_contract.id AND is_active = true
     AND status IN ('unpaid', 'partially_paid', 'overdue')
     AND COALESCE(balance, 0) > 0
   ORDER BY due_date ASC NULLS LAST, created_at ASC
   LIMIT 1;

  IF v_invoice IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Nothing is due on this contract right now', 'error_code', 'NOTHING_DUE');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'mode', v_mode,
    'tenant_id', v_contract.tenant_id,
    'contract_id', v_contract.id,
    'contract_number', v_contract.contract_number,
    'is_live', COALESCE(v_contract.is_live, true),
    'invoice_id', v_invoice.id,
    'invoice_number', v_invoice.invoice_number,
    'due_date', v_invoice.due_date,
    'amount', v_invoice.balance,
    'currency', v_invoice.currency
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END $$;

REVOKE ALL ON FUNCTION fn_tenant_offline_upi(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_tenant_offline_upi(uuid, boolean) TO authenticated, service_role;
