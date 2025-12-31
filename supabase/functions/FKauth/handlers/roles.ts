// supabase/functions/FKauth/handlers/roles.ts
export async function createDefaultRolesForTenant(supabase: any, tenantId: string, userTenantId: string) {
  try {
    // Check if roles already exist
    const { data: existingRoles } = await supabase
      .from('t_category_master')
      .select('id')
      .eq('tenant_id', tenantId)
      .eq('category_name', 'Roles')
      .single();

    if (existingRoles) {
      console.log('Roles already exist for family space');
      return;
    }

    // Create Roles category
    const { data: roleCategory, error: categoryError } = await supabase
      .from('t_category_master')
      .insert({
        category_name: 'Roles',
        display_name: 'Family Roles',
        is_active: true,
        description: 'Roles in the family space',
        tenant_id: tenantId
      })
      .select()
      .single();

    if (categoryError) {
      console.error('Role category creation error:', categoryError.message);
      throw new Error(`Error creating roles category: ${categoryError.message}`);
    }

    console.log('Role category created successfully:', roleCategory.id);

    // Create default FamilyKnows roles: Owner (Head) and Member
    const defaultRoles = [
      {
        sub_cat_name: 'Owner',
        display_name: 'Family Head',
        category_id: roleCategory.id,
        hexcolor: '#32e275',
        is_active: true,
        sequence_no: 1,
        tenant_id: tenantId,
        is_deletable: false
      },
      {
        sub_cat_name: 'Admin',
        display_name: 'Family Admin',
        category_id: roleCategory.id,
        hexcolor: '#3b82f6',
        is_active: true,
        sequence_no: 2,
        tenant_id: tenantId,
        is_deletable: true
      },
      {
        sub_cat_name: 'Member',
        display_name: 'Family Member',
        category_id: roleCategory.id,
        hexcolor: '#8b5cf6',
        is_active: true,
        sequence_no: 3,
        tenant_id: tenantId,
        is_deletable: true
      }
    ];

    const { data: createdRoles, error: rolesError } = await supabase
      .from('t_category_details')
      .insert(defaultRoles)
      .select();

    if (rolesError) {
      console.error('Roles creation error:', rolesError.message);
      throw new Error(`Error creating default roles: ${rolesError.message}`);
    }

    console.log('Default family roles created successfully:', createdRoles.map((r: any) => r.display_name).join(', '));

    // Find the Owner role to assign to user
    const ownerRole = createdRoles.find((r: any) => r.sub_cat_name === 'Owner');

    // Assign Owner role to user (family head)
    const { error: roleAssignError } = await supabase
      .from('t_user_tenant_roles')
      .insert({
        user_tenant_id: userTenantId,
        role_id: ownerRole.id
      });

    if (roleAssignError) {
      console.error('Role assignment error:', roleAssignError.message);
      throw new Error(`Error assigning family head role: ${roleAssignError.message}`);
    }

    console.log('Family head role assigned successfully to user');
  } catch (error: any) {
    console.error('Error creating default family roles:', error.message);
    throw error;
  }
}
