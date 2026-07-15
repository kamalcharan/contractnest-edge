-- ============================================================================
-- bbb-foundation/018_group_session_dashboard_rpcs.sql
-- Phase 1 of the Group Sessions dashboard: chair-side, tenant-scoped read RPCs.
-- ALREADY APPLIED LIVE to project uwyqhzotluikawcboldr (file = repo record;
-- re-running these CREATE OR REPLACE statements is a safe no-op).
--
-- A "group session" = a t_contracts row flagged metadata.group_session_owner='true'
-- that owns the shared audience='group' service occurrences (the schedule).
-- Roster = tenant contacts who are the buyer on an active billing contract
-- (reuses gs_membership_contract from 017). SECURITY DEFINER: the underlying
-- tables have RLS enabled with no policies, so access is via these RPCs only.
-- ============================================================================

-- 1. list group sessions with aggregates
CREATE OR REPLACE FUNCTION gs_dash_sessions(p_tenant uuid, p_is_live boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v jsonb; v_roster int;
BEGIN
  SELECT count(*) INTO v_roster FROM t_contacts ct
    WHERE ct.tenant_id=p_tenant AND gs_membership_contract(p_tenant, ct.id) IS NOT NULL;
  SELECT coalesce(jsonb_agg(r ORDER BY r->>'name'), '[]'::jsonb) INTO v FROM (
    SELECT jsonb_build_object(
      'contract_id', c.id,
      'name', coalesce(c.name,'Group Session'),
      'occurrences_total', (select count(*) from t_contract_events e where e.contract_id=c.id and e.event_type='service'),
      'occurrences_done',  (select count(*) from t_contract_events e where e.contract_id=c.id and e.event_type='service' and e.scheduled_date::date < current_date),
      'next_occurrence',   (select min(e.scheduled_date::date) from t_contract_events e where e.contract_id=c.id and e.event_type='service' and e.scheduled_date::date >= current_date),
      'roster_size', v_roster,
      'qr_ready', exists(select 1 from t_group_session_tokens t where t.contract_id=c.id and t.is_active),
      'attendance_pct', (
        select case when cnt.occ=0 or v_roster=0 then null
          else round(100.0 * cnt.present / (cnt.occ * v_roster)) end
        from (
          select count(distinct e.id) as occ,
                 count(a.id) filter (where a.status='present') as present
          from t_contract_events e
          left join t_session_attendance a on a.occurrence_event_id=e.id
          where e.contract_id=c.id and e.event_type='service' and e.scheduled_date::date < current_date
        ) cnt)
    ) AS r
    FROM t_contracts c
    WHERE c.tenant_id=p_tenant AND coalesce(c.is_live,true)=p_is_live
      AND coalesce(c.metadata->>'group_session_owner','false')='true'
  ) s;
  RETURN jsonb_build_object('sessions', v, 'roster_size', v_roster);
END $$;

-- 2. occurrences for one session + attendance counts
CREATE OR REPLACE FUNCTION gs_dash_occurrences(p_tenant uuid, p_contract uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(r ORDER BY (r->>'date')), '[]'::jsonb) INTO v FROM (
    SELECT jsonb_build_object(
      'event_id', e.id,
      'date', e.scheduled_date::date,
      'seq', e.sequence_number, 'total', e.total_occurrences,
      'status', case when e.scheduled_date::date < current_date then 'past' else 'upcoming' end,
      'present', (select count(*) from t_session_attendance a where a.occurrence_event_id=e.id and a.status='present')
    ) AS r
    FROM t_contract_events e
    WHERE e.contract_id=p_contract AND e.event_type='service'
  ) s;
  RETURN jsonb_build_object('occurrences', v);
END $$;

-- 3. enumerate roster for a session + per-member attendance + dues (NEW capability)
CREATE OR REPLACE FUNCTION gs_dash_roster(p_tenant uuid, p_contract uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(r ORDER BY r->>'name'), '[]'::jsonb) INTO v FROM (
    SELECT jsonb_build_object(
      'contact_id', ct.id,
      'name', ct.name,
      'membership_contract_id', mc,
      'attended', (select count(*) from t_session_attendance a where a.session_contract_id=p_contract and a.member_contact_id=ct.id and a.status='present'),
      'dues_pending', exists(select 1 from t_contract_events be where be.contract_id=mc and be.event_type='billing' and coalesce(be.status,'')<>'paid')
    ) AS r
    FROM t_contacts ct
    CROSS JOIN LATERAL gs_membership_contract(p_tenant, ct.id) AS mc
    WHERE ct.tenant_id=p_tenant AND mc IS NOT NULL
  ) s;
  RETURN jsonb_build_object('roster', v);
END $$;

-- 4. member detail (chair-side, no token)
CREATE OR REPLACE FUNCTION gs_dash_member(p_tenant uuid, p_member uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_mc uuid; v_att jsonb; v_bill jsonb;
BEGIN
  v_mc := gs_membership_contract(p_tenant, p_member);
  SELECT coalesce(jsonb_agg(jsonb_build_object('date',a.occurrence_date,'status',a.status) ORDER BY a.occurrence_date desc),'[]'::jsonb)
    INTO v_att FROM t_session_attendance a WHERE a.tenant_id=p_tenant AND a.member_contact_id=p_member;
  SELECT coalesce(jsonb_agg(jsonb_build_object('label',be.billing_cycle_label,'date',be.scheduled_date::date,'amount',be.amount,'currency',be.currency,'status',be.status) ORDER BY be.scheduled_date),'[]'::jsonb)
    INTO v_bill FROM t_contract_events be WHERE be.contract_id=v_mc AND be.event_type='billing';
  RETURN jsonb_build_object('membership_contract_id', v_mc, 'attendance', v_att, 'billing', v_bill);
END $$;

GRANT EXECUTE ON FUNCTION gs_dash_sessions(uuid,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_dash_occurrences(uuid,uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_dash_roster(uuid,uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_dash_member(uuid,uuid) TO authenticated, service_role;
