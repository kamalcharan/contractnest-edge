-- get_appointments_list only ever INNER JOINed t_contract_events/t_contracts,
-- which requires event_id/contract_id to be non-null. Group Session chair
-- appointments (t_appointments.group_session_occurrence_id set instead,
-- widened by bbb-foundation/031_group_session_chair_appointment.sql) were
-- silently excluded from the /ops/appointments kanban — confirmed against
-- real data: 18 real, active, accepted appointments for BBB, zero of them
-- visible on the board. Add a second branch for group-session-linked rows,
-- unioned with the existing (unchanged) contract/event path.
--
-- DEPENDS ON: bbb-foundation/031_group_session_chair_appointment.sql
-- (adds t_appointments.group_session_occurrence_id + nullable contract_id/
-- event_id). Already applied live; copy that migration too if replaying
-- this repo's migrations from scratch.
--
-- buyer_name/block_name/contract_name are repurposed for the group-session
-- branch since there's no single buyer on a chair appointment:
--   buyer_name    -> the session block's name (e.g. "Saturday Cadence")
--   block_name    -> literal 'Group Session' (subtitle, mirrors 'Service visit')
--   contract_name -> 'Session #<seq>'
--   event_date    -> the occurrence's date
-- buyer_phone/email/contract_number/task_id are NULL — the UI only renders
-- those fields when present, so they simply don't show.

CREATE OR REPLACE FUNCTION public.get_appointments_list(p_tenant_id uuid, p_is_live boolean DEFAULT true, p_status text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_items JSONB;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.event_date ASC NULLS LAST), '[]'::jsonb)
    INTO v_items
    FROM (
        -- Regular (contract/event-linked) appointments — unchanged.
        SELECT a.id, a.status, a.proposed_slots, a.scheduled_at,
               a.assigned_to, a.assigned_to_name, a.notes, a.last_activity_at,
               a.version, a.created_at, a.updated_at,
               a.event_id, e.block_name, e.task_id, e.scheduled_date AS event_date, e.status AS event_status,
               a.contract_id, c.contract_number, c.name AS contract_name,
               c.buyer_id,
               COALESCE(c.buyer_company, c.buyer_name) AS buyer_name,
               COALESCE(NULLIF(TRIM(c.buyer_phone), ''), (
                   SELECT ch.value FROM t_contact_channels ch
                   WHERE ch.contact_id = c.buyer_id AND ch.channel_type IN ('mobile', 'whatsapp')
                   ORDER BY CASE ch.channel_type WHEN 'mobile' THEN 0 ELSE 1 END,
                            ch.is_primary DESC NULLS LAST, ch.created_at
                   LIMIT 1)) AS buyer_phone,
               COALESCE(NULLIF(TRIM(c.buyer_email), ''), (
                   SELECT ch.value FROM t_contact_channels ch
                   WHERE ch.contact_id = c.buyer_id AND ch.channel_type = 'email'
                   ORDER BY ch.is_primary DESC NULLS LAST, ch.created_at
                   LIMIT 1)) AS buyer_email
        FROM t_appointments a
        JOIN t_contract_events e ON e.id = a.event_id
        JOIN t_contracts c ON c.id = a.contract_id
        WHERE a.tenant_id = p_tenant_id
          AND a.is_active = true
          AND COALESCE(a.is_live, true) = p_is_live
          AND (p_status IS NULL OR a.status = p_status)

        UNION ALL

        -- Group Session chair appointments — group_session_occurrence_id
        -- set, contract_id/event_id NULL.
        SELECT a.id, a.status, a.proposed_slots, a.scheduled_at,
               a.assigned_to, a.assigned_to_name, a.notes, a.last_activity_at,
               a.version, a.created_at, a.updated_at,
               NULL::uuid AS event_id, 'Group Session' AS block_name, NULL::text AS task_id,
               s.occurrence_date::timestamptz AS event_date, s.status AS event_status,
               NULL::uuid AS contract_id, NULL::character varying AS contract_number,
               ('Session #' || s.seq)::character varying AS contract_name,
               NULL::uuid AS buyer_id,
               b.name AS buyer_name,
               NULL::text AS buyer_phone,
               NULL::text AS buyer_email
        FROM t_appointments a
        JOIN t_group_session_schedule s ON s.id = a.group_session_occurrence_id
        JOIN m_cat_blocks b ON b.id = s.source_block_id
        WHERE a.tenant_id = p_tenant_id
          AND a.is_active = true
          AND COALESCE(a.is_live, true) = p_is_live
          AND (p_status IS NULL OR a.status = p_status)

        LIMIT 500
    ) x;

    RETURN jsonb_build_object('success', true, 'data', v_items, 'retrieved_at', now());

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', 'Failed to fetch appointments', 'details', SQLERRM, 'code', 'RPC_ERROR');
END;
$function$;
