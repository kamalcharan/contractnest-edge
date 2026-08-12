-- Migration 032: public, CNAK-scoped payment collection
-- Already applied live. Source-of-record copy — do not re-run.
--
-- Lets an external buyer on the public /contract-review page (CNAK + secret,
-- no login) pay a payment-gated contract: either via the tenant's Razorpay
-- gateway (Node API resolves tenant_id via get_public_contract_payment_context
-- then reuses the authenticated paymentGatewayService), or by declaring an
-- offline UPI reference for the tenant to confirm.

-- ── 1. Resolve CNAK -> payable invoice, idempotently generating it ──
CREATE OR REPLACE FUNCTION public.get_public_contract_payment_context(p_cnak character varying, p_secret_code character varying)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_access   RECORD;
    v_contract RECORD;
    v_invoice  RECORD;
BEGIN
    IF p_cnak IS NULL OR p_secret_code IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'CNAK and secret code are required');
    END IF;

    SELECT * INTO v_access
    FROM t_contract_access
    WHERE global_access_id = p_cnak
      AND secret_code = p_secret_code
      AND is_active = true;

    IF v_access IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid access code');
    END IF;

    IF v_access.expires_at IS NOT NULL AND v_access.expires_at < NOW() THEN
        RETURN jsonb_build_object('success', false, 'error', 'This access link has expired');
    END IF;

    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = v_access.contract_id AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Contract not found');
    END IF;

    IF v_contract.acceptance_method <> 'payment' THEN
        RETURN jsonb_build_object('success', false, 'error', 'This contract does not require online payment');
    END IF;

    IF COALESCE(v_contract.grand_total, 0) <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'This contract has nothing to pay');
    END IF;

    -- Idempotent: no-ops if an invoice already exists for this contract.
    PERFORM generate_contract_invoices(v_contract.id, v_contract.tenant_id, NULL);

    SELECT * INTO v_invoice
    FROM t_invoices
    WHERE contract_id = v_contract.id
      AND is_active = true
      AND status IN ('unpaid', 'partially_paid')
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_invoice IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No payable invoice found for this contract');
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'tenant_id', v_contract.tenant_id,
        'contract_id', v_contract.id,
        'contract_number', v_contract.contract_number,
        'invoice_id', v_invoice.id,
        'amount', v_invoice.balance,
        'currency', v_invoice.currency
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ── 2. Offline UPI config (VPA + QR), scoped by CNAK — mirrors gs_checkin_payment_config ──
CREATE OR REPLACE FUNCTION public.get_public_offline_upi_config(p_cnak character varying, p_secret_code character varying)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_access RECORD;
    v_pub    JSONB;
BEGIN
    SELECT * INTO v_access
    FROM t_contract_access
    WHERE global_access_id = p_cnak
      AND secret_code = p_secret_code
      AND is_active = true;

    IF v_access IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid access code');
    END IF;

    SELECT ti.credentials->'public' INTO v_pub
    FROM t_tenant_integrations ti
    JOIN t_integration_providers ip ON ip.id = ti.master_integration_id
    WHERE ip.name = 'offline_upi'
      AND ti.tenant_id = v_access.tenant_id
      AND ti.is_active = true
    ORDER BY ti.updated_at DESC NULLS LAST
    LIMIT 1;

    IF v_pub IS NULL OR COALESCE(v_pub->>'upi_id', '') = '' THEN
        RETURN jsonb_build_object('success', true, 'configured', false);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'configured', true,
        'upi_id', v_pub->>'upi_id',
        'payee_name', COALESCE(v_pub->>'payee_name', ''),
        'qr_image_url', v_pub->>'qr_image_url'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ── 3. Public payment declarations table ──
CREATE TABLE IF NOT EXISTS public.t_public_payment_declarations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES t_tenants(id),
    contract_id UUID NOT NULL REFERENCES t_contracts(id),
    invoice_id UUID NOT NULL REFERENCES t_invoices(id),
    reference TEXT NOT NULL,
    amount NUMERIC,
    currency VARCHAR(3) DEFAULT 'INR',
    declarer_name TEXT,
    declarer_contact TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'rejected')),
    confirmed_by UUID,
    confirmed_at TIMESTAMPTZ,
    is_live BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_public_payment_declarations_contract
    ON public.t_public_payment_declarations (contract_id, status);
CREATE INDEX IF NOT EXISTS ix_public_payment_declarations_tenant
    ON public.t_public_payment_declarations (tenant_id, status);
-- Only one pending declaration per invoice at a time — a second attempt
-- while one is outstanding is rejected by declare_public_contract_payment
-- rather than silently creating a duplicate.
CREATE UNIQUE INDEX IF NOT EXISTS ux_public_payment_declarations_pending
    ON public.t_public_payment_declarations (invoice_id) WHERE (status = 'pending');

-- ── 4. Buyer declares an offline UPI payment reference (public) ──
CREATE OR REPLACE FUNCTION public.declare_public_contract_payment(
    p_cnak character varying,
    p_secret_code character varying,
    p_reference text,
    p_amount numeric DEFAULT NULL::numeric,
    p_declarer_name text DEFAULT NULL::text,
    p_declarer_contact text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_ctx    JSONB;
    v_decl_id UUID;
BEGIN
    IF COALESCE(TRIM(p_reference), '') = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'A payment reference is required');
    END IF;

    v_ctx := get_public_contract_payment_context(p_cnak, p_secret_code);
    IF NOT COALESCE((v_ctx->>'success')::BOOLEAN, false) THEN
        RETURN v_ctx;
    END IF;

    INSERT INTO t_public_payment_declarations (
        tenant_id, contract_id, invoice_id, reference, amount, currency,
        declarer_name, declarer_contact
    ) VALUES (
        (v_ctx->>'tenant_id')::UUID,
        (v_ctx->>'contract_id')::UUID,
        (v_ctx->>'invoice_id')::UUID,
        TRIM(p_reference),
        COALESCE(p_amount, (v_ctx->>'amount')::NUMERIC),
        COALESCE(v_ctx->>'currency', 'INR'),
        p_declarer_name,
        p_declarer_contact
    )
    ON CONFLICT (invoice_id) WHERE status = 'pending'
    DO NOTHING
    RETURNING id INTO v_decl_id;

    IF v_decl_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'A payment declaration is already pending confirmation for this contract',
            'error_code', 'ALREADY_PENDING'
        );
    END IF;

    RETURN jsonb_build_object('success', true, 'declaration_id', v_decl_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ── 5. Tenant confirms/rejects a declaration (authenticated) ──
CREATE OR REPLACE FUNCTION public.confirm_public_payment_declaration(
    p_declaration_id uuid,
    p_tenant_id uuid,
    p_user_id uuid,
    p_confirm boolean DEFAULT true
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_d   RECORD;
    v_inv RECORD;
    v_res JSONB;
BEGIN
    SELECT * INTO v_d
    FROM t_public_payment_declarations
    WHERE id = p_declaration_id AND tenant_id = p_tenant_id
    FOR UPDATE;

    IF v_d.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Declaration not found');
    END IF;

    IF v_d.status <> 'pending' THEN
        RETURN jsonb_build_object('success', false, 'error', 'This declaration was already ' || v_d.status);
    END IF;

    IF NOT p_confirm THEN
        UPDATE t_public_payment_declarations
        SET status = 'rejected', confirmed_by = p_user_id, confirmed_at = now()
        WHERE id = p_declaration_id;
        RETURN jsonb_build_object('success', true, 'status', 'rejected');
    END IF;

    SELECT id, contract_id, balance INTO v_inv
    FROM t_invoices
    WHERE id = v_d.invoice_id AND is_active = true;

    IF v_inv.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
    END IF;

    v_res := record_invoice_payment_with_allocations(jsonb_build_object(
        'invoice_id', v_inv.id,
        'contract_id', v_inv.contract_id,
        'tenant_id', p_tenant_id,
        'recorded_by', p_user_id,
        'amount', LEAST(COALESCE(v_d.amount, v_inv.balance), v_inv.balance),
        'payment_method', 'upi',
        'payment_date', (now() at time zone 'Asia/Kolkata')::date,
        'reference_number', v_d.reference,
        'notes', 'Contract payment — declaration confirmed by tenant'
    ));

    IF NOT COALESCE((v_res->>'success')::BOOLEAN, false) THEN
        RETURN jsonb_build_object('success', false, 'error', COALESCE(v_res->>'error', 'Payment recording failed'), 'detail', v_res);
    END IF;

    UPDATE t_public_payment_declarations
    SET status = 'confirmed', confirmed_by = p_user_id, confirmed_at = now()
    WHERE id = p_declaration_id;

    RETURN jsonb_build_object('success', true, 'status', 'confirmed', 'receipt', v_res->'data');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;
