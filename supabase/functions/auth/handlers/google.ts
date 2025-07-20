// supabase/functions/auth/handlers/google.ts
import { corsHeaders } from '../utils/cors.ts';
import { errorResponse, successResponse } from '../utils/helpers.ts';

export async function handleLinkGoogleAccount(supabase: any, authHeader: string | null, data: any) {
  if (!authHeader) {
    return errorResponse('Authentication required', 401);
  }

  try {
    const { googleEmail, googleId } = data;
    
    if (!googleEmail || !googleId) {
      return errorResponse('Google email and ID are required');
    }

    // Get user from token
    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    
    if (userError || !user) {
      return errorResponse('Invalid token', 401);
    }

    // Check if user already has a Google account linked
    const { data: existingGoogle } = await supabase
      .from('t_user_auth_methods')
      .select('id, is_deleted')
      .eq('user_id', user.id)
      .eq('auth_type', 'google')
      .single();

    if (existingGoogle && !existingGoogle.is_deleted) {
      return errorResponse('You already have a Google account linked. Please unlink it first.');
    }

    // Check if this Google account is already linked to another user
    const { data: googleInUse } = await supabase
      .from('t_user_auth_methods')
      .select('user_id')
      .eq('auth_identifier', googleEmail)
      .eq('auth_type', 'google')
      .eq('is_deleted', false)
      .single();

    if (googleInUse && googleInUse.user_id !== user.id) {
      return errorResponse('This Google account is already linked to another user');
    }

    // Update user metadata
    const { error: updateError } = await supabase.auth.admin.updateUserById(
      user.id,
      {
        user_metadata: {
          ...user.user_metadata,
          google_linked: true,
          google_id: googleId,
          google_email: googleEmail
        }
      }
    );
    
    if (updateError) {
      throw updateError;
    }

    // Check if user has any auth methods
    const { data: authMethods } = await supabase
      .from('t_user_auth_methods')
      .select('id')
      .eq('user_id', user.id)
      .eq('is_deleted', false);

    const isFirstMethod = !authMethods || authMethods.length === 0;

    // Create or update auth method entry
    if (existingGoogle) {
      // Reactivate existing entry
      const { error: reactivateError } = await supabase
        .from('t_user_auth_methods')
        .update({
          auth_identifier: googleEmail,
          is_deleted: false,
          is_verified: true,
          linked_at: new Date().toISOString(),
          metadata: { google_id: googleId }
        })
        .eq('id', existingGoogle.id);

      if (reactivateError) {
        console.error('Error reactivating auth method:', reactivateError);
        throw reactivateError;
      }
    } else {
      // Create new entry
      const { error: authMethodError } = await supabase
        .from('t_user_auth_methods')
        .insert({
          user_id: user.id,
          auth_type: 'google',
          auth_identifier: googleEmail,
          is_primary: isFirstMethod,
          is_verified: true,
          linked_at: new Date().toISOString(),
          metadata: { google_id: googleId }
        });

      if (authMethodError) {
        console.error('Error storing auth method:', authMethodError);
        throw authMethodError;
      }
    }

    return successResponse({ 
      success: true,
      message: 'Google account linked successfully'
    });
  } catch (error: any) {
    console.error('Error linking Google account:', error);
    return errorResponse(error.message || 'Failed to link Google account', 500);
  }
}

export async function handleUnlinkGoogleAccount(supabase: any, authHeader: string | null) {
  if (!authHeader) {
    return errorResponse('Authentication required', 401);
  }

  try {
    // Get user from token
    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    
    if (userError || !user) {
      return errorResponse('Invalid token', 401);
    }

    // Check if user has Google auth method
    const { data: googleAuth } = await supabase
      .from('t_user_auth_methods')
      .select('id')
      .eq('user_id', user.id)
      .eq('auth_type', 'google')
      .eq('is_deleted', false)
      .single();

    if (!googleAuth) {
      return errorResponse('No Google account linked');
    }

    // Check if user has other active auth methods
    const { data: otherMethods } = await supabase
      .from('t_user_auth_methods')
      .select('id')
      .eq('user_id', user.id)
      .eq('is_deleted', false)
      .neq('auth_type', 'google');

    if (!otherMethods || otherMethods.length === 0) {
      return errorResponse('Cannot unlink your only authentication method');
    }

    // Soft delete the Google auth method
    const { error: deleteError } = await supabase
      .from('t_user_auth_methods')
      .update({
        is_deleted: true,
        deleted_at: new Date().toISOString()
      })
      .eq('id', googleAuth.id);

    if (deleteError) {
      console.error('Error unlinking auth method:', deleteError);
      throw deleteError;
    }

    // Update user metadata
    await supabase.auth.admin.updateUserById(
      user.id,
      {
        user_metadata: {
          ...user.user_metadata,
          google_linked: false,
          google_id: null,
          google_email: null
        }
      }
    );

    return successResponse({ 
      success: true,
      message: 'Google account unlinked successfully'
    });
  } catch (error: any) {
    console.error('Error unlinking Google account:', error);
    return errorResponse(error.message || 'Failed to unlink Google account', 500);
  }
}