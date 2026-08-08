-- =====================================================================
-- 020_balance_on_context.sql   —   BUSINESS MODEL V4, PHASE A
--
-- The running balance moves onto t_tenant_context.
--
-- Until now a credit lived in t_bm_credit_balance and was *copied* into
-- t_tenant_context by a sync trigger. Two homes for one number, kept in
-- step by a trigger that had already silently stopped working once
-- (it opened with a lookup on the empty t_bm_tenant_subscription and
-- returned before syncing — see 019). One home removes the class of bug.
--
-- After this migration:
--   · t_tenant_context.credits_<channel> IS the balance. Nothing copies.
--   · t_tenant_context.credits_reserved  (jsonb) holds in-flight holds.
--   · t_tenant_context.credits_other     (jsonb) holds credit types with
--     no typed column (ai_report, and whatever comes next) so a new
--     credit type never needs DDL.
--   · t_bm_credit_transaction becomes t_credit_journal — still a table,
--     still carrying balance_before/balance_after, because that is what
--     lets us PROVE a balance rather than recompute it and hope. (D1)
--   · credits do not expire. A plan contract expires; the credits it
--     granted stay with the tenant. All expiry machinery is removed. (D2)
--
-- SIGNATURES ARE UNCHANGED. add_credits / deduct_credits /
-- reserve_credits / release_reserved_credits / check_credit_availability
-- / get_credit_balance keep their exact argument lists and return shapes,
-- so every caller — billing/index.ts, _shared/businessModel/index.ts,
-- trg_fn_contract_consumption — keeps working with no edit. Verified:
-- no code anywhere reads t_bm_credit_balance or t_bm_credit_transaction
-- directly; every access is through these six RPCs.
--
-- t_bm_credit_balance is left in place but is no longer read or written.
-- It is dropped in Phase E, after one billing period of observation.
-- =====================================================================


-- ── 1. new columns ────────────────────────────────────────────────────
ALTER TABLE public.t_tenant_context
    ADD COLUMN IF NOT EXISTS credits_reserved JSONB NOT NULL DEFAULT '{}'::JSONB,
    ADD COLUMN IF NOT EXISTS credits_other    JSONB NOT NULL DEFAULT '{}'::JSONB;

COMMENT ON COLUMN public.t_tenant_context.credits_reserved IS
'In-flight holds, keyed "<credit_type>:<channel|_>". Taken by reserve_credits before dispatch, released on success (converted to a deduction) or failure. One jsonb column rather than five typed ones so a new channel needs no DDL.';

COMMENT ON COLUMN public.t_tenant_context.credits_other IS
'Balances for credit types with no typed column (e.g. ai_report), keyed "<credit_type>:<channel|_>". The typed columns stay for the hot notification path.';


-- ── 2. key + column mapping ───────────────────────────────────────────
-- One place that decides where a (credit_type, channel) pair lives, so
-- the six RPCs cannot drift from each other.

CREATE OR REPLACE FUNCTION public.fn_credit_key(p_credit_type TEXT, p_channel TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS
$function$
    SELECT COALESCE(p_credit_type, 'notification') || ':' || COALESCE(p_channel, '_');
$function$;

CREATE OR REPLACE FUNCTION public.fn_credit_column(p_credit_type TEXT, p_channel TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS
$function$
    SELECT CASE
        WHEN p_credit_type = 'notification' AND p_channel = 'whatsapp' THEN 'credits_whatsapp'
        WHEN p_credit_type = 'notification' AND p_channel = 'sms'      THEN 'credits_sms'
        WHEN p_credit_type = 'notification' AND p_channel = 'email'    THEN 'credits_email'
        WHEN p_credit_type = 'notification' AND p_channel = 'inapp'    THEN 'credits_inapp'
        WHEN p_credit_type = 'notification' AND p_channel IS NULL      THEN 'credits_pooled'
        WHEN p_credit_type = 'wallet'       AND p_channel IS NULL      THEN 'wallet_balance_paise'
        ELSE NULL   -- lives in credits_other
    END;
$function$;


-- ── 3. read / apply primitives ────────────────────────────────────────

-- Current gross balance and reservation for one (tenant, type, channel).
-- p_lock takes the row lock that makes reserve/deduct safe against a
-- concurrent send.
-- NOTE: the RETURNS TABLE column "product_code" shadows
-- t_tenant_context.product_code inside the body, so every reference to the
-- table is aliased. Without the alias Postgres raises 42702 at runtime, not
-- at CREATE time — it only surfaces on the first call.
CREATE OR REPLACE FUNCTION public.fn_credit_state(
    p_tenant_id UUID, p_credit_type TEXT, p_channel TEXT, p_lock BOOLEAN DEFAULT FALSE)
RETURNS TABLE(product_code TEXT, gross BIGINT, reserved BIGINT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$function$
DECLARE
    v_col   TEXT := fn_credit_column(p_credit_type, p_channel);
    v_key   TEXT := fn_credit_key(p_credit_type, p_channel);
    v_pc    TEXT;
    v_gross BIGINT;
    v_res   BIGINT;
BEGIN
    SELECT c.product_code INTO v_pc
    FROM t_tenant_context c
    WHERE c.tenant_id = p_tenant_id
    ORDER BY (c.product_code = 'contractnest') DESC
    LIMIT 1;

    IF v_pc IS NULL THEN
        RETURN;   -- no context row: caller treats as "no balance"
    END IF;

    IF p_lock THEN
        PERFORM 1 FROM t_tenant_context c
        WHERE c.tenant_id = p_tenant_id AND c.product_code = v_pc
        FOR UPDATE;
    END IF;

    IF v_col IS NOT NULL THEN
        EXECUTE format(
            'SELECT COALESCE(c.%I,0)::BIGINT FROM t_tenant_context c WHERE c.tenant_id=$1 AND c.product_code=$2',
            v_col)
        INTO v_gross USING p_tenant_id, v_pc;
    ELSE
        SELECT COALESCE((c.credits_other->>v_key)::BIGINT, 0) INTO v_gross
        FROM t_tenant_context c
        WHERE c.tenant_id = p_tenant_id AND c.product_code = v_pc;
    END IF;

    SELECT COALESCE((c.credits_reserved->>v_key)::BIGINT, 0) INTO v_res
    FROM t_tenant_context c
    WHERE c.tenant_id = p_tenant_id AND c.product_code = v_pc;

    RETURN QUERY SELECT v_pc, COALESCE(v_gross, 0), COALESCE(v_res, 0);
END;
$function$;


-- Move the balance by p_delta. Returns the new gross, or NULL when the
-- tenant has no context row. Caller must already hold the lock.
CREATE OR REPLACE FUNCTION public.fn_credit_apply(
    p_product_code TEXT, p_tenant_id UUID, p_credit_type TEXT,
    p_channel TEXT, p_delta BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$function$
DECLARE
    v_col TEXT := fn_credit_column(p_credit_type, p_channel);
    v_key TEXT := fn_credit_key(p_credit_type, p_channel);
    v_new BIGINT;
BEGIN
    IF v_col IS NOT NULL THEN
        EXECUTE format(
            'UPDATE t_tenant_context SET %I = COALESCE(%I,0) + $3, updated_at = NOW()
             WHERE tenant_id = $1 AND product_code = $2 RETURNING %I::BIGINT',
            v_col, v_col, v_col)
        INTO v_new USING p_tenant_id, p_product_code, p_delta;
    ELSE
        UPDATE t_tenant_context
        SET credits_other = jsonb_set(
                credits_other, ARRAY[v_key],
                to_jsonb(COALESCE((credits_other->>v_key)::BIGINT, 0) + p_delta), TRUE),
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id AND product_code = p_product_code
        RETURNING (credits_other->>v_key)::BIGINT INTO v_new;
    END IF;

    RETURN v_new;
END;
$function$;


-- ── 4. the six public RPCs, rewritten against the context row ─────────
-- Argument lists and return shapes are byte-identical to the versions
-- they replace.

CREATE OR REPLACE FUNCTION public.add_credits(
    p_tenant_id uuid, p_credit_type text, p_quantity integer,
    p_channel text DEFAULT NULL::text, p_source text DEFAULT 'manual'::text,
    p_reference_id text DEFAULT NULL::text, p_description text DEFAULT NULL::text,
    p_reference_type text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_state    RECORD;
    v_new      BIGINT;
    v_ref_uuid UUID;
    v_txn_type TEXT;
BEGIN
    IF p_quantity <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Quantity must be positive');
    END IF;

    BEGIN
        v_ref_uuid := NULLIF(p_reference_id, '')::uuid;
    EXCEPTION WHEN others THEN
        v_ref_uuid := NULL;
    END;

    v_txn_type := CASE lower(COALESCE(p_source, 'manual'))
                      WHEN 'manual'  THEN 'adjustment'
                      WHEN 'initial' THEN 'initial'
                      WHEN 'refund'  THEN 'refund'
                      ELSE 'topup' END;

    SELECT * INTO v_state
    FROM fn_credit_state(p_tenant_id, p_credit_type, p_channel, TRUE);

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'No tenant context found',
            'tenant_id', p_tenant_id, 'credit_type', p_credit_type, 'channel', p_channel);
    END IF;

    v_new := fn_credit_apply(v_state.product_code, p_tenant_id, p_credit_type,
                             p_channel, p_quantity::BIGINT);

    INSERT INTO t_credit_journal (
        tenant_id, credit_type, channel, transaction_type, quantity,
        balance_before, balance_after, reference_type, reference_id, description, metadata
    ) VALUES (
        p_tenant_id, p_credit_type, p_channel, v_txn_type, p_quantity,
        v_state.gross, v_new, COALESCE(p_reference_type, p_source), v_ref_uuid,
        p_description, jsonb_build_object('source', p_source, 'reference_id_raw', p_reference_id)
    );

    RETURN jsonb_build_object(
        'success', true, 'tenant_id', p_tenant_id, 'credit_type', p_credit_type,
        'channel', p_channel, 'quantity_added', p_quantity,
        'previous_balance', v_state.gross, 'new_balance', v_new,
        'source', p_source, 'reference_type', COALESCE(p_reference_type, p_source),
        'reference_id', p_reference_id, 'description', p_description
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.deduct_credits(
    p_tenant_id uuid, p_credit_type text, p_quantity integer,
    p_channel text DEFAULT NULL::text, p_reference_type text DEFAULT NULL::text,
    p_reference_id text DEFAULT NULL::text, p_description text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_state     RECORD;
    v_available BIGINT;
    v_new       BIGINT;
    v_ref_uuid  UUID;
BEGIN
    IF p_quantity <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Quantity must be positive');
    END IF;

    BEGIN
        v_ref_uuid := NULLIF(p_reference_id, '')::uuid;
    EXCEPTION WHEN others THEN
        v_ref_uuid := NULL;
    END;

    SELECT * INTO v_state
    FROM fn_credit_state(p_tenant_id, p_credit_type, p_channel, TRUE);

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'No credit balance found',
            'tenant_id', p_tenant_id, 'credit_type', p_credit_type, 'channel', p_channel);
    END IF;

    -- A deduction that follows a reservation is spending its own hold, so
    -- the hold must not also count against it. reserve → deduct is the
    -- normal path from jtd-worker; a bare deduct (no prior reserve) still
    -- works and is checked against gross minus other holds.
    v_available := v_state.gross - GREATEST(v_state.reserved - p_quantity, 0);

    IF v_available < p_quantity THEN
        RETURN jsonb_build_object('success', false, 'error', 'Insufficient credits',
            'required', p_quantity, 'available', v_available, 'balance', v_state.gross,
            'reserved', v_state.reserved);
    END IF;

    v_new := fn_credit_apply(v_state.product_code, p_tenant_id, p_credit_type,
                             p_channel, -p_quantity::BIGINT);

    -- Consume the hold this deduction was made against, if there was one.
    IF v_state.reserved > 0 THEN
        PERFORM * FROM release_reserved_credits(p_tenant_id, p_credit_type, p_channel,
                                               LEAST(p_quantity, v_state.reserved)::INTEGER);
    END IF;

    INSERT INTO t_credit_journal (
        tenant_id, credit_type, channel, transaction_type, quantity,
        balance_before, balance_after, reference_type, reference_id, description, metadata
    ) VALUES (
        p_tenant_id, p_credit_type, p_channel, 'deduction', -p_quantity,
        v_state.gross, v_new, p_reference_type, v_ref_uuid,
        p_description, jsonb_build_object('reference_id_raw', p_reference_id)
    );

    RETURN jsonb_build_object(
        'success', true, 'tenant_id', p_tenant_id, 'credit_type', p_credit_type,
        'channel', p_channel, 'quantity_deducted', p_quantity,
        'previous_balance', v_state.gross, 'new_balance', v_new,
        'reference_type', p_reference_type, 'reference_id', p_reference_id,
        'description', p_description
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.reserve_credits(
    p_tenant_id uuid, p_credit_type text, p_channel text DEFAULT NULL::text,
    p_quantity integer DEFAULT 1)
RETURNS TABLE(success boolean, available_after integer, error_message text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_state     RECORD;
    v_key       TEXT := fn_credit_key(p_credit_type, p_channel);
    v_available BIGINT;
BEGIN
    SELECT * INTO v_state
    FROM fn_credit_state(p_tenant_id, p_credit_type, p_channel, TRUE);

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 0, 'No credit balance found'::TEXT;
        RETURN;
    END IF;

    v_available := v_state.gross - v_state.reserved;

    IF v_available < p_quantity THEN
        RETURN QUERY SELECT false, v_available::INTEGER,
            format('Insufficient available credits. Available: %s', v_available)::TEXT;
        RETURN;
    END IF;

    UPDATE t_tenant_context
    SET credits_reserved = jsonb_set(
            credits_reserved, ARRAY[v_key],
            to_jsonb(v_state.reserved + p_quantity), TRUE),
        updated_at = NOW()
    WHERE tenant_id = p_tenant_id AND product_code = v_state.product_code;

    RETURN QUERY SELECT true, (v_available - p_quantity)::INTEGER, NULL::TEXT;

EXCEPTION WHEN lock_not_available THEN
    RETURN QUERY SELECT false, 0, 'Resource is locked. Please retry'::TEXT;
END;
$function$;


CREATE OR REPLACE FUNCTION public.release_reserved_credits(
    p_tenant_id uuid, p_credit_type text, p_channel text DEFAULT NULL::text,
    p_quantity integer DEFAULT 1)
RETURNS TABLE(success boolean, reserved_after integer, error_message text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_state RECORD;
    v_key   TEXT := fn_credit_key(p_credit_type, p_channel);
    v_after BIGINT;
BEGIN
    SELECT * INTO v_state
    FROM fn_credit_state(p_tenant_id, p_credit_type, p_channel, TRUE);

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 0, 'No credit balance found'::TEXT;
        RETURN;
    END IF;

    v_after := GREATEST(0, v_state.reserved - p_quantity);

    UPDATE t_tenant_context
    SET credits_reserved = jsonb_set(credits_reserved, ARRAY[v_key], to_jsonb(v_after), TRUE),
        updated_at = NOW()
    WHERE tenant_id = p_tenant_id AND product_code = v_state.product_code;

    RETURN QUERY SELECT true, v_after::INTEGER, NULL::TEXT;
END;
$function$;


CREATE OR REPLACE FUNCTION public.check_credit_availability(
    p_tenant_id uuid, p_credit_type text, p_quantity integer,
    p_channel text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_state     RECORD;
    v_available BIGINT;
BEGIN
    SELECT * INTO v_state
    FROM fn_credit_state(p_tenant_id, p_credit_type, p_channel, FALSE);

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', true, 'is_available', false, 'reason', 'No credit balance found',
            'required', p_quantity, 'available', 0, 'tenant_id', p_tenant_id,
            'credit_type', p_credit_type, 'channel', p_channel);
    END IF;

    v_available := v_state.gross - v_state.reserved;

    RETURN jsonb_build_object(
        'success', true,
        'is_available', v_available >= p_quantity,
        'required', p_quantity,
        'available', v_available,
        'balance', v_state.gross,
        'reserved', v_state.reserved,
        'shortfall', GREATEST(0, p_quantity - v_available),
        'tenant_id', p_tenant_id,
        'credit_type', p_credit_type,
        'channel', p_channel
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.get_credit_balance(p_tenant_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_ctx     RECORD;
    v_lines   JSONB;
    v_summary JSONB;
BEGIN
    SELECT * INTO v_ctx
    FROM t_tenant_context
    WHERE tenant_id = p_tenant_id
    ORDER BY (product_code = 'contractnest') DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', true, 'tenant_id', p_tenant_id,
            'credits', '[]'::JSONB, 'summary', '{}'::JSONB, 'generated_at', NOW());
    END IF;

    WITH typed(credit_type, channel, balance) AS (
        VALUES ('notification'::TEXT, 'whatsapp'::TEXT, COALESCE(v_ctx.credits_whatsapp, 0)::BIGINT),
               ('notification',        'sms',            COALESCE(v_ctx.credits_sms, 0)::BIGINT),
               ('notification',        'email',          COALESCE(v_ctx.credits_email, 0)::BIGINT),
               ('notification',        'inapp',          COALESCE(v_ctx.credits_inapp, 0)::BIGINT),
               ('notification',        NULL::TEXT,       COALESCE(v_ctx.credits_pooled, 0)::BIGINT),
               ('wallet',              NULL::TEXT,       COALESCE(v_ctx.wallet_balance_paise, 0)::BIGINT)
    ),
    other AS (
        SELECT split_part(k, ':', 1) AS credit_type,
               NULLIF(split_part(k, ':', 2), '_') AS channel,
               v::BIGINT AS balance
        FROM jsonb_each_text(v_ctx.credits_other) AS e(k, v)
    ),
    all_lines AS (
        SELECT * FROM typed UNION ALL SELECT * FROM other
    ),
    enriched AS (
        SELECT
            NULL::UUID AS id,
            l.credit_type,
            l.channel,
            l.balance,
            COALESCE((v_ctx.credits_reserved->>fn_credit_key(l.credit_type, l.channel))::BIGINT, 0)
                AS reserved_balance,
            l.balance - COALESCE(
                (v_ctx.credits_reserved->>fn_credit_key(l.credit_type, l.channel))::BIGINT, 0)
                AS available_balance,
            10 AS low_balance_threshold,
            l.balance < 10 AS is_low,
            NULL::TIMESTAMPTZ AS expires_at,   -- credits do not expire (V4 D2)
            (SELECT max(j.created_at) FROM t_credit_journal j
              WHERE j.tenant_id = p_tenant_id AND j.credit_type = l.credit_type
                AND j.channel IS NOT DISTINCT FROM l.channel
                AND j.quantity > 0) AS last_topup_at,
            (SELECT j.quantity FROM t_credit_journal j
              WHERE j.tenant_id = p_tenant_id AND j.credit_type = l.credit_type
                AND j.channel IS NOT DISTINCT FROM l.channel
                AND j.quantity > 0
              ORDER BY j.created_at DESC LIMIT 1) AS last_topup_amount
        FROM all_lines l
    )
    SELECT jsonb_agg(to_jsonb(e) ORDER BY e.credit_type, e.channel)
    INTO v_lines
    FROM enriched e;

    SELECT jsonb_object_agg(credit_type, totals) INTO v_summary
    FROM (
        SELECT e->>'credit_type' AS credit_type,
               jsonb_build_object(
                   'total_balance',   SUM((e->>'balance')::BIGINT),
                   'total_reserved',  SUM((e->>'reserved_balance')::BIGINT),
                   'total_available', SUM((e->>'available_balance')::BIGINT)
               ) AS totals
        FROM jsonb_array_elements(COALESCE(v_lines, '[]'::JSONB)) e
        GROUP BY e->>'credit_type'
    ) s;

    RETURN jsonb_build_object(
        'success', true,
        'tenant_id', p_tenant_id,
        'credits', COALESCE(v_lines, '[]'::JSONB),
        'summary', COALESCE(v_summary, '{}'::JSONB),
        'generated_at', NOW()
    );
END;
$function$;


-- ── 5. flags recalculate on the context row itself ────────────────────
-- Previously the flags were set by the sync trigger on t_bm_credit_balance.
-- With the balance living here, a BEFORE trigger on this table catches
-- EVERY writer — the RPCs above, subscribe_tenant_to_plan, and any manual
-- correction — instead of only writers that went through the ledger.

CREATE OR REPLACE FUNCTION public.trg_fn_context_credit_flags()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS
$function$
DECLARE
    v_status TEXT;
    v_flags  RECORD;
    v_w INTEGER; v_s INTEGER; v_e INTEGER; v_i INTEGER; v_p INTEGER;
BEGIN
    v_status := COALESCE(
        NEW.subscription_status,
        CASE WHEN NEW.billing_mode IN ('plan', 'wallet', 'freemium', 'exempt')
             THEN 'active' END);

    -- Flags describe what can be SENT right now, so they are computed on
    -- available (gross minus holds) — the same figure the old sync trigger
    -- wrote.
    v_w := GREATEST(0, COALESCE(NEW.credits_whatsapp,0)
             - COALESCE((NEW.credits_reserved->>'notification:whatsapp')::INT, 0));
    v_s := GREATEST(0, COALESCE(NEW.credits_sms,0)
             - COALESCE((NEW.credits_reserved->>'notification:sms')::INT, 0));
    v_e := GREATEST(0, COALESCE(NEW.credits_email,0)
             - COALESCE((NEW.credits_reserved->>'notification:email')::INT, 0));
    v_i := GREATEST(0, COALESCE(NEW.credits_inapp,0)
             - COALESCE((NEW.credits_reserved->>'notification:inapp')::INT, 0));
    v_p := GREATEST(0, COALESCE(NEW.credits_pooled,0)
             - COALESCE((NEW.credits_reserved->>'notification:_')::INT, 0));

    SELECT * INTO v_flags
    FROM fn_recalc_credit_flags(v_w, v_s, v_e, v_p, v_status, v_i);

    NEW.flag_can_send_whatsapp := v_flags.can_send_whatsapp;
    NEW.flag_can_send_sms      := v_flags.can_send_sms;
    NEW.flag_can_send_email    := v_flags.can_send_email;
    NEW.flag_can_send_inapp    := v_flags.can_send_inapp;
    NEW.flag_credits_low       := v_flags.credits_low;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_context_credit_flags ON public.t_tenant_context;
CREATE TRIGGER trg_context_credit_flags
    BEFORE INSERT OR UPDATE OF credits_whatsapp, credits_sms, credits_email,
                               credits_inapp, credits_pooled, credits_reserved,
                               subscription_status, billing_mode
    ON public.t_tenant_context
    FOR EACH ROW EXECUTE FUNCTION public.trg_fn_context_credit_flags();


-- ── 6. JTD release fires off the context row ──────────────────────────
-- The release machinery (no_credits → pending, FIFO, per channel) was
-- built in jtd-framework/003 and is unchanged. Only its trigger point
-- moves, from t_bm_credit_balance to here.

CREATE OR REPLACE FUNCTION public.trg_fn_release_jtds_on_context_credit()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$function$
BEGIN
    IF COALESCE(NEW.credits_whatsapp,0) > COALESCE(OLD.credits_whatsapp,0) THEN
        PERFORM release_waiting_jtds(NEW.tenant_id, 'whatsapp', 50);
    END IF;
    IF COALESCE(NEW.credits_sms,0) > COALESCE(OLD.credits_sms,0) THEN
        PERFORM release_waiting_jtds(NEW.tenant_id, 'sms', 50);
    END IF;
    IF COALESCE(NEW.credits_email,0) > COALESCE(OLD.credits_email,0) THEN
        PERFORM release_waiting_jtds(NEW.tenant_id, 'email', 50);
    END IF;
    IF COALESCE(NEW.credits_inapp,0) > COALESCE(OLD.credits_inapp,0) THEN
        PERFORM release_waiting_jtds(NEW.tenant_id, 'inapp', 50);
    END IF;
    -- Pooled credits back every channel, so a pooled topup releases all.
    IF COALESCE(NEW.credits_pooled,0) > COALESCE(OLD.credits_pooled,0) THEN
        PERFORM release_waiting_jtds(NEW.tenant_id, 'all', 50);
    END IF;
    RETURN NULL;

EXCEPTION WHEN OTHERS THEN
    -- Releasing parked work must never fail a credit grant.
    RAISE WARNING 'JTD release after credit topup failed for %: %', NEW.tenant_id, SQLERRM;
    RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_context_release_jtds ON public.t_tenant_context;
CREATE TRIGGER trg_context_release_jtds
    AFTER UPDATE OF credits_whatsapp, credits_sms, credits_email,
                    credits_inapp, credits_pooled
    ON public.t_tenant_context
    FOR EACH ROW EXECUTE FUNCTION public.trg_fn_release_jtds_on_context_credit();


-- release_waiting_jtds now reads availability from the context row.
-- Body below is the 003 original with only the availability query changed.
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

        -- channel-specific credits plus the pooled bucket, net of holds
        SELECT GREATEST(0,
                 (CASE v_current_channel
                    WHEN 'whatsapp' THEN COALESCE(credits_whatsapp, 0)
                    WHEN 'sms'      THEN COALESCE(credits_sms, 0)
                    WHEN 'email'    THEN COALESCE(credits_email, 0)
                    WHEN 'inapp'    THEN COALESCE(credits_inapp, 0)
                    ELSE 0 END)
                 + COALESCE(credits_pooled, 0)
                 - COALESCE((credits_reserved->>('notification:' || v_current_channel))::INT, 0)
                 - COALESCE((credits_reserved->>'notification:_')::INT, 0))
        INTO v_available
        FROM t_tenant_context
        WHERE tenant_id = p_tenant_id
        ORDER BY (product_code = 'contractnest') DESC
        LIMIT 1;

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


-- ── 7. the journal keeps its name honest ──────────────────────────────
-- Nothing reads this table directly — every access is via the RPCs above
-- (verified by grep across api, ui and edge) — so the rename is safe
-- without a compatibility view.
ALTER TABLE IF EXISTS public.t_bm_credit_transaction RENAME TO t_credit_journal;

COMMENT ON TABLE public.t_credit_journal IS
'Append-only credit journal. One row per grant or spend, carrying balance_before/balance_after so a balance on t_tenant_context can be PROVEN rather than recomputed. Grants reference the contract that earned them; spends will reference the JTD that spent them (Phase B).';


-- ── 8. backfill, then stop reading the old table ──────────────────────
DO $do$
DECLARE
    r            RECORD;
    v_pc         TEXT;
    v_orphans    INTEGER := 0;
    v_moved      INTEGER := 0;
BEGIN
    FOR r IN
        SELECT tenant_id, credit_type, channel, balance
        FROM t_bm_credit_balance
        WHERE balance <> 0
    LOOP
        SELECT product_code INTO v_pc
        FROM t_tenant_context
        WHERE tenant_id = r.tenant_id
        ORDER BY (product_code = 'contractnest') DESC
        LIMIT 1;

        IF v_pc IS NULL THEN
            -- No context row (in practice: tenants deleted from t_tenants
            -- whose balances were never cleaned up). Reported, not migrated.
            v_orphans := v_orphans + 1;
            RAISE NOTICE 'orphan balance skipped: tenant=% type=% channel=% balance=%',
                r.tenant_id, r.credit_type, r.channel, r.balance;
            CONTINUE;
        END IF;

        -- Set, do not add: the old sync trigger already copied notification
        -- balances into the typed columns, so adding would double them.
        DECLARE
            v_col TEXT := fn_credit_column(r.credit_type, r.channel);
            v_key TEXT := fn_credit_key(r.credit_type, r.channel);
            v_cur BIGINT;
        BEGIN
            IF v_col IS NOT NULL THEN
                EXECUTE format(
                    'SELECT COALESCE(%I,0)::BIGINT FROM t_tenant_context WHERE tenant_id=$1 AND product_code=$2',
                    v_col) INTO v_cur USING r.tenant_id, v_pc;

                IF v_cur IS DISTINCT FROM r.balance::BIGINT THEN
                    EXECUTE format(
                        'UPDATE t_tenant_context SET %I = $3, updated_at = NOW()
                         WHERE tenant_id = $1 AND product_code = $2', v_col)
                    USING r.tenant_id, v_pc, r.balance;
                    v_moved := v_moved + 1;
                    RAISE NOTICE 'corrected %.% for %: % -> %', v_col, v_key, r.tenant_id, v_cur, r.balance;
                END IF;
            ELSE
                UPDATE t_tenant_context
                SET credits_other = jsonb_set(credits_other, ARRAY[v_key], to_jsonb(r.balance), TRUE),
                    updated_at = NOW()
                WHERE tenant_id = r.tenant_id AND product_code = v_pc;
                v_moved := v_moved + 1;
            END IF;
        END;
    END LOOP;

    RAISE NOTICE 'backfill complete: % lines written, % orphaned balances skipped', v_moved, v_orphans;
END $do$;


-- ── 9. retire what the balance move makes redundant ───────────────────

-- The sync trigger existed only to copy one number into another table.
-- There is one number now.
DROP TRIGGER IF EXISTS trg_credit_balance_update_context ON public.t_bm_credit_balance;
DROP TRIGGER IF EXISTS trg_credit_topup_release_jtds     ON public.t_bm_credit_balance;
DROP FUNCTION IF EXISTS public.trg_fn_update_context_on_credit_change();
DROP FUNCTION IF EXISTS public.trg_fn_release_jtds_on_credit_topup();

-- Credits do not expire (V4 decision D2): a plan contract expires, the
-- credits it granted stay with the tenant. Nothing calls this.
DO $do$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT p.oid::regprocedure AS sig
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = 'process_credit_expiry'
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig;
    END LOOP;
END $do$;

-- t_bm_credit_balance is intentionally NOT dropped here — it stays as a
-- read-only reference for one billing period, then goes in Phase E along
-- with t_bm_tenant_subscription and the other empty tables.


-- ── 10. get_tenant_context: credits.* stays "available" ───────────────
-- The old sync wrote available (gross minus holds) into credits_*, so
-- every existing reader — the pricing page, the subscription page, the
-- mobile app — already means available when it says credits.whatsapp.
-- The column now holds GROSS, so the read model does the subtraction and
-- the meaning callers depend on is unchanged. credits_reserved is exposed
-- alongside for anything that wants to show holds.
CREATE OR REPLACE FUNCTION public.get_tenant_context(p_product_code text, p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_context     RECORD;
    v_platform_id UUID;
    v_plan        RECORD;
    v_res         JSONB;
BEGIN
    IF p_product_code IS NULL OR p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false,
            'error', 'product_code and tenant_id are required');
    END IF;

    SELECT * INTO v_context
    FROM t_tenant_context
    WHERE product_code = p_product_code AND tenant_id = p_tenant_id;

    IF v_context IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Tenant context not found',
            'product_code', p_product_code, 'tenant_id', p_tenant_id);
    END IF;

    v_res := COALESCE(v_context.credits_reserved, '{}'::JSONB);

    -- The plan, resolved from the actual contract. Always live: ContractNest's
    -- own commercial model exists once, so a tenant in its test environment is
    -- still on the same real plan.
    SELECT id INTO v_platform_id FROM t_tenants WHERE is_admin = TRUE LIMIT 1;

    IF v_platform_id IS NOT NULL THEN
        SELECT c.id, c.contract_number, c.name, c.status,
               c.start_date, c.end_date, c.grand_total, c.currency,
               c.metadata->>'plan_template_id' AS plan_template_id
        INTO v_plan
        FROM t_contracts c
        JOIN t_contacts ct ON ct.id = c.buyer_id
        WHERE c.tenant_id = v_platform_id
          AND c.is_live = TRUE
          AND c.record_type = 'contract'
          AND c.status IN ('active', 'pending_acceptance')
          AND ct.source_tenant_id = p_tenant_id
        ORDER BY c.created_at DESC
        LIMIT 1;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'product_code', v_context.product_code,
        'tenant_id', v_context.tenant_id,

        'profile', jsonb_build_object(
            'business_name', v_context.business_name,
            'logo_url', v_context.logo_url,
            'primary_color', v_context.primary_color,
            'secondary_color', v_context.secondary_color
        ),

        'billing_mode', v_context.billing_mode,
        'credit_grant_rates', v_context.credit_grant_rates,

        'subscription', jsonb_build_object(
            'id', v_plan.id,
            'contract_id', v_plan.id,
            'contract_number', v_plan.contract_number,
            'plan_template_id', v_plan.plan_template_id,
            'plan_name', v_plan.name,
            'status', v_plan.status,
            'period_start', v_plan.start_date,
            'period_end', v_plan.end_date,
            'amount', v_plan.grand_total,
            'currency', v_plan.currency,
            'billing_cycle', v_context.billing_cycle,
            'trial_end', v_context.trial_end_date,
            'grace_end', v_context.grace_end_date,
            'next_billing_date', COALESCE(v_plan.end_date, v_context.next_billing_date)
        ),

        -- available = gross - holds, the figure callers have always received
        'credits', jsonb_build_object(
            'whatsapp', GREATEST(0, COALESCE(v_context.credits_whatsapp,0)
                          - COALESCE((v_res->>'notification:whatsapp')::INT, 0)),
            'sms',      GREATEST(0, COALESCE(v_context.credits_sms,0)
                          - COALESCE((v_res->>'notification:sms')::INT, 0)),
            'email',    GREATEST(0, COALESCE(v_context.credits_email,0)
                          - COALESCE((v_res->>'notification:email')::INT, 0)),
            'inapp',    GREATEST(0, COALESCE(v_context.credits_inapp,0)
                          - COALESCE((v_res->>'notification:inapp')::INT, 0)),
            'pooled',   GREATEST(0, COALESCE(v_context.credits_pooled,0)
                          - COALESCE((v_res->>'notification:_')::INT, 0))
        ),

        -- gross and holds, for anything that needs to show "3 in flight"
        'credits_gross', jsonb_build_object(
            'whatsapp', COALESCE(v_context.credits_whatsapp,0),
            'sms',      COALESCE(v_context.credits_sms,0),
            'email',    COALESCE(v_context.credits_email,0),
            'inapp',    COALESCE(v_context.credits_inapp,0),
            'pooled',   COALESCE(v_context.credits_pooled,0)
        ),
        'credits_reserved', v_res,
        'credits_other', COALESCE(v_context.credits_other, '{}'::JSONB),

        -- NULL means unlimited ONLY for the exempt platform tenant. For a
        -- subscribing tenant a plan always states a number, and 0 means zero.
        'limits', jsonb_build_object(
            'users', v_context.limit_users,
            'contracts', v_context.limit_contracts,
            'rfqs', v_context.limit_rfqs,
            'contacts', v_context.limit_contacts,
            'templates', v_context.limit_templates,
            'storage_mb', v_context.limit_storage_mb
        ),

        'usage', jsonb_build_object(
            'users', v_context.usage_users,
            'contracts', v_context.usage_contracts,
            'rfqs', v_context.usage_rfqs,
            'contacts', v_context.usage_contacts,
            'templates', v_context.usage_templates,
            'storage_mb', v_context.usage_storage_mb
        ),

        'addons', jsonb_build_object(
            'vani_ai', v_context.addon_vani_ai,
            'rfp', v_context.addon_rfp
        ),

        'flags', jsonb_build_object(
            'can_access', v_context.flag_can_access,
            'can_send_whatsapp', v_context.flag_can_send_whatsapp,
            'can_send_sms', v_context.flag_can_send_sms,
            'can_send_email', v_context.flag_can_send_email,
            'can_send_inapp', v_context.flag_can_send_inapp,
            'credits_low', v_context.flag_credits_low,
            'near_limit', v_context.flag_near_limit
        ),

        'retrieved_at', NOW()
    );
END;
$function$;

COMMENT ON FUNCTION public.get_tenant_context IS
'Tenant context read model. The balance lives on this row (V4 Phase A); credits.* is available (gross minus holds) to preserve the meaning callers have always had, with credits_gross/credits_reserved exposed alongside. The subscription block is resolved from the plan CONTRACT under the platform tenant.';


-- =====================================================================
-- Verify:
--
--   select credits_whatsapp, credits_email, credits_reserved, credits_other
--   from t_tenant_context where tenant_id = 'c0000000-0000-4000-8000-000000000001';
--
--   select add_credits('c0000000-0000-4000-8000-000000000001','notification',
--                      5,'whatsapp','manual',null,'phase A smoke test');
--   select * from reserve_credits('c0000000-0000-4000-8000-000000000001',
--                                 'notification','whatsapp',2);
--   select check_credit_availability('c0000000-0000-4000-8000-000000000001',
--                                    'notification',1,'whatsapp');
--   select deduct_credits('c0000000-0000-4000-8000-000000000001','notification',
--                         2,'whatsapp','jtd',null,'phase A smoke test');
--
--   select jsonb_pretty(get_credit_balance('c0000000-0000-4000-8000-000000000001'));
--   select jsonb_pretty(get_tenant_context('contractnest','c0000000-0000-4000-8000-000000000001'));
-- =====================================================================
