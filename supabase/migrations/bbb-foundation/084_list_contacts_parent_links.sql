-- 084: list_contacts_with_channels_v2 gains `parent_links` — the companies a
-- person is linked to, resolved from parent_contact_ids (the array the product
-- actually uses; the emitted legacy parent_contact_id is NULL everywhere).
-- Additive: one field per row, nothing else changes. Applied live 2026-09-17
-- (batch contacts-type-and-links) — source-of-record copy, do not re-run.
--
-- Method: substitute into the live definition (CLAUDE.md migration 048/059
-- pattern) and RAISE if the anchor did not land, so a silent no-op is impossible.
DO $$
DECLARE
  v_def text;
  v_anchor text := $a$'parent_contact_id', c.parent_contact_id,$a$;
  v_new text := $n$'parent_contact_id', c.parent_contact_id,
      'parent_links', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object('id', pc.id, 'name', COALESCE(pc.company_name, pc.name)) ORDER BY pc.company_name, pc.name), '[]'::jsonb)
        FROM t_contacts pc
        WHERE pc.id IN (SELECT jsonb_array_elements_text(COALESCE(c.parent_contact_ids, '[]'::jsonb))::uuid)
          AND pc.tenant_id = c.tenant_id
          AND pc.is_live = c.is_live
          AND pc.status <> 'archived'
      ),$n$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'list_contacts_with_channels_v2';

  IF v_def IS NULL THEN RAISE EXCEPTION '084: list_contacts_with_channels_v2 not found'; END IF;
  IF position('parent_links' IN v_def) > 0 THEN RAISE NOTICE '084: parent_links already present, nothing to do'; RETURN; END IF;
  IF (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 THEN
    RAISE EXCEPTION '084: expected exactly one anchor, found %', (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  END IF;

  v_def := replace(v_def, v_anchor, v_new);
  EXECUTE v_def;

  -- Post-check: the rewrite must have landed.
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'list_contacts_with_channels_v2';
  IF position('parent_links' IN v_def) = 0 THEN RAISE EXCEPTION '084: rewrite did not land'; END IF;
END $$;
