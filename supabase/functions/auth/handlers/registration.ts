import { corsHeaders } from '../utils/cors.ts';
import { generateWorkspaceCode, generateUserCode, errorResponse, successResponse } from '../utils/helpers.ts';
import { validateEmail, validatePassword, validateRequired } from '../utils/validation.ts';
import { RegisterData } from '../types/index.ts';
import { createDefaultRolesForTenant } from './roles.ts';
import { createDefaultTagsForTenant, createDefaultComplianceForTenant } from './seedData.ts';

export async function handleRegister(supabase: any, data: RegisterData) {
  const { email, password, firstName, lastName, workspaceName, countryCode, mobileNumber } = data;
  
  // Validate required fields
  const validationError = validateRequired(
    { email, password, workspaceName, firstName, lastName },
    ['email', 'password', 'workspaceName', 'firstName', 'lastName']
  );
  
  if (validationError) {
    return errorResponse(validationError);
  }

  // Validate email format
  if (!validateEmail(email)) {
    return errorResponse('Invalid email format');
  }

  // Validate password
  const passwordValidation = validatePassword(password);
  if (!passwordValidation.valid) {
    return errorResponse(passwordValidation.error!);
  }

  try {
    // Check if workspace name already exists
    const { data: existingTenants } = await supabase
      .from('t_tenants')
      .select('id')
      .ilike('name', workspaceName)
      .limit(1);
    
    if (existingTenants && existingTenants.length > 0) {
      return errorResponse('Workspace name already exists. Please choose a different name.');
    }

    console.log('Creating user with email:', email);
    
    // Create user
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        first_name: firstName || '',
        last_name: lastName || '',
        registration_status: 'complete'
      }
    });

    if (authError || !authData?.user) {
      console.error('User creation error:', authError?.message);
      throw new Error(authError?.message || 'Failed to create user account');
    }

    console.log('User created successfully:', authData.user.id);
    
    // Generate workspace code
    const workspaceCode = generateWorkspaceCode(workspaceName);

    // Create tenant
    const { data: tenant, error: tenantError } = await supabase
      .from('t_tenants')
      .insert({
        name: workspaceName,
        workspace_code: workspaceCode,
        status: 'active',
        created_by: authData.user.id,
        is_admin: false
      })
      .select()
      .single();

    if (tenantError) {
      console.error('Tenant creation error:', tenantError.message);
      // TODO: Consider cleaning up the created user
      throw new Error(`Error creating workspace: ${tenantError.message}`);
    }

    console.log('Tenant created successfully:', tenant.id);

    // Create user profile - USING UPSERT TO PREVENT DUPLICATES
    // Generate unique user code with duplicate check
    const userCode = await generateUserCode(supabase, firstName, lastName);

    const profileData = {
      user_id: authData.user.id,
      first_name: firstName || '',
      last_name: lastName || '',
      email: authData.user.email,
      is_active: true,
      user_code: userCode,
      ...(countryCode && { country_code: countryCode }),
      ...(mobileNumber && { mobile_number: mobileNumber })
    };

    const { data: profile, error: profileError } = await supabase
      .from('t_user_profiles')
      .upsert(profileData, {
        onConflict: 'user_id',
        ignoreDuplicates: false
      })
      .select()
      .single();

    if (profileError) {
      console.error('Profile creation error:', profileError.message);
      // Don't fail if profile already exists
      if (!profileError.message.includes('duplicate')) {
        throw new Error(`Error creating user profile: ${profileError.message}`);
      }
    }

    // Create auth method entry - USING UPSERT
    await supabase
      .from('t_user_auth_methods')
      .upsert({
        user_id: authData.user.id,
        auth_type: 'email',
        auth_identifier: email,
        is_primary: true,
        is_verified: true,
        linked_at: new Date().toISOString()
      }, {
        onConflict: 'user_id,auth_type',
        ignoreDuplicates: false
      });

    // Link user to tenant
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
      console.error('User-tenant link error:', linkError.message);
      throw new Error(`Error linking user to workspace: ${linkError.message}`);
    }

    // Create default roles
    await createDefaultRolesForTenant(supabase, tenant.id, userTenant.id);

    // Seed default Tags and Compliance Numbers
    await createDefaultTagsForTenant(supabase, tenant.id);
    await createDefaultComplianceForTenant(supabase, tenant.id);

    // Sign in the user
    const { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({
      email,
      password
    });

    if (signInError) {
      console.error('Sign-in error:', signInError.message);
      throw new Error(`Error signing in: ${signInError.message}`);
    }

    return successResponse({
      user_id: authData.user.id,
      email: authData.user.email,
      access_token: signInData.session.access_token,
      refresh_token: signInData.session.refresh_token,
      expires_in: signInData.session.expires_in,
      user: profile || profileData, // Use profileData if profile is null
      tenant: {
        ...tenant,
        is_admin: tenant.is_admin || false
      }
    }, 201);
    
  } catch (error: any) {
    console.error('Registration process error:', error.message);
    return errorResponse(error.message);
  }
}

export async function handleRegisterWithInvitation(supabase: any, data: any) {
  const { email, password, firstName, lastName, userCode, secretCode, countryCode, mobileNumber } = data;
  
  // Validate required fields
  const validationError = validateRequired(
    { email, password, firstName, lastName, userCode, secretCode },
    ['email', 'password', 'firstName', 'lastName', 'userCode', 'secretCode']
  );
  
  if (validationError) {
    return errorResponse(validationError);
  }

  try {
    console.log('Validating invitation for registration:', { userCode, email });
    
    // Validate the invitation
    const { data: invitation, error: inviteError } = await supabase
      .from('t_user_invitations')
      .select(`
        *,
        t_tenants!inner (
          id,
          name,
          workspace_code,
          domain,
          status,
          is_admin
        )
      `)
      .eq('user_code', userCode)
      .eq('secret_code', secretCode)
      .single();

    if (inviteError || !invitation) {
      console.error('Invalid invitation:', inviteError?.message);
      return errorResponse('Invalid invitation code');
    }

    // Check if invitation is still valid
    if (new Date(invitation.expires_at) < new Date()) {
      return errorResponse('Invitation has expired');
    }

    if (invitation.status === 'accepted') {
      return errorResponse('Invitation has already been accepted');
    }

    if (invitation.status === 'cancelled') {
      return errorResponse('Invitation has been cancelled');
    }

    // Verify email matches invitation if specified
    if (invitation.email && invitation.email !== email) {
      return errorResponse('Email does not match invitation');
    }

    console.log('Creating user account from invitation');

    // Create user account
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        first_name: firstName || '',
        last_name: lastName || '',
        registration_status: 'complete'
      }
    });

    if (authError || !authData?.user) {
      console.error('User creation error:', authError?.message);
      throw new Error(authError?.message || 'Failed to create user account');
    }

    // Create user profile - USING UPSERT
    // Generate unique user code with duplicate check
    const userCode2 = await generateUserCode(supabase, firstName, lastName);

    const profileData = {
      user_id: authData.user.id,
      first_name: firstName || '',
      last_name: lastName || '',
      email: authData.user.email,
      is_active: true,
      user_code: userCode2,
      ...(countryCode && { country_code: countryCode }),
      ...(mobileNumber && { mobile_number: mobileNumber })
    };

    const { data: profile, error: profileError } = await supabase
      .from('t_user_profiles')
      .upsert(profileData, {
        onConflict: 'user_id',
        ignoreDuplicates: false
      })
      .select()
      .single();

    if (profileError) {
      console.error('Profile creation error:', profileError.message);
      // Don't fail if profile already exists
      if (!profileError.message.includes('duplicate')) {
        throw new Error(`Error creating user profile: ${profileError.message}`);
      }
    }

    // Create auth method entry - USING UPSERT
    await supabase
      .from('t_user_auth_methods')
      .upsert({
        user_id: authData.user.id,
        auth_type: 'email',
        auth_identifier: email,
        is_primary: true,
        is_verified: true,
        linked_at: new Date().toISOString()
      }, {
        onConflict: 'user_id,auth_type',
        ignoreDuplicates: false
      });

    // Update invitation status
    await supabase
      .from('t_user_invitations')
      .update({
        status: 'accepted',
        accepted_at: new Date().toISOString(),
        accepted_by: authData.user.id
      })
      .eq('id', invitation.id);

    // Link user to tenant
    const { data: userTenant, error: linkError } = await supabase
      .from('t_user_tenants')
      .insert({
        user_id: authData.user.id,
        tenant_id: invitation.tenant_id,
        is_default: true,
        status: 'active'
      })
      .select()
      .single();

    if (linkError) {
      console.error('User-tenant link error:', linkError.message);
      throw new Error(`Error linking user to workspace: ${linkError.message}`);
    }

    // Assign role if specified in invitation
    if (invitation.metadata?.intended_role?.role_id) {
      await supabase
        .from('t_user_tenant_roles')
        .insert({
          user_tenant_id: userTenant.id,
          role_id: invitation.metadata.intended_role.role_id
        });
    }

    // NOTE: Invited users do NOT affect tenant onboarding status
    // Only the owner (signup user) can complete onboarding
    // The UI will check is_owner and show OnboardingPending screen for non-owners

    // Sign in the user
    const { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({
      email,
      password
    });

    if (signInError) {
      console.error('Sign-in error:', signInError.message);
      throw new Error(`Error signing in: ${signInError.message}`);
    }

    return successResponse({
      user_id: authData.user.id,
      email: authData.user.email,
      access_token: signInData.session.access_token,
      refresh_token: signInData.session.refresh_token,
      expires_in: signInData.session.expires_in,
      user: profile || profileData,
      tenant: {
        ...invitation.t_tenants,
        is_owner: false,  // Invited users are NOT owners
        is_default: true
      },
      tenants: [{
        ...invitation.t_tenants,
        is_owner: false,  // Invited users are NOT owners
        is_default: true
      }]
    }, 201);
    
  } catch (error: any) {
    console.error('Registration with invitation error:', error.message);
    return errorResponse(error.message);
  }
}

export async function handleCompleteRegistration(supabase: any, authHeader: string | null, data: any) {
  if (!authHeader) {
    return errorResponse('Authorization header is required', 401);
  }

  const { user: userData, tenant: tenantData } = data;
  
  if (!tenantData || !tenantData.name) {
    return errorResponse('Tenant details are required');
  }

  try {
    // Get user from token
    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    
    if (userError || !user) {
      throw new Error('User not found');
    }

    console.log('Completing registration process for user:', user.id);

    // Generate workspace code
    const workspaceCode = generateWorkspaceCode(tenantData.name);

    // Create tenant
    const { data: tenant, error: tenantError } = await supabase
      .from('t_tenants')
      .insert({
        name: tenantData.name,
        workspace_code: workspaceCode,
        domain: tenantData.domain || null,
        status: 'active',
        created_by: user.id,
        is_admin: false
      })
      .select()
      .single();

    if (tenantError) {
      console.error('Tenant creation error:', tenantError.message);
      throw tenantError;
    }

    // Create or update user profile - USING UPSERT
    const { data: existingProfile } = await supabase
      .from('t_user_profiles')
      .select('id')
      .eq('user_id', user.id)
      .maybeSingle();

    // Generate unique user code if not provided
    const firstName3 = userData?.firstName || user.user_metadata?.first_name || '';
    const lastName3 = userData?.lastName || user.user_metadata?.last_name || '';
    const userCode3 = userData?.user_code || await generateUserCode(supabase, firstName3, lastName3);

    const profileData = {
      user_id: user.id,
      first_name: firstName3,
      last_name: lastName3,
      email: user.email,
      country_code: userData?.country_code || null,
      mobile_number: userData?.mobile_number || null,
      user_code: userCode3,
      is_active: true
    };

    const { data: profile, error: profileError } = await supabase
      .from('t_user_profiles')
      .upsert(profileData, {
        onConflict: 'user_id',
        ignoreDuplicates: false
      })
      .select()
      .single();
    
    if (profileError) {
      console.error('Profile upsert error:', profileError.message);
      // Don't fail if profile already exists
      if (!profileError.message.includes('duplicate')) {
        throw profileError;
      }
    }

    // Link user to tenant
    const { data: userTenant, error: linkError } = await supabase
      .from('t_user_tenants')
      .insert({
        user_id: user.id,
        tenant_id: tenant.id,
        is_default: true,
        status: 'active'
      })
      .select()
      .single();

    if (linkError) {
      console.error('User-tenant link error:', linkError.message);
      throw linkError;
    }

    // Create default roles
    await createDefaultRolesForTenant(supabase, tenant.id, userTenant.id);

    // Seed default Tags and Compliance Numbers
    await createDefaultTagsForTenant(supabase, tenant.id);
    await createDefaultComplianceForTenant(supabase, tenant.id);

    // Update user metadata to mark registration as complete
    await supabase.auth.admin.updateUserById(user.id, {
      user_metadata: {
        ...user.user_metadata,
        registration_status: 'complete'
      }
    });

    return successResponse({
      user: profile || profileData,
      tenant: {
        ...tenant,
        is_admin: tenant.is_admin || false
      }
    });
    
  } catch (error: any) {
    console.error('Complete registration error:', error.message);
    return errorResponse(error.message, 500);
  }
}