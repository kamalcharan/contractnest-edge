// supabase/functions/resources/index.ts
// Production-Ready Resources Edge Function with Complete Business Rules
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-internal-signature, x-timestamp, x-idempotency-key',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS'
};

// Internal signing validation
const INTERNAL_SIGNING_KEY = Deno.env.get('INTERNAL_SIGNING_SECRET') || 'fallback-key-for-dev';

async function validateInternalSignature(payload: string, timestamp: string, signature: string): Promise<boolean> {
  try {
    const data = payload + timestamp + INTERNAL_SIGNING_KEY;
    const encoder = new TextEncoder();
    const dataBytes = encoder.encode(data);
    
    const hashBuffer = await crypto.subtle.digest('SHA-256', dataBytes);
    const hashArray = new Uint8Array(hashBuffer);
    const base64Hash = btoa(String.fromCharCode(...hashArray));
    const expectedSignature = base64Hash.substring(0, 32);
    
    console.log('🔐 Signature Validation:', {
      expected: expectedSignature,
      received: signature,
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
    const requestId = crypto.randomUUID();
    
    // Get headers
    const authHeader = req.headers.get('Authorization');
    const tenantHeader = req.headers.get('x-tenant-id');
    const internalSignature = req.headers.get('x-internal-signature');
    const timestamp = req.headers.get('x-timestamp');
    const idempotencyKey = req.headers.get('x-idempotency-key');
    
    console.log('🚀 Resources Edge Function Request:', {
      method: req.method,
      url: req.url,
      hasAuth: !!authHeader,
      tenantId: tenantHeader,
      hasInternalSig: !!internalSignature,
      requestId
    });
    
    // Validate required headers
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
    
    // Validate internal signature if present
    if (internalSignature && timestamp) {
      const requestBody = req.method !== 'GET' ? await req.clone().text() : '';
      const isValidSignature = await validateInternalSignature(requestBody, timestamp, internalSignature);
      
      if (!isValidSignature) {
        console.log('❌ Signature validation failed');
        return new Response(
          JSON.stringify({ error: 'Invalid internal signature', requestId }),
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
    
    // Parse URL to get path segments and query parameters
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const resourceType = pathSegments.length > 1 ? pathSegments[1] : null;
    
    console.log('🔍 Request Analysis:', {
      pathname: url.pathname,
      pathSegments,
      resourceType,
      method: req.method,
      queryParams: Object.fromEntries(url.searchParams.entries())
    });
    
    // =================================================================
    // HEALTH CHECK ENDPOINT
    // =================================================================
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
    
    // =================================================================
    // RESOURCE TYPES ENDPOINT - GET
    // =================================================================
    if (resourceType === 'resource-types' && req.method === 'GET') {
      try {
        console.log('✅ Fetching resource types...');
        
        const { data, error } = await supabase
          .from('m_catalog_resource_types')
          .select('*')
          .eq('is_active', true)
          .order('sort_order', { ascending: true, nullsLast: true });
          
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
        
        // Return empty data instead of mock data
        return new Response(
          JSON.stringify({
            success: true,
            data: [],
            requestId
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // =================================================================
    // RESOURCES ENDPOINT - GET
    // =================================================================
    if ((resourceType === null || resourceType === 'resources') && req.method === 'GET') {
      const resourceTypeId = url.searchParams.get('resourceTypeId');
      const nextSequence = url.searchParams.get('nextSequence') === 'true';
      const resourceId = url.searchParams.get('resourceId');
      
      console.log('✅ Processing GET resources request:', { 
        resourceTypeId, 
        nextSequence, 
        resourceId,
        tenantId: tenantHeader 
      });
      
      try {
        // Handle next sequence number request
        if (nextSequence && resourceTypeId) {
          console.log(`🔢 Fetching next sequence for resource type: ${resourceTypeId}`);
          
          const { data, error } = await supabase
            .from('t_catalog_resources')
            .select('sequence_no')
            .eq('resource_type_id', resourceTypeId)
            .eq('tenant_id', tenantHeader)
            .eq('is_live', true)
            .eq('status', 'active');
            
          if (error) {
            console.error('❌ Error fetching sequence numbers:', error);
            // Return default sequence on error
            return new Response(
              JSON.stringify({ success: true, data: { nextSequence: 1 }, requestId }),
              { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          
          const maxSequence = data && data.length > 0 
            ? Math.max(...data.map(d => d.sequence_no || 0), 0)
            : 0;
          const nextSeq = maxSequence + 1;
          
          console.log(`✅ Next sequence for ${resourceTypeId}: ${nextSeq}`);
          
          return new Response(
            JSON.stringify({ success: true, data: { nextSequence: nextSeq }, requestId }),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Handle regular resources query
        console.log('📋 Fetching resources...');
        
        let query = supabase
          .from('t_catalog_resources')
          .select(`
            id,
            tenant_id,
            is_live,
            resource_type_id,
            name,
            display_name,
            description,
            hexcolor,
            sequence_no,
            contact_id,
            tags,
            form_settings,
            is_deletable,
            status,
            created_at,
            updated_at,
            created_by,
            updated_by,
            contact:t_contacts(id, first_name, last_name, email, contact_classification)
          `)
          .eq('tenant_id', tenantHeader)
          .eq('is_live', true)
          .eq('status', 'active');
          
        // Apply filters
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
        
        // Transform data to match frontend expectations
        const transformedData = (data || []).map(item => ({
          id: item.id,
          resource_type_id: item.resource_type_id,
          name: item.name,
          display_name: item.display_name || item.name, // Fallback to name if display_name is null
          description: item.description,
          hexcolor: item.hexcolor,
          sequence_no: item.sequence_no,
          contact_id: item.contact_id,
          tags: item.tags,
          form_settings: item.form_settings,
          is_active: item.status === 'active',
          is_deletable: item.is_deletable !== false, // Default to true if null
          created_at: item.created_at,
          updated_at: item.updated_at,
          contact: item.contact
        }));
        
        return new Response(
          JSON.stringify({ success: true, data: transformedData, requestId }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (dbError) {
        console.error('❌ Database error when fetching resources:', dbError);
        
        // Return empty data instead of mock data
        return new Response(
          JSON.stringify({
            success: true,
            data: [],
            requestId
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // =================================================================
    // RESOURCES ENDPOINT - POST (Create)
    // =================================================================
    if ((resourceType === null || resourceType === 'resources') && req.method === 'POST') {
      try {
        const requestData = await req.json();
        
        console.log('✅ Creating resource with data:', requestData);
        
        // Validate required fields
        if (!requestData.resource_type_id || !requestData.name || !requestData.display_name) {
          return new Response(
            JSON.stringify({ 
              error: 'resource_type_id, name, and display_name are required',
              requestId 
            }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Transform frontend data to database format
        const dbRecord = {
          tenant_id: tenantHeader,
          is_live: true,
          resource_type_id: requestData.resource_type_id,
          name: requestData.name,
          display_name: requestData.display_name,
          description: requestData.description || null,
          hexcolor: requestData.hexcolor || '#40E0D0',
          sequence_no: requestData.sequence_no || 1,
          contact_id: requestData.contact_id || null,
          tags: requestData.tags || null,
          form_settings: requestData.form_settings || null,
          is_deletable: requestData.is_deletable !== false, // Default to true
          status: requestData.is_active !== false ? 'active' : 'inactive' // Default to active
        };
        
        console.log('📤 Inserting record into database:', dbRecord);
        
        // Insert into database
        const { data, error } = await supabase
          .from('t_catalog_resources')
          .insert([dbRecord])
          .select(`
            id,
            tenant_id,
            is_live,
            resource_type_id,
            name,
            display_name,
            description,
            hexcolor,
            sequence_no,
            contact_id,
            tags,
            form_settings,
            is_deletable,
            status,
            created_at,
            updated_at,
            created_by,
            updated_by,
            contact:t_contacts(id, first_name, last_name, email, contact_classification)
          `)
          .single();
          
        if (error) {
          console.error('❌ Error inserting resource:', error);
          throw error;
        }
        
        if (!data) {
          throw new Error('Failed to create resource - no data returned');
        }
        
        console.log('✅ Resource created successfully:', data.id);
        
        // Transform response to match frontend expectations
        const transformedData = {
          id: data.id,
          resource_type_id: data.resource_type_id,
          name: data.name,
          display_name: data.display_name || data.name,
          description: data.description,
          hexcolor: data.hexcolor,
          sequence_no: data.sequence_no,
          contact_id: data.contact_id,
          tags: data.tags,
          form_settings: data.form_settings,
          is_active: data.status === 'active',
          is_deletable: data.is_deletable !== false,
          created_at: data.created_at,
          updated_at: data.updated_at,
          contact: data.contact
        };
        
        return new Response(
          JSON.stringify({
            success: true,
            data: transformedData,
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
    
    // =================================================================
    // RESOURCES ENDPOINT - PATCH (Update)
    // =================================================================
    if ((resourceType === null || resourceType === 'resources') && req.method === 'PATCH') {
      try {
        const updateResourceId = url.searchParams.get('id');
        
        if (!updateResourceId) {
          return new Response(
            JSON.stringify({ error: 'Resource ID is required', requestId }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        const requestData = await req.json();
        
        console.log('✅ Updating resource:', updateResourceId, 'with data:', requestData);
        
        // Transform frontend data to database format (selective updates)
        const updates: Record<string, any> = {};
        
        if (requestData.name !== undefined) updates.name = requestData.name;
        if (requestData.display_name !== undefined) updates.display_name = requestData.display_name;
        if (requestData.description !== undefined) updates.description = requestData.description;
        if (requestData.hexcolor !== undefined) updates.hexcolor = requestData.hexcolor;
        if (requestData.sequence_no !== undefined) updates.sequence_no = requestData.sequence_no;
        if (requestData.contact_id !== undefined) updates.contact_id = requestData.contact_id;
        if (requestData.tags !== undefined) updates.tags = requestData.tags;
        if (requestData.form_settings !== undefined) updates.form_settings = requestData.form_settings;
        if (requestData.is_deletable !== undefined) updates.is_deletable = requestData.is_deletable;
        if (requestData.is_active !== undefined) updates.status = requestData.is_active ? 'active' : 'inactive';
        
        console.log('📤 Updating database with:', updates);
        
        // Update in database
        const { data, error } = await supabase
          .from('t_catalog_resources')
          .update(updates)
          .eq('id', updateResourceId)
          .eq('tenant_id', tenantHeader)
          .select(`
            id,
            tenant_id,
            is_live,
            resource_type_id,
            name,
            display_name,
            description,
            hexcolor,
            sequence_no,
            contact_id,
            tags,
            form_settings,
            is_deletable,
            status,
            created_at,
            updated_at,
            created_by,
            updated_by,
            contact:t_contacts(id, first_name, last_name, email, contact_classification)
          `)
          .single();
          
        if (error) {
          console.error('❌ Error updating resource:', error);
          throw error;
        }
        
        if (!data) {
          return new Response(
            JSON.stringify({ error: 'Resource not found or update failed', requestId }),
            { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        console.log('✅ Resource updated successfully:', updateResourceId);
        
        // Transform response to match frontend expectations
        const transformedData = {
          id: data.id,
          resource_type_id: data.resource_type_id,
          name: data.name,
          display_name: data.display_name || data.name,
          description: data.description,
          hexcolor: data.hexcolor,
          sequence_no: data.sequence_no,
          contact_id: data.contact_id,
          tags: data.tags,
          form_settings: data.form_settings,
          is_active: data.status === 'active',
          is_deletable: data.is_deletable !== false,
          created_at: data.created_at,
          updated_at: data.updated_at,
          contact: data.contact
        };
        
        return new Response(
          JSON.stringify({
            success: true,
            data: transformedData,
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
    
    // =================================================================
    // RESOURCES ENDPOINT - DELETE (Soft Delete)
    // =================================================================
    if ((resourceType === null || resourceType === 'resources') && req.method === 'DELETE') {
      try {
        const deleteResourceId = url.searchParams.get('id');
        
        if (!deleteResourceId) {
          return new Response(
            JSON.stringify({ error: 'Resource ID is required', requestId }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        console.log('✅ Soft deleting resource:', deleteResourceId);
        
        // Soft delete by setting status to inactive
        const { error } = await supabase
          .from('t_catalog_resources')
          .update({ status: 'inactive' })
          .eq('id', deleteResourceId)
          .eq('tenant_id', tenantHeader);
          
        if (error) {
          console.error('❌ Error soft deleting resource:', error);
          throw error;
        }
        
        console.log('✅ Resource soft deleted successfully:', deleteResourceId);
        
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
    
    // =================================================================
    // TEST DATABASE CONNECTION
    // =================================================================
    if (resourceType === 'test-db') {
      try {
        const { data, error } = await supabase
          .from('t_catalog_resources')
          .select('count(*)')
          .limit(1);
          
        if (error) {
          console.error('Database query error:', error);
          return new Response(
            JSON.stringify({ error: error.message, details: error, requestId }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        return new Response(
          JSON.stringify({ 
            status: 'success', 
            message: 'Database connection successful',
            data,
            requestId
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (dbError) {
        console.error('Database connection error:', dbError);
        return new Response(
          JSON.stringify({ 
            error: 'Database connection failed', 
            details: dbError.message,
            requestId 
          }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // =================================================================
    // 404 HANDLER - Route not found
    // =================================================================
    console.log('❓ Unknown route:', { pathname: url.pathname, method: req.method });
    
    return new Response(
      JSON.stringify({ 
        error: 'Route not found',
        availableRoutes: [
          'GET /health - Health check',
          'GET /resource-types - Get all resource types', 
          'GET /resources - Get resources (supports ?resourceTypeId, ?resourceId, ?nextSequence=true)',
          'POST /resources - Create new resource',
          'PATCH /resources?id=... - Update existing resource',
          'DELETE /resources?id=... - Soft delete resource',
          'GET /test-db - Test database connection'
        ],
        requestedRoute: `${req.method} ${url.pathname}`,
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