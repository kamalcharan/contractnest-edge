-- Freeze completed (held) occurrences: date and chair become immutable once
-- an occurrence's status is 'held'; attendance corrections stay editable.
-- Add an audit trail (t_audit_log, mirroring update_appointment's p_changed_by
-- convention) for move/status/chair-assign/attendance actions.
-- Fix substitute check-in display: gs_occurrence_attendance now prefers the
-- attendance row's member_name (which already carries the substitute-decorated
-- string from gs_checkin_substitute) instead of always showing the contract's
-- buyer_name.

CREATE OR REPLACE FUNCTION public.gs_schedule_move(p_tenant uuid, p_id uuid, p_new_date date, p_note text DEFAULT NULL::text, p_changed_by uuid DEFAULT NULL::uuid, p_changed_by_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_block uuid; v_live boolean; v_status text; v_old_date date;
BEGIN
  SELECT source_block_id, is_live, status, occurrence_date INTO v_block, v_live, v_status, v_old_date
  FROM t_group_session_schedule WHERE id=p_id AND tenant_id=p_tenant;
  IF v_block IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_status = 'held' THEN RETURN jsonb_build_object('ok', false, 'reason', 'occurrence_completed'); END IF;

  UPDATE t_group_session_schedule
    SET occurrence_date=p_new_date, note=coalesce(p_note, note), updated_at=now()
  WHERE id=p_id AND tenant_id=p_tenant;

  INSERT INTO t_audit_log (tenant_id, entity_type, entity_id, category, action, description, old_value, new_value, performed_by, performed_by_name)
  VALUES (p_tenant, 'group_session_occurrence', p_id, 'group_session', 'occurrence_moved',
    format('Session moved %s → %s', v_old_date, p_new_date),
    jsonb_build_object('occurrence_date', v_old_date), jsonb_build_object('occurrence_date', p_new_date, 'note', p_note),
    p_changed_by, p_changed_by_name);

  PERFORM gs_renumber_schedule(p_tenant, v_block, v_live);
  RETURN gs_dash_occurrences(p_tenant, v_block, v_live);
END $function$;

CREATE OR REPLACE FUNCTION public.gs_schedule_status(p_tenant uuid, p_id uuid, p_status text, p_note text DEFAULT NULL::text, p_changed_by uuid DEFAULT NULL::uuid, p_changed_by_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_block uuid; v_live boolean; v_old_status text;
BEGIN
  IF p_status NOT IN ('scheduled','held','skipped','cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_status');
  END IF;
  SELECT source_block_id, is_live, status INTO v_block, v_live, v_old_status
  FROM t_group_session_schedule WHERE id=p_id AND tenant_id=p_tenant;
  IF v_block IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_old_status = 'held' AND p_status <> 'held' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'occurrence_completed');
  END IF;

  UPDATE t_group_session_schedule
    SET status=p_status, note=coalesce(p_note, note), updated_at=now()
  WHERE id=p_id AND tenant_id=p_tenant;

  IF p_status IS DISTINCT FROM v_old_status THEN
    INSERT INTO t_audit_log (tenant_id, entity_type, entity_id, category, action, description, old_value, new_value, performed_by, performed_by_name)
    VALUES (p_tenant, 'group_session_occurrence', p_id, 'group_session', 'occurrence_status_changed',
      format('Session status %s → %s', v_old_status, p_status),
      jsonb_build_object('status', v_old_status), jsonb_build_object('status', p_status, 'note', p_note),
      p_changed_by, p_changed_by_name);
  END IF;

  PERFORM gs_renumber_schedule(p_tenant, v_block, v_live);
  RETURN gs_dash_occurrences(p_tenant, v_block, v_live);
END $function$;

CREATE OR REPLACE FUNCTION public.gs_schedule_assign(p_tenant uuid, p_id uuid, p_assigned_to uuid, p_assigned_to_name text DEFAULT NULL::text, p_changed_by uuid DEFAULT NULL::uuid, p_changed_by_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_block uuid; v_live boolean; v_date date; v_status text; v_appt_id uuid; v_old_name text;
BEGIN
  SELECT source_block_id, is_live, occurrence_date, status, assigned_to_name
    INTO v_block, v_live, v_date, v_status, v_old_name
  FROM t_group_session_schedule WHERE id=p_id AND tenant_id=p_tenant;
  IF v_block IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_status = 'held' THEN RETURN jsonb_build_object('ok', false, 'reason', 'occurrence_completed'); END IF;

  IF p_assigned_to IS NULL THEN
    UPDATE t_group_session_schedule
      SET assigned_to=NULL, assigned_to_name=NULL, updated_at=now()
    WHERE id=p_id AND tenant_id=p_tenant;

    UPDATE t_appointments SET is_active=false, updated_at=now()
    WHERE group_session_occurrence_id=p_id AND is_active=true;

    INSERT INTO t_audit_log (tenant_id, entity_type, entity_id, category, action, description, old_value, new_value, performed_by, performed_by_name)
    VALUES (p_tenant, 'group_session_occurrence', p_id, 'group_session', 'chair_unassigned',
      format('Chair removed (was %s)', coalesce(v_old_name, 'unassigned')),
      jsonb_build_object('assigned_to_name', v_old_name), jsonb_build_object('assigned_to_name', NULL),
      p_changed_by, p_changed_by_name);

    RETURN gs_dash_occurrences(p_tenant, v_block, v_live);
  END IF;

  UPDATE t_group_session_schedule
    SET assigned_to=p_assigned_to, assigned_to_name=p_assigned_to_name, updated_at=now()
  WHERE id=p_id AND tenant_id=p_tenant;

  INSERT INTO t_audit_log (tenant_id, entity_type, entity_id, category, action, description, old_value, new_value, performed_by, performed_by_name)
  VALUES (p_tenant, 'group_session_occurrence', p_id, 'group_session', 'chair_assigned',
    format('Chair %s → %s', coalesce(v_old_name, 'unassigned'), p_assigned_to_name),
    jsonb_build_object('assigned_to_name', v_old_name), jsonb_build_object('assigned_to_name', p_assigned_to_name),
    p_changed_by, p_changed_by_name);

  SELECT id INTO v_appt_id FROM t_appointments
  WHERE group_session_occurrence_id=p_id AND is_active=true;

  IF v_appt_id IS NULL THEN
    INSERT INTO t_appointments
      (tenant_id, group_session_occurrence_id, status, scheduled_at, assigned_to, assigned_to_name, is_live)
    VALUES
      (p_tenant, p_id, 'accepted', v_date::timestamptz, p_assigned_to, p_assigned_to_name, v_live);
  ELSE
    UPDATE t_appointments
    SET assigned_to=p_assigned_to, assigned_to_name=p_assigned_to_name, scheduled_at=v_date::timestamptz,
        status='accepted', version=version+1, last_activity_at=now(), updated_at=now()
    WHERE id=v_appt_id;
  END IF;

  RETURN gs_dash_occurrences(p_tenant, v_block, v_live);
END $function$;

CREATE OR REPLACE FUNCTION public.gs_schedule_assign_default(p_tenant uuid, p_block uuid, p_is_live boolean, p_assigned_to uuid, p_assigned_to_name text DEFAULT NULL::text, p_changed_by uuid DEFAULT NULL::uuid, p_changed_by_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r RECORD; v_count int := 0;
BEGIN
  FOR r IN
    SELECT id FROM t_group_session_schedule
    WHERE tenant_id=p_tenant AND source_block_id=p_block AND is_live=p_is_live
      AND occurrence_date >= current_date AND status <> 'cancelled' AND status <> 'held'
  LOOP
    PERFORM gs_schedule_assign(p_tenant, r.id, p_assigned_to, p_assigned_to_name, p_changed_by, p_changed_by_name);
    v_count := v_count + 1;
  END LOOP;

  UPDATE m_cat_blocks
    SET config = jsonb_set(
      coalesce(config, '{}'::jsonb),
      '{groupSession}',
      coalesce(config->'groupSession', '{}'::jsonb) || jsonb_build_object(
        'defaultChairContactId', p_assigned_to,
        'defaultChairName', p_assigned_to_name
      ),
      true
    )
  WHERE id = p_block;

  RETURN jsonb_build_object('ok', true, 'assigned_count', v_count, 'occurrences', (gs_dash_occurrences(p_tenant, p_block, p_is_live)->'occurrences'));
END $function$;

CREATE OR REPLACE FUNCTION public.gs_mark_attendance(p_tenant uuid, p_occurrence uuid, p_member uuid, p_present boolean, p_member_name text DEFAULT NULL::text, p_changed_by uuid DEFAULT NULL::uuid, p_changed_by_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_block uuid; v_date date; v_status text; v_old_status text;
BEGIN
  SELECT source_block_id, occurrence_date INTO v_block, v_date
  FROM t_group_session_schedule WHERE id=p_occurrence AND tenant_id=p_tenant;
  IF v_block IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  v_status := CASE WHEN p_present THEN 'present' ELSE 'absent' END;

  SELECT status INTO v_old_status FROM t_session_attendance
  WHERE schedule_occurrence_id=p_occurrence AND member_contact_id=p_member;

  INSERT INTO t_session_attendance (tenant_id, source_block_id, schedule_occurrence_id, occurrence_date, member_contact_id, member_name, status, checked_in_at)
  VALUES (p_tenant, v_block, p_occurrence, v_date, p_member, p_member_name, v_status, now())
  ON CONFLICT (schedule_occurrence_id, member_contact_id) WHERE schedule_occurrence_id IS NOT NULL AND member_contact_id IS NOT NULL
    DO UPDATE SET status=excluded.status, member_name=coalesce(excluded.member_name, t_session_attendance.member_name), checked_in_at=now();

  IF v_old_status IS DISTINCT FROM v_status THEN
    INSERT INTO t_audit_log (tenant_id, entity_type, entity_id, category, action, description, old_value, new_value, performed_by, performed_by_name)
    VALUES (p_tenant, 'group_session_attendance', p_occurrence, 'group_session', 'attendance_marked',
      format('%s marked %s', coalesce(p_member_name, 'Member'), v_status),
      jsonb_build_object('status', v_old_status), jsonb_build_object('status', v_status),
      p_changed_by, p_changed_by_name);
  END IF;

  UPDATE t_group_session_schedule SET status='held', updated_at=now() WHERE id=p_occurrence AND status='scheduled';
  RETURN gs_occurrence_attendance(p_tenant, p_occurrence);
END $function$;

CREATE OR REPLACE FUNCTION public.gs_occurrence_attendance(p_tenant uuid, p_occurrence uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_occ record; v_roster jsonb; v_present int;
BEGIN
  SELECT id, source_block_id, is_live, occurrence_date, seq, status
    INTO v_occ FROM t_group_session_schedule WHERE id=p_occurrence AND tenant_id=p_tenant;
  IF v_occ.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  SELECT count(*) INTO v_present FROM t_session_attendance a
   WHERE a.schedule_occurrence_id=p_occurrence AND a.status='present';
  SELECT coalesce(jsonb_agg(r ORDER BY r->>'name'), '[]'::jsonb) INTO v_roster FROM (
    SELECT jsonb_build_object(
      'contact_id', m.buyer_id,
      'name', coalesce(a.member_name, m.buyer_name),
      'membership_contract_id', m.contract_id,
      'present', coalesce(a.status='present', false),
      'dues_pending', exists(SELECT 1 FROM t_contract_events be WHERE be.contract_id=m.contract_id AND be.event_type='billing' AND coalesce(be.status,'')<>'paid')
    ) AS r
    FROM (SELECT DISTINCT ON (c.buyer_id) c.buyer_id, c.buyer_name, c.id AS contract_id
      FROM t_contract_blocks cb JOIN t_contracts c ON c.id=cb.contract_id
      WHERE cb.source_block_id=v_occ.source_block_id AND c.tenant_id=p_tenant AND coalesce(c.is_live,true)=v_occ.is_live AND c.status='active'
      ORDER BY c.buyer_id, c.start_date DESC NULLS LAST) m
    LEFT JOIN t_session_attendance a ON a.schedule_occurrence_id=p_occurrence AND a.member_contact_id=m.buyer_id
  ) s;
  RETURN jsonb_build_object('ok', true,
    'occurrence', jsonb_build_object('event_id', v_occ.id, 'date', v_occ.occurrence_date, 'seq', v_occ.seq, 'status', v_occ.status, 'block_id', v_occ.source_block_id),
    'present_count', v_present, 'roster', v_roster);
END $function$;
