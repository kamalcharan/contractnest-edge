-- 078_update_contact_idempotent_v2_persons.sql
-- ALREADY APPLIED LIVE (2026-09-16) — this file is a source-of-record copy.
-- DO NOT RE-RUN.
--
-- update_contact_idempotent_v2 has always accepted p_contact_persons but its
-- body never read it — dead parameter since the function was introduced.
-- Every caller that ever tried to save linked/alternate contacts on an
-- EXISTING contact via this RPC silently did nothing (persons only ever
-- persisted through create_contact_idempotent_v2, at contact-create time —
-- this is why the old ProfileDrawer's "Contact Persons" edit never worked).
--
-- Adds real handling, mirroring create's child-contact shape and using the
-- same full-replace semantics this function already uses for channels/
-- addresses (NULL = leave untouched, an array = replace):
--   - a person with an id already among this contact's children -> updated
--   - a person with no id -> inserted as a new child contact (individual ·
--     team_member · parent_contact_ids = [this contact]), mirroring
--     create_contact_idempotent_v2's insert
--   - an existing child NOT present in the incoming array -> unlinked
--     (parent_contact_ids cleared) — never deleted; it remains a normal,
--     standalone contact, consistent with every other place a child is
--     detached today (e.g. the guest check-in dedupe merge)
--
-- Verified live in a self-contained rollback transaction (throwaway parent +
-- child, create/edit/unlink all asserted, final RAISE EXCEPTION rolled back
-- so nothing persisted) before this file was written.

CREATE OR REPLACE FUNCTION public.update_contact_idempotent_v2(
  p_idempotency_key uuid,
  p_contact_id uuid,
  p_contact_data jsonb,
  p_contact_channels jsonb DEFAULT NULL::jsonb,
  p_addresses jsonb DEFAULT NULL::jsonb,
  p_contact_persons jsonb DEFAULT NULL::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_existing_contact RECORD;
  v_person RECORD;
  v_person_contact_id UUID;
  v_incoming_ids UUID[];
BEGIN
  INSERT INTO api_idempotency (key, resource_type, resource_id)
  VALUES (p_idempotency_key, 'contact_update', p_contact_id)
  ON CONFLICT (key) DO NOTHING;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', TRUE,
      'data', jsonb_build_object('id', p_contact_id),
      'was_duplicate', TRUE,
      'message', 'Update already processed with this idempotency key'
    );
  END IF;

  SELECT id, status, tenant_id, is_live INTO v_existing_contact
  FROM t_contacts WHERE id = p_contact_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Contact not found', 'code', 'NOT_FOUND');
  END IF;

  IF v_existing_contact.status = 'archived' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Cannot update archived contact', 'code', 'CONTACT_ARCHIVED');
  END IF;

  UPDATE t_contacts SET
    name = COALESCE((p_contact_data->>'name')::TEXT, name),
    company_name = COALESCE((p_contact_data->>'company_name')::TEXT, company_name),
    registration_number = COALESCE((p_contact_data->>'registration_number')::TEXT, registration_number),
    salutation = COALESCE((p_contact_data->>'salutation')::TEXT, salutation),
    designation = COALESCE((p_contact_data->>'designation')::TEXT, designation),
    department = COALESCE((p_contact_data->>'department')::TEXT, department),
    is_primary_contact = COALESCE((p_contact_data->>'is_primary_contact')::BOOLEAN, is_primary_contact),
    classifications = COALESCE(p_contact_data->'classifications', classifications),
    tags = COALESCE(p_contact_data->'tags', tags),
    industries = COALESCE(p_contact_data->'industries', industries),
    compliance_numbers = COALESCE(p_contact_data->'compliance_numbers', compliance_numbers),
    notes = COALESCE((p_contact_data->>'notes')::TEXT, notes),
    parent_contact_ids = COALESCE(p_contact_data->'parent_contact_ids', parent_contact_ids),
    updated_by = (p_contact_data->>'updated_by')::UUID,
    updated_at = NOW()
  WHERE id = p_contact_id;

  IF p_contact_channels IS NOT NULL THEN
    DELETE FROM t_contact_channels WHERE contact_id = p_contact_id;
    IF jsonb_array_length(p_contact_channels) > 0 THEN
      INSERT INTO t_contact_channels (contact_id, channel_type, value, country_code, is_primary, is_verified, notes)
      SELECT p_contact_id, x.channel_type, x.value, x.country_code,
        COALESCE(x.is_primary, FALSE), COALESCE(x.is_verified, FALSE), x.notes
      FROM jsonb_to_recordset(p_contact_channels) AS x(
        channel_type TEXT, value TEXT, country_code TEXT,
        is_primary BOOLEAN, is_verified BOOLEAN, notes TEXT
      );
    END IF;
  END IF;

  IF p_addresses IS NOT NULL THEN
    DELETE FROM t_contact_addresses WHERE contact_id = p_contact_id;
    IF jsonb_array_length(p_addresses) > 0 THEN
      INSERT INTO t_contact_addresses (contact_id, type, label, address_line1, address_line2, city, state_code, country_code, postal_code, google_pin, is_primary, notes)
      SELECT p_contact_id,
        COALESCE(x.type, x.address_type), x.label,
        COALESCE(x.address_line1, x.line1), COALESCE(x.address_line2, x.line2),
        x.city, COALESCE(x.state_code, x.state),
        COALESCE(x.country_code, x.country, 'IN'),
        x.postal_code, x.google_pin, COALESCE(x.is_primary, FALSE), x.notes
      FROM jsonb_to_recordset(p_addresses) AS x(
        type TEXT, address_type TEXT, label TEXT,
        address_line1 TEXT, line1 TEXT, address_line2 TEXT, line2 TEXT,
        city TEXT, state_code TEXT, state TEXT, country_code TEXT, country TEXT,
        postal_code TEXT, google_pin TEXT, is_primary BOOLEAN, notes TEXT
      );
    END IF;
  END IF;

  -- Linked/alternate contacts (contact_persons) — NEWLY WIRED. NULL leaves
  -- children untouched; an array is treated as the full current set, same
  -- full-replace convention as channels/addresses above.
  IF p_contact_persons IS NOT NULL THEN
    SELECT COALESCE(array_agg((x->>'id')::UUID), ARRAY[]::UUID[])
    INTO v_incoming_ids
    FROM jsonb_array_elements(p_contact_persons) x
    WHERE x->>'id' IS NOT NULL;

    -- Unlink existing children that are no longer in the incoming list.
    -- Never deletes — the child remains a normal, standalone contact.
    UPDATE t_contacts
    SET parent_contact_ids = '[]'::jsonb,
        updated_at = NOW()
    WHERE tenant_id = v_existing_contact.tenant_id
      AND parent_contact_ids @> jsonb_build_array(p_contact_id::TEXT)
      AND NOT (id = ANY(v_incoming_ids));

    FOR v_person IN
      SELECT * FROM jsonb_to_recordset(p_contact_persons) AS x(
        id UUID, name TEXT, salutation TEXT, designation TEXT, department TEXT,
        is_primary BOOLEAN, notes TEXT, contact_channels JSONB
      )
    LOOP
      IF v_person.id IS NOT NULL THEN
        UPDATE t_contacts SET
          name = COALESCE(v_person.name, name),
          salutation = COALESCE(v_person.salutation, salutation),
          designation = COALESCE(v_person.designation, designation),
          department = COALESCE(v_person.department, department),
          notes = COALESCE(v_person.notes, notes),
          parent_contact_ids = jsonb_build_array(p_contact_id),
          updated_at = NOW()
        WHERE id = v_person.id AND tenant_id = v_existing_contact.tenant_id;
        v_person_contact_id := v_person.id;
      ELSE
        INSERT INTO t_contacts (
          type, status, name, salutation, designation, department,
          is_primary_contact, parent_contact_ids, classifications,
          tags, compliance_numbers, notes, tenant_id, created_by, is_live
        )
        VALUES (
          'individual', 'active', v_person.name, v_person.salutation,
          v_person.designation, v_person.department,
          COALESCE(v_person.is_primary, FALSE),
          jsonb_build_array(p_contact_id),
          '["team_member"]'::JSONB,
          '[]'::JSONB, '[]'::JSONB, v_person.notes,
          v_existing_contact.tenant_id,
          (p_contact_data->>'updated_by')::UUID,
          v_existing_contact.is_live
        )
        RETURNING id INTO v_person_contact_id;
      END IF;

      -- Channels use the same replace convention: present (even empty) ->
      -- wipe and reinsert; the key simply absent on the JSON object -> NULL
      -- here, left untouched.
      IF v_person.contact_channels IS NOT NULL THEN
        DELETE FROM t_contact_channels WHERE contact_id = v_person_contact_id;
        IF jsonb_array_length(v_person.contact_channels) > 0 THEN
          INSERT INTO t_contact_channels (contact_id, channel_type, value, country_code, is_primary, is_verified, notes)
          SELECT v_person_contact_id, x.channel_type, x.value, x.country_code,
            COALESCE(x.is_primary, FALSE), COALESCE(x.is_verified, FALSE), x.notes
          FROM jsonb_to_recordset(v_person.contact_channels) AS x(
            channel_type TEXT, value TEXT, country_code TEXT,
            is_primary BOOLEAN, is_verified BOOLEAN, notes TEXT
          );
        END IF;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'data', jsonb_build_object('id', p_contact_id),
    'was_duplicate', FALSE,
    'message', 'Contact updated successfully'
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', SQLERRM,
      'code', 'UPDATE_CONTACT_ERROR'
    );
END;
$function$;
