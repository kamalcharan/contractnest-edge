-- gs_generate_schedule: honor an explicit first-occurrence date
-- (config.serviceCycles.anchorDate) when the catalog-studio block sets one,
-- instead of always deriving it as "next occurrence of anchorWeekday on/after
-- the earliest contract start date". Existing blocks with no anchorDate keep
-- today's exact behavior — this only takes effect when the field is set.
CREATE OR REPLACE FUNCTION public.gs_generate_schedule(p_tenant uuid, p_block uuid, p_is_live boolean DEFAULT true, p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_cfg jsonb; v_days int; v_anchor int; v_anchor_date date; v_start date; v_end date; v_first date; v_d date;
  v_default_chair uuid; v_default_chair_name text;
BEGIN
  SELECT config->'serviceCycles' INTO v_cfg FROM m_cat_blocks WHERE id=p_block;
  v_days := coalesce((v_cfg->>'days')::int, 14);
  IF v_days < 1 THEN v_days := 14; END IF;
  v_anchor := (v_cfg->>'anchorWeekday')::int;
  v_anchor_date := nullif(v_cfg->>'anchorDate','')::date;

  SELECT nullif(config->'groupSession'->>'defaultChairContactId','')::uuid,
         config->'groupSession'->>'defaultChairName'
    INTO v_default_chair, v_default_chair_name
  FROM m_cat_blocks WHERE id=p_block;

  SELECT coalesce(p_start, min(c.start_date)::date),
         coalesce(p_end,   max(c.end_date)::date)
    INTO v_start, v_end
  FROM t_contract_blocks cb JOIN t_contracts c ON c.id=cb.contract_id
  WHERE cb.source_block_id=p_block AND c.tenant_id=p_tenant
    AND coalesce(c.is_live,true)=p_is_live AND c.status='active';
  v_start := coalesce(v_start, (now() at time zone 'Asia/Kolkata')::date);
  v_end   := coalesce(v_end, v_start + 365);
  IF v_anchor_date IS NOT NULL THEN
    v_first := v_anchor_date;
  ELSIF v_anchor IS NOT NULL THEN
    v_first := v_start + ((v_anchor - extract(dow from v_start)::int + 7) % 7);
  ELSE
    v_first := v_start;
  END IF;
  v_d := v_first;
  WHILE v_d <= v_end LOOP
    INSERT INTO t_group_session_schedule (tenant_id, source_block_id, is_live, occurrence_date, assigned_to, assigned_to_name)
    VALUES (p_tenant, p_block, p_is_live, v_d, v_default_chair, v_default_chair_name)
    ON CONFLICT (tenant_id, source_block_id, is_live, occurrence_date) DO NOTHING;
    v_d := v_d + v_days;
  END LOOP;
  PERFORM gs_renumber_schedule(p_tenant, p_block, p_is_live);
  RETURN gs_dash_occurrences(p_tenant, p_block, p_is_live);
END $function$
