-- Equipment identity belongs to the registry. Generated service forms contain
-- work performed, readings, parts and sign-off only. Keep every existing
-- submission immutable; this migration aborts if any affected form acquired
-- a submission between audit and application.
DO $$
DECLARE affected_count integer;
BEGIN
  SELECT count(*) INTO affected_count
  FROM public.m_form_templates t
  WHERE EXISTS (
    SELECT 1 FROM jsonb_array_elements(coalesce(t.schema->'sections','[]'::jsonb)) section
    WHERE section->>'id'='identification'
      AND section->>'title'='Equipment Identification'
      AND (section->'fields' @> '[{"id":"asset_id"},{"id":"serial_number"}]'::jsonb)
  );
  IF affected_count <> 46 THEN
    RAISE EXCEPTION 'Expected 46 legacy generated forms, found %. Review scope before migration.', affected_count;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.m_form_templates t
    JOIN public.m_form_submissions s ON s.form_template_id=t.id
    WHERE EXISTS (
      SELECT 1 FROM jsonb_array_elements(coalesce(t.schema->'sections','[]'::jsonb)) section
      WHERE section->>'id'='identification'
        AND section->>'title'='Equipment Identification'
        AND (section->'fields' @> '[{"id":"asset_id"},{"id":"serial_number"}]'::jsonb)
    )
  ) THEN
    RAISE EXCEPTION 'A legacy form now has submissions. Preserve its version and migrate separately.';
  END IF;

  UPDATE public.m_form_templates t
  SET schema = jsonb_set(
      jsonb_set(t.schema,'{sections}',
        (SELECT jsonb_agg(section ORDER BY ordinal)
         FROM jsonb_array_elements(t.schema->'sections') WITH ORDINALITY AS items(section,ordinal)
         WHERE NOT (section->>'id'='identification'
           AND section->>'title'='Equipment Identification'))),
      '{version}',to_jsonb(t.version+1),true),
      version=t.version+1,
      updated_at=now()
  WHERE EXISTS (
    SELECT 1 FROM jsonb_array_elements(coalesce(t.schema->'sections','[]'::jsonb)) section
    WHERE section->>'id'='identification'
      AND section->>'title'='Equipment Identification'
      AND (section->'fields' @> '[{"id":"asset_id"},{"id":"serial_number"}]'::jsonb)
  );
END $$;
