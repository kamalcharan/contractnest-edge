// supabase/functions/resources/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-internal-signature',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS'
};

serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const internalSigningSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');
    
    // Get headers
    const authHeader = req.headers.get('Authorization');
    const tenantId = req.headers.get('x-tenant-id');
    const internalSignature = req.headers.get('x-internal-signature');
    
    // Log function invocation for debugging
    console.log(`[Resources] ${req.method} ${req.url}`);
    
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    if (!tenantId) {
      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Verify internal signature for API calls
    if (internalSigningSecret && internalSignature) {
      const requestBody = req.method !== 'GET' ? await req.text() : '';
      const isValidSignature = await verifyInternalSignature(requestBody, internalSignature, internalSigningSecret);
      
      if (!isValidSignature) {
        console.error('Invalid internal signature for resources function');
        return new Response(
          JSON.stringify({ error: 'Invalid internal signature' }),
          { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      // Re-parse body for JSON requests
      if (req.method !== 'GET' && requestBody) {
        try {
          req.json = () => Promise.resolve(JSON.parse(requestBody));
        } catch (e) {
          // If not JSON, leave as is
        }
      }
    }
    
    // Create Supabase client
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: { 
        headers: { 
          Authorization: authHeader,
          'x-tenant-id': tenantId
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
    const resourceSegment = pathSegments[pathSegments.length - 1];
    
    console.log('Request routing:', {
      pathSegments,
      resourceSegment,
      queryParams: Object.fromEntries(url.searchParams.entries())
    });
    
    // Health check endpoint
    if (resourceSegment === 'health') {
      return new Response(
        JSON.stringify({ 
          status: 'ok', 
          message: 'Resources edge function is working',
          timestamp: new Date().toISOString()
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Resource types endpoint
    if (resourceSegment === 'resource-types' && req.method === 'GET') {
      return await handleGetResourceTypes(supabase, tenantId);
    }
    
    // Main resources endpoints
    if (req.method === 'GET') {
      return await handleGetResources(supabase, tenantId, url.searchParams);
    }
    
    if (req.method === 'POST') {
      return await handleCreateResource(supabase, tenantId, req);
    }
    
    if (req.method === 'PATCH') {
      const resourceId = url.searchParams.get('id');
      if (!resourceId) {
        return new Response(
          JSON.stringify({ error: 'Resource ID is required for update' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      return await handleUpdateResource(supabase, tenantId, resourceId, req);
    }
    
    if (req.method === 'DELETE') {
      const resourceId = url.searchParams.get('id');
      if (!resourceId) {
        return new Response(
          JSON.stringify({ error: 'Resource ID is required for delete' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      return await handleDeleteResource(supabase, tenantId, resourceId);
    }
    
    // Invalid endpoint
    return new Response(
      JSON.stringify({ 
        error: 'Invalid endpoint or method',
        availableEndpoints: [
          'GET /resource-types',
          'GET /',
          'POST /',
          'PATCH /?id={id}',
          'DELETE /?id={id}'
        ],
        requestedMethod: req.method,
        requestedPath: url.pathname
      }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error: any) {
    console.error('Resources edge function error:', error);
    
    return new Response(
      JSON.stringify({ 
        error: 'Internal server error',
        message: error.message,
        requestId: crypto.randomUUID()
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

// ==========================================
// HANDLER FUNCTIONS
// ==========================================

async function handleGetResourceTypes(supabase: any, tenantId: string) {
  try {
    const { data, error } = await supabase
      .from('m_catalog_resource_types')
      .select('*')
      .eq('is_active', true)
      .order('sort_order', { ascending: true });
      
    if (error) {
      console.error('Error fetching resource types:', error);
      throw new Error(`Failed to fetch resource types: ${error.message}`);
    }
    
    return new Response(
      JSON.stringify(data),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleGetResourceTypes:', error);
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetResources(supabase: any, tenantId: string, searchParams: URLSearchParams) {
  try {
    const resourceTypeId = searchParams.get('resourceTypeId');
    const nextSequence = searchParams.get('nextSequence') === 'true';
    const resourceId = searchParams.get('resourceId');

    // Handle next sequence request
    if (nextSequence && resourceTypeId) {
      return await handleGetNextSequence(supabase, tenantId, resourceTypeId);
    }

    // Handle single resource request
    if (resourceId) {
      return await handleGetSingleResource(supabase, tenantId, resourceId);
    }

    // Handle list request
    if (resourceTypeId) {
      return await handleGetResourcesByType(supabase, tenantId, resourceTypeId);
    } else {
      return await handleGetAllResources(supabase, tenantId);
    }
    
  } catch (error: any) {
    console.error('Error in handleGetResources:', error);
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetNextSequence(supabase: any, tenantId: string, resourceTypeId: string) {
  try {
    // First check if this resource type requires human assignment
    const { data: resourceType, error: typeError } = await supabase
      .from('m_catalog_resource_types')
      .select('requires_human_assignment')
      .eq('id', resourceTypeId)
      .single();

    if (typeError || !resourceType) {
      return new Response(
        JSON.stringify({ error: 'Invalid resource type' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (resourceType.requires_human_assignment) {
      return new Response(
        JSON.stringify({ error: 'This resource type does not support manual entry - resources come from contacts' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    const { data, error } = await supabase
      .from('t_catalog_resources')
      .select('sequence_no')
      .eq('tenant_id', tenantId)
      .eq('resource_type_id', resourceTypeId)
      .eq('is_live', true)
      .eq('status', 'active')
      .order('sequence_no', { ascending: false, nullsLast: false })
      .limit(1);
      
    if (error) {
      console.error('Error fetching sequence for resource type:', resourceTypeId, error);
      throw new Error(`Failed to fetch sequence: ${error.message}`);
    }
    
    const maxSequence = data && data.length > 0 ? (data[0].sequence_no || 0) : 0;
    const nextSequence = maxSequence + 1;
    
    return new Response(
      JSON.stringify({ nextSequence }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleGetNextSequence:', error);
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetSingleResource(supabase: any, tenantId: string, resourceId: string) {
  try {
    const { data, error } = await supabase
      .from('t_catalog_resources')
      .select('*')
      .eq('id', resourceId)
      .eq('tenant_id', tenantId)
      .eq('is_live', true)
      .single();
      
    if (error) {
      if (error.code === 'PGRST116') {
        return new Response(
          JSON.stringify({ error: 'Resource not found' }),
          { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      throw new Error(`Failed to fetch resource: ${error.message}`);
    }
    
    return new Response(
      JSON.stringify([transformResourceForFrontend(data)]),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleGetSingleResource:', error);
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetResourcesByType(supabase: any, tenantId: string, resourceTypeId: string) {
  try {
    console.log(`📋 Fetching resources for type: ${resourceTypeId}`);

    // First check if this resource type allows manual entry
    const { data: resourceType, error: typeError } = await supabase
      .from('m_catalog_resource_types')
      .select('*')
      .eq('id', resourceTypeId)
      .single();

    if (typeError || !resourceType) {
      return new Response(
        JSON.stringify({ error: 'Invalid resource type' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!resourceType.requires_human_assignment) {
      // Get manual entry resources from t_catalog_resources
      const { data, error } = await supabase
        .from('t_catalog_resources')
        .select('*')
        .eq('tenant_id', tenantId)
        .eq('resource_type_id', resourceTypeId)
        .eq('is_live', true)
        .eq('status', 'active')
        .order('sequence_no', { ascending: true, nullsLast: true });
        
      if (error) {
        console.error('❌ Error fetching manual resources:', error);
        throw new Error(`Failed to fetch resources: ${error.message}`);
      }
      
      console.log(`✅ Found ${data.length} manual entry resources`);
      
      const transformedData = data.map(transformResourceForFrontend);
      
      return new Response(
        JSON.stringify(transformedData),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    } else {
      // Get contact-based resources from contacts API
      return await getContactBasedResources(tenantId, resourceTypeId);
    }
    
  } catch (error: any) {
    console.error('💥 Error in handleGetResourcesByType:', error);
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetAllResources(supabase: any, tenantId: string) {
  try {
    // First get all resource types
    const { data: resourceTypes, error: typesError } = await supabase
      .from('m_catalog_resource_types')
      .select('*')
      .eq('is_active', true);

    if (typesError) {
      throw new Error(`Failed to fetch resource types: ${typesError.message}`);
    }

    const allResources = [];

    // Process each resource type
    for (const resourceType of resourceTypes) {
      if (!resourceType.requires_human_assignment) {
        // Get manual entry resources
        const { data, error } = await supabase
          .from('t_catalog_resources')
          .select('*')
          .eq('tenant_id', tenantId)
          .eq('resource_type_id', resourceType.id)
          .eq('is_live', true)
          .eq('status', 'active')
          .order('sequence_no', { ascending: true, nullsLast: true });
          
        if (!error && data) {
          allResources.push(...data.map(transformResourceForFrontend));
        }
      } else {
        // Get contact-based resources
        try {
          const contactResources = await fetchContactBasedResourcesData(tenantId, resourceType.id);
          allResources.push(...contactResources);
        } catch (error) {
          console.warn(`Failed to fetch contact resources for ${resourceType.id}:`, error);
          // Continue with other types even if contacts fail
        }
      }
    }
    
    return new Response(
      JSON.stringify(allResources),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error: any) {
    console.error('Error in handleGetAllResources:', error);
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleCreateResource(supabase: any, tenantId: string, req: Request) {
  try {
    const requestData = await req.json();

    // First check if this resource type requires human assignment
    const { data: resourceType, error: typeError } = await supabase
      .from('m_catalog_resource_types')
      .select('requires_human_assignment')
      .eq('id', requestData.resource_type_id)
      .single();

    if (typeError || !resourceType) {
      return new Response(
        JSON.stringify({ error: 'Invalid resource type' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (resourceType.requires_human_assignment) {
      return new Response(
        JSON.stringify({ 
          error: 'This resource type does not support manual entry. Resources are populated from contacts.' 
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Validate required fields
    if (!requestData.name || !requestData.display_name) {
      return new Response(
        JSON.stringify({ error: 'Name and display_name are required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check for duplicate names
    const { data: existingResource } = await supabase
      .from('t_catalog_resources')
      .select('id')
      .eq('tenant_id', tenantId)
      .eq('resource_type_id', requestData.resource_type_id)
      .eq('name', requestData.name.trim())
      .eq('is_live', true)
      .eq('status', 'active')
      .single();

    if (existingResource) {
      return new Response(
        JSON.stringify({ 
          error: 'A resource with this name already exists for this type' 
        }),
        { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Auto-generate sequence number if not provided
    if (!requestData.sequence_no) {
      const { data: maxSeqData } = await supabase
        .from('t_catalog_resources')
        .select('sequence_no')
        .eq('tenant_id', tenantId)
        .eq('resource_type_id', requestData.resource_type_id)
        .eq('is_live', true)
        .order('sequence_no', { ascending: false, nullsLast: false })
        .limit(1)
        .single();

      requestData.sequence_no = (maxSeqData?.sequence_no || 0) + 1;
    }

    // Transform field names for database
    const dbRecord = {
      tenant_id: tenantId,
      resource_type_id: requestData.resource_type_id,
      name: requestData.name.trim(),
      display_name: requestData.display_name.trim(),
      description: requestData.description?.trim() || null,
      hexcolor: requestData.hexcolor || null,
      sequence_no: requestData.sequence_no,
      tags: requestData.tags || null,
      form_settings: requestData.form_settings || null,
      is_custom: true,
      status: 'active',
      is_live: true,
      is_deletable: true,
      created_by: null,              
  updated_by: null,              
  created_at: new Date().toISOString(),
  updated_at: new Date().toISOString(),
  attributes: requestData.attributes || null,
  availability_config: requestData.availability_config || null,
  master_template_id: requestData.master_template_id || null,
  code: requestData.code || null,
  contact_id: requestData.contact_id || null
    };

    // Insert new record
    const { data, error } = await supabase
      .from('t_catalog_resources')
      .insert([dbRecord])
      .select()
      .single();
      
    if (error) {
      console.error('Error inserting resource:', error);
      throw new Error(`Failed to create resource: ${error.message}`);
    }
    
    return new Response(
      JSON.stringify(transformResourceForFrontend(data)),
      { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleCreateResource:', error);
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleUpdateResource(supabase: any, tenantId: string, resourceId: string, req: Request) {
  try {
    const requestData = await req.json();

    // Get current resource
    const { data: current, error: fetchError } = await supabase
      .from('t_catalog_resources')
      .select('*')
      .eq('id', resourceId)
      .eq('tenant_id', tenantId)
      .eq('is_live', true)
      .single();
      
    if (fetchError || !current) {
      return new Response(
        JSON.stringify({ error: 'Resource not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check if this resource type requires human assignment
    const { data: resourceType, error: typeError } = await supabase
      .from('m_catalog_resource_types')
      .select('requires_human_assignment')
      .eq('id', current.resource_type_id)
      .single();

    if (typeError || !resourceType || resourceType.requires_human_assignment) {
      return new Response(
        JSON.stringify({ 
          error: 'This resource cannot be updated as it is managed by the contacts system' 
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Build update data
    const updateData: any = {
      updated_at: new Date().toISOString()
    };

    if (requestData.name !== undefined) {
      if (!requestData.name.trim()) {
        return new Response(
          JSON.stringify({ error: 'Name cannot be empty' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      updateData.name = requestData.name.trim();
    }

    if (requestData.display_name !== undefined) {
      if (!requestData.display_name.trim()) {
        return new Response(
          JSON.stringify({ error: 'Display name cannot be empty' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      updateData.display_name = requestData.display_name.trim();
    }

    if (requestData.description !== undefined) {
      updateData.description = requestData.description?.trim() || null;
    }

    if (requestData.hexcolor !== undefined) {
      updateData.hexcolor = requestData.hexcolor || null;
    }

    if (requestData.sequence_no !== undefined) {
      updateData.sequence_no = requestData.sequence_no;
    }

    if (requestData.tags !== undefined) {
      updateData.tags = requestData.tags;
    }

    if (requestData.form_settings !== undefined) {
      updateData.form_settings = requestData.form_settings;
    }

    // Check for duplicate name if name is changing
    if (updateData.name && updateData.name !== current.name) {
      const { data: existingResource } = await supabase
        .from('t_catalog_resources')
        .select('id')
        .eq('tenant_id', tenantId)
        .eq('resource_type_id', current.resource_type_id)
        .eq('name', updateData.name)
        .eq('is_live', true)
        .eq('status', 'active')
        .neq('id', resourceId)
        .single();

      if (existingResource) {
        return new Response(
          JSON.stringify({ 
            error: 'A resource with this name already exists for this type' 
          }),
          { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // Update record
    const { data, error } = await supabase
      .from('t_catalog_resources')
      .update(updateData)
      .eq('id', resourceId)
      .eq('tenant_id', tenantId)
      .select()
      .single();
      
    if (error) {
      console.error('Error updating resource:', error);
      throw new Error(`Failed to update resource: ${error.message}`);
    }
    
    return new Response(
      JSON.stringify(transformResourceForFrontend(data)),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleUpdateResource:', error);
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleDeleteResource(supabase: any, tenantId: string, resourceId: string) {
  try {
    // Get current resource
    const { data: current, error: fetchError } = await supabase
      .from('t_catalog_resources')
      .select('*, resource_type_id')
      .eq('id', resourceId)
      .eq('tenant_id', tenantId)
      .eq('is_live', true)
      .single();
      
    if (fetchError || !current) {
      return new Response(
        JSON.stringify({ error: 'Resource not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (current.status !== 'active') {
      return new Response(
        JSON.stringify({ error: 'Resource is already deleted' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check if this resource type requires human assignment
    const { data: resourceType, error: typeError } = await supabase
      .from('m_catalog_resource_types')
      .select('requires_human_assignment')
      .eq('id', current.resource_type_id)
      .single();

    if (typeError || !resourceType || resourceType.requires_human_assignment) {
      return new Response(
        JSON.stringify({ 
          error: 'This resource cannot be deleted as it is managed by the contacts system' 
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!current.is_deletable) {
      return new Response(
        JSON.stringify({ error: 'This resource cannot be deleted' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Soft delete by setting status to inactive
    const { data, error } = await supabase
      .from('t_catalog_resources')
      .update({ 
        status: 'inactive',
        updated_at: new Date().toISOString()
      })
      .eq('id', resourceId)
      .eq('tenant_id', tenantId)
      .select()
      .single();
      
    if (error) {
      console.error('Error deleting resource:', error);
      throw new Error(`Failed to delete resource: ${error.message}`);
    }
    
    return new Response(
      JSON.stringify({ 
        success: true, 
        message: 'Resource deleted successfully',
        deletedResource: {
          id: data.id,
          name: data.name
        }
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleDeleteResource:', error);
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// ==========================================
// CONTACT-BASED RESOURCES HELPERS
// ==========================================

async function getContactBasedResources(tenantId: string, resourceTypeId: string) {
  try {
    const contactResources = await fetchContactBasedResourcesData(tenantId, resourceTypeId);
    
    return new Response(
      JSON.stringify(contactResources),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error fetching contact-based resources:', error);
    
    // Return empty array for contact-based resources if contacts API fails
    return new Response(
      JSON.stringify([]),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function fetchContactBasedResourcesData(tenantId: string, resourceTypeId: string) {
  // Map resource types to contact classifications
  const contactClassificationMap: Record<string, string> = {
    'team_staff': 'team_member',
    'partner': 'vendor'
  };

  const contactClassification = contactClassificationMap[resourceTypeId];
  if (!contactClassification) {
    console.warn(`No contact classification mapping for resource type: ${resourceTypeId}`);
    return [];
  }

  try {
    // Call contacts edge function directly (edge-to-edge, no internal signature needed)
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const contactsUrl = `${supabaseUrl}/functions/v1/contacts?classifications=${contactClassification}&limit=100`;
    
    const response = await fetch(contactsUrl, {
      method: 'GET',
      headers: {
        'x-tenant-id': tenantId,
        'Authorization': 'Bearer ' + Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
        'Content-Type': 'application/json'
      }
    });

    if (!response.ok) {
      throw new Error(`Contacts API responded with status: ${response.status}`);
    }

    const contactsData = await response.json();

    // Transform contacts to resource format
    const contacts = contactsData.data || [];
    return contacts.map((contact: any, index: number) => ({
      id: contact.id,
      resource_type_id: resourceTypeId,
      name: contact.email || `${contact.first_name}_${contact.last_name}`.toLowerCase(),
      display_name: `${contact.first_name} ${contact.last_name}`.trim(),
      description: contact.job_title || null,
      hexcolor: null, // No color for contact-based resources
      sequence_no: index + 1,
      contact_id: contact.id,
      tags: null,
      form_settings: null,
      is_active: contact.is_active,
      is_deletable: false, // Contact-based resources are not deletable
      created_at: contact.created_at,
      updated_at: contact.updated_at,
      contact: contact
    }));
  } catch (error) {
    console.error(`Failed to fetch contacts for ${resourceTypeId}:`, error);
    return [];
  }
}

// ==========================================
// UTILITY FUNCTIONS
// ==========================================

function transformResourceForFrontend(dbResource: any) {
  return {
    id: dbResource.id,
    resource_type_id: dbResource.resource_type_id,
    name: dbResource.name,
    display_name: dbResource.display_name,
    description: dbResource.description,
    hexcolor: dbResource.hexcolor,
    sequence_no: dbResource.sequence_no,
    contact_id: dbResource.contact_id,
    tags: dbResource.tags,
    form_settings: dbResource.form_settings,
    is_active: dbResource.status === 'active',
    is_deletable: dbResource.is_deletable,
    created_at: dbResource.created_at,
    updated_at: dbResource.updated_at
  };
}

async function verifyInternalSignature(body: string, signature: string, secret: string): Promise<boolean> {
  if (!secret) {
    console.warn('Internal signature verification skipped - no secret configured');
    return true;
  }
  
  try {
    const encoder = new TextEncoder();
    const keyData = encoder.encode(secret);
    const messageData = encoder.encode(body);
    
    const cryptoKey = await crypto.subtle.importKey(
      'raw',
      keyData,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );
    
    const signatureBuffer = await crypto.subtle.sign('HMAC', cryptoKey, messageData);
    const expectedSignature = Array.from(new Uint8Array(signatureBuffer))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');
    
    return signature === expectedSignature;
  } catch (error) {
    console.error('Signature verification error:', error);
    return false;
  }
}