// supabase/functions/auth/handlers/preferences.ts
import { corsHeaders } from '../utils/cors.ts';
import { errorResponse, successResponse } from '../utils/helpers.ts';

export async function handleUpdatePreferences(supabaseAdmin: any, authHeader: string | null, data: any) {
  if (!authHeader) {
    return errorResponse('Authentication required', 401);
  }

  try {
    // Get user from token
    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: userError } = await supabaseAdmin.auth.getUser(token);
    
    if (userError || !user) {
      return errorResponse('Invalid token', 401);
    }

    const { preferred_theme, is_dark_mode, preferred_language } = data;
    
    // Build update object
    const updates: any = {};
    if (preferred_theme !== undefined) updates.preferred_theme = preferred_theme;
    if (is_dark_mode !== undefined) updates.is_dark_mode = is_dark_mode;
    if (preferred_language !== undefined) updates.preferred_language = preferred_language;

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

    console.log('User preferences updated successfully');
    return successResponse(updatedProfile);
    
  } catch (error: any) {
    console.error('Preferences update error:', error.message);
    return errorResponse(error.message || 'Failed to update preferences', 500);
  }
}