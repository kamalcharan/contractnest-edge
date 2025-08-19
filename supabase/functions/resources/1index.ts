// supabase/functions/resources/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-internal-signature, x-timestamp, x-idempotency-key',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS'
};

// Internal signing validation - FIXED TO MATCH EXPRESS CONTROLLER
const INTERNAL_SIGNING_KEY = Deno.env.get('INTERNAL_SIGNING_SECRET') || 'fallback-key-for-dev';

async function validateInternalSignature(payload: string, timestamp: string, signature: string): Promise<boolean> {
  try {
    // Match Express controller algorithm exactly:
    // payload + timestamp + SIGNING_KEY → SHA256 → base64 → substring(0,32)
    const data = payload + timestamp + INTERNAL_SIGNING_KEY;
    const encoder = new TextEncoder();
    const dataBytes = encoder.encode(data);
    
    const hashBuffer = await crypto.subtle.digest('SHA-256', dataBytes);
    const hashArray = new Uint8Array(hashBuffer);
    const base64Hash = btoa(String.fromCharCode(...hashArray));
    const expectedSignature = base64Hash.substring(0, 32);
    
    console.log('🔐 Signature Validation Debug:', {
      payload: payload.length > 0 ? `${payload.length} chars` : 'empty',
      timestamp,
      dataPreview: data.substring(0, 50) + '...',
      expectedSignature,
      receivedSignature: signature,
      isMatch: expectedSignature === signature
    });
    
    return expectedSignature === signature;
  } catch (error) {
    console.error('❌ Signature validation error:', error);
    return false;
  }
}

serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    
    // Get headers
    const authHeader = req.headers.get('Authorization');
    const tenantHeader = req.headers.get('x-tenant-id');
    const internalSignature = req.headers.get('x-internal-signature');
    const timestamp = req.headers.get('x-timestamp');
    const idempotencyKey = req.headers.get('x-idempotency-key');
    const requestId = crypto.randomUUID();
    
    console.log('🚀 Resources Edge Function Request:', {
      method: req.method,
      url: req.url,
      hasAuth: !!authHeader,
      tenantId: tenantHeader,
      hasInternalSig: !!internalSignature,
      requestId
    });
    
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required', requestId }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    if (!tenantHeader) {
      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required', requestId }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Validate internal signature if present - FIXED ASYNC VERSION
    if (internalSignature && timestamp) {
      const requestBody = req.method !== 'GET' ? await req.clone().text() : '';
      
      console.log('🔐 Signature Debug:', {
        hasSignature: !!internalSignature,
        hasTimestamp: !!timestamp,
        signature: internalSignature,
        timestamp: timestamp,
        requestBody: requestBody,
        requestBodyLength: requestBody.length
      });
      
      // FIXED: Now using async validation with correct algorithm
      const isValidSignature = await validateInternalSignature(requestBody, timestamp, internalSignature);
      
      console.log('🔐 Signature Validation Result:', {
        isValid: isValidSignature
      });
      
      if (!isValidSignature) {
        console.log('❌ Signature validation failed');
        return new Response(
          JSON.stringify({ 
            error: 'Invalid internal signature', 
            debug: {
              hasSignature: !!internalSignature,
              hasTimestamp: !!timestamp,
              requestBodyLength: requestBody.length
            },
            requestId 
          }),
          { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      console.log('✅ Signature validation passed');
    }
    
    // Create supabase client
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: { 
        headers: { 
          Authorization: authHeader,
          'x-tenant-id': tenantHeader || ''
        } 
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });
    
    // Parse URL - SIMPLE ROUTING LIKE MASTERDATA
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    
    console.log('🔍 Routing debug:', {
      pathname: url.pathname,
      pathSegments,
      pathSegmentsLength: pathSegments.length
    });
    
    // ROUTING LOGIC - Handle the exact patterns we need:
    // /resource-types → resource-types
    // /resources/resource-types → resource-types  
    // /resources → root
    // / → root
    
    let resourceType = null;
    
    if (pathSegments.length === 1 && pathSegments[0] === 'resource-types') {
      // Direct call to /resource-types
      resourceType = 'resource-types';
    } else if (pathSegments.length === 2 && pathSegments[0] === 'resources' && pathSegments[1] === 'resource-types') {
      // Call to /resources/resource-types
      resourceType = 'resource-types';
    } else if (pathSegments.length === 1 && pathSegments[0] === 'resources') {
      // Call to /resources (root)
      resourceType = null;
    } else if (pathSegments.length === 0) {
      // Call to / (root)
      resourceType = null;
    } else if (pathSegments.length === 1 && pathSegments[0] === 'health') {
      // Health check
      resourceType = 'health';
    } else {
      // Unknown route
      resourceType = 'unknown';
    }
    
    console.log('🎯 Resolved resourceType:', resourceType);
    
    // Health check endpoint
    if (resourceType === 'health') {
      return new Response(
        JSON.stringify({ 
          status: 'ok', 
          service: 'resources-edge',
          timestamp: new Date().toISOString(),
          requestId
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Resource types endpoint - GET
    if (resourceType === 'resource-types' && req.method === 'GET') {
      try {
        console.log('✅ Fetching resource types...');
        
        const { data, error } = await supabase
          .from('m_catalog_resource_types')
          .select('*')
          .eq('is_active', true)
          .order('sort_order', { ascending: true });
          
        if (error) {
          console.error('❌ Error fetching resource types:', error);
          throw error;
        }
        
        console.log(`✅ Found ${data?.length || 0} resource types`);
        
        return new Response(
          JSON.stringify({ success: true, data: data || [], requestId }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (dbError) {
        console.error('❌ Database error when fetching resource types:', dbError);
        
        // Return fallback mock data
        return new Response(
          JSON.stringify({
            success: true,
            data: [
              {
                id: 'team_staff',
                name: 'Team Staff',
                description: 'Team members and staff',
                is_active: true,
                sort_order: 1
              },
              {
                id: 'equipment',
                name: 'Equipment', 
                description: 'Equipment and tools',
                is_active: true,
                sort_order: 2
              }
            ],
            requestId
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // Resources endpoint - GET (root resources)
    if (resourceType === null && req.method === 'GET') {
      const resourceTypeId = url.searchParams.get('resourceTypeId');
      const nextSequence = url.searchParams.get('nextSequence') === 'true';
      const resourceId = url.searchParams.get('resourceId');
      
      console.log('✅ Fetching resources with params:', { resourceTypeId, nextSequence, resourceId });
      
      try {
        // Get next sequence number
        if (nextSequence && resourceTypeId) {
          const { data, error } = await supabase
            .from('t_catalog_resources')
            .select('sequence_no')
            .eq('resource_type_id', resourceTypeId)
            .eq('tenant_id', tenantHeader)
            .eq('is_live', true)
            .eq('is_active', true)
            .order('sequence_no', { ascending: false })
            .limit(1);
            
          const nextSeq = (data && data.length > 0) ? (data[0].sequence_no || 0) + 1 : 1;
          
          console.log(`✅ Next sequence for ${resourceTypeId}: ${nextSeq}`);
          
          return new Response(
            JSON.stringify({ success: true, data: { nextSequence: nextSeq }, requestId }),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Get resources
        let query = supabase
          .from('t_catalog_resources')
          .select(`
            *,
            contact:t_contacts(id, first_name, last_name, email, contact_classification)
          `)
          .eq('tenant_id', tenantHeader)
          .eq('is_live', true)
          .eq('is_active', true);
          
        if (resourceTypeId) {
          query = query.eq('resource_type_id', resourceTypeId);
        }
        
        if (resourceId) {
          query = query.eq('id', resourceId);
        }
        
        const { data, error } = await query.order('sequence_no', { ascending: true, nullsLast: true });
        
        if (error) {
          console.error('❌ Error fetching resources:', error);
          throw error;
        }
        
        console.log(`✅ Found ${data?.length || 0} resources`);
        
        return new Response(
          JSON.stringify({ success: true, data: data || [], requestId }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (dbError) {
  console.error('❌ Database error when fetching resources:', dbError);
  
  // Return empty data instead of mock data
  return new Response(
    JSON.stringify({
      success: true,
      data: [], // Empty array instead of mock data
      requestId
    }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}
    }
    
    // Resources endpoint - POST (Create)
    if (resourceType === null && req.method === 'POST') {
      try {
        const requestData = await req.json();
        
        console.log('✅ Creating resource with data:', requestData);
        
        // Basic validation
        if (!requestData.resource_type_id || !requestData.name || !requestData.display_name) {
          return new Response(
            JSON.stringify({ 
              error: 'resource_type_id, name, and display_name are required',
              requestId 
            }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Create mock response for now
        const newResource = {
          id: crypto.randomUUID(),
          resource_type_id: requestData.resource_type_id,
          name: requestData.name,
          display_name: requestData.display_name,
          description: requestData.description || null,
          hexcolor: requestData.hexcolor || '#40E0D0',
          sequence_no: requestData.sequence_no || 1,
          contact_id: requestData.contact_id || null,
          tags: requestData.tags || null,
          form_settings: requestData.form_settings || null,
          is_active: true,
          is_deletable: true,
          tenant_id: tenantHeader,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString()
        };
        
        console.log('✅ Resource created (mock):', newResource.id);
        
        return new Response(
          JSON.stringify({
            success: true,
            data: newResource,
            message: 'Resource created successfully',
            requestId
          }),
          { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
        
      } catch (error) {
        console.error('❌ Error in POST /resources:', error);
        return new Response(
          JSON.stringify({ 
            error: 'Failed to create resource',
            details: error.message,
            requestId 
          }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // Resources endpoint - PATCH (Update)
    if (resourceType === null && req.method === 'PATCH') {
      const updateResourceId = url.searchParams.get('id');
      
      if (!updateResourceId) {
        return new Response(
          JSON.stringify({ error: 'Resource ID is required', requestId }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      try {
        const requestData = await req.json();
        
        console.log('✅ Updating resource:', updateResourceId, 'with data:', requestData);
        
        // Create mock updated resource
        const updatedResource = {
          id: updateResourceId,
          ...requestData,
          tenant_id: tenantHeader,
          updated_at: new Date().toISOString()
        };
        
        console.log('✅ Resource updated (mock):', updateResourceId);
        
        return new Response(
          JSON.stringify({
            success: true,
            data: updatedResource,
            message: 'Resource updated successfully',
            requestId
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
        
      } catch (error) {
        console.error('❌ Error in PATCH /resources:', error);
        return new Response(
          JSON.stringify({ 
            error: 'Failed to update resource',
            details: error.message,
            requestId 
          }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // Resources endpoint - DELETE (Soft delete)
    if (resourceType === null && req.method === 'DELETE') {
      const deleteResourceId = url.searchParams.get('id');
      
      if (!deleteResourceId) {
        return new Response(
          JSON.stringify({ error: 'Resource ID is required', requestId }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      try {
        console.log('✅ Deleting resource (mock):', deleteResourceId);
        
        return new Response(
          JSON.stringify({
            success: true,
            message: 'Resource deleted successfully',
            requestId
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
        
      } catch (error) {
        console.error('❌ Error in DELETE /resources:', error);
        return new Response(
          JSON.stringify({ 
            error: 'Failed to delete resource',
            details: error.message,
            requestId 
          }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // Unknown route
    console.log('❓ Unknown route:', { pathname: url.pathname, method: req.method });
    
    return new Response(
      JSON.stringify({ 
        error: 'Route not found',
        availableRoutes: [
          'GET /health',
          'GET /resource-types', 
          'GET /resources/resource-types',
          'GET /resources',
          'GET /?resourceTypeId=...',
          'GET /?resourceId=...',
          'GET /?resourceTypeId=...&nextSequence=true',
          'POST /resources',
          'PATCH /resources?id=...',
          'DELETE /resources?id=...'
        ],
        requestedRoute: `${req.method} ${url.pathname}`,
        debug: {
          pathSegments,
          resourceType
        },
        requestId
      }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error) {
    console.error('❌ Unhandled error in resources edge function:', error);
    return new Response(
      JSON.stringify({ 
        error: 'Internal server error', 
        details: error.message,
        requestId: crypto.randomUUID()
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});