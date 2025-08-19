//src/_shared/adminAuth.ts

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import { corsHeaders } from "./cors.ts";

export interface AdminVerificationResult {
  isAdmin: boolean;
  userId?: string;
  error?: string;
  status?: number;
}

/**
 * Verify if the user from the auth header has admin privileges
 * @param authHeader Authorization header from the request
 * @returns Object with verification result
 */
export const verifyAdminPermission = async (
  authHeader: string | null
): Promise<AdminVerificationResult> => {
  if (!authHeader) {
    return {
      isAdmin: false,
      error: 'Authorization header is required',
      status: 401
    };
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    
    if (!supabaseUrl || !supabaseKey) {
      return {
        isAdmin: false,
        error: 'Supabase configuration missing',
        status: 500
      };
    }

    // Create Supabase client with admin role key
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: {
        headers: { Authorization: authHeader }
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    // Get user from auth header
    const { data: { user }, error: userError } = await supabase.auth.getUser();
    
    if (userError || !user) {
      return {
        isAdmin: false,
        error: userError?.message || 'Failed to authenticate user',
        status: 401
      };
    }

    // Check if user has admin role in the system
    const { data: adminData, error: adminError } = await supabase
      .from('user_roles')
      .select('*')
      .eq('user_id', user.id)
      .eq('role', 'admin')
      .single();
    
    if (adminError || !adminData) {
      return {
        isAdmin: false,
        userId: user.id,
        error: 'User does not have admin privileges',
        status: 403
      };
    }

    return {
      isAdmin: true,
      userId: user.id
    };