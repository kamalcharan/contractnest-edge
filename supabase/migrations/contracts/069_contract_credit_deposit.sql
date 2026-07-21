-- Contract-level Credit and Deposit — replaces the invoice-level
-- "Mark as Adjustment" flow (which zeroed the ENTIRE remaining balance —
-- confirmed live as a real bug against a real mid-cycle-join scenario:
-- only a specific PARTIAL amount should be carved out and carried
-- forward, not the whole invoice).
--
-- Credit: a specific amount + reason captured on a contract that's
-- ending, representing a deferred amount owed to the buyer's NEXT
-- contract (e.g. a mid-cycle-join proration: 3000 of this year's
-- collection is really an advance for next year). Lives as plain columns
-- on t_contracts — same pattern as discount_type/discount_value/
-- discount_total already do — not a new table. Lifecycle: pending ->
-- applied (once a later contract for the same buyer consumes it).
--
-- Deposit: a security deposit the SELLER holds against this contract
-- (regulated industries), reclaimed once the contract closes. Also plain
-- columns on t_contracts. Lifecycle: held -> reclaimed.
--
-- Applying a credit forward is a MANUAL action (find_buyer_pending_credits
-- + apply_buyer_credit_to_contract), not wizard-automated — there's no
-- "Renew" feature yet (confirmed: renewal today is just creating a new
-- contract normally), so a tenant applies a pending credit from the
-- Overview/Financials screen of the NEW contract once it exists. This
-- reduces the target contract's grand_total directly; it does NOT
-- retroactively adjust invoices/billing events already generated on the
-- target — apply the credit before those exist for a clean result,
-- consistent with the platform's existing "no system-invented proration,
-- human confirms the number" philosophy.

ALTER TABLE t_contracts
  ADD COLUMN IF NOT EXISTS credit_amount numeric NULL,
  ADD COLUMN IF NOT EXISTS credit_reason text NULL,
  ADD COLUMN IF NOT EXISTS credit_status text NULL,
  ADD COLUMN IF NOT EXISTS credit_created_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS credit_applied_to_contract_id uuid NULL REFERENCES t_contracts(id),
  ADD COLUMN IF NOT EXISTS credit_applied_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS credit_received_amount numeric NULL,
  ADD COLUMN IF NOT EXISTS credit_received_from_contract_id uuid NULL REFERENCES t_contracts(id),
  ADD COLUMN IF NOT EXISTS deposit_amount numeric NULL,
  ADD COLUMN IF NOT EXISTS deposit_status text NULL,
  ADD COLUMN IF NOT EXISTS deposit_created_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deposit_reclaimed_at timestamptz NULL;

ALTER TABLE t_contracts
  DROP CONSTRAINT IF EXISTS t_contracts_credit_status_check,
  ADD CONSTRAINT t_contracts_credit_status_check CHECK (credit_status IS NULL OR credit_status IN ('pending', 'applied'));

ALTER TABLE t_contracts
  DROP CONSTRAINT IF EXISTS t_contracts_deposit_status_check,
  ADD CONSTRAINT t_contracts_deposit_status_check CHECK (deposit_status IS NULL OR deposit_status IN ('held', 'reclaimed'));

-- ── set_contract_credit: capture amount + reason on the ending contract ──
CREATE OR REPLACE FUNCTION public.set_contract_credit(p_contract_id uuid, p_tenant_id uuid, p_amount numeric, p_reason text, p_performed_by uuid DEFAULT NULL::uuid, p_performed_by_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contract RECORD;
BEGIN
  IF p_contract_id IS NULL OR p_tenant_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'contract_id and tenant_id are required');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'amount must be a positive number');
  END IF;
  IF coalesce(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'reason is required');
  END IF;

  SELECT id, tenant_id, buyer_id, credit_status INTO v_contract
  FROM t_contracts WHERE id = p_contract_id AND is_active = true FOR UPDATE;

  IF v_contract IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Contract not found');
  END IF;
  IF v_contract.tenant_id != p_tenant_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only the contract owner can set a credit');
  END IF;
  IF v_contract.credit_status IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'A credit is already set for this contract (status: ' || v_contract.credit_status || ')');
  END IF;

  UPDATE t_contracts
  SET credit_amount = p_amount, credit_reason = p_reason, credit_status = 'pending', credit_created_at = now()
  WHERE id = p_contract_id;

  INSERT INTO t_contract_history (contract_id, tenant_id, action, note, changes, performed_by_id, performed_by_type, performed_by_name)
  VALUES (p_contract_id, p_tenant_id, 'updated',
    format('Credit of %s set aside for buyer''s next contract — %s', p_amount, p_reason),
    jsonb_build_object('field', 'credit', 'amount', p_amount, 'reason', p_reason),
    p_performed_by, 'user', p_performed_by_name);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'contract_id', p_contract_id, 'credit_amount', p_amount, 'credit_reason', p_reason, 'credit_status', 'pending'));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'Failed to set credit', 'details', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ── find_buyer_pending_credits: for the "Apply Credit" picker on a new/other contract ──
CREATE OR REPLACE FUNCTION public.find_buyer_pending_credits(p_tenant_id uuid, p_buyer_id uuid, p_exclude_contract_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_credits jsonb;
BEGIN
  IF p_tenant_id IS NULL OR p_buyer_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'tenant_id and buyer_id are required');
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'contract_id', c.id, 'contract_number', c.contract_number,
      'credit_amount', c.credit_amount, 'credit_reason', c.credit_reason,
      'credit_created_at', c.credit_created_at
    ) ORDER BY c.credit_created_at), '[]'::jsonb)
  INTO v_credits
  FROM t_contracts c
  WHERE c.tenant_id = p_tenant_id AND c.buyer_id = p_buyer_id AND c.is_active = true
    AND c.credit_status = 'pending'
    AND c.id IS DISTINCT FROM p_exclude_contract_id;

  RETURN jsonb_build_object('success', true, 'data', v_credits);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'Failed to look up pending credits', 'details', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ── apply_buyer_credit_to_contract: consume a pending credit into another contract ──
CREATE OR REPLACE FUNCTION public.apply_buyer_credit_to_contract(p_source_contract_id uuid, p_target_contract_id uuid, p_tenant_id uuid, p_performed_by uuid DEFAULT NULL::uuid, p_performed_by_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_source RECORD;
  v_target RECORD;
  v_new_grand_total numeric;
BEGIN
  IF p_source_contract_id IS NULL OR p_target_contract_id IS NULL OR p_tenant_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'source_contract_id, target_contract_id and tenant_id are required');
  END IF;
  IF p_source_contract_id = p_target_contract_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'A contract cannot apply a credit to itself');
  END IF;

  SELECT id, tenant_id, buyer_id, credit_amount, credit_status INTO v_source
  FROM t_contracts WHERE id = p_source_contract_id AND is_active = true FOR UPDATE;
  IF v_source IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Source contract not found');
  END IF;
  IF v_source.tenant_id != p_tenant_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only the contract owner can apply this credit');
  END IF;
  IF v_source.credit_status IS DISTINCT FROM 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'This credit is not pending (status: ' || coalesce(v_source.credit_status, 'none') || ')');
  END IF;

  SELECT id, tenant_id, buyer_id, grand_total, credit_received_amount INTO v_target
  FROM t_contracts WHERE id = p_target_contract_id AND is_active = true FOR UPDATE;
  IF v_target IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Target contract not found');
  END IF;
  IF v_target.tenant_id != p_tenant_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only the contract owner can apply this credit');
  END IF;
  IF v_target.buyer_id IS DISTINCT FROM v_source.buyer_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Credit and target contract belong to different buyers');
  END IF;
  IF v_target.credit_received_amount IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'This contract has already received a credit');
  END IF;

  v_new_grand_total := GREATEST(0, coalesce(v_target.grand_total, 0) - v_source.credit_amount);

  UPDATE t_contracts
  SET credit_status = 'applied', credit_applied_to_contract_id = p_target_contract_id, credit_applied_at = now()
  WHERE id = p_source_contract_id;

  UPDATE t_contracts
  SET credit_received_amount = v_source.credit_amount, credit_received_from_contract_id = p_source_contract_id,
      grand_total = v_new_grand_total
  WHERE id = p_target_contract_id;

  INSERT INTO t_contract_history (contract_id, tenant_id, action, note, changes, performed_by_id, performed_by_type, performed_by_name)
  VALUES (p_source_contract_id, p_tenant_id, 'updated',
    format('Credit of %s applied to contract %s', v_source.credit_amount, p_target_contract_id),
    jsonb_build_object('field', 'credit', 'applied_to_contract_id', p_target_contract_id, 'amount', v_source.credit_amount),
    p_performed_by, 'user', p_performed_by_name);
  INSERT INTO t_contract_history (contract_id, tenant_id, action, note, changes, performed_by_id, performed_by_type, performed_by_name)
  VALUES (p_target_contract_id, p_tenant_id, 'updated',
    format('Credit of %s received from contract %s — grand total reduced accordingly', v_source.credit_amount, p_source_contract_id),
    jsonb_build_object('field', 'credit', 'received_from_contract_id', p_source_contract_id, 'amount', v_source.credit_amount, 'new_grand_total', v_new_grand_total),
    p_performed_by, 'user', p_performed_by_name);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'source_contract_id', p_source_contract_id, 'target_contract_id', p_target_contract_id,
    'amount', v_source.credit_amount, 'target_new_grand_total', v_new_grand_total));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'Failed to apply credit', 'details', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ── set_contract_deposit: seller holds a security deposit against this contract ──
CREATE OR REPLACE FUNCTION public.set_contract_deposit(p_contract_id uuid, p_tenant_id uuid, p_amount numeric, p_performed_by uuid DEFAULT NULL::uuid, p_performed_by_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contract RECORD;
BEGIN
  IF p_contract_id IS NULL OR p_tenant_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'contract_id and tenant_id are required');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'amount must be a positive number');
  END IF;

  SELECT id, tenant_id, deposit_status INTO v_contract
  FROM t_contracts WHERE id = p_contract_id AND is_active = true FOR UPDATE;
  IF v_contract IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Contract not found');
  END IF;
  IF v_contract.tenant_id != p_tenant_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only the contract owner can set a deposit');
  END IF;
  IF v_contract.deposit_status IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'A deposit is already recorded for this contract (status: ' || v_contract.deposit_status || ')');
  END IF;

  UPDATE t_contracts
  SET deposit_amount = p_amount, deposit_status = 'held', deposit_created_at = now()
  WHERE id = p_contract_id;

  INSERT INTO t_contract_history (contract_id, tenant_id, action, note, changes, performed_by_id, performed_by_type, performed_by_name)
  VALUES (p_contract_id, p_tenant_id, 'updated', format('Security deposit of %s recorded as held', p_amount),
    jsonb_build_object('field', 'deposit', 'amount', p_amount), p_performed_by, 'user', p_performed_by_name);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'contract_id', p_contract_id, 'deposit_amount', p_amount, 'deposit_status', 'held'));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'Failed to set deposit', 'details', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ── reclaim_contract_deposit: seller reclaims the held deposit after the contract closes ──
CREATE OR REPLACE FUNCTION public.reclaim_contract_deposit(p_contract_id uuid, p_tenant_id uuid, p_performed_by uuid DEFAULT NULL::uuid, p_performed_by_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contract RECORD;
BEGIN
  IF p_contract_id IS NULL OR p_tenant_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'contract_id and tenant_id are required');
  END IF;

  SELECT id, tenant_id, deposit_amount, deposit_status INTO v_contract
  FROM t_contracts WHERE id = p_contract_id AND is_active = true FOR UPDATE;
  IF v_contract IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Contract not found');
  END IF;
  IF v_contract.tenant_id != p_tenant_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only the contract owner can reclaim this deposit');
  END IF;
  IF v_contract.deposit_status IS DISTINCT FROM 'held' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No held deposit to reclaim (status: ' || coalesce(v_contract.deposit_status, 'none') || ')');
  END IF;

  UPDATE t_contracts SET deposit_status = 'reclaimed', deposit_reclaimed_at = now() WHERE id = p_contract_id;

  INSERT INTO t_contract_history (contract_id, tenant_id, action, note, changes, performed_by_id, performed_by_type, performed_by_name)
  VALUES (p_contract_id, p_tenant_id, 'updated', format('Security deposit of %s reclaimed', v_contract.deposit_amount),
    jsonb_build_object('field', 'deposit', 'amount', v_contract.deposit_amount), p_performed_by, 'user', p_performed_by_name);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'contract_id', p_contract_id, 'deposit_amount', v_contract.deposit_amount, 'deposit_status', 'reclaimed'));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', 'Failed to reclaim deposit', 'details', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;

-- ── get_contract_by_id: + Part D (credit / deposit fields) ──
CREATE OR REPLACE FUNCTION public.get_contract_by_id(p_contract_id uuid, p_tenant_id uuid DEFAULT NULL::uuid, p_access_key character varying DEFAULT NULL::character varying, p_access_secret character varying DEFAULT NULL::character varying)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_contract RECORD;
    v_blocks JSONB;
    v_vendors JSONB;
    v_attachments JSONB;
    v_history JSONB;
    v_evidence_forms JSONB;
    v_result JSONB;
    v_tenant_id UUID;
    v_is_buyer_access BOOLEAN := false;
    v_access_record RECORD;
    v_access_role TEXT;
    -- Seller contact info (new in 060)
    v_seller_name TEXT;
    v_seller_company TEXT;
    v_seller_contact_id UUID;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 1: Determine access method
    -- ═══════════════════════════════════════════
    IF p_access_key IS NOT NULL AND p_access_secret IS NOT NULL THEN
        -- CNAK-based access (buyer/external via link)
        SELECT ca.*, c.tenant_id AS contract_tenant_id
        INTO v_access_record
        FROM t_contract_access ca
        JOIN t_contracts c ON c.id = ca.contract_id
        WHERE ca.contract_id = p_contract_id
          AND ca.access_key = p_access_key
          AND ca.access_secret = p_access_secret
          AND ca.is_active = true;

        IF v_access_record IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Invalid access credentials'
            );
        END IF;

        v_tenant_id := v_access_record.contract_tenant_id;
        v_is_buyer_access := true;

    ELSIF p_tenant_id IS NOT NULL THEN
        -- Direct tenant access — could be seller OR buyer
        v_tenant_id := p_tenant_id;
    ELSE
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Either tenant_id or access credentials required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Fetch contract
    --   Path A: requesting tenant is the owner (seller)
    --   Path B: requesting tenant has an active access grant (buyer who claimed)
    --   Path C: requesting tenant matches buyer_tenant_id on the contract
    -- ═══════════════════════════════════════════

    -- Path A: Owner (seller) — tenant_id matches directly
    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND tenant_id = v_tenant_id
      AND is_active = true;

    -- Path B & C: Only needed when Path A fails AND we're using tenant_id (not CNAK)
    IF v_contract IS NULL AND NOT v_is_buyer_access THEN

        -- Path B: Check t_contract_access for active accessor grant
        SELECT ca.accessor_role INTO v_access_role
        FROM t_contract_access ca
        WHERE ca.contract_id = p_contract_id
          AND ca.accessor_tenant_id = p_tenant_id
          AND ca.is_active = true
          AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
        LIMIT 1;

        IF v_access_role IS NOT NULL THEN
            -- Buyer has a valid access grant — fetch using contract's own data
            SELECT * INTO v_contract
            FROM t_contracts
            WHERE id = p_contract_id
              AND is_active = true;

            v_is_buyer_access := true;
        END IF;

        -- Path C: Check buyer_tenant_id on the contract itself
        IF v_contract IS NULL THEN
            SELECT * INTO v_contract
            FROM t_contracts
            WHERE id = p_contract_id
              AND buyer_tenant_id = p_tenant_id
              AND is_active = true;

            IF v_contract IS NOT NULL THEN
                v_is_buyer_access := true;
            END IF;
        END IF;
    END IF;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found',
            'contract_id', p_contract_id
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2b (NEW - 060): Look up seller contact in buyer's workspace
    -- Only when the requesting tenant is a buyer, find the seller's
    -- contact record (created during CNAK claim) to get seller name.
    -- ═══════════════════════════════════════════
    IF v_is_buyer_access AND p_tenant_id IS NOT NULL THEN
        SELECT c.id, c.name, c.company_name
        INTO v_seller_contact_id, v_seller_name, v_seller_company
        FROM t_contacts c
        WHERE c.tenant_id = p_tenant_id
          AND c.source_tenant_id = v_contract.tenant_id
          AND c.is_active = true
        LIMIT 1;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Fetch related blocks
    -- ═══════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', b.id,
            'position', b.position,
            'source_type', b.source_type,
            'source_block_id', b.source_block_id,
            'block_name', b.block_name,
            'block_description', b.block_description,
            'category_id', b.category_id,
            'category_name', b.category_name,
            'unit_price', b.unit_price,
            'quantity', b.quantity,
            'billing_cycle', b.billing_cycle,
            'total_price', b.total_price,
            'flyby_type', b.flyby_type,
            'custom_fields', COALESCE(b.custom_fields, '{}'::JSONB)
        ) ORDER BY b.position
    ), '[]'::JSONB)
    INTO v_blocks
    FROM t_contract_blocks b
    WHERE b.contract_id = p_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Fetch related vendors
    -- ═══════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', v.id,
            'vendor_id', v.vendor_id,
            'vendor_name', v.vendor_name,
            'vendor_company', v.vendor_company,
            'vendor_email', v.vendor_email,
            'response_status', v.response_status,
            'responded_at', v.responded_at,
            'quoted_amount', v.quoted_amount,
            'quote_notes', v.quote_notes,
            'created_at', v.created_at
        )
    ), '[]'::JSONB)
    INTO v_vendors
    FROM t_contract_vendors v
    WHERE v.contract_id = p_contract_id;

    -- ═══════════════════════════════════════════
    -- STEP 5: Fetch attachments (if table exists)
    -- ═══════════════════════════════════════════
    v_attachments := '[]'::JSONB;
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_name = 't_contract_attachments' AND table_schema = 'public'
    ) THEN
        EXECUTE format(
            'SELECT COALESCE(jsonb_agg(
                jsonb_build_object(
                    ''id'', a.id,
                    ''block_id'', a.block_id,
                    ''file_name'', a.file_name,
                    ''file_path'', a.file_path,
                    ''file_size'', a.file_size,
                    ''file_type'', a.file_type,
                    ''mime_type'', a.mime_type,
                    ''download_url'', a.download_url,
                    ''file_category'', a.file_category,
                    ''metadata'', a.metadata,
                    ''uploaded_by'', a.uploaded_by,
                    ''created_at'', a.created_at
                )
            ), ''[]''::JSONB)
            FROM t_contract_attachments a
            WHERE a.contract_id = %L', p_contract_id
        ) INTO v_attachments;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 6: Fetch history (last 50 entries)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', h.id,
            'action', h.action,
            'from_status', h.from_status,
            'to_status', h.to_status,
            'changes', COALESCE(h.changes, '{}'::JSONB),
            'performed_by_type', h.performed_by_type,
            'performed_by_id', h.performed_by_id,
            'performed_by_name', h.performed_by_name,
            'note', h.note,
            'created_at', h.created_at
        ) ORDER BY h.created_at DESC
    ), '[]'::JSONB)
    INTO v_history
    FROM (
        SELECT * FROM t_contract_history
        WHERE contract_id = p_contract_id
        ORDER BY created_at DESC
        LIMIT 50
    ) h;

    -- ═══════════════════════════════════════════
    -- STEP 7: Fetch evidence forms (if table exists)
    -- ═══════════════════════════════════════════
    v_evidence_forms := '[]'::JSONB;
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_name = 't_contract_evidence_forms' AND table_schema = 'public'
    ) THEN
        EXECUTE format(
            'SELECT COALESCE(jsonb_agg(
                jsonb_build_object(
                    ''id'', ef.id,
                    ''form_template_id'', ef.form_template_id,
                    ''name'', ef.name,
                    ''version'', ef.version,
                    ''category'', ef.category,
                    ''sort_order'', ef.sort_order
                ) ORDER BY ef.sort_order
            ), ''[]''::JSONB)
            FROM t_contract_evidence_forms ef
            WHERE ef.contract_id = %L', p_contract_id
        ) INTO v_evidence_forms;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 8: Build full response
    -- NOTE: Split into jsonb_build_object calls merged with ||
    --       to stay under PostgreSQL's 100-argument limit.
    -- ═══════════════════════════════════════════
    v_result := jsonb_build_object(
        'success', true,
        'data', (
            -- Part A: core + counterparty + terms (25 pairs = 50 args)
            jsonb_build_object(
                'id', v_contract.id,
                'tenant_id', v_contract.tenant_id,
                'seller_id', v_contract.seller_id,
                'buyer_tenant_id', v_contract.buyer_tenant_id,
                'contract_number', v_contract.contract_number,
                'rfq_number', v_contract.rfq_number,
                'record_type', v_contract.record_type,
                'contract_type', v_contract.contract_type,
                'path', v_contract.path,
                'template_id', v_contract.template_id,
                'name', v_contract.name,
                'description', v_contract.description,
                'status', v_contract.status,
                'buyer_id', v_contract.buyer_id,
                'buyer_name', v_contract.buyer_name,
                'buyer_company', v_contract.buyer_company,
                'buyer_email', v_contract.buyer_email,
                'buyer_phone', v_contract.buyer_phone,
                'buyer_contact_person_id', v_contract.buyer_contact_person_id,
                'buyer_contact_person_name', v_contract.buyer_contact_person_name,
                'global_access_id', v_contract.global_access_id,
                'acceptance_method', v_contract.acceptance_method,
                'start_date', v_contract.start_date,
                'duration_value', v_contract.duration_value,
                'duration_unit', v_contract.duration_unit
            )
            ||
            -- Part B: billing + financials + evidence + nomenclature + equipment + metadata + relations + audit (30 pairs = 60 args)
            jsonb_build_object(
                'grace_period_value', v_contract.grace_period_value,
                'grace_period_unit', v_contract.grace_period_unit,
                'currency', v_contract.currency,
                'billing_cycle_type', v_contract.billing_cycle_type,
                'payment_mode', v_contract.payment_mode,
                'emi_months', v_contract.emi_months,
                'per_block_payment_type', v_contract.per_block_payment_type,
                'total_value', v_contract.total_value,
                'tax_total', v_contract.tax_total,
                'grand_total', v_contract.grand_total,
                'selected_tax_rate_ids', COALESCE(v_contract.selected_tax_rate_ids, '[]'::JSONB),
                'tax_breakdown', COALESCE(v_contract.tax_breakdown, '[]'::JSONB),
                'computed_events', v_contract.computed_events,
                'evidence_policy_type', COALESCE(v_contract.evidence_policy_type, 'none'),
                'evidence_selected_forms', COALESCE(v_contract.evidence_selected_forms, '[]'::JSONB),
                'nomenclature_id', v_contract.nomenclature_id,
                'nomenclature_code', v_contract.nomenclature_code,
                'nomenclature_name', v_contract.nomenclature_name,
                'equipment_details', COALESCE(v_contract.equipment_details, '[]'::JSONB),
                'allow_buyer_to_add_equipment', v_contract.allow_buyer_to_add_equipment,
                'coverage_types', COALESCE(v_contract.coverage_types, '[]'::JSONB),
                'metadata', COALESCE(v_contract.metadata, '{}'::JSONB),
                'blocks', v_blocks,
                'vendors', v_vendors,
                'attachments', v_attachments,
                'history', v_history,
                'evidence_forms', v_evidence_forms,
                'blocks_count', jsonb_array_length(v_blocks),
                'vendors_count', jsonb_array_length(v_vendors),
                'attachments_count', jsonb_array_length(v_attachments)
            )
            ||
            -- Part C: version + audit + seller info (13 pairs = 26 args)
            jsonb_build_object(
                'version', v_contract.version,
                'is_live', v_contract.is_live,
                'created_by', v_contract.created_by,
                'updated_by', v_contract.updated_by,
                'created_at', v_contract.created_at,
                'updated_at', v_contract.updated_at,
                'sent_at', v_contract.sent_at,
                'accepted_at', v_contract.accepted_at,
                'completed_at', v_contract.completed_at,
                'access_role', CASE WHEN v_is_buyer_access THEN 'buyer' ELSE 'owner' END,
                'seller_name', v_seller_name,
                'seller_company', v_seller_company,
                'seller_contact_id', v_seller_contact_id
            )
            ||
            -- Part D (NEW - 069): credit + deposit
            jsonb_build_object(
                'credit_amount', v_contract.credit_amount,
                'credit_reason', v_contract.credit_reason,
                'credit_status', v_contract.credit_status,
                'credit_created_at', v_contract.credit_created_at,
                'credit_applied_to_contract_id', v_contract.credit_applied_to_contract_id,
                'credit_applied_at', v_contract.credit_applied_at,
                'credit_received_amount', v_contract.credit_received_amount,
                'credit_received_from_contract_id', v_contract.credit_received_from_contract_id,
                'deposit_amount', v_contract.deposit_amount,
                'deposit_status', v_contract.deposit_status,
                'deposit_created_at', v_contract.deposit_created_at,
                'deposit_reclaimed_at', v_contract.deposit_reclaimed_at
            )
        ),
        'is_buyer_access', v_is_buyer_access
    );

    RETURN v_result;

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$function$;
