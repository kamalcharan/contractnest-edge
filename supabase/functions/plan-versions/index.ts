// /supabase/functions/plan-versions/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import { getVersionTenantCount } from "../utils/business-model.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-user-id',
  'Access-Control-Allow-Methods': 'GET, PUT, OPTIONS'
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
    const tenantHeader = req.headers.get('x-tenant-id');
    
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    if (!tenantHeader) {
      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Create client with service role key - do NOT override Authorization header
    // as that would replace service role auth with user JWT and apply RLS policies
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: {
        headers: {
          'x-tenant-id': tenantHeader
        }
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });
    
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(segment => segment);
    
    // GET - List versions
    if (req.method === 'GET') {
      const planId = url.searchParams.get('planId');
      
      if (!planId) {
        return new Response(
          JSON.stringify({ error: 'planId query parameter is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      const { data: versions, error } = await supabase
        .from('t_bm_plan_version')
        .select('*')
        .eq('plan_id', planId)
        .order('created_at', { ascending: false });
        
      if (error) throw error;
      
      // Add tenant counts
      const enrichedVersions = await Promise.all(
        versions.map(async (version) => {
          const tenantCount = await getVersionTenantCount(supabase, version.version_id);
          return { ...version, tenant_count: tenantCount };
        })
      );
      
      return new Response(
        JSON.stringify(enrichedVersions),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // PUT - Activate version
    if (req.method === 'PUT') {
      if (pathSegments.length < 2) {
        return new Response(
          JSON.stringify({ error: 'Version ID is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      const versionId = pathSegments[1];
      
      if (pathSegments[2] === 'activate') {
        const { data: version, error: versionError } = await supabase
          .from('t_bm_plan_version')
          .select('plan_id, is_active')
          .eq('version_id', versionId)
          .single();
          
        if (versionError) {
          if (versionError.code === 'PGRST116') {
            return new Response(
              JSON.stringify({ error: 'Version not found' }),
              { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          throw versionError;
        }
        
        if (version.is_active) {
          return new Response(
            JSON.stringify({ message: 'Version is already active' }),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Deactivate other versions
        await supabase
          .from('t_bm_plan_version')
          .update({ is_active: false })
          .eq('plan_id', version.plan_id)
          .eq('is_active', true);
        
        // Activate this version
        const { data: activatedVersion, error: activateError } = await supabase
          .from('t_bm_plan_version')
          .update({ is_active: true, updated_at: new Date().toISOString() })
          .eq('version_id', versionId)
          .select()
          .single();
          
        if (activateError) throw activateError;
        
        // Update plan timestamp
        await supabase
          .from('t_bm_pricing_plan')
          .update({ updated_at: new Date().toISOString() })
          .eq('plan_id', version.plan_id);
        
        return new Response(
          JSON.stringify(activatedVersion),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      return new Response(
        JSON.stringify({ error: 'Invalid operation' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    return new Response(
      JSON.stringify({ error: 'Method not supported' }),
      { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error) {
    console.error('Error:', error);
    return new Response(
      JSON.stringify({ error: 'Internal server error', details: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
