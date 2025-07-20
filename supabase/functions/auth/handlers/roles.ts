// supabase/functions/auth/handlers/roles.ts
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
      console.log('Roles already exist for tenant');
      return;
    }

    // Create Roles category
    const { data: roleCategory, error: categoryError } = await supabase
      .from('t_category_master')
      .insert({
        category_name: 'Roles',
        display_name: 'Roles',
        is_active: true,
        description: 'User roles in the system',
        tenant_id: tenantId
      })
      .select()
      .single();

    if (categoryError) {
      console.error('Role category creation error:', categoryError.message);
      throw new Error(`Error creating roles category: ${categoryError.message}`);
    }

    console.log('Role category created successfully:', roleCategory.id);

    // Create Owner role
    const { data: ownerRole, error: ownerError } = await supabase
      .from('t_category_details')
      .insert({
        sub_cat_name: 'Owner',
        display_name: 'Owner',
        category_id: roleCategory.id,
        hexcolor: '#32e275',
        is_active: true,
        sequence_no: 1,
        tenant_id: tenantId,
        is_deletable: false
      })
      .select()
      .single();

    if (ownerError) {
      console.error('Owner role creation error:', ownerError.message);
      throw new Error(`Error creating owner role: ${ownerError.message}`);
    }

    console.log('Owner role created successfully:', ownerRole.id);

    // Assign Owner role to user
    const { error: roleAssignError } = await supabase
      .from('t_user_tenant_roles')
      .insert({
        user_tenant_id: userTenantId,
        role_id: ownerRole.id
      });

    if (roleAssignError) {
      console.error('Role assignment error:', roleAssignError.message);
      throw new Error(`Error assigning owner role: ${roleAssignError.message}`);
    }

    console.log('Role assigned successfully to user');
  } catch (error: any) {
    console.error('Error creating default roles:', error.message);
    throw error;
  }
}