-- Contact external_data — a small, generic JSONB bucket for values sourced
-- from external systems (member rosters, future CRM/POS integrations), NOT
-- user-editable via the create/edit contact forms — populated only by the
-- import flow. Starts with one key: member_id (e.g. BBB B-Hive's "Member Id"
-- column, like "HYDBHA2750"). Future integration keys just add another key
-- to this same JSONB — no new column/migration needed.
--
-- Threaded through:
--   - create_contact_idempotent_v2 (accepts p_contact_data->'external_data')
--     — the only write path, since import always creates fresh contacts
--     (confirmed: no update-existing-contact path in the import flow).
--   - get_contact_full_v2 (returns it) so the contact view can display it.
-- update_contact_idempotent_v2 is intentionally NOT touched — this field is
-- import-only, never sent by the normal edit-contact form.

ALTER TABLE t_contacts
  ADD COLUMN IF NOT EXISTS external_data jsonb DEFAULT '{}'::jsonb;

-- ── create_contact_idempotent_v2: add external_data to the INSERT ──
CREATE OR REPLACE FUNCTION public.create_contact_idempotent_v2(p_idempotency_key uuid, p_contact_data jsonb, p_contact_channels jsonb DEFAULT '[]'::jsonb, p_addresses jsonb DEFAULT '[]'::jsonb, p_contact_persons jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contact_id UUID;
  v_existing_id UUID;
  v_person RECORD;
  v_person_contact_id UUID;
BEGIN
  -- Idempotency check
  INSERT INTO api_idempotency (key, resource_type)
  VALUES (p_idempotency_key, 'contact')
  ON CONFLICT (key) DO NOTHING;

  IF NOT FOUND THEN
    SELECT resource_id INTO v_existing_id
    FROM api_idempotency
    WHERE key = p_idempotency_key;

    IF v_existing_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'success', TRUE,
        'data', (SELECT to_jsonb(c.*) FROM t_contacts c WHERE c.id = v_existing_id),
        'was_duplicate', TRUE,
        'message', 'Contact already created with this idempotency key'
      );
    END IF;
  END IF;

  -- Create main contact
  INSERT INTO t_contacts (
    type, status, name, company_name, registration_number,
    salutation, designation, department, is_primary_contact,
    classifications, tags, industries, compliance_numbers, notes,
    parent_contact_ids, tenant_id, auth_user_id, created_by, is_live,
    external_data
  )
  VALUES (
    (p_contact_data->>'type')::TEXT,
    COALESCE((p_contact_data->>'status')::TEXT, 'active'),
    (p_contact_data->>'name')::TEXT,
    (p_contact_data->>'company_name')::TEXT,
    (p_contact_data->>'registration_number')::TEXT,
    (p_contact_data->>'salutation')::TEXT,
    (p_contact_data->>'designation')::TEXT,
    (p_contact_data->>'department')::TEXT,
    COALESCE((p_contact_data->>'is_primary_contact')::BOOLEAN, FALSE),
    COALESCE(p_contact_data->'classifications', '[]'::JSONB),
    COALESCE(p_contact_data->'tags', '[]'::JSONB),
    COALESCE(p_contact_data->'industries', '[]'::JSONB),
    COALESCE(p_contact_data->'compliance_numbers', '[]'::JSONB),
    (p_contact_data->>'notes')::TEXT,
    COALESCE(p_contact_data->'parent_contact_ids', '[]'::JSONB),
    (p_contact_data->>'tenant_id')::UUID,
    (p_contact_data->>'auth_user_id')::UUID,
    (p_contact_data->>'created_by')::UUID,
    COALESCE((p_contact_data->>'is_live')::BOOLEAN, TRUE),
    COALESCE(p_contact_data->'external_data', '{}'::JSONB)
  )
  RETURNING id INTO v_contact_id;

  -- Bulk insert channels
  IF jsonb_array_length(p_contact_channels) > 0 THEN
    INSERT INTO t_contact_channels (contact_id, channel_type, value, country_code, is_primary, is_verified, notes)
    SELECT
      v_contact_id,
      x.channel_type, x.value, x.country_code,
      COALESCE(x.is_primary, FALSE),
      COALESCE(x.is_verified, FALSE),
      x.notes
    FROM jsonb_to_recordset(p_contact_channels) AS x(
      channel_type TEXT, value TEXT, country_code TEXT,
      is_primary BOOLEAN, is_verified BOOLEAN, notes TEXT
    );
  END IF;

  -- Bulk insert addresses
  IF jsonb_array_length(p_addresses) > 0 THEN
    INSERT INTO t_contact_addresses (contact_id, type, label, address_line1, address_line2, city, state_code, country_code, postal_code, google_pin, is_primary, notes)
    SELECT
      v_contact_id,
      COALESCE(x.type, x.address_type),
      x.label,
      COALESCE(x.address_line1, x.line1),
      COALESCE(x.address_line2, x.line2),
      x.city,
      COALESCE(x.state_code, x.state),
      COALESCE(x.country_code, x.country, 'IN'),
      x.postal_code,
      x.google_pin,
      COALESCE(x.is_primary, FALSE),
      x.notes
    FROM jsonb_to_recordset(p_addresses) AS x(
      type TEXT, address_type TEXT, label TEXT,
      address_line1 TEXT, line1 TEXT, address_line2 TEXT, line2 TEXT,
      city TEXT, state_code TEXT, state TEXT, country_code TEXT, country TEXT,
      postal_code TEXT, google_pin TEXT, is_primary BOOLEAN, notes TEXT
    );
  END IF;

  -- Create contact persons
  IF jsonb_array_length(p_contact_persons) > 0 THEN
    FOR v_person IN
      SELECT * FROM jsonb_to_recordset(p_contact_persons) AS x(
        name TEXT, salutation TEXT, designation TEXT, department TEXT,
        is_primary BOOLEAN, notes TEXT, contact_channels JSONB
      )
    LOOP
      INSERT INTO t_contacts (
        type, status, name, salutation, designation, department,
        is_primary_contact, parent_contact_ids, classifications,
        tags, compliance_numbers, notes, tenant_id, created_by, is_live
      )
      VALUES (
        'individual', 'active', v_person.name, v_person.salutation,
        v_person.designation, v_person.department,
        COALESCE(v_person.is_primary, FALSE),
        jsonb_build_array(v_contact_id),
        '["team_member"]'::JSONB,
        '[]'::JSONB, '[]'::JSONB, v_person.notes,
        (p_contact_data->>'tenant_id')::UUID,
        (p_contact_data->>'created_by')::UUID,
        COALESCE((p_contact_data->>'is_live')::BOOLEAN, TRUE)
      )
      RETURNING id INTO v_person_contact_id;

      IF v_person.contact_channels IS NOT NULL AND jsonb_array_length(v_person.contact_channels) > 0 THEN
        INSERT INTO t_contact_channels (contact_id, channel_type, value, country_code, is_primary, is_verified, notes)
        SELECT
          v_person_contact_id,
          x.channel_type, x.value, x.country_code,
          COALESCE(x.is_primary, FALSE),
          COALESCE(x.is_verified, FALSE),
          x.notes
        FROM jsonb_to_recordset(v_person.contact_channels) AS x(
          channel_type TEXT, value TEXT, country_code TEXT,
          is_primary BOOLEAN, is_verified BOOLEAN, notes TEXT
        );
      END IF;
    END LOOP;
  END IF;

  -- Update idempotency record
  UPDATE api_idempotency SET resource_id = v_contact_id WHERE key = p_idempotency_key;

  RETURN jsonb_build_object(
    'success', TRUE,
    'data', jsonb_build_object('id', v_contact_id),
    'was_duplicate', FALSE,
    'message', 'Contact created successfully'
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', SQLERRM,
      'code', 'CREATE_CONTACT_ERROR'
    );
END;
$function$;

-- ── get_contact_full_v2: return external_data ──
CREATE OR REPLACE FUNCTION public.get_contact_full_v2(p_contact_id uuid, p_tenant_id uuid, p_is_live boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contact JSONB;
BEGIN
  SELECT jsonb_build_object(
    'id', c.id,
    'name', c.name,
    'company_name', c.company_name,
    'type', c.type,
    'status', c.status,
    'classifications', c.classifications,
    'tags', COALESCE(c.tags, '[]'::JSONB),
    'industries', COALESCE(c.industries, '[]'::JSONB),
    'compliance_numbers', COALESCE(c.compliance_numbers, '[]'::JSONB),
    'notes', c.notes,
    'salutation', c.salutation,
    'designation', c.designation,
    'department', c.department,
    'registration_number', c.registration_number,
    'parent_contact_ids', c.parent_contact_ids,
    'manager_id', c.manager_id,
    'manager_name', c.manager_name,
    'potential_duplicate', c.potential_duplicate,
    'auth_user_id', c.auth_user_id,
    'tenant_id', c.tenant_id,
    'is_live', c.is_live,
    'created_at', c.created_at,
    'updated_at', c.updated_at,
    'created_by', c.created_by,
    'external_data', COALESCE(c.external_data, '{}'::JSONB),
    'displayName', CASE
      WHEN c.type = 'corporate' THEN COALESCE(c.company_name, 'Unnamed Company')
      ELSE COALESCE(
        CASE WHEN c.salutation IS NOT NULL THEN c.salutation || '. ' ELSE '' END || c.name,
        'Unnamed Contact'
      )
    END,
    'contact_channels', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', ch.id,
          'channel_type', ch.channel_type,
          'value', ch.value,
          'country_code', ch.country_code,
          'is_primary', ch.is_primary,
          'is_verified', ch.is_verified,
          'notes', ch.notes
        ) ORDER BY ch.is_primary DESC, ch.created_at
      )
      FROM t_contact_channels ch
      WHERE ch.contact_id = c.id
    ), '[]'::JSONB),
    'addresses', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', a.id,
          'type', a.type,
          'label', a.label,
          'address_line1', a.address_line1,
          'address_line2', a.address_line2,
          'city', a.city,
          'state_code', a.state_code,
          'country_code', a.country_code,
          'postal_code', a.postal_code,
          'google_pin', a.google_pin,
          'is_primary', a.is_primary,
          'notes', a.notes
        ) ORDER BY a.is_primary DESC, a.created_at
      )
      FROM t_contact_addresses a
      WHERE a.contact_id = c.id
    ), '[]'::JSONB),
    'contact_addresses', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', a.id,
          'type', a.type,
          'label', a.label,
          'address_line1', a.address_line1,
          'address_line2', a.address_line2,
          'city', a.city,
          'state_code', a.state_code,
          'country_code', a.country_code,
          'postal_code', a.postal_code,
          'google_pin', a.google_pin,
          'is_primary', a.is_primary,
          'notes', a.notes
        ) ORDER BY a.is_primary DESC, a.created_at
      )
      FROM t_contact_addresses a
      WHERE a.contact_id = c.id
    ), '[]'::JSONB),
    'parent_contacts', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'name', p.name,
          'company_name', p.company_name,
          'type', p.type,
          'status', p.status
        )
      )
      FROM t_contacts p
      WHERE p.id = ANY(
        SELECT jsonb_array_elements_text(c.parent_contact_ids)::UUID
      )
        AND p.is_live = p_is_live
        AND p.tenant_id = p_tenant_id
    ), '[]'::JSONB),
    'contact_persons', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', child.id,
          'name', child.name,
          'salutation', child.salutation,
          'designation', child.designation,
          'department', child.department,
          'type', child.type,
          'status', child.status,
          'contact_channels', COALESCE((
            SELECT jsonb_agg(
              jsonb_build_object(
                'id', ch2.id,
                'channel_type', ch2.channel_type,
                'value', ch2.value,
                'country_code', ch2.country_code,
                'is_primary', ch2.is_primary
              )
            )
            FROM t_contact_channels ch2
            WHERE ch2.contact_id = child.id
          ), '[]'::JSONB)
        )
      )
      FROM t_contacts child
      WHERE child.parent_contact_ids @> jsonb_build_array(c.id::TEXT)
        AND child.is_live = p_is_live
        AND child.tenant_id = p_tenant_id
        AND child.status != 'archived'
    ), '[]'::JSONB)
  )
  INTO v_contact
  FROM t_contacts c
  WHERE c.id = p_contact_id
    AND c.tenant_id = p_tenant_id
    AND c.is_live = p_is_live;

  IF v_contact IS NULL THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'Contact not found',
      'code', 'NOT_FOUND'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'data', v_contact
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', SQLERRM,
      'code', SQLSTATE
    );
END;
$function$;
