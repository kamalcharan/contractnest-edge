// supabase/functions/FKauth/handlers/preferences.ts
import { corsHeaders } from '../utils/cors.ts';
import { errorResponse, successResponse } from '../utils/helpers.ts';

export async function handleUpdatePreferences(supabaseAdmin: any, authHeader: string | null, data: any, req?: Request) {
  if (!authHeader) {
    return errorResponse('Authentication required', 401);
  }

  try {
    // Get x-tenant-id from header for tenant-scoped operations
    const tenantId = req?.headers.get('x-tenant-id');
    if (tenantId) {
      console.log('Preferences update for tenant:', tenantId);
    }

    // Get user from token
    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: userError } = await supabaseAdmin.auth.getUser(token);

    if (userError || !user) {
      return errorResponse('Invalid token', 401);
    }

    // Validate user belongs to tenant if tenant_id is provided
    if (tenantId) {
      const { data: userTenant, error: tenantError } = await supabaseAdmin
        .from('t_user_tenants')
        .select('id, tenant_id')
        .eq('user_id', user.id)
        .eq('tenant_id', tenantId)
        .eq('status', 'active')
        .single();

      if (tenantError || !userTenant) {
        console.error('User does not belong to tenant:', tenantId);
        return errorResponse('Access denied: User does not belong to this family space', 403);
      }
      console.log('User validated for tenant:', tenantId);
    }

    const { preferred_theme, is_dark_mode, preferred_language, date_of_birth, gender } = data;

    // Build update object - FamilyKnows supports additional fields
    const updates: any = {};
    if (preferred_theme !== undefined) updates.preferred_theme = preferred_theme;
    if (is_dark_mode !== undefined) updates.is_dark_mode = is_dark_mode;
    if (preferred_language !== undefined) updates.preferred_language = preferred_language;
    if (date_of_birth !== undefined) updates.date_of_birth = date_of_birth;
    if (gender !== undefined) updates.gender = gender;

    if (Object.keys(updates).length === 0) {
      return errorResponse('No preferences to update');
    }

    updates.updated_at = new Date().toISOString();

    // Update user profile
    const { data: updatedProfile, error: updateError } = await supabaseAdmin
      .from('t_user_profiles')
      .update(updates)
      .eq('user_id', user.id)
      .select()
      .single();

    if (updateError) {
      console.error('Profile update error:', updateError.message);
      throw updateError;
    }

    console.log('FamilyKnows user preferences updated successfully');
    return successResponse(updatedProfile);

  } catch (error: any) {
    console.error('Preferences update error:', error.message);
    return errorResponse(error.message || 'Failed to update preferences', 500);
  }
}
