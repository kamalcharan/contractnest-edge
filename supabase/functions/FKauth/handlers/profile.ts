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
      console.log('Using family space ID from header:', tenantId);
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

      const userCode = generateUserCode(
        user.user_metadata?.first_name || '',
        user.user_metadata?.last_name || ''
      );

      const newProfile = {
        user_id: user.id,
        first_name: user.user_metadata?.first_name || '',
        last_name: user.user_metadata?.last_name || '',
        email: user.email,
        user_code: userCode,
        is_active: true,
        // FamilyKnows defaults
        preferred_theme: 'light',
        is_dark_mode: false,
        preferred_language: 'en'
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
            registration_status: user.user_metadata?.registration_status || 'complete'
          };
          return successResponse(profileWithStatus);
        }
      }

      // Add registration status from user metadata
      const profileWithStatus = {
        ...createdProfile,
        registration_status: user.user_metadata?.registration_status || 'complete'
      };

      return successResponse(profileWithStatus);
    }

    // Add registration status to existing profile
    const profileWithStatus = {
      ...profile,
      registration_status: user.user_metadata?.registration_status || 'complete'
    };

    console.log('Profile fetched successfully');
    return successResponse(profileWithStatus);

  } catch (error: any) {
    console.error('User profile fetch error:', error.message);
    return errorResponse(error.message, 401);
  }
}
