// supabase/functions/FKauth/utils/supabase.ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4';

export function createAdminClient() {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    }
  );
}

export function createAuthClient(authHeader?: string | null) {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    authHeader ? {
      global: {
        headers: {
          Authorization: authHeader
        }
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    } : {
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    }
  );
}

export async function getUserFromToken(supabaseClient: any, token: string) {
  const { data, error } = await supabaseClient.auth.getUser(token);
  if (error || !data?.user) {
    throw new Error('Invalid token');
  }
  return data.user;
}
