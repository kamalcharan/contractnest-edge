-- =====================================================================
-- 021_close_the_spend_loop.sql   —   BUSINESS MODEL V4, PHASE B
--
-- Until now credits only ever went UP.
--
-- The release machinery has been in place since jtd-framework/003 —
-- a 'no_credits' status, FIFO release on topup, a daily expiry cron,
-- an admin dashboard that counts what is waiting. It has never fired,
-- because NOTHING IN THE PRODUCT EVER WROTE status_code = 'no_credits'
-- and nothing ever called deduct_credits. The worker sent, and the
-- balance stayed where it was.
--
-- This closes the loop in three places:
--
--   1. AT CREATION — a BEFORE INSERT trigger on n_jtd parks the row as
--      'no_credits' when the tenant cannot pay for it. A trigger, not a
--      check in each caller, because JTDs are inserted from many places
--      and a gate that a new caller can skip is not a gate.
--
--   2. AT DISPATCH — the worker reserves before handing to the provider,
--      charges on provider success, releases on failure. The reservation
--      is what stops two workers spending the same last credit.
--
--   3. IN THE JOURNAL — every deduction carries reference_type = 'jtd'
--      and the JTD's id, so the chain reads end to end:
--      contract → grant → balance → JTD → provider message id.
--
-- WHAT IS DELIBERATELY NOT CHARGED
--
--   · Identity/access messages (user_invite, user_created,
--     contract_signoff). These are already exempt from the TEST-env
--     guardrail, the channel kill switch and the per-message-type toggle
--     in jtd-worker/index.ts, for the same reason: a tenant who cannot
--     invite a teammate or let a counterparty reach the signing page has
--     an outage, not a saving. Running out of credits must not lock
--     someone out of the platform.
--   · TEST environment (is_live = false). Test-env email and WhatsApp
--     are already blocked from real delivery; charging real credits for
--     a send that never happens would be theft.
--   · billing_mode = 'exempt' (the platform tenant) and any tenant with
--     no context row at all.
--
-- FAIL-OPEN. If the metering lookup errors, the message goes. Same
-- posture as the existing vani_rule_enabled gate in the worker: a
-- metering outage must never become a silent send stoppage.
-- =====================================================================


-- ── 1. 'no_credits' for the other event types that actually send ──────
-- 003 created this status for 'notification' and 'reminder' only.
-- 'payment' and 'document' also flow through the queue and the worker.
INSERT INTO n_jtd_statuses (
    event_type_code, code, name, description, status_type,
    is_initial, is_terminal, is_success, is_failure, allows_retry,
    display_order, is_active)
SELECT et.code, 'no_credits', 'No Credits',
       'Blocked due to insufficient credits. Will be sent when credits are topped up.',
       'waiting', FALSE, FALSE, FALSE, FALSE, FALSE, 15, TRUE
FROM n_jtd_event_types et
WHERE et.code IN ('payment', 'document')
  AND NOT EXISTS (
      SELECT 1 FROM n_jtd_statuses s
      WHERE s.event_type_code = et.code AND s.code = 'no_credits');


-- ── 2. status-flow edges ──────────────────────────────────────────────
-- created → no_credits already exists for notification/reminder. The new
-- edge everywhere is pending → no_credits: the worker can find the pool
-- empty AFTER the message was queued, when another send drained it in
-- between. Without the edge the audit trail would record a valid
-- transition as invalid.
DO $do$
DECLARE
    v_et TEXT;
BEGIN
    FOREACH v_et IN ARRAY ARRAY['notification', 'reminder', 'payment', 'document']
    LOOP
        BEGIN
            PERFORM insert_status_flow_by_codes(v_et, 'created',    'no_credits');
            PERFORM insert_status_flow_by_codes(v_et, 'pending',    'no_credits');
            PERFORM insert_status_flow_by_codes(v_et, 'queued',     'no_credits');
            PERFORM insert_status_flow_by_codes(v_et, 'no_credits', 'pending');
            PERFORM insert_status_flow_by_codes(v_et, 'no_credits', 'expired');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'flow edge skipped for %: %', v_et, SQLERRM;
        END;
    END LOOP;
END $do$;


-- ── 3. one definition of "can this tenant afford one send" ────────────
-- The channel's own pool plus the shared pooled bucket, net of holds.
-- Used by the creation gate, by the worker's reserve, and by
-- release_waiting_jtds, so all three agree on the same number.
CREATE OR REPLACE FUNCTION public.fn_channel_credit_available(
    p_tenant_id UUID, p_channel TEXT)
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS
$function$
    SELECT GREATEST(0,
        (CASE p_channel
           WHEN 'whatsapp' THEN COALESCE(c.credits_whatsapp, 0)
           WHEN 'sms'      THEN COALESCE(c.credits_sms, 0)
           WHEN 'email'    THEN COALESCE(c.credits_email, 0)
           WHEN 'inapp'    THEN COALESCE(c.credits_inapp, 0)
           ELSE 0 END)
        + COALESCE(c.credits_pooled, 0)
        - COALESCE((c.credits_reserved->>('notification:' || p_channel))::INT, 0)
        - COALESCE((c.credits_reserved->>'notification:_')::INT, 0))
    FROM t_tenant_context c
    WHERE c.tenant_id = p_tenant_id
    ORDER BY (c.product_code = 'contractnest') DESC
    LIMIT 1;
$function$;


-- ── 4. what is never charged ──────────────────────────────────────────
-- Kept in SQL so the creation gate and the worker's RPCs cannot drift
-- from each other. The identity list mirrors GATE_EXEMPT_SOURCE_TYPES in
-- jtd-worker/index.ts — change both together.
CREATE OR REPLACE FUNCTION public.fn_jtd_credit_exempt(
    p_source_type TEXT, p_is_live BOOLEAN, p_channel TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS
$function$
    SELECT p_source_type IN ('user_invite', 'user_created', 'contract_signoff')
        OR COALESCE(p_is_live, TRUE) = FALSE
        OR p_channel IS NULL
        OR p_channel NOT IN ('whatsapp', 'sms', 'email', 'inapp');
$function$;


-- ── 5. the creation gate ──────────────────────────────────────────────
-- Named trg_jtd_credit_gate so it sorts BEFORE trg_jtd_enqueue: same
-- timing (BEFORE INSERT), and Postgres fires same-timing triggers in
-- name order. It must run first — trg_jtd_enqueue only queues rows whose
-- status_code is still 'created', so setting 'no_credits' here is what
-- keeps an unpayable message out of the queue entirely.
CREATE OR REPLACE FUNCTION public.trg_fn_jtd_credit_gate()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$function$
DECLARE
    v_mode  TEXT;
    v_avail INTEGER;
BEGIN
    IF NEW.status_code IS DISTINCT FROM 'created' THEN
        RETURN NEW;
    END IF;

    IF fn_jtd_credit_exempt(NEW.source_type_code, NEW.is_live, NEW.channel_code) THEN
        RETURN NEW;
    END IF;

    SELECT billing_mode INTO v_mode
    FROM t_tenant_context
    WHERE tenant_id = NEW.tenant_id
    ORDER BY (product_code = 'contractnest') DESC
    LIMIT 1;

    -- No context row, or the platform tenant: not metered, never parked.
    IF v_mode IS NULL OR v_mode = 'exempt' THEN
        RETURN NEW;
    END IF;

    v_avail := fn_channel_credit_available(NEW.tenant_id, NEW.channel_code);

    IF COALESCE(v_avail, 0) < 1 THEN
        NEW.status_code       := 'no_credits';
        NEW.status_changed_at := NOW();
        NEW.transition_note   := 'Parked at creation: no ' || NEW.channel_code || ' credits';
    END IF;

    RETURN NEW;

EXCEPTION WHEN OTHERS THEN
    -- Fail open. A broken meter must not stop a tenant's messages.
    RAISE WARNING 'jtd credit gate failed for tenant % (%): %',
        NEW.tenant_id, NEW.id, SQLERRM;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_jtd_credit_gate ON public.n_jtd;
CREATE TRIGGER trg_jtd_credit_gate
    BEFORE INSERT ON public.n_jtd
    FOR EACH ROW EXECUTE FUNCTION public.trg_fn_jtd_credit_gate();


-- ── 6. idempotency backstop ───────────────────────────────────────────
-- The worker checks the journal before charging, but a retry racing
-- itself would slip through a check-then-act. One deduction per JTD,
-- enforced by the database.
CREATE UNIQUE INDEX IF NOT EXISTS uq_credit_journal_jtd_deduction
    ON public.t_credit_journal (reference_id)
    WHERE reference_type = 'jtd'
      AND transaction_type = 'deduction'
      AND reference_id IS NOT NULL;


-- ── 7. the three worker RPCs ──────────────────────────────────────────
-- The worker calls these rather than reserve/deduct directly, so all the
-- exemption rules, the pool choice and the idempotency live in one place
-- instead of being restated in TypeScript.

-- Take a hold before handing the message to the provider.
CREATE OR REPLACE FUNCTION public.jtd_reserve_credit(p_jtd_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$function$
DECLARE
    v_jtd   RECORD;
    v_mode  TEXT;
    v_pool  TEXT;
    v_state RECORD;
    v_r     RECORD;
BEGIN
    SELECT id, tenant_id, channel_code, source_type_code, is_live, metadata
    INTO v_jtd FROM n_jtd WHERE id = p_jtd_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'reason', 'jtd_not_found');
    END IF;

    IF fn_jtd_credit_exempt(v_jtd.source_type_code, v_jtd.is_live, v_jtd.channel_code) THEN
        RETURN jsonb_build_object('success', true, 'metered', false, 'reason', 'exempt');
    END IF;

    SELECT billing_mode INTO v_mode
    FROM t_tenant_context
    WHERE tenant_id = v_jtd.tenant_id
    ORDER BY (product_code = 'contractnest') DESC
    LIMIT 1;

    IF v_mode IS NULL OR v_mode = 'exempt' THEN
        RETURN jsonb_build_object('success', true, 'metered', false, 'reason', 'not_metered');
    END IF;

    -- A retry of an already-paid send must not pay again.
    IF EXISTS (SELECT 1 FROM t_credit_journal
               WHERE reference_type = 'jtd' AND reference_id = p_jtd_id
                 AND transaction_type = 'deduction') THEN
        RETURN jsonb_build_object('success', true, 'metered', false, 'reason', 'already_charged');
    END IF;

    -- A hold left over from an earlier attempt is reused, not doubled.
    IF (v_jtd.metadata->'credit'->>'pool') IS NOT NULL
       AND (v_jtd.metadata->'credit'->>'charged') IS NULL THEN
        RETURN jsonb_build_object('success', true, 'metered', true, 'reason', 'already_reserved',
            'pool', v_jtd.metadata->'credit'->>'pool');
    END IF;

    -- The channel's own pool first, the shared pooled bucket as fallback.
    SELECT * INTO v_state
    FROM fn_credit_state(v_jtd.tenant_id, 'notification', v_jtd.channel_code, FALSE);

    IF FOUND AND (v_state.gross - v_state.reserved) >= 1 THEN
        v_pool := v_jtd.channel_code;
    ELSE
        SELECT * INTO v_state
        FROM fn_credit_state(v_jtd.tenant_id, 'notification', NULL, FALSE);

        IF FOUND AND (v_state.gross - v_state.reserved) >= 1 THEN
            v_pool := NULL;   -- pooled bucket
        ELSE
            RETURN jsonb_build_object('success', false, 'reason', 'no_credits',
                'channel', v_jtd.channel_code);
        END IF;
    END IF;

    SELECT * INTO v_r FROM reserve_credits(v_jtd.tenant_id, 'notification', v_pool, 1);

    IF NOT COALESCE(v_r.success, FALSE) THEN
        RETURN jsonb_build_object('success', false, 'reason', 'no_credits',
            'error', v_r.error_message, 'channel', v_jtd.channel_code);
    END IF;

    UPDATE n_jtd
    SET metadata = jsonb_set(COALESCE(metadata, '{}'::JSONB), '{credit}',
            jsonb_build_object('pool', COALESCE(v_pool, '_'),
                               'reserved', 1,
                               'reserved_at', NOW()), TRUE)
    WHERE id = p_jtd_id;

    RETURN jsonb_build_object('success', true, 'metered', true,
        'pool', COALESCE(v_pool, '_'), 'available_after', v_r.available_after);

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'jtd_reserve_credit failed for %: %', p_jtd_id, SQLERRM;
    RETURN jsonb_build_object('success', true, 'metered', false, 'reason', 'meter_error');
END;
$function$;


-- Convert the hold into a spend, once the provider has accepted it.
CREATE OR REPLACE FUNCTION public.jtd_charge_credit(p_jtd_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$function$
DECLARE
    v_jtd  RECORD;
    v_pool TEXT;
    v_res  JSONB;
BEGIN
    SELECT id, tenant_id, channel_code, source_type_code, is_live, metadata
    INTO v_jtd FROM n_jtd WHERE id = p_jtd_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'reason', 'jtd_not_found');
    END IF;

    IF EXISTS (SELECT 1 FROM t_credit_journal
               WHERE reference_type = 'jtd' AND reference_id = p_jtd_id
                 AND transaction_type = 'deduction') THEN
        RETURN jsonb_build_object('success', true, 'charged', false, 'reason', 'already_charged');
    END IF;

    IF (v_jtd.metadata->'credit'->>'pool') IS NULL THEN
        -- Nothing was reserved, so this send was exempt or unmetered.
        RETURN jsonb_build_object('success', true, 'charged', false, 'reason', 'no_reservation');
    END IF;

    v_pool := NULLIF(v_jtd.metadata->'credit'->>'pool', '_');

    -- deduct_credits consumes the hold it finds, so reserve → deduct nets
    -- to exactly one credit rather than one held plus one spent.
    v_res := deduct_credits(v_jtd.tenant_id, 'notification', 1, v_pool,
                            'jtd', p_jtd_id::TEXT,
                            v_jtd.source_type_code || ' via ' || v_jtd.channel_code);

    IF COALESCE((v_res->>'success')::BOOLEAN, FALSE) THEN
        UPDATE n_jtd
        SET metadata = jsonb_set(COALESCE(metadata, '{}'::JSONB), '{credit}',
                jsonb_build_object('pool', COALESCE(v_pool, '_'),
                                   'charged', TRUE,
                                   'charged_at', NOW()), TRUE)
        WHERE id = p_jtd_id;
    END IF;

    RETURN v_res;

EXCEPTION WHEN OTHERS THEN
    -- The message HAS been sent by this point. Losing the charge is
    -- recoverable; raising here would rewrite a sent message as failed.
    RAISE WARNING 'jtd_charge_credit failed for %: %', p_jtd_id, SQLERRM;
    RETURN jsonb_build_object('success', false, 'reason', 'meter_error', 'error', SQLERRM);
END;
$function$;


-- Give the hold back when the provider refused the message.
CREATE OR REPLACE FUNCTION public.jtd_release_credit(p_jtd_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$function$
DECLARE
    v_jtd  RECORD;
    v_pool TEXT;
    v_r    RECORD;
BEGIN
    SELECT id, tenant_id, metadata INTO v_jtd FROM n_jtd WHERE id = p_jtd_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'reason', 'jtd_not_found');
    END IF;

    IF (v_jtd.metadata->'credit'->>'pool') IS NULL
       OR (v_jtd.metadata->'credit'->>'charged') IS NOT NULL THEN
        RETURN jsonb_build_object('success', true, 'released', false, 'reason', 'nothing_held');
    END IF;

    v_pool := NULLIF(v_jtd.metadata->'credit'->>'pool', '_');

    SELECT * INTO v_r
    FROM release_reserved_credits(v_jtd.tenant_id, 'notification', v_pool, 1);

    UPDATE n_jtd
    SET metadata = COALESCE(metadata, '{}'::JSONB) - 'credit'
    WHERE id = p_jtd_id;

    RETURN jsonb_build_object('success', true, 'released', TRUE,
        'pool', COALESCE(v_pool, '_'), 'reserved_after', v_r.reserved_after);

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'jtd_release_credit failed for %: %', p_jtd_id, SQLERRM;
    RETURN jsonb_build_object('success', false, 'reason', 'meter_error');
END;
$function$;


-- ── 8. release_waiting_jtds uses the shared availability function ─────
CREATE OR REPLACE FUNCTION public.release_waiting_jtds(
    p_tenant_id uuid, p_channel text, p_max_release integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_available INTEGER;
    v_released  INTEGER := 0;
    v_jtd       RECORD;
    v_channels  TEXT[];
    v_current_channel TEXT;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    IF p_channel = 'all' OR p_channel IS NULL THEN
        v_channels := ARRAY['whatsapp', 'sms', 'email', 'inapp'];
    ELSE
        v_channels := ARRAY[p_channel];
    END IF;

    FOREACH v_current_channel IN ARRAY v_channels
    LOOP
        EXIT WHEN v_released >= p_max_release;

        v_available := fn_channel_credit_available(p_tenant_id, v_current_channel);
        CONTINUE WHEN COALESCE(v_available, 0) <= 0;

        FOR v_jtd IN
            SELECT id, event_type_code, source_type_code, recipient_contact
            FROM n_jtd
            WHERE tenant_id = p_tenant_id
              AND channel_code = v_current_channel
              AND status_code = 'no_credits'
            ORDER BY created_at ASC
            LIMIT LEAST(v_available, p_max_release - v_released)
        LOOP
            UPDATE n_jtd
            SET status_code = 'pending', updated_at = NOW()
            WHERE id = v_jtd.id;

            INSERT INTO n_jtd_status_history (
                jtd_id, from_status_code, to_status_code, performed_by_type,
                performed_by_name, transition_note, status_started_at
            ) VALUES (
                v_jtd.id, 'no_credits', 'pending', 'system',
                'Credit Topup Release', 'Released after credit topup', NOW()
            );

            BEGIN
                PERFORM pgmq.send('jtd_queue', jsonb_build_object(
                    'jtd_id', v_jtd.id,
                    'tenant_id', p_tenant_id,
                    'channel_code', v_current_channel,
                    'event_type_code', v_jtd.event_type_code,
                    'source_type_code', v_jtd.source_type_code,
                    'released_from_no_credits', true
                ));
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'Could not queue JTD %: %', v_jtd.id, SQLERRM;
            END;

            v_released := v_released + 1;
            EXIT WHEN v_released >= p_max_release;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true, 'released_count', v_released, 'tenant_id', p_tenant_id,
        'channels', v_channels, 'max_release', p_max_release
    );
END;
$function$;


COMMENT ON FUNCTION public.trg_fn_jtd_credit_gate IS
'Parks a JTD as no_credits at INSERT when the tenant cannot pay for it. Runs before trg_jtd_enqueue (name order) so an unpayable message never reaches the queue. Fails open.';
COMMENT ON FUNCTION public.jtd_reserve_credit IS
'Worker step 1: hold one credit before dispatch. Idempotent — an already-charged or already-held JTD is not double-counted.';
COMMENT ON FUNCTION public.jtd_charge_credit IS
'Worker step 2: convert the hold into a spend after the provider accepts. Writes the journal row carrying reference_type=jtd.';
COMMENT ON FUNCTION public.jtd_release_credit IS
'Worker step 3 (failure path): return the hold when the provider refuses.';


-- =====================================================================
-- Verify:
--   select fn_channel_credit_available('<tenant>', 'whatsapp');
--   select jtd_reserve_credit('<jtd_id>');
--   select jtd_charge_credit('<jtd_id>');
--   select transaction_type, reference_type, count(*)
--     from t_credit_journal group by 1,2;      -- expect deduction/jtd
--   select status_code, count(*) from n_jtd group by 1;
-- =====================================================================
