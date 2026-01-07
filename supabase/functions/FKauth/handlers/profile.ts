// supabase/functions/FKauth/handlers/profile.ts
import { corsHeaders } from '../utils/cors.ts';
import { errorResponse, successResponse, generateUserCode } from '../utils/helpers.ts';
import { getUserFromToken } from '../utils/supabase.ts';

export async function handleGetUserProfile(supabaseAdmin: any, authHeader: string | null, req: Request) {
  try {
    if (!authHeader) {
      return errorResponse('Missing Authorization header', 401);
    }

    console.log('Getting FamilyKnows user profile with token');

    const token = authHeader.replace('Bearer ', '');
    let user = null;

    try {
      // Try to get user from token
      const { data, error } = await supabaseAdmin.auth.getUser(token);

      if (error) {
        console.error('Token verification error:', error.message);
        return errorResponse('Invalid or expired token', 401);
      }

      if (data?.user) {
        user = data.user;
        console.log('User authenticated successfully');
      } else {
        console.error('No user data returned from token verification');
        return errorResponse('User not found', 401);
      }
    } catch (error: any) {
      console.error('Token verification failed:', error?.message || error);
      return errorResponse('Invalid or expired token', 401);
    }

    console.log('User authenticated successfully:', user.id);

    // Get tenant ID from header if present
    const tenantId = req.headers.get('x-tenant-id');
    let currentTenant = null;
    let userRoles: string[] = [];

    if (tenantId) {
      console.log('Using family space ID from header:', tenantId);

      // Validate user belongs to this tenant and get tenant details
      const { data: userTenant, error: tenantError } = await supabaseAdmin
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
            status,
            created_by,
            storage_setup_complete
          )
        `)
        .eq('user_id', user.id)
        .eq('tenant_id', tenantId)
        .eq('status', 'active')
        .single();

      if (tenantError || !userTenant) {
        console.error('User does not belong to tenant:', tenantId);
        return errorResponse('Access denied: User does not belong to this family space', 403);
      }

      // Get user's roles for this tenant
      const { data: rolesData } = await supabaseAdmin
        .from('t_user_tenant_roles')
        .select(`
          t_category_details!inner (
            sub_cat_name,
            display_name
          )
        `)
        .eq('user_tenant_id', userTenant.id);

      if (rolesData) {
        userRoles = rolesData.map((r: any) => r.t_category_details.sub_cat_name);
      }

      const isOwner = userTenant.t_tenants.created_by === user.id;
      currentTenant = {
        id: userTenant.t_tenants.id,
        name: userTenant.t_tenants.name,
        workspace_code: userTenant.t_tenants.workspace_code,
        status: userTenant.t_tenants.status,
        is_default: userTenant.is_default,
        is_owner: isOwner,
        is_admin: isOwner || userRoles.includes('Owner') || userRoles.includes('Admin'),
        storage_setup_complete: userTenant.t_tenants.storage_setup_complete || false,
        user_roles: userRoles
      };

      console.log('User validated for tenant:', tenantId, 'Roles:', userRoles);
    }

    // Get user profile from database
    const { data: profile, error: profileError } = await supabaseAdmin
      .from('t_user_profiles')
      .select('*')
      .eq('user_id', user.id)
      .maybeSingle();

    if (profileError && profileError.code !== 'PGRST116') {
      console.error('Profile fetch error:', profileError.message);
      throw profileError;
    }

    // If profile doesn't exist, create one with FamilyKnows defaults
    if (!profile) {
      console.log('Profile not found, creating a new one');

      // Only generate user_code if we have name data
      const firstName = user.user_metadata?.first_name || null;
      const lastName = user.user_metadata?.last_name || null;
      const userCode = (firstName || lastName)
        ? generateUserCode(firstName || '', lastName || '')
        : null;

      const newProfile: any = {
        user_id: user.id,
        email: user.email,
        is_active: true,
        // FamilyKnows defaults
        preferred_theme: 'light',
        is_dark_mode: false,
        preferred_language: 'en'
      };

      // Only include name/user_code if available (they're nullable now)
      if (firstName) newProfile.first_name = firstName;
      if (lastName) newProfile.last_name = lastName;
      if (userCode) newProfile.user_code = userCode;

      const { data: createdProfile, error: createError } = await supabaseAdmin
        .from('t_user_profiles')
        .upsert(newProfile, {
          onConflict: 'user_id',
          ignoreDuplicates: false
        })
        .select()
        .single();

      if (createError) {
        console.error('Profile creation error:', createError.message);
        if (!createError.message.includes('duplicate')) {
          throw createError;
        }

        // If it's a duplicate error, try to fetch the profile again
        const { data: existingProfile } = await supabaseAdmin
          .from('t_user_profiles')
          .select('*')
          .eq('user_id', user.id)
          .single();

        if (existingProfile) {
          const profileWithStatus = {
            ...existingProfile,
            registration_status: user.user_metadata?.registration_status || 'complete',
            current_tenant: currentTenant,
            user_roles: userRoles
          };
          return successResponse(profileWithStatus);
        }
      }

      // Add registration status from user metadata
      const profileWithStatus = {
        ...createdProfile,
        registration_status: user.user_metadata?.registration_status || 'complete',
        current_tenant: currentTenant,
        user_roles: userRoles
      };

      return successResponse(profileWithStatus);
    }

    // Add registration status to existing profile
    const profileWithStatus = {
      ...profile,
      registration_status: user.user_metadata?.registration_status || 'complete',
      current_tenant: currentTenant,
      user_roles: userRoles
    };

    console.log('Profile fetched successfully');
    return successResponse(profileWithStatus);

  } catch (error: any) {
    console.error('User profile fetch error:', error.message);
    return errorResponse(error.message, 401);
  }
}
