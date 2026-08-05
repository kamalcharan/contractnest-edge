-- 054_group_session_scheduled_notifications.sql
-- Sprint 2 (scheduled): the two TIME-DRIVEN Group Session WhatsApp triggers.
--
--   group_session_looking_forward  → 3 days out AND 1 day out, to every active
--                                    roster member of the occurrence.
--   group_session_noshow_regret    → session end + 2h, to roster members with
--                                    no 'present' attendance row.
--
-- group_session_absentee_reminder is deliberately NOT built (owner decision:
-- on hold). Its n_jtd_source_types row from 008 stays seeded and inert — no
-- template, no trigger, nothing enqueues it.
--
-- Unlike 053 (which rode the transaction of an RPC that was already firing),
-- these have no host transaction, so they need a scheduler. That brings four
-- things that did not exist before: an IST-aware runner, an idempotency guard
-- on n_jtd, a reusable roster enumeration, and a safe phone lookup.
--
-- ============================================================================
-- 1. IDEMPOTENCY GUARD
-- ============================================================================
-- n_jtd had NO unique index other than its primary key. That is fine for
-- 053's triggers (they fire once, inside the write they ride along with) but
-- fatal for a cron: every run would re-insert, and a member would get the same
-- reminder every 15 minutes forever.
--
-- reminder_key discriminates the two looking-forward sends for the SAME
-- occurrence + member ('lf_3' vs 'lf_1'), which source_id alone cannot.
-- Partial, so it constrains only these two source types and leaves every other
-- JTD producer untouched.

CREATE UNIQUE INDEX IF NOT EXISTS ux_n_jtd_group_session_reminder
    ON public.n_jtd (
        tenant_id, source_type_code, source_id, recipient_id, is_live,
        (metadata->>'reminder_key')
    )
    WHERE source_type_code IN (
        'group_session_looking_forward',
        'group_session_noshow_regret'
    );

-- ============================================================================
-- 2. PHONE LOOKUP
-- ============================================================================
-- Deliberately IGNORES t_contact_channels.country_code. That column is
-- inconsistent in live data — '+91' (207 rows), 'IN' (141), NULL (6) — while
-- `value` already carries the full +91… number in every observed row. The
-- concat style used inline in gs_confirm_declaration
-- (coalesce(country_code,'') || value) therefore DOUBLES the prefix whenever
-- country_code = '+91', producing a 14-digit number that jtd-worker's
-- formatMobile() passes through unchanged because it already starts with '91'.
--
-- This function works from `value` alone and returns NULL rather than guessing
-- when the digit count is not a shape we recognise. A NULL simply means "no
-- message for this member" — strictly better than delivering to a wrong number.

CREATE OR REPLACE FUNCTION public.gs_member_whatsapp_phone(p_contact uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
    WITH best AS (
        SELECT regexp_replace(ch.value, '\D', '', 'g') AS digits
        FROM public.t_contact_channels ch
        WHERE ch.contact_id = p_contact
          AND ch.channel_type IN ('whatsapp', 'mobile', 'phone')
          AND coalesce(ch.value, '') <> ''
        ORDER BY ch.is_primary DESC NULLS LAST,
                 (ch.channel_type = 'whatsapp') DESC,
                 (ch.channel_type = 'mobile') DESC
        LIMIT 1
    )
    SELECT CASE
             WHEN length(digits) = 12 AND left(digits, 2) = '91' THEN digits
             WHEN length(digits) = 10                            THEN '91' || digits
             ELSE NULL
           END
    FROM best;
$function$;

COMMENT ON FUNCTION public.gs_member_whatsapp_phone(uuid) IS
'Best WhatsApp-able number for a contact as bare digits (91XXXXXXXXXX), or NULL if none is safely derivable. Ignores country_code by design — see 054 migration header.';

-- ============================================================================
-- 3. ROSTER ENUMERATION
-- ============================================================================
-- Mirrors the member derivation already inside gs_dash_roster (active contracts
-- whose blocks reference this group-session block, one row per buyer, newest
-- contract wins) so the dashboard and the notifications can never disagree
-- about who is on the roster.
--
-- p_as_of is the OCCURRENCE date, not today: a member whose contract ended
-- last week should not be reminded about next week's session, and a member
-- whose contract starts next month should not be chased about this one.

CREATE OR REPLACE FUNCTION public.gs_roster_members(
    p_tenant  uuid,
    p_block   uuid,
    p_is_live boolean,
    p_as_of   date
)
RETURNS TABLE (contact_id uuid, member_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
    SELECT DISTINCT ON (c.buyer_id) c.buyer_id, c.buyer_name
    FROM public.t_contract_blocks cb
    JOIN public.t_contracts c ON c.id = cb.contract_id
    WHERE cb.source_block_id = p_block
      AND c.tenant_id        = p_tenant
      AND coalesce(c.is_live, true) = p_is_live
      AND c.status = 'active'
      AND (c.start_date IS NULL OR p_as_of >= c.start_date::date)
      AND (c.end_date   IS NULL OR p_as_of <= c.end_date::date)
    ORDER BY c.buyer_id, c.start_date DESC NULLS LAST;
$function$;

-- ============================================================================
-- 4. THE SCHEDULER
-- ============================================================================
-- "Today" is Asia/Kolkata, never the database's UTC current_date — same class
-- of bug as migration 048 (check-in thought it was still yesterday between
-- 00:00 and 05:30 IST). Every date comparison below goes through v_today.
--
-- Both halves are gated on a template mapping existing for that tenant. Without
-- the gate, shipping this before a tenant is mapped would manufacture ~98 failed
-- JTD rows + DLQ entries per occurrence. With it, an unmapped tenant is simply
-- silent, and mapping them in /admin/jtd/templates switches them on — the same
-- rollout gate 008 established.
--
-- Schedule status is NOT used to decide whether an occurrence happened: seven
-- past BBB occurrences with 29–35 attendees each are still marked 'scheduled'
-- (status only flips on first check-in, and clearly did not stick). Only
-- occurrence_date is trusted; status is consulted solely to skip
-- cancelled/skipped.

CREATE OR REPLACE FUNCTION public.gs_run_session_notifications()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_now_ist timestamp := (now() at time zone 'Asia/Kolkata');
    v_today   date;
    v_lf      integer := 0;
    v_ns      integer := 0;
BEGIN
    v_today := v_now_ist::date;

    -- ------------------------------------------------------------------
    -- 4a. LOOKING FORWARD — 3 days out and 1 day out
    -- ------------------------------------------------------------------
    -- Requires timing.startTime because the approved template carries a
    -- start_time variable ({{4}}). A block with no start time set sends
    -- nothing at all, rather than a message with a blank in it.
    WITH blk AS (
        SELECT mcb.id AS block_id,
               mcb.tenant_id,
               coalesce(mcb.display_name, mcb.name) AS block_name,
               mcb.config->'groupSession'->'timing'->>'startTime' AS start_time
        FROM public.m_cat_blocks mcb
        WHERE mcb.config->'groupSession'->'timing'->>'startTime' IS NOT NULL
          AND coalesce(mcb.is_active, true)
    ),
    occ AS (
        SELECT s.id AS occ_id, s.tenant_id, s.source_block_id, s.is_live,
               s.occurrence_date, (s.occurrence_date - v_today) AS days_out,
               b.block_name, b.start_time
        FROM public.t_group_session_schedule s
        JOIN blk b ON b.block_id = s.source_block_id AND b.tenant_id = s.tenant_id
        WHERE coalesce(s.status, '') NOT IN ('cancelled', 'skipped')
          AND (s.occurrence_date - v_today) IN (3, 1)
    )
    INSERT INTO public.n_jtd (
        tenant_id, event_type_code, channel_code, source_type_code, source_id,
        recipient_type, recipient_id, recipient_name, recipient_contact,
        template_key, template_variables, metadata, is_live, performed_by_type
    )
    SELECT o.tenant_id, 'reminder', 'whatsapp', 'group_session_looking_forward', o.occ_id,
           'contact', m.contact_id, m.member_name, ph.phone,
           'group_session_looking_forward',
           jsonb_build_object(
               'member_name',     coalesce(m.member_name, ''),
               'session_name',    coalesce(o.block_name, ''),
               'occurrence_date', to_char(o.occurrence_date, 'DD Mon YYYY'),
               'start_time',      o.start_time
           ),
           jsonb_build_object('reminder_key', 'lf_' || o.days_out::text),
           o.is_live, 'system'
    FROM occ o
    CROSS JOIN LATERAL public.gs_roster_members(o.tenant_id, o.source_block_id, o.is_live, o.occurrence_date) m
    CROSS JOIN LATERAL (SELECT public.gs_member_whatsapp_phone(m.contact_id) AS phone) ph
    WHERE ph.phone IS NOT NULL
      AND EXISTS (
          SELECT 1 FROM public.n_jtd_templates t
           WHERE t.tenant_id        = o.tenant_id
             AND t.source_type_code = 'group_session_looking_forward'
             AND t.channel_code     = 'whatsapp'
             AND t.is_active
      )
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_lf = ROW_COUNT;

    -- ------------------------------------------------------------------
    -- 4b. NO-SHOW REGRET — session end + 2 hours
    -- ------------------------------------------------------------------
    -- Session end = occurrence_date + startTime + durationMinutes, in IST.
    -- Needs BOTH timing values; a block missing either sends nothing.
    --
    -- The `occurrence_date >= v_today - 1` guard is the important one. Without
    -- it the very first run would look back over every past occurrence in the
    -- schedule and blast a regret for each one — for BBB that is 8 past
    -- occurrences x ~15 absentees = ~120 messages to real people about
    -- sessions months ago. The guard means only yesterday's and today's
    -- occurrences are ever in scope, so deploying is inert until the next
    -- session actually concludes.
    WITH blk AS (
        SELECT mcb.id AS block_id,
               mcb.tenant_id,
               coalesce(mcb.display_name, mcb.name) AS block_name,
               (mcb.config->'groupSession'->'timing'->>'startTime')::time AS start_time,
               (mcb.config->'groupSession'->'timing'->>'durationMinutes')::int AS duration_min
        FROM public.m_cat_blocks mcb
        WHERE mcb.config->'groupSession'->'timing'->>'startTime'       IS NOT NULL
          AND mcb.config->'groupSession'->'timing'->>'durationMinutes' IS NOT NULL
          AND coalesce(mcb.is_active, true)
    ),
    occ AS (
        SELECT s.id AS occ_id, s.tenant_id, s.source_block_id, s.is_live,
               s.occurrence_date, b.block_name
        FROM public.t_group_session_schedule s
        JOIN blk b ON b.block_id = s.source_block_id AND b.tenant_id = s.tenant_id
        WHERE coalesce(s.status, '') NOT IN ('cancelled', 'skipped')
          AND s.occurrence_date >= v_today - 1
          AND v_now_ist >= (
                s.occurrence_date
              + b.start_time
              + make_interval(mins => b.duration_min)
              + interval '2 hours'
          )
    )
    INSERT INTO public.n_jtd (
        tenant_id, event_type_code, channel_code, source_type_code, source_id,
        recipient_type, recipient_id, recipient_name, recipient_contact,
        template_key, template_variables, metadata, is_live, performed_by_type
    )
    SELECT o.tenant_id, 'reminder', 'whatsapp', 'group_session_noshow_regret', o.occ_id,
           'contact', m.contact_id, m.member_name, ph.phone,
           'group_session_noshow_regret',
           jsonb_build_object(
               'member_name',     coalesce(m.member_name, ''),
               'session_name',    coalesce(o.block_name, ''),
               'occurrence_date', to_char(o.occurrence_date, 'DD Mon YYYY')
           ),
           jsonb_build_object('reminder_key', 'regret'),
           o.is_live, 'system'
    FROM occ o
    CROSS JOIN LATERAL public.gs_roster_members(o.tenant_id, o.source_block_id, o.is_live, o.occurrence_date) m
    CROSS JOIN LATERAL (SELECT public.gs_member_whatsapp_phone(m.contact_id) AS phone) ph
    WHERE ph.phone IS NOT NULL
      -- A substitute is recorded against the MEMBER's own contact_id with
      -- status='present' (verified: 9 rows, 7 distinct members, none NULL), so
      -- sending a substitute excludes you here automatically. 'apologies' is
      -- likewise excluded by requiring 'present' — moot today (0 rows ever).
      AND NOT EXISTS (
          SELECT 1 FROM public.t_session_attendance a
           WHERE a.schedule_occurrence_id = o.occ_id
             AND a.member_contact_id      = m.contact_id
             AND a.status                 = 'present'
      )
      AND EXISTS (
          SELECT 1 FROM public.n_jtd_templates t
           WHERE t.tenant_id        = o.tenant_id
             AND t.source_type_code = 'group_session_noshow_regret'
             AND t.channel_code     = 'whatsapp'
             AND t.is_active
      )
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_ns = ROW_COUNT;

    RETURN jsonb_build_object(
        'ok', true,
        'ist_now', to_char(v_now_ist, 'YYYY-MM-DD HH24:MI'),
        'looking_forward_enqueued', v_lf,
        'noshow_regret_enqueued', v_ns
    );
END;
$function$;

COMMENT ON FUNCTION public.gs_run_session_notifications() IS
'Cron-driven Group Session WhatsApp reminders (looking-forward at 3 and 1 days out; no-show regret at session end + 2h). Idempotent via ux_n_jtd_group_session_reminder. IST-aware.';

-- ============================================================================
-- 5. CRON
-- ============================================================================
-- Every 15 minutes, matching contract-event-scanner. That bounds the no-show
-- regret to within 15 minutes of the intended end+2h mark; looking-forward is
-- date-based so cadence does not affect it beyond "at least once a day".
-- Re-running this migration re-registers the job rather than duplicating it.

DO $$
BEGIN
    PERFORM cron.unschedule('group-session-notifications');
EXCEPTION WHEN OTHERS THEN
    NULL;  -- not previously scheduled
END $$;

SELECT cron.schedule(
    'group-session-notifications',
    '*/15 * * * *',
    'SELECT public.gs_run_session_notifications();'
);

-- ============================================================================
-- 6. BBB TEMPLATE MAPPINGS
-- ============================================================================
-- Same shape as 009. provider_template_id matches the approved MSG91 template
-- name; as with the first two, MSG91 assigned no separate name, so it equals
-- the source_type_code. `content` is documentation only — what actually ships
-- is MSG91's approved body, filled positionally by jtd-worker.
--
-- Variable ORDER below must match the branches added to
-- jtd-worker/handlers/whatsapp.ts in this same batch. jtd-worker fills WhatsApp
-- placeholders positionally, not by name.

INSERT INTO public.n_jtd_templates (
    tenant_id, template_key, name, description, channel_code, source_type_code,
    content, provider_template_id, is_live, is_active
) VALUES
    (
        'dd194710-92b4-4110-80eb-0b492a0d2c1f',
        'group_session_looking_forward',
        'Group Session Looking Forward (BBB)',
        'Sent 3 days and 1 day before an occurrence to every active roster member',
        'whatsapp',
        'group_session_looking_forward',
        'Hi {{member_name}}, looking forward to seeing you at {{session_name}} on {{occurrence_date}} at {{start_time}}. See you there!',
        'group_session_looking_forward',
        true,
        true
    ),
    (
        'dd194710-92b4-4110-80eb-0b492a0d2c1f',
        'group_session_noshow_regret',
        'Group Session No-Show Regret (BBB)',
        'Sent 2 hours after a session ends to roster members who did not check in',
        'whatsapp',
        'group_session_noshow_regret',
        'Hi {{member_name}}, we missed you at {{session_name}} on {{occurrence_date}}. Hope to see you at the next one!',
        'group_session_noshow_regret',
        true,
        true
    )
ON CONFLICT (tenant_id, template_key, channel_code, is_live) DO UPDATE SET
    provider_template_id = EXCLUDED.provider_template_id,
    content              = EXCLUDED.content,
    is_active            = EXCLUDED.is_active,
    updated_at           = NOW();
