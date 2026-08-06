-- ============================================================
-- BUSINESS MODEL V3 — 013 : D7 — release_waiting_jtds wrong column
-- ============================================================
-- Found by the Step 4 regression test for D1, immediately after 012 landed.
--
-- release_waiting_jtds aggregates "balance - COALESCE(reserved, 0)" but the
-- column is reserved_balance — the same defect as D3, in a different function.
--
-- This one is MORE severe than D3:
--   * D3 lives in trg_fn_update_context_on_credit_change, which returns early
--     when the tenant has no active subscription. With 0 subscription rows it
--     never fired, so it was latent.
--   * D7 lives in release_waiting_jtds, invoked by trg_credit_topup_release_jtds,
--     which fires on EVERY balance increase and has NO early return.
--
-- Net effect before this fix: add_credits threw for every tenant, so no credit
-- could be added to anyone. Not latent — broken in production.
--
-- Verified: after this migration, add_credits succeeds and journals correctly.
--
-- Also adds 'inapp' to the channel fan-out, matching the four-pool model
-- (previously ARRAY['whatsapp','sms','email']). Body is otherwise identical to
-- the definition captured in SPRINT1_STEP1_BASELINE.md.
-- ============================================================

CREATE OR REPLACE FUNCTION public.release_waiting_jtds(
    p_tenant_id uuid, p_channel text, p_max_release integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_available INTEGER;
    v_released INTEGER := 0;
    v_jtd RECORD;
    v_channels TEXT[];
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
        IF v_released >= p_max_release THEN
            EXIT;
        END IF;

        -- D7 FIX: the column is reserved_balance, not reserved.
        SELECT COALESCE(SUM(
            CASE WHEN channel = v_current_channel OR channel IS NULL
            THEN balance - COALESCE(reserved_balance, 0)
            END
        ), 0)
        INTO v_available
        FROM t_bm_credit_balance
        WHERE tenant_id = p_tenant_id
          AND credit_type = 'notification'
          AND (expires_at IS NULL OR expires_at > NOW());

        IF v_available <= 0 THEN
            CONTINUE;
        END IF;

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

            IF v_released >= p_max_release THEN
                EXIT;
            END IF;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true, 'released_count', v_released, 'tenant_id', p_tenant_id,
        'channels', v_channels, 'max_release', p_max_release
    );
END;
$function$;
