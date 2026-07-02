import { corsHeaders } from '../utils/cors.ts';
import { errorResponse, successResponse, generateUserCode } from '../utils/helpers.ts';
import { getUserFromToken } from '../utils/supabase.ts';

/**
 * Derive first/last name from a Supabase/Google user_metadata object.
 * Mirrors the fallback chain previously done client-side in GoogleCallbackPage:
 *   full_name -> given_name/family_name -> first_name/last_name -> name -> email
 */
function deriveName(meta: any, email: string | null): { firstName: string; lastName: string } {
  meta = meta || {};
  let firstName = '';
  let lastName = '';

  if (meta.full_name) {
    const parts = String(meta.full_name).trim().split(/\s+/);
    firstName = parts[0] || '';
    lastName = parts.slice(1).join(' ') || '';
  }

  firstName = meta.given_name || meta.first_name || firstName || '';
  lastName = meta.family_name || meta.last_name || lastName || '';

  if (!firstName && !lastName && meta.name) {
    const parts = String(meta.name).trim().split(/\s+/);
    firstName = parts[0] || '';
    lastName = parts.slice(1).join(' ') || '';
  }

  if (!firstName && email) {
    firstName = email.split('@')[0] || '';
  }

  return { firstName, lastName };
}

/**
 * Fetch the active tenants for a user, shaped exactly as the UI expects.
 * Centralised here (service_role) so clients never query t_user_tenants/t_tenants directly.
 */
async function fetchUserTenants(supabaseAdmin: any, userId: string, profile: any) {
  const { data: userTenants } = await supabaseAdmin
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
    .eq('user_id', userId)
    .eq('status', 'active');

  return (userTenants || []).map((ut: any) => ({
    id: ut.t_tenants.id,
    name: ut.t_tenants.name,
    workspace_code: ut.t_tenants.workspace_code,
    domain: ut.t_tenants.domain,
    status: ut.t_tenants.status,
    is_admin: ut.t_tenants.is_admin || false,
    storage_setup_complete: ut.t_tenants.storage_setup_complete || false,
    is_default: ut.is_default || false,
    is_owner: ut.t_tenants.created_by === userId,
    user_is_profile_admin: profile?.is_admin || false,
    is_explicitly_assigned: true
  }));
}

export async function handleGetUserProfile(supabaseAdmin: any, authHeader: string | null, req: Request) {
  try {
    if (!authHeader) {
      return errorResponse('Missing Authorization header', 401);
    }

    console.log('Getting user profile with token');

    const token = authHeader.replace('Bearer ', '');
    let user = null;

    try {
      // Try to get user from token
      const { data, error } = await supabaseAdmin.auth.getUser(token);

      if (!error && data?.user) {
        user = data.user;
        console.log('User authenticated successfully');
      }
    } catch (error) {
      console.error('Token verification failed:', error);
      return errorResponse('Invalid or expired token', 401);
    }

    if (!user) {
      return errorResponse('User not found', 401);
    }

    console.log('User authenticated successfully:', user.id);

    // Get tenant ID from header if present
    const tenantId = req.headers.get('x-tenant-id');
    if (tenantId) {
      console.log('Using tenant ID from header:', tenantId);
    }

    // Get user profile from database
    const { data: profile, error: profileError } = await supabaseAdmin
      .from('t_user_profiles')
      .select('*')
      .eq('user_id', user.id)
      .maybeSingle(); // Use maybeSingle instead of single

    if (profileError && profileError.code !== 'PGRST116') {
      console.error('Profile fetch error:', profileError.message);
      throw profileError;
    }

    let resolvedProfile = profile;
    let isNewUser = false;

    // If profile doesn't exist, create a minimal one - USING UPSERT
    if (!profile) {
      console.log('Profile not found, creating a new one');
      isNewUser = true;

      // Derive name from (Google) metadata with the full fallback chain
      const { firstName, lastName } = deriveName(user.user_metadata, user.email);
      const userCode = generateUserCode(firstName, lastName);

      const newProfile = {
        user_id: user.id,
        first_name: firstName,
        last_name: lastName,
        email: user.email,
        user_code: userCode,
        is_active: true
      };

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
        // Don't fail if profile already exists
        if (!createError.message.includes('duplicate')) {
          throw createError;
        }

        // If it's a duplicate error, the profile already existed - fetch it
        const { data: existingProfile } = await supabaseAdmin
          .from('t_user_profiles')
          .select('*')
          .eq('user_id', user.id)
          .single();

        if (existingProfile) {
          resolvedProfile = existingProfile;
          isNewUser = false;
        }
      } else {
        resolvedProfile = createdProfile;
      }
    }

    // Fetch the user's active tenants server-side (service_role) so the client
    // never has to query t_user_tenants / t_tenants directly.
    const tenants = await fetchUserTenants(supabaseAdmin, user.id, resolvedProfile);

    // Compose response: profile fields at top level (backward compatible) plus
    // registration_status, isNewUser and tenants (additive for the Google flow).
    const profileWithStatus = {
      ...resolvedProfile,
      registration_status: user.user_metadata?.registration_status || 'complete',
      isNewUser,
      tenants
    };

    console.log('Profile fetched successfully with', tenants.length, 'tenant(s)');
    return successResponse(profileWithStatus);

  } catch (error: any) {
    console.error('User profile fetch error:', error.message);
    return errorResponse(error.message, 401);
  }
}
