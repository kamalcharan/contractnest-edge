// /supabase/functions/product-masterdata/index.ts

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
    
    // New parameters for extended functionality
    const page = parseInt(url.searchParams.get('page') || '1');
    const limit = parseInt(url.searchParams.get('limit') || '50');
    const search = url.searchParams.get('search') || '';
    const industryId = url.searchParams.get('industry_id');
    const isPrimary = url.searchParams.get('is_primary') === 'true';

    // Add debug logging
    console.log('🔍 Request parameters:', {
      pathname,
      categoryName,
      isActive,
      tenantId,
      page,
      limit,
      search,
      industryId,
      isPrimary
    });

    // Validate category_name for existing endpoints that require it
    // Note: These endpoints do NOT require category_name:
    // - /industries, /all-categories, /industry-categories
    // - /all-global-categories, /all-tenant-categories
    const isIndustriesEndpoint = pathname.includes('/industries');
    const isAllCategoriesEndpoint = pathname.includes('/all-categories');
    const isIndustryCategoriesEndpoint = pathname.includes('/industry-categories');
    const isAllGlobalCategoriesEndpoint = pathname.includes('/all-global-categories');
    const isAllTenantCategoriesEndpoint = pathname.includes('/all-tenant-categories');
    const requiresCategoryName =
      (pathname.includes('/product-masterdata') || pathname.includes('/tenant-masterdata'))
      && !isIndustriesEndpoint
      && !isAllCategoriesEndpoint
      && !isIndustryCategoriesEndpoint
      && !isAllGlobalCategoriesEndpoint
      && !isAllTenantCategoriesEndpoint;

    if (requiresCategoryName && !categoryName) {
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

    // =================================================================
    // IMPORTANT: Check specific sub-routes BEFORE generic /product-masterdata
    // Otherwise /product-masterdata/industries matches /product-masterdata first!
    // =================================================================

    if (pathname.includes('/industries')) {
      // Get all industries with pagination and search (m_catalog_industries)
      response = await getIndustries(supabase, isActive, page, limit, search);

    } else if (pathname.includes('/all-categories')) {
      // Get all categories across all industries with pagination and search
      response = await getAllCategories(supabase, isActive, page, limit, search);

    } else if (pathname.includes('/industry-categories')) {
      // Get categories filtered by industry with pagination and search
      if (!industryId) {
        return new Response(
          JSON.stringify({
            success: false,
            error: 'industry_id parameter is required for industry-categories'
          }),
          {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' }
          }
        );
      }
      response = await getIndustryCategoriesFiltered(supabase, industryId, isActive, isPrimary, page, limit, search);

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

    } else if (pathname.includes('/product-masterdata')) {
      // Global Product Master Data (uses m_ tables) - MUST come AFTER specific routes
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

    } else {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Invalid endpoint. Use /product-masterdata, /tenant-masterdata, /all-global-categories, /all-tenant-categories, /industries, /all-categories, or /industry-categories' 
        }),
        { 
          status: 404, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Debug final response
    console.log('📤 Final response:', {
      success: response.success,
      dataLength: response.data?.length || 0,
      hasError: !!response.error,
      keys: response.data?.[0] ? Object.keys(response.data[0]) : []
    });

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
        error: 'Internal server error',
        debug: error.message
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
    
    // FIRST: Let's check what tables actually exist
    console.log('🔍 Checking available tables...');
    
    // Method 1: Try to get category info from m_category_master first
    console.log('📋 Attempting to query m_category_master...');
    const { data: categoryMaster, error: categoryError } = await supabase
      .from('m_category_master')
      .select('*')
      .eq('category_name', categoryName)
      .eq('is_active', isActive);

    console.log('📋 m_category_master query result:', {
      data: categoryMaster,
      error: categoryError,
      count: categoryMaster?.length || 0
    });

    // If m_category_master doesn't exist or has no data, try direct approach
    if (categoryError || !categoryMaster || categoryMaster.length === 0) {
      console.log('⚠️ m_category_master failed, trying direct sub-category approach...');
      
      // Let's try querying the sub-category table directly
      // Based on your data sample, it looks like you might be using a different table structure
      const { data: directData, error: directError } = await supabase
        .from('m_category_details') // or whatever your actual table is
        .select('*')
        .limit(10); // Get a sample to understand structure

      console.log('📋 Direct m_category_details sample:', {
        data: directData,
        error: directError,
        count: directData?.length || 0,
        sampleKeys: directData?.[0] ? Object.keys(directData[0]) : []
      });

      // If that fails, let's try other possible table names
      if (directError) {
        console.log('⚠️ m_category_details failed, trying other table names...');
        
        // Try common variations
        const possibleTables = [
          'category_details',
          'subcategories', 
          'category_subcategories',
          'master_data',
          'product_categories'
        ];

        for (const tableName of possibleTables) {
          try {
            const { data: testData, error: testError } = await supabase
              .from(tableName)
              .select('*')
              .limit(1);
            
            if (!testError && testData) {
              console.log(`✅ Found working table: ${tableName}`, {
                sampleKeys: testData[0] ? Object.keys(testData[0]) : [],
                count: testData.length
              });
            }
          } catch (e) {
            console.log(`❌ Table ${tableName} does not exist`);
          }
        }
      }

      return {
        success: false,
        error: `Unable to find data for category '${categoryName}'. Debug info logged.`,
        debug: {
          categoryError: categoryError,
          directError: directError,
          attempted_tables: ['m_category_master', 'm_category_details']
        }
      };
    }

    // If we found the category, get the details
    const categoryId = categoryMaster[0].id;
    console.log(`✅ Found global category:`, categoryMaster[0]);

    // Step 2: Get the category details
    const { data: categoryDetails, error: detailsError } = await supabase
      .from('m_category_details')
      .select('*')
      .eq('category_id', categoryId)
      .eq('is_active', isActive)
      .order('sequence_no');

    console.log('📋 Category details result:', {
      data: categoryDetails,
      error: detailsError,
      count: categoryDetails?.length || 0
    });

    if (detailsError) {
      console.log(`❌ Failed to fetch global details for category '${categoryName}':`, detailsError);
      return {
        success: false,
        error: `Failed to fetch global details for category '${categoryName}'`,
        debug: {
          detailsError: detailsError,
          categoryId: categoryId
        }
      };
    }

    // Transform data to match expected format
    const transformedDetails = categoryDetails?.map(item => ({
      ...item,
      // Map your actual field names to expected field names
      detail_name: item.display_name || item.sub_cat_name || item.detail_name,
      detail_value: item.sub_cat_name || item.detail_value,
      // Ensure all expected fields are present
      display_name: item.display_name,
      is_selectable: true // default value
    })) || [];

    console.log(`✅ Transformed ${transformedDetails.length} global category details`);

    return {
      success: true,
      data: transformedDetails,
      category_info: {
        id: categoryMaster[0].id,
        name: categoryMaster[0].category_name,
        description: categoryMaster[0].description
      },
      total_count: transformedDetails.length
    };

  } catch (error) {
    console.error('❌ Error fetching global product master data:', error);
    return {
      success: false,
      error: 'Failed to fetch global product master data',
      debug: {
        errorMessage: error.message,
        errorStack: error.stack
      }
    };
  }
}

async function getTenantMasterData(supabase: any, categoryName: string, isActive: boolean, tenantId: string) {
  try {
    console.log(`🔍 Fetching tenant master data for category: ${categoryName}, tenant: ${tenantId}`);
    
    // Step 1: Get the tenant category master from t_category_master
    const { data: categoryMaster, error: categoryError } = await supabase
      .from('t_category_master')
      .select('*')
      .eq('category_name', categoryName)
      .eq('is_active', isActive)
      .eq('tenant_id', tenantId);

    console.log('📋 t_category_master query result:', {
      data: categoryMaster,
      error: categoryError,
      count: categoryMaster?.length || 0
    });

    if (categoryError || !categoryMaster || categoryMaster.length === 0) {
      console.log(`❌ Tenant category '${categoryName}' not found for tenant '${tenantId}':`, categoryError);
      return {
        success: false,
        error: `Tenant category '${categoryName}' not found for tenant '${tenantId}'`,
        debug: {
          categoryError: categoryError,
          searchParams: { categoryName, isActive, tenantId }
        }
      };
    }

    const categoryId = categoryMaster[0].id;
    console.log(`✅ Found tenant category:`, categoryMaster[0]);

    // Step 2: Get the tenant category details from t_category_details
    const { data: categoryDetails, error: detailsError } = await supabase
      .from('t_category_details')
      .select('*')
      .eq('category_id', categoryId)
      .eq('is_active', isActive)
      .eq('tenant_id', tenantId)
      .order('sequence_no');

    console.log('📋 Tenant category details result:', {
      data: categoryDetails,
      error: detailsError,
      count: categoryDetails?.length || 0
    });

    if (detailsError) {
      console.log(`❌ Failed to fetch tenant details for category '${categoryName}', tenant '${tenantId}':`, detailsError);
      return {
        success: false,
        error: `Failed to fetch tenant details for category '${categoryName}' for tenant '${tenantId}'`,
        debug: {
          detailsError: detailsError,
          categoryId: categoryId
        }
      };
    }

    // Transform data to match expected format
    const transformedDetails = categoryDetails?.map(item => ({
      ...item,
      detail_name: item.display_name || item.sub_cat_name || item.detail_name,
      detail_value: item.sub_cat_name || item.detail_value,
      display_name: item.display_name,
      is_selectable: true
    })) || [];

    console.log(`✅ Transformed ${transformedDetails.length} tenant category details`);

    return {
      success: true,
      data: transformedDetails,
      category_info: {
        id: categoryMaster[0].id,
        name: categoryMaster[0].category_name,
        description: categoryMaster[0].description
      },
      tenant_id: tenantId,
      total_count: transformedDetails.length
    };

  } catch (error) {
    console.error('❌ Error fetching tenant master data:', error);
    return {
      success: false,
      error: 'Failed to fetch tenant master data',
      debug: {
        errorMessage: error.message,
        errorStack: error.stack
      }
    };
  }
}

// Keep all other functions the same but add debug logging
async function getIndustries(supabase: any, isActive: boolean, page: number, limit: number, search: string) {
  try {
    console.log(`🔍 Fetching industries - Page: ${page}, Limit: ${limit}, Search: "${search}"`);
    
    const offset = (page - 1) * limit;
    
    let query = supabase
      .from('m_catalog_industries')
      .select('*', { count: 'exact' })
      .eq('is_active', isActive)
      .order('sort_order');
    
    if (search && search.length >= 3) {
      query = query.or(`name.ilike.%${search}%,description.ilike.%${search}%`);
    }
    
    query = query.range(offset, offset + limit - 1);
    
    const { data: industries, error, count } = await query;

    console.log('📋 Industries query result:', {
      data: industries,
      error: error,
      count: count
    });

    if (error) {
      console.log('❌ Failed to fetch industries:', error);
      return {
        success: false,
        error: 'Failed to fetch industries',
        data: []
      };
    }

    const totalPages = Math.ceil((count || 0) / limit);
    const hasNext = page < totalPages;
    const hasPrev = page > 1;

    console.log(`✅ Found ${industries?.length || 0} industries (${count} total)`);

    return {
      success: true,
      data: industries || [],
      pagination: {
        current_page: page,
        total_pages: totalPages,
        total_records: count || 0,
        limit: limit,
        has_next: hasNext,
        has_prev: hasPrev
      }
    };

  } catch (error) {
    console.error('❌ Error fetching industries:', error);
    return {
      success: false,
      error: 'Failed to fetch industries',
      data: []
    };
  }
}

async function getAllCategories(supabase: any, isActive: boolean, page: number, limit: number, search: string) {
  try {
    console.log(`🔍 Fetching all categories - Page: ${page}, Limit: ${limit}, Search: "${search}"`);
    
    const offset = (page - 1) * limit;
    
    let query = supabase
      .from('m_catalog_category_industry_map')
      .select('*', { count: 'exact' })
      .eq('is_active', isActive)
      .order('display_order');
    
    if (search && search.length >= 3) {
      query = query.or(`category_id.ilike.%${search}%,display_name.ilike.%${search}%`);
    }
    
    query = query.range(offset, offset + limit - 1);
    
    const { data: categories, error, count } = await query;

    console.log('📋 All categories query result:', {
      data: categories,
      error: error,
      count: count
    });

    if (error) {
      console.log('❌ Failed to fetch all categories:', error);
      return {
        success: false,
        error: 'Failed to fetch categories',
        data: []
      };
    }

    const totalPages = Math.ceil((count || 0) / limit);
    const hasNext = page < totalPages;
    const hasPrev = page > 1;

    console.log(`✅ Found ${categories?.length || 0} categories (${count} total)`);

    return {
      success: true,
      data: categories || [],
      pagination: {
        current_page: page,
        total_pages: totalPages,
        total_records: count || 0,
        limit: limit,
        has_next: hasNext,
        has_prev: hasPrev
      }
    };

  } catch (error) {
    console.error('❌ Error fetching all categories:', error);
    return {
      success: false,
      error: 'Failed to fetch categories',
      data: []
    };
  }
}

async function getIndustryCategoriesFiltered(supabase: any, industryId: string, isActive: boolean, isPrimary: boolean, page: number, limit: number, search: string) {
  try {
    console.log(`🔍 Fetching categories for industry: ${industryId}, Primary: ${isPrimary}, Page: ${page}, Limit: ${limit}, Search: "${search}"`);
    
    const offset = (page - 1) * limit;
    
    let query = supabase
      .from('m_catalog_category_industry_map')
      .select('*', { count: 'exact' })
      .eq('industry_id', industryId)
      .eq('is_active', isActive);
    
    if (isPrimary) {
      query = query.eq('is_primary', true);
    }
    
    if (search && search.length >= 3) {
      query = query.or(`category_id.ilike.%${search}%,display_name.ilike.%${search}%`);
    }
    
    query = query
      .order('is_primary', { ascending: false })
      .order('display_order')
      .range(offset, offset + limit - 1);
    
    const { data: categories, error, count } = await query;

    console.log('📋 Industry categories query result:', {
      data: categories,
      error: error,
      count: count
    });

    if (error) {
      console.log(`❌ Failed to fetch categories for industry ${industryId}:`, error);
      return {
        success: false,
        error: `Failed to fetch categories for industry ${industryId}`,
        data: []
      };
    }

    const totalPages = Math.ceil((count || 0) / limit);
    const hasNext = page < totalPages;
    const hasPrev = page > 1;

    console.log(`✅ Found ${categories?.length || 0} categories for industry ${industryId} (${count} total)`);

    return {
      success: true,
      data: categories || [],
      industry_id: industryId,
      filters: {
        is_primary_only: isPrimary,
        search_applied: search.length >= 3
      },
      pagination: {
        current_page: page,
        total_pages: totalPages,
        total_records: count || 0,
        limit: limit,
        has_next: hasNext,
        has_prev: hasPrev
      }
    };

  } catch (error) {
    console.error(`❌ Error fetching categories for industry ${industryId}:`, error);
    return {
      success: false,
      error: `Failed to fetch categories for industry ${industryId}`,
      data: []
    };
  }
}

async function getAllGlobalCategories(supabase: any, isActive: boolean) {
  try {
    console.log(`🔍 Fetching all global categories`);
    
    const { data: categories, error } = await supabase
      .from('m_category_master')
      .select('*')
      .eq('is_active', isActive)
      .order('sequence_no');

    console.log('📋 All global categories query result:', {
      data: categories,
      error: error,
      count: categories?.length || 0
    });

    if (error) {
      console.log('❌ Failed to fetch all global categories:', error);
      return {
        success: false,
        error: 'Failed to fetch all global categories',
        data: []
      };
    }

    console.log(`✅ Found ${categories?.length || 0} global categories`);

    return {
      success: true,
      data: categories || [],
      total_count: categories?.length || 0
    };

  } catch (error) {
    console.error('❌ Error fetching all global categories:', error);
    return {
      success: false,
      error: 'Failed to fetch all global categories',
      data: []
    };
  }
}

async function getAllTenantCategories(supabase: any, isActive: boolean, tenantId: string) {
  try {
    console.log(`🔍 Fetching all tenant categories for tenant: ${tenantId}`);
    
    const { data: categories, error } = await supabase
      .from('t_category_master')
      .select('*')
      .eq('is_active', isActive)
      .eq('tenant_id', tenantId)
      .order('sequence_no');

    console.log('📋 All tenant categories query result:', {
      data: categories,
      error: error,
      count: categories?.length || 0
    });

    if (error) {
      console.log(`❌ Failed to fetch all tenant categories for tenant ${tenantId}:`, error);
      return {
        success: false,
        error: `Failed to fetch all tenant categories for tenant ${tenantId}`,
        data: []
      };
    }

    console.log(`✅ Found ${categories?.length || 0} tenant categories for tenant ${tenantId}`);

    return {
      success: true,
      data: categories || [],
      tenant_id: tenantId,
      total_count: categories?.length || 0
    };

  } catch (error) {
    console.error(`❌ Error fetching all tenant categories for tenant ${tenantId}:`, error);
    return {
      success: false,
      error: `Failed to fetch all tenant categories for tenant ${tenantId}`,
      data: []
    };
  }
}

console.log('🎯 Product Master Data Edge Function - Ready to serve requests');