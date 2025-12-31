// supabase/functions/FKauth/handlers/authentication.ts
import { corsHeaders } from '../utils/cors.ts';
import { errorResponse, successResponse } from '../utils/helpers.ts';
import { validateEmail, validateRequired } from '../utils/validation.ts';

export async function handleLogin(supabase: any, data: any) {
  const { email, password } = data;

  console.log('FamilyKnows login attempt for:', email);

  if (!email || !password) {
    return errorResponse('Email and password are required');
  }

  try {
    console.log('Attempting login for email:', email);

    // Check if email exists in auth methods
    const { data: authMethod } = await supabase
      .from('t_user_auth_methods')
      .select('user_id, auth_type')
      .eq('auth_identifier', email)
      .eq('auth_type', 'email')
      .single();

    // Authenticate user
    const { data: authData, error: authError } = await supabase.auth.signInWithPassword({
      email,
      password
    });

    if (authError) {
      console.error('Login error:', authError.message);

      if (authError.message.includes('Invalid login credentials') ||
          authError.message.includes('invalid_grant')) {
        return errorResponse('Invalid email or password', 401);
      }

      if (authError.message.includes('Email not confirmed')) {
        return errorResponse('Please verify your email before logging in', 401);
      }

      return errorResponse('Login failed. Please try again.', 401);
    }

    console.log('User authenticated successfully:', authData.user.id);

    // Update last used timestamp
    if (authMethod) {
      await supabase
        .from('t_user_auth_methods')
        .update({ last_used_at: new Date().toISOString() })
        .eq('user_id', authData.user.id)
        .eq('auth_type', 'email');
    }

    // Get user profile
    const { data: userProfile } = await supabase
      .from('t_user_profiles')
      .select('*')
      .eq('user_id', authData.user.id)
      .single();

    // Get user's family spaces
    const { data: userTenantData, error: tenantError } = await supabase
      .from('t_user_tenants')
      .select(`
        id,
        tenant_id,
        is_default,
        status,
        t_tenants!inner (
          id,
          name,
          workspace_code,
          domain,
          status,
          is_admin,
          created_by,
          storage_setup_complete
        )
      `)
      .eq('user_id', authData.user.id)
      .eq('status', 'active');

    if (tenantError) {
      console.error('Family space fetch error:', tenantError.message);
      throw tenantError;
    }

    console.log('Found', userTenantData?.length || 0, 'family spaces for user');

    // Get user's roles for each family space
    const tenantIds = userTenantData?.map(ut => ut.tenant_id) || [];
    let userTenantRoles = {};

    if (tenantIds.length > 0) {
      const { data: rolesData } = await supabase
        .from('t_user_tenant_roles')
        .select(`
          user_tenant_id,
          t_category_details!inner (
            id,
            sub_cat_name,
            display_name,
            tenant_id
          )
        `)
        .in('user_tenant_id', userTenantData.map(ut => ut.id));

      if (rolesData) {
        rolesData.forEach(role => {
          const tenantId = role.t_category_details.tenant_id;
          if (!userTenantRoles[tenantId]) {
            userTenantRoles[tenantId] = [];
          }
          userTenantRoles[tenantId].push(role.t_category_details.sub_cat_name);
        });
      }
    }

    // Transform family space data
    const familySpaces = (userTenantData || []).map(ut => {
      const tenantRoles = userTenantRoles[ut.tenant_id] || [];
      const isOwner = ut.t_tenants.created_by === authData.user.id;
      const isAdmin = isOwner || tenantRoles.includes('Owner') || tenantRoles.includes('Admin');

      return {
        id: ut.t_tenants.id,
        name: ut.t_tenants.name,
        workspace_code: ut.t_tenants.workspace_code,
        domain: ut.t_tenants.domain,
        status: ut.t_tenants.status,
        is_admin: ut.t_tenants.is_admin || false,
        storage_setup_complete: ut.t_tenants.storage_setup_complete || false,
        is_default: ut.is_default || false,
        is_owner: isOwner,
        is_family_admin: isAdmin,
        user_roles: tenantRoles
      };
    });

    // Sort family spaces
    familySpaces.sort((a, b) => {
      if (a.is_default !== b.is_default) return a.is_default ? -1 : 1;
      if (a.is_admin !== b.is_admin) return a.is_admin ? -1 : 1;
      return a.name.localeCompare(b.name);
    });

    // Check onboarding status for default family space
    let needsOnboarding = false;
    const defaultSpace = familySpaces.find(fs => fs.is_default) || familySpaces[0];

    if (defaultSpace) {
      const { data: onboardingData } = await supabase
        .from('t_tenant_onboarding')
        .select('is_completed, onboarding_type')
        .eq('tenant_id', defaultSpace.id)
        .single();

      needsOnboarding = !onboardingData?.is_completed;
    }

    // Prepare user info
    const userInfo = {
      id: authData.user.id,
      email: authData.user.email,
      first_name: userProfile?.first_name || '',
      last_name: userProfile?.last_name || '',
      user_code: userProfile?.user_code || '',
      date_of_birth: userProfile?.date_of_birth || null,
      gender: userProfile?.gender || null,
      preferred_theme: userProfile?.preferred_theme || 'light',
      is_dark_mode: userProfile?.is_dark_mode || false,
      preferred_language: userProfile?.preferred_language || 'en',
      is_admin: userProfile?.is_admin || false,
      user_metadata: authData.user.user_metadata,
      registration_status: authData.user.user_metadata?.registration_status || 'complete'
    };

    return successResponse({
      access_token: authData.session.access_token,
      refresh_token: authData.session.refresh_token,
      expires_in: authData.session.expires_in,
      user: userInfo,
      family_spaces: familySpaces,
      tenants: familySpaces, // Alias for compatibility
      needs_onboarding: needsOnboarding,
      onboarding_type: 'family'
    });

  } catch (error: any) {
    console.error('Login process error:', error.message);
    return errorResponse('An error occurred during login. Please try again.', 500);
  }
}

export async function handleSignout(supabase: any) {
  try {
    const { error } = await supabase.auth.signOut();
    if (error) {
      console.error('Signout error:', error.message);
      throw error;
    }

    return successResponse({ message: 'Signed out successfully' });
  } catch (error: any) {
    console.error('Signout process error:', error.message);
    return errorResponse(error.message, 500);
  }
}

export async function handleTokenRefresh(supabase: any, data: any) {
  const { refresh_token } = data;

  if (!refresh_token) {
    return errorResponse('Refresh token is required');
  }

  try {
    console.log('Attempting to refresh token');
    const { data: authData, error: authError } = await supabase.auth.refreshSession({
      refresh_token
    });

    if (authError) {
      console.error('Token refresh error:', authError.message);
      throw authError;
    }

    console.log('Token refreshed successfully');
    return successResponse({
      access_token: authData.session.access_token,
      refresh_token: authData.session.refresh_token,
      expires_in: authData.session.expires_in
    });
  } catch (error: any) {
    console.error('Token refresh process error:', error.message);
    return errorResponse(error.message, 401);
  }
}
