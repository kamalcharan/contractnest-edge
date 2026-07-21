-- Roster page now shows every member as a card with their own attendance
-- history grid, not just aggregate counts — gs_dash_roster needs to return
-- each member's occurrence-by-occurrence attendance array (same shape
-- gs_member_block already computes per-member) so ~60 members' grids load
-- in one call instead of one API call per member.

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
      'dues_pending', exists(select 1 from t_contract_events be where be.contract_id=m.contract_id and be.event_type='billing' and coalesce(be.status,'')<>'paid'),
      'attendance', m.attendance
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
        ) AS substituted,
        (SELECT coalesce(jsonb_agg(jsonb_build_object(
              'date', s.occurrence_date, 'seq', s.seq, 'is_past', s.occurrence_date < current_date,
              'present', exists(SELECT 1 FROM t_session_attendance a WHERE a.schedule_occurrence_id=s.id AND a.member_contact_id=c.buyer_id AND a.status='present'),
              'is_substitute', exists(SELECT 1 FROM t_session_attendance a WHERE a.schedule_occurrence_id=s.id AND a.member_contact_id=c.buyer_id AND a.status='present' AND a.form_responses->>'is_substitute'='true')
            ) ORDER BY s.occurrence_date), '[]'::jsonb)
         FROM t_group_session_schedule s
         WHERE s.tenant_id=p_tenant AND s.source_block_id=p_block AND s.is_live=p_is_live AND s.status<>'cancelled'
        ) AS attendance
      FROM t_contract_blocks cb JOIN t_contracts c ON c.id=cb.contract_id
      WHERE cb.source_block_id=p_block AND c.tenant_id=p_tenant AND coalesce(c.is_live,true)=p_is_live AND c.status='active'
      ORDER BY c.buyer_id, c.start_date DESC NULLS LAST
    ) m
  ) s;
  RETURN jsonb_build_object('roster', v);
END $function$;
