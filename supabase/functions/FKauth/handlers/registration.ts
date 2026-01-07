// FamilyKnows Registration Handler
// This version initializes FamilyKnows-specific onboarding (not ContractNest)

import { corsHeaders } from '../utils/cors.ts';
import { generateWorkspaceCode, generateUserCode, errorResponse, successResponse } from '../utils/helpers.ts';
import { validateEmail, validatePassword, validateRequired } from '../utils/validation.ts';
import { RegisterData } from '../types/index.ts';
import { createDefaultRolesForTenant } from './roles.ts';

// FamilyKnows Onboarding Configuration (must match FKonboarding/index.ts)
const FK_ONBOARDING_CONFIG = {
  type: 'family',
  totalSteps: 6,
  steps: [
    { step_id: 'personal-profile', step_sequence: 1, required: true },
    { step_id: 'theme', step_sequence: 2, required: true, default_value: 'purple-tone' },
    { step_id: 'language', step_sequence: 3, required: true, default_value: 'en' },
    { step_id: 'family-space', step_sequence: 4, required: true },
    { step_id: 'storage', step_sequence: 5, required: false },
    { step_id: 'family-invite', step_sequence: 6, required: false }
  ]
};

// Initialize FamilyKnows onboarding for a tenant
async function initializeFKOnboarding(supabase: any, tenantId: string): Promise<void> {
  try {
    console.log(`Initializing FamilyKnows onboarding for tenant: ${tenantId}`);

    // Check if already exists
    const { data: existingData } = await supabase
      .from('t_tenant_onboarding')
      .select('id')
      .eq('tenant_id', tenantId);

    if (existingData && existingData.length > 0) {
      console.log('Onboarding already initialized for tenant:', tenantId);
      return;
    }

    // Create onboarding record with FamilyKnows configuration
    const { error: createError } = await supabase
      .from('t_tenant_onboarding')
      .insert({
        tenant_id: tenantId,
        onboarding_type: FK_ONBOARDING_CONFIG.type,
        total_steps: FK_ONBOARDING_CONFIG.totalSteps,
        current_step: 1,
        completed_steps: [],
        skipped_steps: [],
        step_data: {
          // Set default values
          theme: { value: 'purple-tone', is_dark_mode: false },
          language: { value: 'en' }
        },
        is_completed: false
      });

    if (createError) {
      console.error('Failed to create onboarding record:', createError.message);
      // Non-fatal - continue with registration
      return;
    }

    // Create step records
    const steps = FK_ONBOARDING_CONFIG.steps.map(step => ({
      tenant_id: tenantId,
      step_id: step.step_id,
      step_sequence: step.step_sequence,
      status: 'pending'
    }));

    const { error: stepsError } = await supabase
      .from('t_onboarding_step_status')
      .insert(steps);

    if (stepsError) {
      console.error('Failed to create step records:', stepsError.message);
      // Non-fatal - continue with registration
    }

    console.log('FamilyKnows onboarding initialized successfully for tenant:', tenantId);
  } catch (error) {
    console.error('Error initializing FK onboarding:', error);
    // Non-fatal - don't fail registration
  }
}

export async function handleRegister(supabase: any, data: RegisterData) {
  // FamilyKnows: email + password required, with optional first_name, last_name, workspace_name
  // If workspace_name is provided, tenant is created during signup
  const { email, password, first_name, last_name, workspace_name } = data as any;

  // Validate required fields - only email and password
  const validationError = validateRequired(
    { email, password },
    ['email', 'password']
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
    console.log('Creating FamilyKnows user with email:', email);
    console.log('Prefill data:', { first_name, last_name, workspace_name });

    // Create user with metadata (including name if provided)
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        first_name: first_name || '',
        last_name: last_name || '',
        registration_status: workspace_name ? 'complete' : 'pending_onboarding',
        product: 'familyknows'
      }
    });

    if (authError || !authData?.user) {
      console.error('User creation error:', authError?.message);
      throw new Error(authError?.message || 'Failed to create user account');
    }

    console.log('User created successfully:', authData.user.id);

    // Create user profile with name if provided
    const profileData: any = {
      user_id: authData.user.id,
      email: authData.user.email,
      is_active: true,
      // FamilyKnows defaults - purple-tone theme
      preferred_theme: 'purple-tone',
      is_dark_mode: false,
      preferred_language: 'en'
    };

    // Add name fields if provided
    if (first_name) {
      profileData.first_name = first_name;
    }
    if (last_name) {
      profileData.last_name = last_name;
    }
    // Generate user_code if name is provided
    if (first_name || last_name) {
      profileData.user_code = generateUserCode(first_name || '', last_name || '');
    }

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
      if (!profileError.message.includes('duplicate')) {
        throw new Error(`Error creating user profile: ${profileError.message}`);
      }
    }

    // Create auth method entry
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

    // Create tenant if workspace_name is provided
    let tenant = null;
    let tenants: any[] = [];

    if (workspace_name) {
      console.log('Creating family space:', workspace_name);

      const workspaceCode = generateWorkspaceCode(workspace_name);

      const { data: newTenant, error: tenantError } = await supabase
        .from('t_tenants')
        .insert({
          name: workspace_name,
          workspace_code: workspaceCode,
          status: 'active',
          created_by: authData.user.id,
          is_admin: false
        })
        .select()
        .single();

      if (tenantError) {
        console.error('Tenant creation error:', tenantError.message);
        throw new Error(`Error creating family space: ${tenantError.message}`);
      }

      tenant = newTenant;
      console.log('Family space created:', tenant.id);

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
        throw new Error(`Error linking user to family space: ${linkError.message}`);
      }

      console.log('User linked to family space:', userTenant.id);

      // Create default roles for the tenant
      await createDefaultRolesForTenant(supabase, tenant.id, userTenant.id);

      // Initialize FamilyKnows onboarding
      await initializeFKOnboarding(supabase, tenant.id);

      // Mark family-space step as complete since tenant was just created
      await supabase
        .from('t_onboarding_step_status')
        .update({
          status: 'completed',
          completed_at: new Date().toISOString()
        })
        .eq('tenant_id', tenant.id)
        .eq('step_id', 'family-space');

      // Get current onboarding data to merge step_data
      const { data: onboardingData } = await supabase
        .from('t_tenant_onboarding')
        .select('step_data, completed_steps')
        .eq('tenant_id', tenant.id)
        .single();

      const currentStepData = onboardingData?.step_data || {};
      const currentCompletedSteps = onboardingData?.completed_steps || [];

      // Update step_data with family-space info
      await supabase
        .from('t_tenant_onboarding')
        .update({
          step_data: {
            ...currentStepData,
            'family-space': {
              name: workspace_name,
              tenant_id: tenant.id,
              user_id: authData.user.id
            }
          },
          completed_steps: [...currentCompletedSteps, 'family-space']
        })
        .eq('tenant_id', tenant.id);

      console.log('Family-space step marked as completed');

      tenants = [tenant];
    }

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
      tenant: tenant,
      tenants: tenants,
      // FamilyKnows-specific: indicate onboarding is needed
      needs_onboarding: true,
      onboarding_type: 'family'
    }, 201);

  } catch (error: any) {
    console.error('FamilyKnows registration error:', error.message);
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
    console.log('Validating family invitation for registration:', { userCode, email });

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

    console.log('Creating FamilyKnows user account from invitation');

    // Create user account
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        first_name: firstName || '',
        last_name: lastName || '',
        registration_status: 'complete',
        product: 'familyknows'
      }
    });

    if (authError || !authData?.user) {
      console.error('User creation error:', authError?.message);
      throw new Error(authError?.message || 'Failed to create user account');
    }

    // Create user profile with FamilyKnows defaults
    const profileData = {
      user_id: authData.user.id,
      first_name: firstName || '',
      last_name: lastName || '',
      email: authData.user.email,
      is_active: true,
      user_code: generateUserCode(firstName, lastName),
      preferred_theme: 'purple-tone',
      is_dark_mode: false,
      preferred_language: 'en',
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
      if (!profileError.message.includes('duplicate')) {
        throw new Error(`Error creating user profile: ${profileError.message}`);
      }
    }

    // Create auth method entry
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

    // Link user to family space
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
      console.error('User-family space link error:', linkError.message);
      throw new Error(`Error linking user to family space: ${linkError.message}`);
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
      tenant: invitation.t_tenants,
      tenants: [invitation.t_tenants],
      // Invited users don't need onboarding (owner handles it)
      needs_onboarding: false
    }, 201);

  } catch (error: any) {
    console.error('FamilyKnows registration with invitation error:', error.message);
    return errorResponse(error.message);
  }
}

export async function handleCompleteRegistration(supabase: any, authHeader: string | null, data: any) {
  if (!authHeader) {
    return errorResponse('Authorization header is required', 401);
  }

  const { user: userData, tenant: tenantData } = data;

  if (!tenantData || !tenantData.name) {
    return errorResponse('Family space details are required');
  }

  try {
    // Get user from token
    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);

    if (userError || !user) {
      throw new Error('User not found');
    }

    console.log('Completing FamilyKnows registration for user:', user.id);

    // Generate workspace code
    const workspaceCode = generateWorkspaceCode(tenantData.name);

    // Create family space
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
      console.error('Family space creation error:', tenantError.message);
      throw tenantError;
    }

    // Initialize FamilyKnows onboarding
    await initializeFKOnboarding(supabase, tenant.id);

    // Create or update user profile
    const profileData = {
      user_id: user.id,
      first_name: userData?.firstName || user.user_metadata?.first_name || '',
      last_name: userData?.lastName || user.user_metadata?.last_name || '',
      email: user.email,
      country_code: userData?.country_code || null,
      mobile_number: userData?.mobile_number || null,
      user_code: userData?.user_code || generateUserCode(
        userData?.firstName || user.user_metadata?.first_name || '',
        userData?.lastName || user.user_metadata?.last_name || ''
      ),
      is_active: true,
      preferred_theme: 'purple-tone',
      is_dark_mode: false,
      preferred_language: 'en'
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
      if (!profileError.message.includes('duplicate')) {
        throw profileError;
      }
    }

    // Link user to family space
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
      console.error('User-family space link error:', linkError.message);
      throw linkError;
    }

    // Create default roles
    await createDefaultRolesForTenant(supabase, tenant.id, userTenant.id);

    // Update user metadata
    await supabase.auth.admin.updateUserById(user.id, {
      user_metadata: {
        ...user.user_metadata,
        registration_status: 'complete',
        product: 'familyknows'
      }
    });

    return successResponse({
      user: profile || profileData,
      tenant: {
        ...tenant,
        is_admin: tenant.is_admin || false
      },
      needs_onboarding: true,
      onboarding_type: 'family'
    });

  } catch (error: any) {
    console.error('Complete FamilyKnows registration error:', error.message);
    return errorResponse(error.message, 500);
  }
}
