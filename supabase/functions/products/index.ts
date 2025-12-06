// /supabase/functions/products/index.ts
// Products Edge Function - Returns available products for dropdown selection
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-user-id',
  'Access-Control-Allow-Methods': 'GET, OPTIONS'
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

    if (!supabaseUrl || !supabaseKey) {
      return new Response(
        JSON.stringify({ error: 'Server configuration error' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const authHeader = req.headers.get('Authorization');

    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: {
        headers: { Authorization: authHeader }
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(segment => segment);

    console.log('Products request:', req.method, url.pathname);

    if (req.method === 'GET') {
      // Get specific product by code
      if (pathSegments.length > 1 && pathSegments[1]) {
        const productCode = pathSegments[1];

        const { data: product, error } = await supabase
          .from('m_products')
          .select('*')
          .eq('code', productCode)
          .eq('is_active', true)
          .single();

        if (error) {
          if (error.code === 'PGRST116') {
            return new Response(
              JSON.stringify({ error: 'Product not found' }),
              { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          throw error;
        }

        return new Response(
          JSON.stringify({ success: true, data: product }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // List all active products
      const includeInactive = url.searchParams.get('includeInactive') === 'true';

      let query = supabase
        .from('m_products')
        .select('id, code, name, description, is_active, is_default, settings, created_at')
        .order('is_default', { ascending: false })
        .order('name', { ascending: true });

      if (!includeInactive) {
        query = query.eq('is_active', true);
      }

      const { data: products, error } = await query;

      if (error) throw error;

      return new Response(
        JSON.stringify({ success: true, data: products || [], count: products?.length || 0 }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify({ error: 'Method not supported' }),
      { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Products edge function error:', error);
    return new Response(
      JSON.stringify({ error: 'Internal server error', details: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
