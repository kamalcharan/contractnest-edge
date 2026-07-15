-- ============================================================================
-- bbb-foundation/023_group_session_drilldowns.sql
-- Phase E: data for the reference dashboard drill-downs.
--   * gs_occurrence_attendance(tenant, occurrence) → one session's roster with
--     present/absent + present count (the Occurrence attendance screen).
--   * gs_mark_attendance(tenant, occurrence, member, present, name) → chair marks
--     a member present/absent for that occurrence (manual, no QR).
--   * gs_member_block(tenant, block, member, is_live) → member profile within a
--     block: per-occurrence attendance grid + dues + billing history.
-- Block-scoped, SECURITY DEFINER, RLS-on-no-policies. Idempotent.
-- ============================================================================

-- one occurrence → roster with present/absent -------------------------------
CREATE OR REPLACE FUNCTION gs_occurrence_attendance(p_tenant uuid, p_occurrence uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_occ record; v_roster jsonb; v_present int;
BEGIN
  SELECT id, source_block_id, is_live, occurrence_date, seq, status
    INTO v_occ FROM t_group_session_schedule
   WHERE id=p_occurrence AND tenant_id=p_tenant;
  IF v_occ.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;

  SELECT count(*) INTO v_present FROM t_session_attendance a
   WHERE a.schedule_occurrence_id=p_occurrence AND a.status='present';

  SELECT coalesce(jsonb_agg(r ORDER BY r->>'name'), '[]'::jsonb) INTO v_roster FROM (
    SELECT jsonb_build_object(
      'contact_id', m.buyer_id, 'name', m.buyer_name,
      'membership_contract_id', m.contract_id,
      'present', exists(SELECT 1 FROM t_session_attendance a
                         WHERE a.schedule_occurrence_id=p_occurrence
                           AND a.member_contact_id=m.buyer_id AND a.status='present'),
      'dues_pending', exists(SELECT 1 FROM t_contract_events be
                              WHERE be.contract_id=m.contract_id AND be.event_type='billing'
                                AND coalesce(be.status,'')<>'paid')
    ) AS r
    FROM (
      SELECT DISTINCT ON (c.buyer_id) c.buyer_id, c.buyer_name, c.id AS contract_id
      FROM t_contract_blocks cb JOIN t_contracts c ON c.id=cb.contract_id
      WHERE cb.source_block_id=v_occ.source_block_id AND c.tenant_id=p_tenant
        AND coalesce(c.is_live,true)=v_occ.is_live AND c.status='active'
      ORDER BY c.buyer_id, c.start_date DESC NULLS LAST
    ) m
  ) s;

  RETURN jsonb_build_object('ok', true,
    'occurrence', jsonb_build_object('event_id', v_occ.id, 'date', v_occ.occurrence_date,
                                     'seq', v_occ.seq, 'status', v_occ.status,
                                     'block_id', v_occ.source_block_id),
    'present_count', v_present, 'roster', v_roster);
END $$;

-- chair marks a member present/absent for an occurrence ----------------------
CREATE OR REPLACE FUNCTION gs_mark_attendance(
  p_tenant uuid, p_occurrence uuid, p_member uuid, p_present boolean, p_member_name text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_occ record; v_status text := CASE WHEN p_present THEN 'present' ELSE 'apologies' END;
BEGIN
  SELECT id, source_block_id, is_live, occurrence_date INTO v_occ
    FROM t_group_session_schedule WHERE id=p_occurrence AND tenant_id=p_tenant;
  IF v_occ.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;

  INSERT INTO t_session_attendance
    (tenant_id, source_block_id, schedule_occurrence_id, occurrence_date, member_contact_id, member_name, status)
  VALUES (p_tenant, v_occ.source_block_id, p_occurrence, v_occ.occurrence_date, p_member, p_member_name, v_status)
  ON CONFLICT (schedule_occurrence_id, member_contact_id)
    WHERE schedule_occurrence_id IS NOT NULL AND member_contact_id IS NOT NULL
    DO UPDATE SET status=excluded.status, member_name=coalesce(excluded.member_name, t_session_attendance.member_name), checked_in_at=now();

  UPDATE t_group_session_schedule SET status='held', updated_at=now()
   WHERE id=p_occurrence AND status='scheduled';

  RETURN gs_occurrence_attendance(p_tenant, p_occurrence);
END $$;

-- member profile within a block: attendance grid + dues + billing ------------
CREATE OR REPLACE FUNCTION gs_member_block(p_tenant uuid, p_block uuid, p_member uuid, p_is_live boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_mc uuid; v_name text; v_att jsonb; v_bill jsonb; v_attended int; v_done int; v_last date;
BEGIN
  v_mc := gs_block_membership_contract(p_tenant, p_block, p_member, p_is_live);
  SELECT name INTO v_name FROM t_contacts WHERE id=p_member;

  -- per-occurrence attendance grid (past + upcoming), present = has a present row
  SELECT coalesce(jsonb_agg(jsonb_build_object(
            'date', s.occurrence_date, 'seq', s.seq,
            'is_past', s.occurrence_date < current_date,
            'present', exists(SELECT 1 FROM t_session_attendance a
                               WHERE a.schedule_occurrence_id=s.id AND a.member_contact_id=p_member AND a.status='present'))
            ORDER BY s.occurrence_date), '[]'::jsonb)
    INTO v_att
    FROM t_group_session_schedule s
   WHERE s.tenant_id=p_tenant AND s.source_block_id=p_block AND s.is_live=p_is_live AND s.status<>'cancelled';

  SELECT count(*) INTO v_attended FROM t_session_attendance a
   WHERE a.source_block_id=p_block AND a.member_contact_id=p_member AND a.status='present';
  SELECT count(*) INTO v_done FROM t_group_session_schedule s
   WHERE s.tenant_id=p_tenant AND s.source_block_id=p_block AND s.is_live=p_is_live
     AND s.status<>'cancelled' AND s.occurrence_date < current_date;
  SELECT max(a.occurrence_date) INTO v_last FROM t_session_attendance a
   WHERE a.source_block_id=p_block AND a.member_contact_id=p_member AND a.status='present';

  SELECT coalesce(jsonb_agg(jsonb_build_object(
            'event_id', e.id, 'label', coalesce(e.billing_cycle_label, e.block_name),
            'date', e.scheduled_date::date, 'amount', e.amount, 'currency', e.currency, 'status', e.status)
            ORDER BY e.scheduled_date), '[]'::jsonb)
    INTO v_bill FROM t_contract_events e WHERE e.contract_id=v_mc AND e.event_type='billing';

  RETURN jsonb_build_object('ok', true, 'name', v_name, 'membership_contract_id', v_mc,
    'attended', v_attended, 'occurrences_done', v_done, 'last_seen', v_last,
    'dues_pending', exists(SELECT 1 FROM t_contract_events be WHERE be.contract_id=v_mc AND be.event_type='billing' AND coalesce(be.status,'')<>'paid'),
    'attendance', v_att, 'billing', v_bill);
END $$;

GRANT EXECUTE ON FUNCTION gs_occurrence_attendance(uuid,uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_mark_attendance(uuid,uuid,uuid,boolean,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_member_block(uuid,uuid,uuid,boolean) TO authenticated, service_role;
