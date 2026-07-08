-- ============================================================================
-- 017 — VaNi Rules v1 (tenant-configurable automation rules)
-- ============================================================================
-- Owner decisions (2026-07-08):
--   • Rules live in Settings → Automation Rules; VISIBLE to every tenant,
--     EDITABLE only with VaNi trial/subscription ("defaults run for everyone;
--     controlling the automation is VaNi").
--   • Defaults are seeded per tenant at onboarding (tenant creation trigger)
--     + one-time backfill for existing tenants. Runtime always falls back to
--     template defaults (COALESCE), so a missing row can never break anything.
--   • Curated typed rule TEMPLATES with bounded knobs — no free-form IF/THEN.
--     Every template shipped here is actually consumed by scanner v3 below
--     (honesty rule: no no-op rules).
--
-- Contents:
--   1. m_vani_rule_templates (admin-curated catalog) + seed (6 rules)
--   2. t_vani_rules (per-tenant config) + FKs + unique guard
--   3. Helpers vani_rule_int / vani_rule_enabled (used by scanner v3)
--   4. RPCs: get_vani_rules · update_vani_rule · seed_vani_rules
--   5. Seeding: AFTER INSERT trigger on t_tenants + backfill for existing
--   6. Scanner v3: per-tenant rule resolution (CREATE OR REPLACE, same
--      signature as 013 — cron unchanged; params remain system fallbacks)
-- Depends on: 013 (scanner v2), 012 (t_appointments)
-- Safe to re-run: Yes
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Rule template catalog
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS m_vani_rule_templates (
    rule_key        TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    description     TEXT NOT NULL,
    domain          TEXT NOT NULL,               -- 'services' | 'finance'
    default_config  JSONB NOT NULL DEFAULT '{}'::jsonb,
    constraints     JSONB NOT NULL DEFAULT '{}'::jsonb,  -- {field: {min, max}}
    sort_order      INT NOT NULL DEFAULT 100,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO m_vani_rule_templates
    (rule_key, name, description, domain, default_config, constraints, sort_order)
VALUES
    ('service_due_window', 'Service due window',
     'How many days before the visit date a service event becomes "due" (starts reminders and appointment requests).',
     'services', '{"lead_days": 7}', '{"lead_days": {"min": 0, "max": 60}}', 10),
    ('service_reminder', 'Service reminders',
     'Send the customer an automatic reminder when a service visit becomes due.',
     'services', '{}', '{}', 20),
    ('appointment_request', 'Appointment auto-request',
     'Automatically open an appointment request for service visits that need scheduling. The backlog cutoff stops requests for visits already overdue by more than the given days.',
     'services', '{"lead_days": 6, "backlog_cutoff_days": 30}',
     '{"lead_days": {"min": 0, "max": 30}, "backlog_cutoff_days": {"min": 0, "max": 365}}', 30),
    ('billing_due_window', 'Billing due window',
     'How many days before the billing date a billing event becomes "due" (starts invoice drafting).',
     'finance', '{"lead_days": 7}', '{"lead_days": {"min": 0, "max": 60}}', 40),
    ('draft_invoice', 'Auto-draft invoices',
     'Automatically create a draft invoice when a billing event comes due (you approve before sending).',
     'finance', '{}', '{}', 50),
    ('payment_reminder', 'Payment reminders',
     'Send the customer an automatic payment reminder when an invoice approaches its due date.',
     'finance', '{"lead_days": 3}', '{"lead_days": {"min": 0, "max": 30}}', 60)
ON CONFLICT (rule_key) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 2. Per-tenant rules
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS t_vani_rules (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id   UUID NOT NULL REFERENCES t_tenants(id),
    rule_key    TEXT NOT NULL REFERENCES m_vani_rule_templates(rule_key),
    config      JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_enabled  BOOLEAN NOT NULL DEFAULT true,
    version     INT NOT NULL DEFAULT 1,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  UUID,
    CONSTRAINT uq_vani_rules_tenant_rule UNIQUE (tenant_id, rule_key)
);

CREATE INDEX IF NOT EXISTS idx_vani_rules_tenant ON t_vani_rules(tenant_id);

-- ----------------------------------------------------------------------------
-- 3. Resolution helpers (scanner-facing; STABLE, cheap PK lookups)
--    Precedence: tenant rule config → template default → caller fallback.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vani_rule_int(
    p_tenant_id UUID, p_rule_key TEXT, p_field TEXT, p_fallback INT
)
RETURNS INT
LANGUAGE sql STABLE
SET search_path = public
AS $$
    SELECT COALESCE((
        SELECT COALESCE(tr.config ->> p_field, mt.default_config ->> p_field)::int
        FROM m_vani_rule_templates mt
        LEFT JOIN t_vani_rules tr
               ON tr.tenant_id = p_tenant_id AND tr.rule_key = mt.rule_key
        WHERE mt.rule_key = p_rule_key AND mt.is_active = true
    ), p_fallback);
$$;

CREATE OR REPLACE FUNCTION vani_rule_enabled(p_tenant_id UUID, p_rule_key TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
SET search_path = public
AS $$
    SELECT COALESCE((
        SELECT COALESCE(tr.is_enabled, true)
        FROM m_vani_rule_templates mt
        LEFT JOIN t_vani_rules tr
               ON tr.tenant_id = p_tenant_id AND tr.rule_key = mt.rule_key
        WHERE mt.rule_key = p_rule_key AND mt.is_active = true
    ), true);
$$;

-- ----------------------------------------------------------------------------
-- 4a. get_vani_rules — everything the Settings page renders
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_vani_rules(p_tenant_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'TENANT_REQUIRED');
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'rules', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'rule_key',    mt.rule_key,
                'name',        mt.name,
                'description', mt.description,
                'domain',      mt.domain,
                -- defaults first, tenant overrides on top → new template
                -- fields appear automatically for old tenant rows
                'config',      mt.default_config || COALESCE(tr.config, '{}'::jsonb),
                'is_enabled',  COALESCE(tr.is_enabled, true),
                'defaults',    mt.default_config,
                'constraints', mt.constraints,
                'version',     COALESCE(tr.version, 0),
                'is_customized', (tr.id IS NOT NULL AND
                                  (tr.is_enabled = false OR tr.config <> '{}'::jsonb
                                   AND tr.config <> mt.default_config))
            ) ORDER BY mt.sort_order)
            FROM m_vani_rule_templates mt
            LEFT JOIN t_vani_rules tr
                   ON tr.tenant_id = p_tenant_id AND tr.rule_key = mt.rule_key
            WHERE mt.is_active = true
        ), '[]'::jsonb)
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 4b. update_vani_rule — validated, bounded, optimistic-concurrency upsert
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_vani_rule(
    p_tenant_id        UUID,
    p_rule_key         TEXT,
    p_config           JSONB,
    p_is_enabled       BOOLEAN,
    p_expected_version INT DEFAULT NULL,
    p_updated_by       UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tpl    m_vani_rule_templates%ROWTYPE;
    v_key    TEXT;
    v_val    NUMERIC;
    v_min    NUMERIC;
    v_max    NUMERIC;
    v_row    t_vani_rules%ROWTYPE;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'TENANT_REQUIRED');
    END IF;

    SELECT * INTO v_tpl FROM m_vani_rule_templates
    WHERE rule_key = p_rule_key AND is_active = true;
    IF v_tpl.rule_key IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_RULE');
    END IF;

    -- Validate: only known fields, numeric bounds from the template
    FOR v_key IN SELECT jsonb_object_keys(COALESCE(p_config, '{}'::jsonb))
    LOOP
        IF NOT (v_tpl.default_config ? v_key) THEN
            RETURN jsonb_build_object('success', false, 'error', 'UNKNOWN_FIELD',
                                      'field', v_key);
        END IF;
        IF jsonb_typeof(p_config -> v_key) <> 'number' THEN
            RETURN jsonb_build_object('success', false, 'error', 'INVALID_TYPE',
                                      'field', v_key);
        END IF;
        v_val := (p_config ->> v_key)::numeric;
        v_min := (v_tpl.constraints -> v_key ->> 'min')::numeric;
        v_max := (v_tpl.constraints -> v_key ->> 'max')::numeric;
        IF (v_min IS NOT NULL AND v_val < v_min) OR (v_max IS NOT NULL AND v_val > v_max) THEN
            RETURN jsonb_build_object('success', false, 'error', 'OUT_OF_BOUNDS',
                                      'field', v_key, 'min', v_min, 'max', v_max);
        END IF;
    END LOOP;

    -- Upsert with optimistic concurrency (works even if the row was never seeded)
    INSERT INTO t_vani_rules (tenant_id, rule_key, config, is_enabled, updated_by)
    VALUES (p_tenant_id, p_rule_key, COALESCE(p_config, '{}'::jsonb),
            COALESCE(p_is_enabled, true), p_updated_by)
    ON CONFLICT (tenant_id, rule_key) DO UPDATE SET
        config     = COALESCE(p_config, t_vani_rules.config),
        is_enabled = COALESCE(p_is_enabled, t_vani_rules.is_enabled),
        version    = t_vani_rules.version + 1,
        updated_at = now(),
        updated_by = COALESCE(p_updated_by, t_vani_rules.updated_by)
    WHERE p_expected_version IS NULL
       OR t_vani_rules.version = p_expected_version
    RETURNING * INTO v_row;

    IF v_row.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'VERSION_CONFLICT');
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'rule_key', v_row.rule_key,
        'config', v_tpl.default_config || v_row.config,
        'is_enabled', v_row.is_enabled,
        'version', v_row.version
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 4c. seed_vani_rules — copy template defaults for a tenant (idempotent)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seed_vani_rules(p_tenant_id UUID)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_count INT;
BEGIN
    IF p_tenant_id IS NULL THEN RETURN 0; END IF;

    INSERT INTO t_vani_rules (tenant_id, rule_key, config, is_enabled)
    SELECT p_tenant_id, mt.rule_key, mt.default_config, true
    FROM m_vani_rule_templates mt
    WHERE mt.is_active = true
    ON CONFLICT (tenant_id, rule_key) DO NOTHING;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- ----------------------------------------------------------------------------
-- 5. Seeding: new tenants at creation (= onboarding start), existing backfilled
--    Trigger swallows errors — rule seeding must never block tenant signup.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_seed_vani_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        PERFORM seed_vani_rules(NEW.id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'seed_vani_rules failed for tenant %: %', NEW.id, SQLERRM;
    END;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tenants_seed_vani_rules ON t_tenants;
CREATE TRIGGER trg_tenants_seed_vani_rules
    AFTER INSERT ON t_tenants
    FOR EACH ROW EXECUTE FUNCTION trg_fn_seed_vani_rules();

-- Backfill every existing tenant
INSERT INTO t_vani_rules (tenant_id, rule_key, config, is_enabled)
SELECT t.id, mt.rule_key, mt.default_config, true
FROM t_tenants t
CROSS JOIN m_vani_rule_templates mt
WHERE mt.is_active = true
ON CONFLICT (tenant_id, rule_key) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Grants
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION get_vani_rules(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_vani_rules(UUID) TO service_role;
REVOKE ALL ON FUNCTION update_vani_rule(UUID, TEXT, JSONB, BOOLEAN, INT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_vani_rule(UUID, TEXT, JSONB, BOOLEAN, INT, UUID) TO service_role;
REVOKE ALL ON FUNCTION seed_vani_rules(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION seed_vani_rules(UUID) TO service_role;

-- ----------------------------------------------------------------------------
-- 6. Scanner v3 — same signature as 013 (cron unchanged); params are now the
--    SYSTEM FALLBACK, per-tenant rules take precedence. Marked RULES V3.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION run_contract_event_scanner(
    p_service_lead_days          INT DEFAULT 7,
    p_billing_lead_days          INT DEFAULT 7,
    p_payment_reminder_lead_days INT DEFAULT 3,
    p_appointment_lead_days      INT DEFAULT 6,
    p_max_rows                   INT DEFAULT 500
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
    c_appointments_requested INT := 0;
    c_skipped_no_contact INT := 0;
    c_skipped_no_amount INT := 0;
    c_skipped_by_rule   INT := 0;        -- RULES V3
    c_errors            INT := 0;
    v_error_samples     TEXT[] := '{}';
BEGIN
    -- STEP 0: single-flight guard
    IF NOT pg_try_advisory_xact_lock(hashtext('run_contract_event_scanner')::BIGINT) THEN
        RETURN jsonb_build_object('success', true, 'skipped', true,
                                  'reason', 'another scanner run is in progress');
    END IF;

    -- STEP 1: scheduled/due → overdue (past scheduled date)
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

    -- STEP 2: scheduled → due — RULES V3: per-tenant due windows
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

    -- STEP 2b: appointment auto-request — RULES V3: enabled toggle +
    -- per-tenant lead + BACKLOG CUTOFF (skip events overdue > cutoff days)
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

    -- STEP 3: service reminders — RULES V3: enabled toggle
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

    -- STEP 4: billing events → link or draft invoice — RULES V3: linking to an
    -- existing invoice always allowed; CREATING drafts gated by 'draft_invoice'
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
                -- RULES V3: tenant switched auto-drafting off → leave the event
                -- uninvoiced (it is rescanned and catches up if re-enabled)
                IF NOT vani_rule_enabled(v_row.tenant_id, 'draft_invoice') THEN
                    c_skipped_by_rule := c_skipped_by_rule + 1;
                    CONTINUE;
                END IF;

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

    -- STEP 5: payment reminders — RULES V3: enabled toggle + per-tenant lead
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
$$;

REVOKE ALL ON FUNCTION run_contract_event_scanner(INT, INT, INT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION run_contract_event_scanner(INT, INT, INT, INT, INT) TO service_role;
