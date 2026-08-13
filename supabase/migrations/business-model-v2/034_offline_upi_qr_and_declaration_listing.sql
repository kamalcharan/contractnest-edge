-- Migration 034: offline UPI QR upload field + tenant-side declaration listing
-- Already applied live. Source-of-record copy — do not re-run.

-- Add a QR image field to the offline_upi provider's config schema so tenants
-- can upload their bank-issued UPI QR (in addition to typing the VPA). Stored
-- as a URL string; the existing config_only public-copy mechanism in the
-- integrations edge function already mirrors this into credentials.public,
-- which get_public_offline_upi_config (migration 032) already reads as
-- qr_image_url.
UPDATE t_integration_providers
SET config_schema = jsonb_set(
    config_schema,
    '{fields}',
    config_schema->'fields' || jsonb_build_object(
        'name', 'qr_image_url',
        'type', 'image',
        'required', false,
        'sensitive', false,
        'description', 'Upload your UPI QR code (from your bank or UPI app) so payers can scan it directly, in addition to the VPA above',
        'display_name', 'UPI QR Code'
    )
)
WHERE id = '1222363e-9020-4f19-9ffe-b2bb3c5e571a'
  AND NOT (config_schema->'fields' @> '[{"name": "qr_image_url"}]');

-- Tenant-side listing of public payment declarations (migration 032's
-- t_public_payment_declarations) so the chair/admin can see what's pending
-- confirmation. Mirrors the shape confirm_public_payment_declaration expects.
CREATE OR REPLACE FUNCTION public.list_public_payment_declarations(
    p_tenant_id UUID,
    p_status TEXT DEFAULT 'pending'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_rows JSONB;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    SELECT jsonb_agg(jsonb_build_object(
        'id', d.id,
        'contract_id', d.contract_id,
        'contract_number', c.contract_number,
        'contract_name', c.name,
        'invoice_id', d.invoice_id,
        'invoice_number', i.invoice_number,
        'reference', d.reference,
        'amount', d.amount,
        'currency', d.currency,
        'declarer_name', d.declarer_name,
        'declarer_contact', d.declarer_contact,
        'status', d.status,
        'confirmed_by', d.confirmed_by,
        'confirmed_at', d.confirmed_at,
        'created_at', d.created_at
    ) ORDER BY d.created_at DESC)
    INTO v_rows
    FROM t_public_payment_declarations d
    JOIN t_contracts c ON c.id = d.contract_id
    LEFT JOIN t_invoices i ON i.id = d.invoice_id
    WHERE d.tenant_id = p_tenant_id
      AND d.is_live = true
      AND (p_status IS NULL OR p_status = '' OR d.status = p_status);

    RETURN jsonb_build_object('success', true, 'data', COALESCE(v_rows, '[]'::jsonb));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;
