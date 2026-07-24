-- 070_selfheal_sequence_number_collisions.sql
--
-- Bug: t_invoice_receipts.receipt_number and t_invoices.invoice_number are
-- each unique per tenant REGARDLESS of environment (idx_receipts_number_tenant
-- and idx_invoices_number_tenant have no is_live column), but their numbers
-- are generated from t_sequence_counters rows that are tracked SEPARATELY per
-- environment (is_live true/false), each starting at the same start_value.
-- The first time a tenant uses the environment that lags behind, the naive
-- next-value collides with a number already claimed by the other
-- environment — and because a failed INSERT rolls back the whole function
-- body (including the counter's own advance), every retry redraws the exact
-- same colliding number forever.
--
-- Fix: after computing the next formatted number, check whether it's
-- already taken (matching the real uniqueness scope, not the counter's
-- environment scope) and redraw until genuinely free, instead of trusting
-- the counter blindly. Bounded to 1000 attempts as a backstop.

-- ============================================================================
-- record_invoice_payment — RECEIPT sequence (t_invoice_receipts.receipt_number)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_invoice_payment(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_invoice_id UUID;
    v_contract_id UUID;
    v_tenant_id UUID;
    v_recorded_by UUID;
    v_is_live BOOLEAN;

    v_invoice RECORD;
    v_amount NUMERIC;
    v_payment_method VARCHAR(30);
    v_payment_date DATE;
    v_reference_number TEXT;
    v_notes TEXT;
    v_emi_sequence INTEGER;

    v_seq_result JSONB;
    v_receipt_number VARCHAR(30);
    v_receipt_id UUID;
    v_healing_attempt INTEGER;

    v_new_amount_paid NUMERIC;
    v_new_balance NUMERIC;
    v_new_status VARCHAR(20);
    v_receipts_count INTEGER;

    -- STEP 4.5: auto-activate contract on full payment
    v_contract RECORD;
    v_unpaid_count INTEGER;
    v_activation_result JSONB;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Extract and validate inputs
    -- ═══════════════════════════════════════════
    v_invoice_id := (p_payload->>'invoice_id')::UUID;
    v_contract_id := (p_payload->>'contract_id')::UUID;
    v_tenant_id := (p_payload->>'tenant_id')::UUID;
    v_recorded_by := (p_payload->>'recorded_by')::UUID;
    v_is_live := COALESCE((p_payload->>'is_live')::BOOLEAN, true);

    v_amount := (p_payload->>'amount')::NUMERIC;
    v_payment_method := COALESCE(p_payload->>'payment_method', 'bank_transfer');
    v_payment_date := COALESCE((p_payload->>'payment_date')::DATE, CURRENT_DATE);
    v_reference_number := p_payload->>'reference_number';
    v_notes := p_payload->>'notes';
    v_emi_sequence := (p_payload->>'emi_sequence')::INTEGER;

    IF v_invoice_id IS NULL OR v_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'invoice_id and tenant_id are required'
        );
    END IF;

    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'amount must be a positive number'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Fetch and lock the invoice
    -- ═══════════════════════════════════════════
    SELECT * INTO v_invoice
    FROM t_invoices
    WHERE id = v_invoice_id
      AND tenant_id = v_tenant_id
      AND is_active = true
    FOR UPDATE;

    IF v_invoice IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoice not found'
        );
    END IF;

    -- Can't pay a fully paid, cancelled, bad_debt, or adjusted invoice
    IF v_invoice.status IN ('paid', 'cancelled', 'bad_debt', 'adjustment') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoice is already ' || v_invoice.status
        );
    END IF;

    -- Validate amount doesn't exceed balance
    IF v_amount > v_invoice.balance THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Payment amount exceeds invoice balance',
            'balance', v_invoice.balance,
            'attempted', v_amount
        );
    END IF;

    -- Use contract_id from invoice if not provided
    IF v_contract_id IS NULL THEN
        v_contract_id := v_invoice.contract_id;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Generate receipt number (self-healing against cross-environment
    -- collisions — see file header)
    -- ═══════════════════════════════════════════
    FOR v_healing_attempt IN 1..1000 LOOP
        v_seq_result := get_next_formatted_sequence('RECEIPT', v_tenant_id, v_is_live);
        v_receipt_number := v_seq_result->>'formatted';
        EXIT WHEN NOT EXISTS (
            SELECT 1 FROM t_invoice_receipts
            WHERE tenant_id = v_tenant_id AND receipt_number = v_receipt_number AND is_active = true
        );
        IF v_healing_attempt = 1000 THEN
            RAISE EXCEPTION 'Unable to generate a unique receipt number after 1000 attempts';
        END IF;
    END LOOP;

    -- ═══════════════════════════════════════════
    -- STEP 3: Create receipt record
    -- ═══════════════════════════════════════════
    INSERT INTO t_invoice_receipts (
        invoice_id,
        contract_id,
        tenant_id,
        receipt_number,
        amount,
        currency,
        payment_date,
        payment_method,
        reference_number,
        notes,
        is_offline,
        recorded_by
    ) VALUES (
        v_invoice_id,
        v_contract_id,
        v_tenant_id,
        v_receipt_number,
        v_amount,
        v_invoice.currency,
        v_payment_date,
        v_payment_method,
        v_reference_number,
        v_notes,
        true,  -- manually recorded = offline
        v_recorded_by
    )
    RETURNING id INTO v_receipt_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Update invoice totals and status
    -- ═══════════════════════════════════════════
    v_new_amount_paid := v_invoice.amount_paid + v_amount;
    v_new_balance := v_invoice.total_amount - v_new_amount_paid;

    -- Determine new status
    IF v_new_balance <= 0 THEN
        v_new_status := 'paid';
    ELSE
        v_new_status := 'partially_paid';
    END IF;

    UPDATE t_invoices
    SET amount_paid = v_new_amount_paid,
        balance = v_new_balance,
        status = v_new_status,
        paid_at = CASE WHEN v_new_status = 'paid' THEN NOW() ELSE paid_at END,
        updated_at = NOW()
    WHERE id = v_invoice_id;

    -- Count total receipts for this invoice
    SELECT COUNT(*) INTO v_receipts_count
    FROM t_invoice_receipts
    WHERE invoice_id = v_invoice_id AND is_active = true;

    -- ═══════════════════════════════════════════
    -- STEP 4.5: Auto-activate contract on full payment
    --   When acceptance_method = 'manual' (payment acceptance) and the
    --   contract is at pending_acceptance, check if ALL invoices are
    --   now paid. If so, transition the contract to 'active'.
    --   update_contract_status handles audit trail + event triggers.
    -- ═══════════════════════════════════════════
    IF v_new_status = 'paid' AND v_contract_id IS NOT NULL THEN
        SELECT id, status, acceptance_method, record_type, tenant_id
        INTO v_contract
        FROM t_contracts
        WHERE id = v_contract_id
          AND tenant_id = v_tenant_id
          AND is_active = true;

        IF v_contract IS NOT NULL
           AND v_contract.status = 'pending_acceptance'
           AND v_contract.acceptance_method = 'manual'
           AND v_contract.record_type = 'contract'
        THEN
            -- Check if any unpaid invoices remain
            SELECT COUNT(*) INTO v_unpaid_count
            FROM t_invoices
            WHERE contract_id = v_contract_id
              AND tenant_id = v_tenant_id
              AND is_active = true
              AND status NOT IN ('paid', 'cancelled');

            IF v_unpaid_count = 0 THEN
                -- All invoices paid — activate the contract
                v_activation_result := update_contract_status(
                    p_contract_id      := v_contract_id,
                    p_tenant_id        := v_tenant_id,
                    p_new_status       := 'active',
                    p_performed_by_id  := v_recorded_by,
                    p_performed_by_name := NULL,
                    p_performed_by_type := 'system',
                    p_note             := 'Auto-activated: all invoices paid'
                );
            END IF;
        END IF;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 5: Return receipt details
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'receipt_id', v_receipt_id,
            'receipt_number', v_receipt_number,
            'amount', v_amount,
            'currency', v_invoice.currency,
            'payment_method', v_payment_method,
            'payment_date', v_payment_date,
            'emi_sequence', v_emi_sequence,
            'invoice_id', v_invoice_id,
            'invoice_number', v_invoice.invoice_number,
            'invoice_status', v_new_status,
            'amount_paid', v_new_amount_paid,
            'balance', v_new_balance,
            'receipts_count', v_receipts_count,
            'contract_activated', COALESCE((v_activation_result->>'success')::BOOLEAN, false)
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to record payment',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$function$;

-- ============================================================================
-- generate_contract_invoices — INVOICE sequence (t_invoices.invoice_number)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.generate_contract_invoices(p_contract_id uuid, p_tenant_id uuid, p_created_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_contract RECORD;
    v_invoice_type VARCHAR(20);
    v_seq_result JSONB;
    v_invoice_number VARCHAR(30);
    v_invoice_id UUID;
    v_healing_attempt INTEGER;
BEGIN
    SELECT * INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id
      AND tenant_id = p_tenant_id
      AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract not found'
        );
    END IF;

    IF v_contract.status <> 'active' AND NOT (
        v_contract.status = 'pending_acceptance' AND v_contract.acceptance_method = 'manual'
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Contract must be active to generate invoices (payment-acceptance contracts generate at pending_acceptance)',
            'current_status', v_contract.status
        );
    END IF;

    IF EXISTS (
        SELECT 1 FROM t_invoices
        WHERE contract_id = p_contract_id AND is_active = true
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoices already generated for this contract'
        );
    END IF;

    v_invoice_type := CASE v_contract.contract_type
        WHEN 'vendor' THEN 'payable'
        ELSE 'receivable'
    END;

    -- Self-healing against cross-environment collisions — see migration
    -- 070_selfheal_sequence_number_collisions.sql header
    FOR v_healing_attempt IN 1..1000 LOOP
        v_seq_result := get_next_formatted_sequence('INVOICE', p_tenant_id, v_contract.is_live);
        v_invoice_number := v_seq_result->>'formatted';
        EXIT WHEN NOT EXISTS (
            SELECT 1 FROM t_invoices
            WHERE tenant_id = p_tenant_id AND invoice_number = v_invoice_number AND is_active = true
        );
        IF v_healing_attempt = 1000 THEN
            RAISE EXCEPTION 'Unable to generate a unique invoice number after 1000 attempts';
        END IF;
    END LOOP;

    INSERT INTO t_invoices (
        contract_id, tenant_id, invoice_number, invoice_type,
        amount, tax_amount, total_amount, currency,
        balance, status, payment_mode,
        emi_total,
        due_date, issued_at,
        is_live, created_by,
        tax_breakdown
    ) VALUES (
        p_contract_id, p_tenant_id, v_invoice_number, v_invoice_type,
        COALESCE(v_contract.total_value, 0),
        COALESCE(v_contract.tax_total, 0),
        COALESCE(v_contract.grand_total, 0),
        COALESCE(v_contract.currency, 'INR'),
        COALESCE(v_contract.grand_total, 0),
        'unpaid',
        COALESCE(v_contract.payment_mode, 'prepaid'),
        CASE WHEN v_contract.payment_mode = 'emi'
             THEN v_contract.emi_months
             ELSE NULL
        END,
        CURRENT_DATE, NOW(),
        v_contract.is_live, p_created_by,
        COALESCE(v_contract.tax_breakdown, '[]'::jsonb)
    )
    RETURNING id INTO v_invoice_id;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'contract_id', p_contract_id,
            'invoice_id', v_invoice_id,
            'invoice_number', v_invoice_number,
            'invoice_type', v_invoice_type,
            'payment_mode', COALESCE(v_contract.payment_mode, 'prepaid'),
            'emi_months', v_contract.emi_months,
            'total_amount', COALESCE(v_contract.grand_total, 0),
            'currency', COALESCE(v_contract.currency, 'INR')
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to generate invoices',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$function$;

-- ============================================================================
-- run_contract_event_scanner — draft-invoice creation path, INVOICE sequence
-- (t_invoices.invoice_number). Only STEP 4's invoice-number generation
-- changed; every other step is untouched.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.run_contract_event_scanner(p_service_lead_days integer DEFAULT 7, p_billing_lead_days integer DEFAULT 7, p_payment_reminder_lead_days integer DEFAULT 3, p_appointment_lead_days integer DEFAULT 6, p_max_rows integer DEFAULT 500)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_row               RECORD;
    v_email             TEXT;
    v_mobile            TEXT;
    v_channel           TEXT;
    v_contact           TEXT;
    v_template          TEXT;
    v_template_vars     JSONB;
    v_jtd_id            UUID;
    v_invoice_id        UUID;
    v_invoice_number    TEXT;
    v_seq               JSONB;
    v_healing_attempt   INTEGER;
    v_scanner_tax_amount    NUMERIC;
    v_scanner_tax_breakdown JSONB;
    c_marked_due        INT := 0;
    c_marked_overdue    INT := 0;
    c_service_reminders INT := 0;
    c_invoices_created  INT := 0;
    c_invoices_linked   INT := 0;
    c_payment_reminders INT := 0;
    c_appointments_requested INT := 0;
    c_skipped_no_contact INT := 0;
    c_skipped_no_amount INT := 0;
    c_skipped_by_rule   INT := 0;
    c_errors            INT := 0;
    v_error_samples     TEXT[] := '{}';
BEGIN
    IF NOT pg_try_advisory_xact_lock(hashtext('run_contract_event_scanner')::BIGINT) THEN
        RETURN jsonb_build_object('success', true, 'skipped', true,
                                  'reason', 'another scanner run is in progress');
    END IF;

    -- STEP 1: scheduled/due -> overdue
    FOR v_row IN
        SELECT e.id, e.tenant_id, e.status
        FROM t_contract_events e
        JOIN t_contracts c ON c.id = e.contract_id
                          AND c.is_active = true AND c.status = 'active'
        WHERE e.is_active = true
          AND e.status IN ('scheduled', 'due')
          AND e.scheduled_date < date_trunc('day', now())
        ORDER BY e.scheduled_date
        LIMIT p_max_rows
        FOR UPDATE OF e SKIP LOCKED
    LOOP
        BEGIN
            UPDATE t_contract_events
            SET status = 'overdue', version = version + 1, updated_at = now()
            WHERE id = v_row.id;

            INSERT INTO t_contract_event_audit
                (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
            VALUES
                (v_row.id, v_row.tenant_id, 'status', v_row.status, 'overdue', NULL, 'VaNi Scanner', 'Auto: past scheduled date');

            c_marked_overdue := c_marked_overdue + 1;
        EXCEPTION WHEN OTHERS THEN
            c_errors := c_errors + 1;
            IF COALESCE(array_length(v_error_samples, 1), 0) < 5 THEN
                v_error_samples := v_error_samples || format('[overdue %s] %s', v_row.id, SQLERRM);
            END IF;
        END;
    END LOOP;

    -- STEP 2: scheduled -> due (RULES V3: per-tenant due windows)
    FOR v_row IN
        SELECT e.id, e.tenant_id, e.status
        FROM t_contract_events e
        JOIN t_contracts c ON c.id = e.contract_id
                          AND c.is_active = true AND c.status = 'active'
        WHERE e.is_active = true
          AND e.status = 'scheduled'
          AND e.scheduled_date >= date_trunc('day', now())
          AND e.scheduled_date <  date_trunc('day', now()) + make_interval(days =>
                CASE WHEN e.event_type = 'billing'
                     THEN vani_rule_int(e.tenant_id, 'billing_due_window', 'lead_days', p_billing_lead_days)
                     ELSE vani_rule_int(e.tenant_id, 'service_due_window', 'lead_days', p_service_lead_days) END + 1)
        ORDER BY e.scheduled_date
        LIMIT p_max_rows
        FOR UPDATE OF e SKIP LOCKED
    LOOP
        BEGIN
            UPDATE t_contract_events
            SET status = 'due', version = version + 1, updated_at = now()
            WHERE id = v_row.id;

            INSERT INTO t_contract_event_audit
                (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
            VALUES
                (v_row.id, v_row.tenant_id, 'status', v_row.status, 'due', NULL, 'VaNi Scanner', 'Auto: inside due window');

            c_marked_due := c_marked_due + 1;
        EXCEPTION WHEN OTHERS THEN
            c_errors := c_errors + 1;
            IF COALESCE(array_length(v_error_samples, 1), 0) < 5 THEN
                v_error_samples := v_error_samples || format('[due %s] %s', v_row.id, SQLERRM);
            END IF;
        END;
    END LOOP;

    -- STEP 2b: appointment auto-request (RULES V3: enabled + lead + backlog cutoff)
    FOR v_row IN
        SELECT e.id, e.tenant_id, e.contract_id, e.scheduled_date, e.is_live
        FROM t_contract_events e
        JOIN t_contracts c ON c.id = e.contract_id
                          AND c.is_active = true AND c.status = 'active'
        WHERE e.is_active = true
          AND e.event_type = 'service'
          AND e.status IN ('due', 'overdue')
          AND vani_rule_enabled(e.tenant_id, 'appointment_request')
          AND e.scheduled_date <  date_trunc('day', now()) + make_interval(days =>
                vani_rule_int(e.tenant_id, 'appointment_request', 'lead_days', p_appointment_lead_days) + 1)
          AND e.scheduled_date >= date_trunc('day', now()) - make_interval(days =>
                vani_rule_int(e.tenant_id, 'appointment_request', 'backlog_cutoff_days', 30))
          AND NOT EXISTS (
              SELECT 1 FROM t_appointments a
              WHERE a.event_id = e.id AND a.is_active = true
          )
        ORDER BY e.scheduled_date
        LIMIT p_max_rows
        FOR UPDATE OF e SKIP LOCKED
    LOOP
        BEGIN
            INSERT INTO t_appointments
                (tenant_id, contract_id, event_id, status, proposed_slots, is_live, notes)
            VALUES
                (v_row.tenant_id, v_row.contract_id, v_row.id, 'requested',
                 jsonb_build_array(jsonb_build_object('slot', v_row.scheduled_date, 'note', 'event date')),
                 COALESCE(v_row.is_live, true),
                 'Auto-requested by scanner — contact the customer to agree a slot');

            c_appointments_requested := c_appointments_requested + 1;
        EXCEPTION
            WHEN unique_violation THEN
                NULL;
            WHEN OTHERS THEN
                c_errors := c_errors + 1;
                IF COALESCE(array_length(v_error_samples, 1), 0) < 5 THEN
                    v_error_samples := v_error_samples || format('[appointment %s] %s', v_row.id, SQLERRM);
                END IF;
        END;
    END LOOP;

    -- STEP 3: service reminders (RULES V3: enabled toggle)
    FOR v_row IN
        SELECT e.id, e.tenant_id, e.scheduled_date, e.block_name, e.is_live,
               c.id AS contract_id, c.contract_number,
               c.buyer_id, c.buyer_name, c.buyer_email, c.buyer_phone,
               t.name AS tenant_name
        FROM t_contract_events e
        JOIN t_contracts c ON c.id = e.contract_id
                          AND c.is_active = true AND c.status = 'active'
        JOIN t_tenants t ON t.id = e.tenant_id
        WHERE e.is_active = true
          AND e.event_type = 'service'
          AND e.status = 'due'
          AND e.reminder_dispatched_at IS NULL
          AND vani_rule_enabled(e.tenant_id, 'service_reminder')
        ORDER BY e.scheduled_date
        LIMIT p_max_rows
        FOR UPDATE OF e SKIP LOCKED
    LOOP
        BEGIN
            v_email := COALESCE(
                NULLIF(TRIM(v_row.buyer_email), ''),
                (SELECT ch.value FROM t_contact_channels ch
                 WHERE ch.contact_id = v_row.buyer_id AND ch.channel_type = 'email'
                   AND NULLIF(TRIM(ch.value), '') IS NOT NULL
                 ORDER BY ch.is_primary DESC NULLS LAST, ch.created_at
                 LIMIT 1));
            v_mobile := COALESCE(
                NULLIF(TRIM(v_row.buyer_phone), ''),
                (SELECT ch.value FROM t_contact_channels ch
                 WHERE ch.contact_id = v_row.buyer_id AND ch.channel_type IN ('mobile', 'whatsapp')
                   AND NULLIF(TRIM(ch.value), '') IS NOT NULL
                 ORDER BY CASE ch.channel_type WHEN 'mobile' THEN 0 ELSE 1 END,
                          ch.is_primary DESC NULLS LAST, ch.created_at
                 LIMIT 1));

            IF v_email IS NOT NULL THEN
                v_channel := 'email';  v_contact := v_email;  v_template := 'service_reminder_email_v1';
            ELSIF v_mobile IS NOT NULL THEN
                v_channel := 'sms';    v_contact := v_mobile; v_template := 'service_reminder_sms_v1';
            ELSE
                UPDATE t_contract_events SET reminder_dispatched_at = now() WHERE id = v_row.id;
                c_skipped_no_contact := c_skipped_no_contact + 1;
                CONTINUE;
            END IF;

            v_template_vars := jsonb_build_object(
                'customer_name', COALESCE(v_row.buyer_name, 'Customer'),
                'service_type',  COALESCE(v_row.block_name, 'Service visit'),
                'service_date',  to_char(v_row.scheduled_date, 'DD Mon YYYY'),
                'tenant_name',   v_row.tenant_name
            );

            INSERT INTO n_jtd (
                tenant_id, event_type_code, channel_code, source_type_code,
                source_id, source_ref,
                recipient_type, recipient_id, recipient_name, recipient_contact,
                payload, template_key, template_variables, business_context,
                performed_by_type, performed_by_name, is_live
            ) VALUES (
                v_row.tenant_id, 'reminder', v_channel, 'service_reminder',
                v_row.id, v_row.contract_number,
                'contact', v_row.buyer_id, v_row.buyer_name, v_contact,
                jsonb_build_object(
                    'recipient_data', jsonb_strip_nulls(jsonb_build_object(
                        'name',   v_row.buyer_name,
                        'email',  v_email,
                        'mobile', v_mobile)),
                    'template_data', v_template_vars
                ),
                v_template, v_template_vars,
                jsonb_build_object(
                    'contract_id',     v_row.contract_id,
                    'contract_number', v_row.contract_number,
                    'event_id',        v_row.id,
                    'origin',          'contract_event_scanner'
                ),
                'system', 'VaNi Scanner', COALESCE(v_row.is_live, true)
            )
            RETURNING id INTO v_jtd_id;

            UPDATE t_contract_events
            SET reminder_jtd_id = v_jtd_id, reminder_dispatched_at = now()
            WHERE id = v_row.id;

            c_service_reminders := c_service_reminders + 1;
        EXCEPTION WHEN OTHERS THEN
            c_errors := c_errors + 1;
            IF COALESCE(array_length(v_error_samples, 1), 0) < 5 THEN
                v_error_samples := v_error_samples || format('[service_reminder %s] %s', v_row.id, SQLERRM);
            END IF;
        END;
    END LOOP;

    -- STEP 4: billing events -> link or draft invoice (RULES V3: draft gated)
    -- tax_amount/tax_breakdown proration added (was hardcoded to 0 — the
    -- draft-invoice path never carried any tax, undercounting a tenant's
    -- GST/tax liability the moment a draft was ever created). tax_amount
    -- prorates by (event.amount / contract.total_value) * contract.tax_total;
    -- tax_breakdown scales each component by (event.amount / total_value) —
    -- documented as an approximation (proportional to this event's share of
    -- the whole contract), not exact per-line tax assignment, since none
    -- exists in the schema.
    FOR v_row IN
        SELECT e.id, e.tenant_id, e.contract_id, e.amount, e.currency,
               e.billing_cycle_label, e.sequence_number, e.total_occurrences,
               e.block_id, e.scheduled_date, e.is_live,
               c.contract_type, c.payment_mode, c.contract_number,
               c.tax_total, c.total_value, c.tax_breakdown
        FROM t_contract_events e
        JOIN t_contracts c ON c.id = e.contract_id
                          AND c.is_active = true AND c.status = 'active'
        WHERE e.is_active = true
          AND e.event_type = 'billing'
          AND e.status IN ('due', 'overdue')
          AND e.invoice_id IS NULL
        ORDER BY e.scheduled_date
        LIMIT p_max_rows
        FOR UPDATE OF e SKIP LOCKED
    LOOP
        BEGIN
            IF v_row.amount IS NULL OR v_row.amount <= 0 THEN
                c_skipped_no_amount := c_skipped_no_amount + 1;
                CONTINUE;
            END IF;

            SELECT i.id INTO v_invoice_id
            FROM t_invoices i
            WHERE i.contract_id = v_row.contract_id
              AND i.is_active = true
              AND i.contract_event_id IS NULL
              AND i.status NOT IN ('cancelled', 'bad_debt', 'adjustment')
            ORDER BY i.created_at
            LIMIT 1;

            IF v_invoice_id IS NOT NULL THEN
                UPDATE t_contract_events
                SET invoice_id = v_invoice_id, updated_at = now()
                WHERE id = v_row.id;

                INSERT INTO t_contract_event_audit
                    (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
                VALUES
                    (v_row.id, v_row.tenant_id, 'invoice_id', NULL, v_invoice_id::TEXT, NULL, 'VaNi Scanner', 'Auto: linked to existing contract invoice');

                c_invoices_linked := c_invoices_linked + 1;
            ELSE
                IF NOT vani_rule_enabled(v_row.tenant_id, 'draft_invoice') THEN
                    c_skipped_by_rule := c_skipped_by_rule + 1;
                    CONTINUE;
                END IF;

                v_scanner_tax_amount := COALESCE(
                    ROUND(v_row.amount * (COALESCE(v_row.tax_total, 0) / NULLIF(v_row.total_value, 0)), 2),
                    0
                );

                SELECT COALESCE(jsonb_agg(
                    jsonb_build_object(
                        'tax_rate_id', comp->>'tax_rate_id',
                        'name',        comp->>'name',
                        'rate',        (comp->>'rate')::numeric,
                        'amount',      ROUND(((comp->>'amount')::numeric) * (v_row.amount / NULLIF(v_row.total_value, 0)), 2)
                    )
                ), '[]'::jsonb)
                INTO v_scanner_tax_breakdown
                FROM jsonb_array_elements(COALESCE(v_row.tax_breakdown, '[]'::jsonb)) AS comp;

                -- Self-healing against cross-environment collisions — see
                -- migration 070_selfheal_sequence_number_collisions.sql header
                v_invoice_number := NULL;
                FOR v_healing_attempt IN 1..1000 LOOP
                    v_seq := get_next_formatted_sequence('INVOICE', v_row.tenant_id, COALESCE(v_row.is_live, true));
                    v_invoice_number := v_seq->>'formatted';
                    IF v_invoice_number IS NULL THEN
                        RAISE EXCEPTION 'INVOICE sequence returned no number: %', v_seq;
                    END IF;
                    EXIT WHEN NOT EXISTS (
                        SELECT 1 FROM t_invoices
                        WHERE tenant_id = v_row.tenant_id AND invoice_number = v_invoice_number AND is_active = true
                    );
                    IF v_healing_attempt = 1000 THEN
                        RAISE EXCEPTION 'Unable to generate a unique invoice number after 1000 attempts';
                    END IF;
                END LOOP;

                INSERT INTO t_invoices (
                    contract_id, tenant_id, invoice_number, invoice_type,
                    amount, tax_amount, total_amount, currency,
                    amount_paid, balance, status, payment_mode,
                    emi_sequence, emi_total, billing_cycle, block_ids,
                    due_date, issued_at, notes, is_live, contract_event_id,
                    tax_breakdown
                ) VALUES (
                    v_row.contract_id, v_row.tenant_id, v_invoice_number,
                    CASE WHEN v_row.contract_type = 'vendor' THEN 'payable' ELSE 'receivable' END,
                    v_row.amount, v_scanner_tax_amount, v_row.amount + v_scanner_tax_amount, COALESCE(v_row.currency, 'INR'),
                    0, v_row.amount + v_scanner_tax_amount,
                    'draft',
                    v_row.payment_mode,
                    v_row.sequence_number, v_row.total_occurrences,
                    v_row.billing_cycle_label,
                    CASE WHEN v_row.block_id IS NOT NULL AND v_row.block_id <> '_contract'
                         THEN jsonb_build_array(v_row.block_id)
                         ELSE '[]'::jsonb END,
                    v_row.scheduled_date::date,
                    NULL,
                    format('Draft auto-created from billing event %s (%s) — pending approval',
                           COALESCE(v_row.billing_cycle_label, 'billing'), v_row.contract_number),
                    COALESCE(v_row.is_live, true),
                    v_row.id,
                    v_scanner_tax_breakdown
                )
                RETURNING id INTO v_invoice_id;

                UPDATE t_contract_events
                SET invoice_id = v_invoice_id, updated_at = now()
                WHERE id = v_row.id;

                INSERT INTO t_contract_event_audit
                    (event_id, tenant_id, field_changed, old_value, new_value, changed_by, changed_by_name, reason)
                VALUES
                    (v_row.id, v_row.tenant_id, 'invoice_id', NULL, v_invoice_id::TEXT, NULL, 'VaNi Scanner', 'Auto: draft invoice created (pending approval)');

                c_invoices_created := c_invoices_created + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            c_errors := c_errors + 1;
            IF COALESCE(array_length(v_error_samples, 1), 0) < 5 THEN
                v_error_samples := v_error_samples || format('[billing_invoice %s] %s', v_row.id, SQLERRM);
            END IF;
        END;
    END LOOP;

    -- STEP 5: payment reminders (RULES V3: enabled + per-tenant lead)
    FOR v_row IN
        SELECT i.id, i.tenant_id, i.invoice_number, i.balance, i.currency,
               i.due_date, i.is_live,
               c.id AS contract_id, c.contract_number,
               c.buyer_id, c.buyer_name, c.buyer_email,
               t.name AS tenant_name
        FROM t_invoices i
        JOIN t_contracts c ON c.id = i.contract_id
                          AND c.is_active = true AND c.status = 'active'
        JOIN t_tenants t ON t.id = i.tenant_id
        WHERE i.is_active = true
          AND i.status IN ('unpaid', 'partially_paid')
          AND i.last_reminder_at IS NULL
          AND i.due_date IS NOT NULL
          AND vani_rule_enabled(i.tenant_id, 'payment_reminder')
          AND i.due_date <= current_date +
                vani_rule_int(i.tenant_id, 'payment_reminder', 'lead_days', p_payment_reminder_lead_days)
        ORDER BY i.due_date
        LIMIT p_max_rows
        FOR UPDATE OF i SKIP LOCKED
    LOOP
        BEGIN
            v_email := COALESCE(
                NULLIF(TRIM(v_row.buyer_email), ''),
                (SELECT ch.value FROM t_contact_channels ch
                 WHERE ch.contact_id = v_row.buyer_id AND ch.channel_type = 'email'
                   AND NULLIF(TRIM(ch.value), '') IS NOT NULL
                 ORDER BY ch.is_primary DESC NULLS LAST, ch.created_at
                 LIMIT 1));

            IF v_email IS NULL THEN
                UPDATE t_invoices SET last_reminder_at = now() WHERE id = v_row.id;
                c_skipped_no_contact := c_skipped_no_contact + 1;
                CONTINUE;
            END IF;

            v_template_vars := jsonb_build_object(
                'customer_name',  COALESCE(v_row.buyer_name, 'Customer'),
                'invoice_number', v_row.invoice_number,
                'amount',         COALESCE(v_row.currency, 'INR') || ' ' || to_char(v_row.balance, 'FM999,999,999,990.00'),
                'due_date',       to_char(v_row.due_date, 'DD Mon YYYY'),
                'tenant_name',    v_row.tenant_name
            );

            INSERT INTO n_jtd (
                tenant_id, event_type_code, channel_code, source_type_code,
                source_id, source_ref,
                recipient_type, recipient_id, recipient_name, recipient_contact,
                payload, template_key, template_variables, business_context,
                performed_by_type, performed_by_name, is_live
            ) VALUES (
                v_row.tenant_id, 'reminder', 'email', 'payment_due',
                v_row.id, v_row.invoice_number,
                'contact', v_row.buyer_id, v_row.buyer_name, v_email,
                jsonb_build_object(
                    'recipient_data', jsonb_strip_nulls(jsonb_build_object(
                        'name',  v_row.buyer_name,
                        'email', v_email)),
                    'template_data', v_template_vars
                ),
                'payment_due_email_v1', v_template_vars,
                jsonb_build_object(
                    'contract_id',     v_row.contract_id,
                    'contract_number', v_row.contract_number,
                    'invoice_id',      v_row.id,
                    'origin',          'contract_event_scanner'
                ),
                'system', 'VaNi Scanner', COALESCE(v_row.is_live, true)
            )
            RETURNING id INTO v_jtd_id;

            UPDATE t_invoices
            SET last_reminder_jtd_id = v_jtd_id, last_reminder_at = now()
            WHERE id = v_row.id;

            c_payment_reminders := c_payment_reminders + 1;
        EXCEPTION WHEN OTHERS THEN
            c_errors := c_errors + 1;
            IF COALESCE(array_length(v_error_samples, 1), 0) < 5 THEN
                v_error_samples := v_error_samples || format('[payment_due %s] %s', v_row.id, SQLERRM);
            END IF;
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'success',                          true,
        'ran_at',                           now(),
        'events_marked_due',                c_marked_due,
        'events_marked_overdue',            c_marked_overdue,
        'service_reminders_enqueued',       c_service_reminders,
        'draft_invoices_created',           c_invoices_created,
        'events_linked_to_existing_invoice', c_invoices_linked,
        'payment_reminders_enqueued',       c_payment_reminders,
        'appointments_requested',           c_appointments_requested,
        'skipped_no_contact',               c_skipped_no_contact,
        'skipped_no_amount',                c_skipped_no_amount,
        'skipped_by_rule',                  c_skipped_by_rule,
        'errors',                           c_errors,
        'error_samples',                    to_jsonb(v_error_samples)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Scanner failed',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$function$;
