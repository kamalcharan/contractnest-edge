-- get_contact_full_v2: expose t_contacts.contact_number (e.g. "CT-10043")
-- to the contact-view header. The column already exists and is populated
-- via the CONTACT sequence counter on insert (trg_auto_contact_number) —
-- it just wasn't in this RPC's returned payload yet.

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
    'contact_number', c.contact_number,
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
$function$
