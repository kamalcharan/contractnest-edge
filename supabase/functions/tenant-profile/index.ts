// supabase/functions/tenant-profile/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS'
};

serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    
    // Get auth header and extract token
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
    
    // Verify the user is authenticated by checking their token
    const userToken = authHeader.replace('Bearer ', '');

    // Create a client with user's token to verify authentication
    const userClient = createClient(supabaseUrl, supabaseKey, {
      global: {
        headers: {
          Authorization: authHeader
        }
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    // Verify the user is authenticated
    const { data: { user }, error: authError } = await userClient.auth.getUser(userToken);

    if (authError || !user) {
      console.error('Auth verification failed:', authError);
      return new Response(
        JSON.stringify({ error: 'Invalid or expired authentication token' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('Authenticated user:', user.id);

    // Verify user has access to this tenant
    const { data: userTenant, error: tenantAccessError } = await userClient
      .from('t_user_tenants')
      .select('id, status')
      .eq('user_id', user.id)
      .eq('tenant_id', tenantHeader)
      .single();

    if (tenantAccessError || !userTenant || userTenant.status !== 'active') {
      console.error('Tenant access check failed:', tenantAccessError);
      return new Response(
        JSON.stringify({ error: 'User does not have access to this tenant' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('User tenant access verified:', userTenant.id);

    // Create supabase client with service role key (bypasses RLS for operations)
    // This is safe because we've already verified user authentication and tenant access above
    const supabase = createClient(supabaseUrl, supabaseKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });
    
    // Parse URL to get query parameters
    const url = new URL(req.url);
    
    console.log('Request path:', url.pathname);
    console.log('HTTP method:', req.method);
    console.log('Tenant header:', tenantHeader);
    
    // GET - Fetch tenant profile
    if (req.method === 'GET') {
      try {
        // Query the tenant profile for this tenant
        const { data, error } = await supabase
          .from('t_tenant_profiles')
          .select('*')
          .eq('tenant_id', tenantHeader)
          .single();
          
        if (error) {
          console.error('Error fetching tenant profile:', error);
          
          // If no rows found, it's not an error - just return null
          if (error.code === 'PGRST116') {
            return new Response(
              JSON.stringify(null),
              { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          
          throw error;
        }
        
        // Map database object to expected response format
        const transformedData = data ? {
          id: data.id,
          tenant_id: data.tenant_id,
          business_type_id: data.profile_type, // Using profile_type for business_type_id
          industry_id: data.industry_id,
          business_name: data.business_name,
          logo_url: data.logo_url,
          address_line1: data.address_line1,
          address_line2: data.address_line2,
          city: data.city,
          state_code: data.state_code,
          country_code: data.country_code,
          postal_code: data.postal_code,
          business_phone_country_code: data.business_phone_country_code,
          business_phone: data.business_phone,
          business_email: data.business_email,
          website_url: data.website_url,
          // ✅ ADDED: WhatsApp fields
          business_whatsapp_country_code: data.business_whatsapp_country_code,
          business_whatsapp: data.business_whatsapp,
          primary_color: data.primary_color,
          secondary_color: data.secondary_color,
          created_at: data.created_at,
          updated_at: data.updated_at
        } : null;
        
        return new Response(
          JSON.stringify(transformedData),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (dbError) {
        console.error('Database error when fetching tenant profile:', dbError);
        
        return new Response(
          JSON.stringify({ error: 'Failed to fetch tenant profile', details: dbError.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // POST - Create new tenant profile
    if (req.method === 'POST') {
      try {
        // Parse request body
        const requestData = await req.json();
        
        // Validate required fields
        if (!requestData.business_name) {
          return new Response(
            JSON.stringify({ error: 'business_name is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Map request to database structure
        const dbRecord = {
          tenant_id: tenantHeader,
          profile_type: requestData.business_type_id, // Using business_type_id for profile_type
          industry_id: requestData.industry_id,
          business_name: requestData.business_name,
          business_email: requestData.business_email,
          business_phone_country_code: requestData.business_phone_country_code,
          business_phone: requestData.business_phone,
          // ✅ ADDED: WhatsApp fields
          business_whatsapp_country_code: requestData.business_whatsapp_country_code,
          business_whatsapp: requestData.business_whatsapp,
          country_code: requestData.country_code,
          state_code: requestData.state_code,
          address_line1: requestData.address_line1,
          address_line2: requestData.address_line2,
          city: requestData.city,
          postal_code: requestData.postal_code,
          logo_url: requestData.logo_url,
          primary_color: requestData.primary_color,
          secondary_color: requestData.secondary_color,
          website_url: requestData.website_url
        };
        
        // Check if profile already exists for this tenant
        const { data: existingProfile } = await supabase
          .from('t_tenant_profiles')
          .select('id')
          .eq('tenant_id', tenantHeader)
          .single();
          
        let result;
        
        if (existingProfile) {
          // Update existing profile
          const { data, error } = await supabase
            .from('t_tenant_profiles')
            .update(dbRecord)
            .eq('id', existingProfile.id)
            .select();
            
          if (error) throw error;
          result = data[0];
        } else {
          // Insert new profile
          const { data, error } = await supabase
            .from('t_tenant_profiles')
            .insert([dbRecord])
            .select();
            
          if (error) throw error;
          result = data[0];
        }
        
        // Transform response to match frontend expectations
        const transformedData = {
          id: result.id,
          tenant_id: result.tenant_id,
          business_type_id: result.profile_type,
          industry_id: result.industry_id,
          business_name: result.business_name,
          logo_url: result.logo_url,
          address_line1: result.address_line1,
          address_line2: result.address_line2,
          city: result.city,
          state_code: result.state_code,
          country_code: result.country_code,
          postal_code: result.postal_code,
          business_phone_country_code: result.business_phone_country_code,
          business_phone: result.business_phone,
          business_email: result.business_email,
          website_url: result.website_url,
          // ✅ ADDED: WhatsApp fields
          business_whatsapp_country_code: result.business_whatsapp_country_code,
          business_whatsapp: result.business_whatsapp,
          primary_color: result.primary_color,
          secondary_color: result.secondary_color,
          created_at: result.created_at,
          updated_at: result.updated_at
        };
        
        return new Response(
          JSON.stringify(transformedData),
          { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error creating tenant profile:', error);
        
        return new Response(
          JSON.stringify({ error: 'Failed to create tenant profile', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // PUT - Update tenant profile
    if (req.method === 'PUT') {
      try {
        // Parse request body
        const requestData = await req.json();
        
        // Validate required fields
        if (!requestData.business_name) {
          return new Response(
            JSON.stringify({ error: 'business_name is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Map request to database structure
        const dbRecord = {
          profile_type: requestData.business_type_id,
          industry_id: requestData.industry_id,
          business_name: requestData.business_name,
          business_email: requestData.business_email,
          business_phone_country_code: requestData.business_phone_country_code,
          business_phone: requestData.business_phone,
          // ✅ ADDED: WhatsApp fields
          business_whatsapp_country_code: requestData.business_whatsapp_country_code,
          business_whatsapp: requestData.business_whatsapp,
          country_code: requestData.country_code,
          state_code: requestData.state_code,
          address_line1: requestData.address_line1,
          address_line2: requestData.address_line2,
          city: requestData.city,
          postal_code: requestData.postal_code,
          logo_url: requestData.logo_url,
          primary_color: requestData.primary_color,
          secondary_color: requestData.secondary_color,
          website_url: requestData.website_url
        };
        
        // Check if profile exists for this tenant
        const { data: existingProfile } = await supabase
          .from('t_tenant_profiles')
          .select('id')
          .eq('tenant_id', tenantHeader)
          .single();
          
        if (!existingProfile) {
          return new Response(
            JSON.stringify({ error: 'Tenant profile not found' }),
            { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Update the profile
        const { data, error } = await supabase
          .from('t_tenant_profiles')
          .update(dbRecord)
          .eq('id', existingProfile.id)
          .eq('tenant_id', tenantHeader)
          .select();
          
        if (error) throw error;
        
        if (!data || data.length === 0) {
          return new Response(
            JSON.stringify({ error: 'Failed to update tenant profile' }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Transform response to match frontend expectations
        const result = data[0];
        const transformedData = {
          id: result.id,
          tenant_id: result.tenant_id,
          business_type_id: result.profile_type,
          industry_id: result.industry_id,
          business_name: result.business_name,
          logo_url: result.logo_url,
          address_line1: result.address_line1,
          address_line2: result.address_line2,
          city: result.city,
          state_code: result.state_code,
          country_code: result.country_code,
          postal_code: result.postal_code,
          business_phone_country_code: result.business_phone_country_code,
          business_phone: result.business_phone,
          business_email: result.business_email,
          website_url: result.website_url,
          // ✅ ADDED: WhatsApp fields
          business_whatsapp_country_code: result.business_whatsapp_country_code,
          business_whatsapp: result.business_whatsapp,
          primary_color: result.primary_color,
          secondary_color: result.secondary_color,
          created_at: result.created_at,
          updated_at: result.updated_at
        };
        
        return new Response(
          JSON.stringify(transformedData),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error updating tenant profile:', error);
        
        return new Response(
          JSON.stringify({ error: 'Failed to update tenant profile', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // POST /logo - Upload logo (handled in a special way as it would typically be handled by a storage API)
    // NOTE: This is a mock implementation as the actual file upload would require integration with storage service
    if (req.method === 'POST' && url.pathname.endsWith('/logo')) {
      // In a real implementation, you would:
      // 1. Process the multipart/form-data request to extract the file
      // 2. Upload the file to storage (e.g., Supabase Storage)
      // 3. Return the URL of the uploaded file
      
      try {
        // Mock implementation - generating a fake URL
        const logoId = crypto.randomUUID();
        const mockLogoUrl = `https://storage.example.com/tenant-logos/${tenantHeader}/${logoId}.png`;
        
        return new Response(
          JSON.stringify({ url: mockLogoUrl }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error uploading logo:', error);
        
        return new Response(
          JSON.stringify({ error: 'Failed to upload logo', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // If no matching endpoint is found
    return new Response(
      JSON.stringify({ 
        error: 'Invalid endpoint or method', 
        availableEndpoints: [
          'GET / (Fetch tenant profile)',
          'POST / (Create tenant profile)',
          'PUT / (Update tenant profile)',
          'POST /logo (Upload logo)'
        ],
        requestedMethod: req.method,
        requestedPath: url.pathname
      }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error processing request:', error.message);
    return new Response(
      JSON.stringify({ error: 'Internal server error', details: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});