-- ============================================================================
-- Migration: Stage 0 Runtime Loop — 004 run_contract_event_scanner()
-- ============================================================================
-- Purpose: THE runtime loop (POA-OPERATIONS-READINESS-2026-07-07, Stage 0).
--          One pass does five things, all idempotent:
--            1. scheduled/due → overdue   (past scheduled_date)
--            2. scheduled     → due       (inside the lead window, per type)
--            3. service events entering 'due' → enqueue service_reminder JTD
--               (inserting into n_jtd IS the dispatch — trg_jtd_enqueue sends
--               to PGMQ, jtd-worker delivers via email/SMS)
--            4. billing events at 'due'/'overdue' with no invoice →
--               LINK to an existing matching contract invoice (activation
--               lump-sum, same amount) or CREATE a 'draft' invoice
--               (manual mode: seller approves/sends — Stage 1 UI)
--            5. open invoices (unpaid/partially_paid) near/past due_date →
--               enqueue ONE payment_due JTD (dunning ladder = VaNi stage)
--
-- Scope guards:
--   - only is_active events/invoices on ACTIVE contracts
--   - draft invoices never enter reminder flows (status filter)
--   - reminders only for events ENTERING 'due' — the historical backlog that
--     jumps straight to 'overdue' is made visible, not spammed
--
-- Concurrency / production hardening:
--   - pg_try_advisory_xact_lock: overlapping cron runs no-op cleanly
--   - FOR UPDATE OF ... SKIP LOCKED: never blocks user edits mid-scan
--   - per-row BEGIN/EXCEPTION: one bad row cannot kill the sweep
--   - version = version + 1 on every event update (optimistic concurrency
--     stays consistent with update_contract_event)
--   - uq_invoices_contract_event (001) makes double-invoicing impossible
--   - invoice numbers via get_next_formatted_sequence (atomic, per-tenant)
--
-- Recipient resolution (live data has buyer_email/buyer_phone = NULL on all
-- contracts): contract.buyer_email → buyer contact's email channel → mobile/
-- whatsapp channel (SMS). No contact at all → row is marked processed
-- (reminder_dispatched_at set, jtd id NULL) and counted skipped_no_contact.
--
-- Templates used (all seeded, system scope):
--   service_reminder_email_v1 / service_reminder_sms_v1 / payment_due_email_v1
--
-- Run manually: SELECT run_contract_event_scanner();
-- Depends on: 001 (columns), 002 ('due' status), jtd-framework 001-003
-- Safe to re-run: Yes — that is the whole point.
-- Applied by: OWNER — project uwyqhzotluikawcboldr
-- ============================================================================

CREATE OR REPLACE FUNCTION run_contract_event_scanner(
    p_service_lead_days          INT DEFAULT 7,   -- scheduled → due window for service events
    p_billing_lead_days          INT DEFAULT 7,   -- scheduled → due window for billing events
    p_payment_reminder_lead_days INT DEFAULT 3,   -- payment_due reminder window before invoice due_date
    p_max_rows                   INT DEFAULT 500  -- per-sweep safety cap
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    c_marked_due        INT := 0;
    c_marked_overdue    INT := 0;
    c_service_reminders INT := 0;
    c_invoices_created  INT := 0;
    c_invoices_linked   INT := 0;
    c_payment_reminders INT := 0;
    c_skipped_no_contact INT := 0;
    c_skipped_no_amount INT := 0;
    c_errors            INT := 0;
    v_error_samples     TEXT[] := '{}';
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: single-flight guard (auto-released at transaction end)
    -- ═══════════════════════════════════════════
    IF NOT pg_try_advisory_xact_lock(hashtext('run_contract_event_scanner')::BIGINT) THEN
        RETURN jsonb_build_object('success', true, 'skipped', true,
                                  'reason', 'another scanner run is in progress');
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: scheduled/due → overdue (past scheduled date)
    -- ═══════════════════════════════════════════
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

    -- ═══════════════════════════════════════════
    -- STEP 2: scheduled → due (inside lead window, today included)
    -- ═══════════════════════════════════════════
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
                     THEN p_billing_lead_days
                     ELSE p_service_lead_days END + 1)
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

    -- ═══════════════════════════════════════════
    -- STEP 3: service events at 'due' → service_reminder JTD (once per event)
    -- ═══════════════════════════════════════════
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
        ORDER BY e.scheduled_date
        LIMIT p_max_rows
        FOR UPDATE OF e SKIP LOCKED
    LOOP
        BEGIN
            -- resolve buyer contact: denormalized fields → contact channels
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
                -- processed, nothing sendable — never rescan this event
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

    -- ═══════════════════════════════════════════
    -- STEP 4: billing events at 'due'/'overdue' with no invoice →
    --         link to matching contract-level invoice OR create a draft
    -- ═══════════════════════════════════════════
    FOR v_row IN
        SELECT e.id, e.tenant_id, e.contract_id, e.amount, e.currency,
               e.billing_cycle_label, e.sequence_number, e.total_occurrences,
               e.block_id, e.scheduled_date, e.is_live,
               c.contract_type, c.payment_mode, c.contract_number
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

            -- An activation-time lump-sum invoice with the same total IS this
            -- event's invoice (generate_contract_invoices creates one per
            -- contract on activation) — link instead of duplicating.
            SELECT i.id INTO v_invoice_id
            FROM t_invoices i
            WHERE i.contract_id = v_row.contract_id
              AND i.is_active = true
              AND i.contract_event_id IS NULL
              AND i.status NOT IN ('cancelled', 'bad_debt')
              AND i.total_amount = v_row.amount
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
                    due_date, issued_at, notes, is_live, contract_event_id
                ) VALUES (
                    v_row.contract_id, v_row.tenant_id, v_invoice_number,
                    CASE WHEN v_row.contract_type = 'vendor' THEN 'payable' ELSE 'receivable' END,
                    v_row.amount, 0, v_row.amount, COALESCE(v_row.currency, 'INR'),
                    0, v_row.amount,
                    'draft',                                   -- manual mode: seller approves/sends (Stage 1)
                    v_row.payment_mode,
                    v_row.sequence_number, v_row.total_occurrences,
                    v_row.billing_cycle_label,
                    CASE WHEN v_row.block_id IS NOT NULL AND v_row.block_id <> '_contract'
                         THEN jsonb_build_array(v_row.block_id)
                         ELSE '[]'::jsonb END,
                    v_row.scheduled_date::date,
                    NULL,                                      -- drafts are not issued yet
                    format('Draft auto-created from billing event %s (%s) — pending approval',
                           COALESCE(v_row.billing_cycle_label, 'billing'), v_row.contract_number),
                    COALESCE(v_row.is_live, true),
                    v_row.id
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

    -- ═══════════════════════════════════════════
    -- STEP 5: open invoices near/past due_date → ONE payment_due JTD
    --         (email only — the only seeded payment_due template;
    --          drafts excluded by the status filter)
    -- ═══════════════════════════════════════════
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
          AND i.due_date <= current_date + p_payment_reminder_lead_days
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
                -- no email and no payment_due SMS template exists — mark
                -- processed so we don't rescan; Stage 1 manual reminder can
                -- still be sent once a contact is added
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

    -- ═══════════════════════════════════════════
    -- Summary (also visible in cron.job_run_details)
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success',                          true,
        'ran_at',                           now(),
        'events_marked_due',                c_marked_due,
        'events_marked_overdue',            c_marked_overdue,
        'service_reminders_enqueued',       c_service_reminders,
        'draft_invoices_created',           c_invoices_created,
        'events_linked_to_existing_invoice', c_invoices_linked,
        'payment_reminders_enqueued',       c_payment_reminders,
        'skipped_no_contact',               c_skipped_no_contact,
        'skipped_no_amount',                c_skipped_no_amount,
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
$$;

-- Internal job — service_role only (pg_cron runs as postgres, unaffected).
REVOKE ALL ON FUNCTION run_contract_event_scanner(INT, INT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION run_contract_event_scanner(INT, INT, INT, INT) TO service_role;
