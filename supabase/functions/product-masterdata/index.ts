import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { corsHeaders } from '../_shared/cors.ts';

console.log('🚀 Product Master Data Edge Function - Starting up');

serve(async (req: Request) => {
  console.log('📨 Product Master Data - Incoming request:', {
    method: req.method,
    url: req.url,
    timestamp: new Date().toISOString()
  });

  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  // Only support GET requests
  if (req.method !== 'GET') {
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: 'Only GET method is supported' 
      }),
      { 
        status: 405, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );
  }

  try {
    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    if (!supabaseUrl || !supabaseServiceKey) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Server configuration error' 
        }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);
    const url = new URL(req.url);
    const pathname = url.pathname;

    // Extract parameters
    const categoryName = url.searchParams.get('category_name');
    const isActive = url.searchParams.get('is_active') !== 'false'; // Default true
    const tenantId = req.headers.get('x-tenant-id'); // For tenant-specific data

    if (!categoryName) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'category_name parameter is required' 
        }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    let response;

    if (pathname.includes('/product-masterdata')) {
      // Global Product Master Data (uses m_ tables)
      response = await getProductMasterData(supabase, categoryName, isActive);
      
    } else if (pathname.includes('/tenant-masterdata')) {
      // Tenant Master Data (uses t_ tables)
      if (!tenantId) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: 'x-tenant-id header is required for tenant master data' 
          }),
          { 
            status: 400, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        );
      }
      response = await getTenantMasterData(supabase, categoryName, isActive, tenantId);
      
    } else if (pathname.includes('/all-global-categories')) {
      // Get all data from m_category_master
      response = await getAllGlobalCategories(supabase, isActive);
      
    } else if (pathname.includes('/all-tenant-categories')) {
      // Get all data from t_category_master
      if (!tenantId) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: 'x-tenant-id header is required for tenant categories' 
          }),
          { 
            status: 400, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        );
      }
      response = await getAllTenantCategories(supabase, isActive, tenantId);
      
    } else {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Invalid endpoint. Use /product-masterdata, /tenant-masterdata, /all-global-categories, or /all-tenant-categories' 
        }),
        { 
          status: 404, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    return new Response(
      JSON.stringify(response),
      {
        status: response.success ? 200 : 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error('❌ Product Master Data - Error:', error);
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: 'Internal server error' 
      }),
      { 
        status: 500, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );
  }
});

async function getProductMasterData(supabase: any, categoryName: string, isActive: boolean) {
  try {
    console.log(`🔍 Fetching global product master data for category: ${categoryName}`);
    
    // Step 1: Get the category master from m_category_master
    const { data: categoryMaster, error: categoryError } = await supabase
      .from('m_category_master')
      .select('id, category_name, description')
      .eq('category_name', categoryName)
      .eq('is_active', isActive)
      .order('sequence_no')
      .single();

    if (categoryError || !categoryMaster) {
      console.log(`❌ Global category '${categoryName}' not found:`, categoryError);
      return {
        success: false,
        error: `Global category '${categoryName}' not found`,
        data: []
      };
    }

    console.log(`✅ Found global category:`, categoryMaster);

    // Step 2: Get the category details from m_category_details
    const { data: categoryDetails, error: detailsError } = await supabase
      .from('m_category_details')
      .select('*')
      .eq('category_id', categoryMaster.id)
      .eq('is_active', isActive)
      .order('sequence_no');

    if (detailsError) {
      console.log(`❌ Failed to fetch global details for category '${categoryName}':`, detailsError);
      return {
        success: false,
        error: `Failed to fetch global details for category '${categoryName}'`,
        data: []
      };
    }

    console.log(`✅ Found ${categoryDetails?.length || 0} global category details`);

    return {
      success: true,
      data: categoryDetails || [],
      category_info: {
        id: categoryMaster.id,
        name: categoryMaster.category_name,
        description: categoryMaster.description
      }
    };

  } catch (error) {
    console.error('❌ Error fetching global product master data:', error);
    return {
      success: false,
      error: 'Failed to fetch global product master data',
      data: []
    };
  }
}

async function getTenantMasterData(supabase: any, categoryName: string, isActive: boolean, tenantId: string) {
  try {
    console.log(`🔍 Fetching tenant master data for category: ${categoryName}, tenant: ${tenantId}`);
    
    // Step 1: Get the tenant category master from t_category_master
    const { data: categoryMaster, error: categoryError } = await supabase
      .from('t_category_master')
      .select('id, category_name, description')
      .eq('category_name', categoryName)
      .eq('is_active', isActive)
      .eq('tenant_id', tenantId)
      .order('sequence_no')
      .single();

    if (categoryError || !categoryMaster) {
      console.log(`❌ Tenant category '${categoryName}' not found for tenant '${tenantId}':`, categoryError);
      return {
        success: false,
        error: `Tenant category '${categoryName}' not found for tenant '${tenantId}'`,
        data: []
      };
    }

    console.log(`✅ Found tenant category:`, categoryMaster);

    // Step 2: Get the tenant category details from t_category_details
    const { data: categoryDetails, error: detailsError } = await supabase
      .from('t_category_details')
      .select('*')
      .eq('category_id', categoryMaster.id)
      .eq('is_active', isActive)
      .eq('tenant_id', tenantId)
      .order('sequence_no');

    if (detailsError) {
      console.log(`❌ Failed to fetch tenant details for category '${categoryName}', tenant '${tenantId}':`, detailsError);
      return {
        success: false,
        error: `Failed to fetch tenant details for category '${categoryName}' for tenant '${tenantId}'`,
        data: []
      };
    }

    console.log(`✅ Found ${categoryDetails?.length || 0} tenant category details`);

    return {
      success: true,
      data: categoryDetails || [],
      category_info: {
        id: categoryMaster.id,
        name: categoryMaster.category_name,
        description: categoryMaster.description
      },
      tenant_id: tenantId
    };

  } catch (error) {
    console.error('❌ Error fetching tenant master data:', error);
    return {
      success: false,
      error: 'Failed to fetch tenant master data',
      data: []
    };
  }
}

console.log('🎯 Product Master Data Edge Function - Ready to serve requests');