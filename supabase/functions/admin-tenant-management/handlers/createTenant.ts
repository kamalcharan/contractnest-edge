// supabase/functions/admin-tenant-management/handlers/createTenant.ts
// Admin Create Tenant - creates auth user, tenant, profile, and sends password reset email

interface CreateTenantData {
  workspace_name: string;
  first_name: string;
  last_name: string;
  email: string;
  mobile_number?: string;
  country_code?: string;
  phone_code?: string;
  tenant_type?: 'buyer' | 'seller' | 'mixed';
  is_test?: boolean;
  send_password_reset?: boolean;
}

// Generate a workspace code from a name
function generateWorkspaceCode(name: string): string {
  let base = name.replace(/[^a-zA-Z0-9]/g, '').toLowerCase();
  if (base.length < 3) {
    base = base.padEnd(3, 'x');
  }
  const random = Math.floor(Math.random() * 1000).toString().padStart(3, '0');
  return (base.substring(0, 3) + random).substring(0, 6);
}

// Generate base user code from first and last name
function generateBaseUserCode(firstName: string, lastName: string): string {
  const cleanFirst = (firstName || '').replace(/[^a-zA-Z0-9]/g, '').toUpperCase();
  const cleanLast = (lastName || '').replace(/[^a-zA-Z0-9]/g, '').toUpperCase();

  if (!cleanFirst && !cleanLast) {
    const timestamp = Date.now().toString(36).slice(-4).toUpperCase();
    const random = Math.random().toString(36).substring(2, 6).toUpperCase();
    return timestamp + random;
  }

  const firstPart = cleanFirst.substring(0, 4).padEnd(4, Math.random().toString(36).substring(2, 3).toUpperCase());
  const lastPart = cleanLast.substring(0, 4).padEnd(4, Math.random().toString(36).substring(2, 3).toUpperCase());

  return firstPart + lastPart;
}

// Generate a unique user code with duplicate check
async function generateUserCode(supabase: any, firstName: string, lastName: string): Promise<string> {
  const baseCode = generateBaseUserCode(firstName, lastName);

  const { data: existing } = await supabase
    .from('t_user_profiles')
    .select('user_code')
    .eq('user_code', baseCode)
    .maybeSingle();

  if (!existing) {
    return baseCode;
  }

  const suffixes = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  for (const suffix of suffixes) {
    const candidateCode = baseCode + suffix;
    const { data: existingSuffix } = await supabase
      .from('t_user_profiles')
      .select('user_code')
      .eq('user_code', candidateCode)
      .maybeSingle();

    if (!existingSuffix) {
      return candidateCode;
    }
  }

  const random = Math.random().toString(36).substring(2, 5).toUpperCase();
  return baseCode + random;
}

// Generate a random temporary password (never shared with anyone)
function generateTemporaryPassword(): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%';
  let password = '';
  for (let i = 0; i < 24; i++) {
    password += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return password;
}

// Create default roles for the tenant (replicates auth/handlers/roles.ts logic)
async function createDefaultRolesForTenant(supabase: any, tenantId: string, userTenantId: string) {
  try {
    // Get default role category
    const { data: roleCategory } = await supabase
      .from('n_masterdata_categories')
      .select('id')
      .eq('code', 'user_roles')
      .maybeSingle();

    if (!roleCategory) {
      console.warn('Role category not found, skipping role creation');
      return;
    }

    // Create Admin role
    const { data: adminRole } = await supabase
      .from('n_masterdata_items')
      .insert({
        category_id: roleCategory.id,
        tenant_id: tenantId,
        code: 'admin',
        name: 'Admin',
        description: 'Full access to all features',
        sort_order: 1,
        is_active: true,
        is_system: true,
        metadata: { permissions: ['*'] }
      })
      .select()
      .single();

    // Create Member role
    await supabase
      .from('n_masterdata_items')
      .insert({
        category_id: roleCategory.id,
        tenant_id: tenantId,
        code: 'member',
        name: 'Member',
        description: 'Standard team member access',
        sort_order: 2,
        is_active: true,
        is_system: true,
        metadata: { permissions: ['read', 'write'] }
      });

    // Create Viewer role
    await supabase
      .from('n_masterdata_items')
      .insert({
        category_id: roleCategory.id,
        tenant_id: tenantId,
        code: 'viewer',
        name: 'Viewer',
        description: 'Read-only access',
        sort_order: 3,
        is_active: true,
        is_system: true,
        metadata: { permissions: ['read'] }
      });

    // Assign Admin role to the owner
    if (adminRole && userTenantId) {
      await supabase
        .from('t_user_tenant_roles')
        .insert({
          user_tenant_id: userTenantId,
          role_id: adminRole.id
        });
    }
  } catch (error: any) {
    console.error('Error creating default roles:', error.message);
    // Non-fatal: don't throw, roles can be created later
  }
}

export async function handleCreateTenant(supabase: any, data: CreateTenantData) {
  const { workspace_name, first_name, last_name, email, mobile_number, country_code, phone_code, tenant_type, is_test, send_password_reset } = data;

  // Validate required fields
  if (!workspace_name || !first_name || !last_name || !email) {
    return { error: 'workspace_name, first_name, last_name, and email are required', status: 400 };
  }

  // Validate email format
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!emailRegex.test(email)) {
    return { error: 'Invalid email format', status: 400 };
  }

  const normalizedEmail = email.toLowerCase().trim();

  try {
    // 1. Check if workspace name already exists
    const { data: existingTenants } = await supabase
      .from('t_tenants')
      .select('id')
      .ilike('name', workspace_name)
      .limit(1);

    if (existingTenants && existingTenants.length > 0) {
      return { error: 'Workspace name already exists. Please choose a different name.', status: 409 };
    }

    // 2. Check if email already exists (case-insensitive)
    const { data: existingProfile } = await supabase
      .from('t_user_profiles')
      .select('id, user_id, email')
      .ilike('email', normalizedEmail)
      .limit(1);

    if (existingProfile && existingProfile.length > 0) {
      return {
        error: 'An account with this email already exists.',
        error_code: 'ACCOUNT_ALREADY_EXISTS',
        status: 409
      };
    }

    // 3. Generate temporary password (never shared)
    const temporaryPassword = generateTemporaryPassword();

    // 4. Create auth user
    console.log('[createTenant] Creating auth user for:', normalizedEmail);
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({
      email: normalizedEmail,
      password: temporaryPassword,
      email_confirm: true,
      user_metadata: {
        first_name: first_name || '',
        last_name: last_name || '',
        registration_status: 'complete',
        created_by_admin: true
      }
    });

    if (authError || !authData?.user) {
      console.error('[createTenant] Auth user creation error:', authError?.message);

      // Check for duplicate user in Supabase auth
      if (authError?.message?.includes('already') || authError?.message?.includes('exists')) {
        return {
          error: 'An account with this email already exists.',
          error_code: 'ACCOUNT_ALREADY_EXISTS',
          status: 409
        };
      }

      throw new Error(authError?.message || 'Failed to create user account');
    }

    console.log('[createTenant] Auth user created:', authData.user.id);

    // 5. Generate workspace code
    const workspaceCode = generateWorkspaceCode(workspace_name);

    // 6. Create tenant
    const { data: tenant, error: tenantError } = await supabase
      .from('t_tenants')
      .insert({
        name: workspace_name,
        workspace_code: workspaceCode,
        status: 'active',
        created_by: authData.user.id,
        is_admin: false,
        is_test: is_test || false
      })
      .select()
      .single();

    if (tenantError) {
      console.error('[createTenant] Tenant creation error:', tenantError.message);
      // Cleanup: delete the auth user we just created
      await supabase.auth.admin.deleteUser(authData.user.id);
      throw new Error(`Error creating workspace: ${tenantError.message}`);
    }

    console.log('[createTenant] Tenant created:', tenant.id);

    // 7. Create user profile
    const userCode = await generateUserCode(supabase, first_name, last_name);

    const profileData = {
      user_id: authData.user.id,
      first_name: first_name || '',
      last_name: last_name || '',
      email: normalizedEmail,
      is_active: true,
      user_code: userCode,
      ...(country_code && { country_code }),
      ...(mobile_number && { mobile_number })
    };

    const { data: profile, error: profileError } = await supabase
      .from('t_user_profiles')
      .upsert(profileData, {
        onConflict: 'user_id',
        ignoreDuplicates: false
      })
      .select()
      .single();

    if (profileError && !profileError.message.includes('duplicate')) {
      console.error('[createTenant] Profile creation error:', profileError.message);
      throw new Error(`Error creating user profile: ${profileError.message}`);
    }

    // 8. Create auth method entry
    await supabase
      .from('t_user_auth_methods')
      .upsert({
        user_id: authData.user.id,
        auth_type: 'email',
        auth_identifier: normalizedEmail,
        is_primary: true,
        is_verified: true,
        linked_at: new Date().toISOString()
      }, {
        onConflict: 'user_id,auth_type',
        ignoreDuplicates: false
      });

    // 9. Link user to tenant
    const { data: userTenant, error: linkError } = await supabase
      .from('t_user_tenants')
      .insert({
        user_id: authData.user.id,
        tenant_id: tenant.id,
        is_default: true,
        status: 'active'
      })
      .select()
      .single();

    if (linkError) {
      console.error('[createTenant] User-tenant link error:', linkError.message);
      throw new Error(`Error linking user to workspace: ${linkError.message}`);
    }

    // 10. Create default roles and assign Admin to owner
    await createDefaultRolesForTenant(supabase, tenant.id, userTenant.id);

    // 11. Optionally send password reset email so user can set their own password
    let resetError: any = null;
    const shouldSendReset = send_password_reset !== false; // defaults to true

    if (shouldSendReset) {
      console.log('[createTenant] Sending password reset email to:', normalizedEmail);
      const frontendUrl = Deno.env.get('FRONTEND_URL') || 'https://app.contractnest.com';
      const result = await supabase.auth.resetPasswordForEmail(normalizedEmail, {
        redirectTo: `${frontendUrl}/auth/reset-password`
      });
      resetError = result.error;

      if (resetError) {
        console.error('[createTenant] Password reset email error:', resetError.message);
        // Non-fatal: account is created, admin can trigger reset later
      }
    } else {
      console.log('[createTenant] Password reset email skipped (admin opted out)');
    }

    console.log('[createTenant] Tenant account created successfully');

    return {
      success: true,
      data: {
        tenant: {
          id: tenant.id,
          name: tenant.name,
          workspace_code: tenant.workspace_code,
          status: tenant.status,
          is_test: tenant.is_test
        },
        owner: {
          user_id: authData.user.id,
          email: normalizedEmail,
          first_name: first_name,
          last_name: last_name,
          user_code: userCode
        },
        password_reset_sent: shouldSendReset && !resetError
      },
      status: 201
    };

  } catch (error: any) {
    console.error('[createTenant] Process error:', error.message);
    return { error: error.message || 'Failed to create tenant account', status: 500 };
  }
}
