-- ═══════════════════════════════════════════════════════════════
-- Migration 066: Fix scanner draft-invoice zero-tax hardcode
-- ═══════════════════════════════════════════════════════════════
-- STATUS: Already applied directly to the Supabase project (2026-07-19)
-- via MCP, verified live (in two passes — see "SELF-CAUGHT BUG" below).
-- This file tracks the final, corrected SQL in source control
-- immediately, per the same discipline established in migrations 064/065.
--
-- ROOT CAUSE: run_contract_event_scanner's STEP 4 (per-event DRAFT
-- invoice creation, when no existing contract-level invoice exists to
-- link to) hardcoded `tax_amount = 0` on every INSERT INTO t_invoices,
-- regardless of the contract's own tax configuration. Zero draft
-- invoices existed in production at the time this was found (verified
-- live), so it was latent, not an active undercount — but it would
-- undercount a tenant's tax liability the moment the scanner ever
-- created one.
--
-- Pulled the LIVE function definition via pg_get_functiondef before
-- touching anything (20,782 chars) rather than trust the tracked
-- migration file (operations-loop/013_stage3_scanner_v2.sql) — it had
-- already drifted significantly: the live version has an advisory
-- lock guard, a STEP 2b appointment-auto-request block, and per-tenant
-- VaNi rule gating (vani_rule_enabled/vani_rule_int) on every step,
-- none of which are in the tracked file. Reproducing from the file
-- would have silently reverted all of that.
--
-- FIX: added `c.tax_total, c.total_value, c.tax_breakdown` to STEP 4's
-- event/contract SELECT, two new local variables
-- (v_scanner_tax_amount, v_scanner_tax_breakdown), and replaced the
-- hardcoded `0` with a proration: this event's amount as a fraction of
-- the contract's total_value, applied to tax_total (for the scalar) and
-- to each tax_breakdown component (for the split) — added the
-- tax_breakdown column to the INSERT too, matching what
-- generate_contract_invoices now does (migration 062). Nothing else in
-- the function — every other step (1, 2, 2b, 3, 5) and the return
-- shape — is touched; verified byte-identical via pg_get_functiondef
-- before calling this done.
--
-- Documented as an approximation, not exact per-line tax assignment,
-- since no per-line tax data exists in the schema — same caveat as
-- get_tenant_tax_summary's tax_collected_approx (migration 062).
--
-- SELF-CAUGHT BUG (why this matters for the record): the first applied
-- version used (tax_total / total_value) — the overall tax RATE — as
-- the scaling factor for the tax_breakdown component amounts too. That
-- double-applies the rate (a component amount already IS a tax value,
-- not a base value), producing wrong, too-small numbers. Caught via a
-- read-only proration test against real contract 84637e9c (total_value
-- 18000, tax_total 1980, CGST 1080 + SGST 900) BEFORE this was called
-- done — a half-value event (9000) computed CGST 118.8 + SGST 99
-- instead of the correct CGST 540 + SGST 450 (which sums to the
-- correct tax_amount of 990; the buggy version did not). Corrected
-- immediately: the breakdown's scaling factor is
-- (event.amount / total_value), not (tax_total / total_value).
-- The live database was never queried through the scanner during the
-- ~2-minute window the buggy version was deployed — no draft invoice
-- was ever created with the wrong numbers (0 drafts exist, and the
-- scanner is cron-triggered, not called on-demand).
--
-- VERIFIED LIVE (2026-07-19, final corrected version):
--   - pg_get_functiondef confirms: advisory lock, STEP 2b, the
--     draft_invoice rule gate, and the RETURN shape are all still
--     present/unchanged.
--   - Did NOT invoke the actual scanner function to test — it has real
--     side effects (sends real reminder emails/SMS to real buyers,
--     creates real appointments, marks real events overdue). Instead
--     verified the tax math via a read-only simulation query against
--     real contract data, confirming: tax_amount = 990.00 for a
--     9000-of-18000 event, tax_breakdown [CGST 540, SGST 450] summing
--     to exactly 990.00 (internal consistency check).
-- ═══════════════════════════════════════════════════════════════
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
              AND i.status NOT IN ('cancelled', 'bad_debt')
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

                v_seq := get_next_formatted_sequence('INVOICE', v_row.tenant_id, COALESCE(v_row.is_live, true));
                v_invoice_number := v_seq->>'formatted';
                IF v_invoice_number IS NULL THEN
                    RAISE EXCEPTION 'INVOICE sequence returned no number: %', v_seq;
                END IF;

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
