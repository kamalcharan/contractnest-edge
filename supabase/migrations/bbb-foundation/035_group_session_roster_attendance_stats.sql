-- Per-member roster/member-drill-down stats: overall/attended/missed/substituted,
-- scoped to each member's OWN contract window (start_date..LEAST(today,end_date)),
-- not the block's total — fixes the "everyone shows the same denominator" bug.
-- The attendance-policy cap is read from the MEMBER'S OWN contract snapshot
-- (t_contract_blocks.custom_fields.config.groupSession.attendancePolicy — a real
-- signed T&C), not the live catalog block, so a later policy change never
-- retroactively applies to someone who already signed under different terms.

CREATE OR REPLACE FUNCTION public.gs_dash_roster(p_tenant uuid, p_block uuid, p_is_live boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(r ORDER BY r->>'name'), '[]'::jsonb) INTO v FROM (
    SELECT jsonb_build_object(
      'contact_id', m.buyer_id, 'name', m.buyer_name, 'membership_contract_id', m.contract_id,
      'contract_name', m.contract_name, 'start_date', m.start_date, 'end_date', m.end_date,
      'overall', m.overall,
      'attended', m.attended,
      'missed', m.overall - m.attended,
      'substituted', m.substituted,
      'max_no_shows', m.max_no_shows,
      'max_substitutes', m.max_substitutes,
      'over_no_show_cap', (m.max_no_shows IS NOT NULL AND (m.overall - m.attended) >= m.max_no_shows),
      'over_substitute_cap', (m.max_substitutes IS NOT NULL AND m.substituted >= m.max_substitutes),
      'dues_pending', exists(select 1 from t_contract_events be where be.contract_id=m.contract_id and be.event_type='billing' and coalesce(be.status,'')<>'paid')
    ) AS r
    FROM (
      SELECT DISTINCT ON (c.buyer_id)
        c.buyer_id, c.buyer_name, c.id AS contract_id, c.name AS contract_name, c.start_date, c.end_date,
        (cb.custom_fields->'config'->'groupSession'->'attendancePolicy'->>'maxNoShows')::int AS max_no_shows,
        (cb.custom_fields->'config'->'groupSession'->'attendancePolicy'->>'maxSubstitutes')::int AS max_substitutes,
        (SELECT count(*) FROM t_group_session_schedule s
           WHERE s.tenant_id=p_tenant AND s.source_block_id=p_block AND s.is_live=p_is_live
             AND s.status NOT IN ('cancelled','skipped')
             AND (c.start_date IS NULL OR s.occurrence_date >= c.start_date::date)
             AND s.occurrence_date <= LEAST(current_date, coalesce(c.end_date::date, current_date))
        ) AS overall,
        (SELECT count(*) FROM t_session_attendance a
           WHERE a.source_block_id=p_block AND a.member_contact_id=c.buyer_id AND a.status='present'
             AND (c.start_date IS NULL OR a.occurrence_date >= c.start_date::date)
             AND a.occurrence_date <= LEAST(current_date, coalesce(c.end_date::date, current_date))
        ) AS attended,
        (SELECT count(*) FROM t_session_attendance a
           WHERE a.source_block_id=p_block AND a.member_contact_id=c.buyer_id AND a.status='present'
             AND a.form_responses->>'is_substitute'='true'
             AND (c.start_date IS NULL OR a.occurrence_date >= c.start_date::date)
             AND a.occurrence_date <= LEAST(current_date, coalesce(c.end_date::date, current_date))
        ) AS substituted
      FROM t_contract_blocks cb JOIN t_contracts c ON c.id=cb.contract_id
      WHERE cb.source_block_id=p_block AND c.tenant_id=p_tenant AND coalesce(c.is_live,true)=p_is_live AND c.status='active'
      ORDER BY c.buyer_id, c.start_date DESC NULLS LAST
    ) m
  ) s;
  RETURN jsonb_build_object('roster', v);
END $function$;

CREATE OR REPLACE FUNCTION public.gs_member_block(p_tenant uuid, p_block uuid, p_member uuid, p_is_live boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_mc uuid; v_name text; v_att jsonb; v_bill jsonb;
  v_start date; v_end date; v_overall int; v_attended int; v_substituted int; v_last date;
  v_max_no_shows int; v_max_substitutes int;
BEGIN
  v_mc := gs_block_membership_contract(p_tenant, p_block, p_member, p_is_live);
  SELECT name INTO v_name FROM t_contacts WHERE id=p_member;

  SELECT c.start_date::date, c.end_date::date,
    (cb.custom_fields->'config'->'groupSession'->'attendancePolicy'->>'maxNoShows')::int,
    (cb.custom_fields->'config'->'groupSession'->'attendancePolicy'->>'maxSubstitutes')::int
  INTO v_start, v_end, v_max_no_shows, v_max_substitutes
  FROM t_contract_blocks cb JOIN t_contracts c ON c.id=cb.contract_id
  WHERE cb.contract_id=v_mc AND cb.source_block_id=p_block
  LIMIT 1;

  SELECT coalesce(jsonb_agg(jsonb_build_object('date', s.occurrence_date, 'seq', s.seq, 'is_past', s.occurrence_date < current_date,
            'present', exists(SELECT 1 FROM t_session_attendance a WHERE a.schedule_occurrence_id=s.id AND a.member_contact_id=p_member AND a.status='present'),
            'is_substitute', exists(SELECT 1 FROM t_session_attendance a WHERE a.schedule_occurrence_id=s.id AND a.member_contact_id=p_member AND a.status='present' AND a.form_responses->>'is_substitute'='true'))
            ORDER BY s.occurrence_date), '[]'::jsonb)
    INTO v_att FROM t_group_session_schedule s
   WHERE s.tenant_id=p_tenant AND s.source_block_id=p_block AND s.is_live=p_is_live AND s.status<>'cancelled';

  SELECT count(*) INTO v_overall FROM t_group_session_schedule s
   WHERE s.tenant_id=p_tenant AND s.source_block_id=p_block AND s.is_live=p_is_live
     AND s.status NOT IN ('cancelled','skipped')
     AND (v_start IS NULL OR s.occurrence_date >= v_start)
     AND s.occurrence_date <= LEAST(current_date, coalesce(v_end, current_date));

  SELECT count(*) INTO v_attended FROM t_session_attendance a
   WHERE a.source_block_id=p_block AND a.member_contact_id=p_member AND a.status='present'
     AND (v_start IS NULL OR a.occurrence_date >= v_start)
     AND a.occurrence_date <= LEAST(current_date, coalesce(v_end, current_date));

  SELECT count(*) INTO v_substituted FROM t_session_attendance a
   WHERE a.source_block_id=p_block AND a.member_contact_id=p_member AND a.status='present'
     AND a.form_responses->>'is_substitute'='true'
     AND (v_start IS NULL OR a.occurrence_date >= v_start)
     AND a.occurrence_date <= LEAST(current_date, coalesce(v_end, current_date));

  SELECT max(a.occurrence_date) INTO v_last FROM t_session_attendance a WHERE a.source_block_id=p_block AND a.member_contact_id=p_member AND a.status='present';

  SELECT coalesce(jsonb_agg(jsonb_build_object('event_id', e.id, 'label', coalesce(e.billing_cycle_label, e.block_name), 'date', e.scheduled_date::date, 'amount', e.amount, 'currency', e.currency, 'status', e.status) ORDER BY e.scheduled_date), '[]'::jsonb)
    INTO v_bill FROM t_contract_events e WHERE e.contract_id=v_mc AND e.event_type='billing';

  RETURN jsonb_build_object('ok', true, 'name', v_name, 'membership_contract_id', v_mc,
    'attended', v_attended, 'occurrences_done', v_overall, 'overall', v_overall,
    'missed', v_overall - v_attended, 'substituted', v_substituted,
    'max_no_shows', v_max_no_shows, 'max_substitutes', v_max_substitutes,
    'over_no_show_cap', (v_max_no_shows IS NOT NULL AND (v_overall - v_attended) >= v_max_no_shows),
    'over_substitute_cap', (v_max_substitutes IS NOT NULL AND v_substituted >= v_max_substitutes),
    'last_seen', v_last,
    'dues_pending', exists(SELECT 1 FROM t_contract_events be WHERE be.contract_id=v_mc AND be.event_type='billing' AND coalesce(be.status,'')<>'paid'),
    'attendance', v_att, 'billing', v_bill);
END $function$;
