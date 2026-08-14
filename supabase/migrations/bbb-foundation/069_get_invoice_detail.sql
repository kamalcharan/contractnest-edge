-- Migration 069: get_invoice_detail — one invoice as a complete document
-- Already applied live (2026-08-14), incl. the EMI/billing-cycle/payment-mode
-- and receipts_count additions. Source-of-record copy — DO NOT RE-RUN.
--
-- The existing invoice viewer is routed through a contract
-- (/contracts/:id/invoice/:invoiceId) and builds its line items from the
-- CONTRACT'S BLOCKS. An ad-hoc invoice has no contract, so it had no page at
-- all — created, paid, and unviewable. This returns the document from the
-- invoice record itself: header, line_items (JSONB, written by
-- create_adhoc_invoice), receipts, and the bill-to contact. Contract-optional,
-- so one viewer can serve both kinds.
--
-- Note: t_contracts has `name`, not `title` (a first attempt used title and
-- failed at runtime — the RPC is verified against both an ad-hoc invoice and
-- a contract-linked one).

CREATE OR REPLACE FUNCTION public.get_invoice_detail(
  p_tenant uuid,
  p_invoice uuid,
  p_is_live boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_inv      RECORD;
  v_receipts jsonb;
BEGIN
  SELECT i.*,
         ct.name           AS contact_name,
         ct.company_name   AS contact_company,
         c.contract_number AS contract_number,
         c.name            AS contract_title
    INTO v_inv
    FROM t_invoices i
    LEFT JOIN t_contacts  ct ON ct.id = i.contact_id
    LEFT JOIN t_contracts c  ON c.id  = i.contract_id
   WHERE i.id = p_invoice
     AND i.tenant_id = p_tenant
     AND i.is_live = p_is_live
     AND COALESCE(i.is_active, true) = true;

  IF v_inv.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', r.id, 'receipt_number', r.receipt_number, 'amount', r.amount,
           'currency', r.currency, 'payment_date', r.payment_date,
           'payment_method', r.payment_method, 'reference_number', r.reference_number,
           'notes', r.notes, 'is_offline', r.is_offline, 'cancelled_at', r.cancelled_at
         ) ORDER BY r.payment_date, r.created_at), '[]'::jsonb)
    INTO v_receipts
    FROM t_invoice_receipts r
   WHERE r.invoice_id = p_invoice
     AND r.tenant_id = p_tenant
     AND COALESCE(r.is_active, true) = true;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'id', v_inv.id, 'invoice_number', v_inv.invoice_number,
      'invoice_type', v_inv.invoice_type, 'status', v_inv.status,
      'is_adhoc', (v_inv.contract_id IS NULL),
      'contract_id', v_inv.contract_id, 'contract_number', v_inv.contract_number,
      'contract_title', v_inv.contract_title,
      'contact_id', v_inv.contact_id,
      'contact_name', COALESCE(v_inv.contact_company, v_inv.contact_name),
      'amount', v_inv.amount, 'tax_amount', v_inv.tax_amount,
      'total_amount', v_inv.total_amount, 'amount_paid', v_inv.amount_paid,
      'balance', v_inv.balance, 'currency', v_inv.currency,
      'issued_at', v_inv.issued_at, 'due_date', v_inv.due_date, 'paid_at', v_inv.paid_at,
      'notes', v_inv.notes,
      -- fields the existing viewer's Bill To / Invoice Details cards render,
      -- so ONE page can be driven entirely by this payload
      'emi_sequence', v_inv.emi_sequence, 'emi_total', v_inv.emi_total,
      'billing_cycle', v_inv.billing_cycle, 'payment_mode', v_inv.payment_mode,
      'line_items', COALESCE(v_inv.line_items, '[]'::jsonb),
      'receipts', v_receipts,
      'receipts_count', jsonb_array_length(v_receipts)
  ));
END;
$function$;
