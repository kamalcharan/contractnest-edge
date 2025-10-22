// supabase/functions/service-catalog/index.ts
// Service Catalog Edge Function - PRODUCTION READY
// ✅ ALL FIXES: Boolean status + Direct toggle + pricing_records + resource_requirements

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import { corsHeaders } from '../_shared/common/cors.ts';
import { formatCurrency, getCurrencyByCode, getAllCurrencies } from '../_shared/common/currencyUtils.ts';
import { ServiceCatalogValidator } from './serviceCatalogValidation.ts';
import { ServiceCatalogDatabase } from './serviceCatalogDatabase.ts';

console.log('Service Catalog Edge Function - Starting up with signature security');

serve(async (req: Request) => {
  const startTime = Date.now();
  const operationId = `op_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
  
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');
    
    if (!supabaseUrl || !supabaseServiceKey) {
      return createErrorResponse('Missing required environment variables', 'CONFIGURATION_ERROR', 500, operationId);
    }
    
    // Extract headers
    const authHeader = req.headers.get('Authorization');
    const tenantIdHeader = req.headers.get('x-tenant-id');
    const internalSignature = req.headers.get('x-internal-signature');
    const timestamp = req.headers.get('x-timestamp');
    
    // Security validation
    if (!authHeader) {
      return createErrorResponse('Authorization header is required', 'MISSING_AUTH', 401, operationId);
    }
    
    if (!tenantIdHeader) {
      return createErrorResponse('x-tenant-id header is required', 'MISSING_TENANT', 400, operationId);
    }

    if (!ServiceCatalogValidator.isValidUUID(tenantIdHeader)) {
      return createErrorResponse('Invalid tenant ID format', 'INVALID_TENANT_ID', 400, operationId);
    }

    if (!internalSignature || !timestamp) {
      return new Response(
        JSON.stringify({
          success: false,
          error: {
            code: 'FORBIDDEN',
            message: 'Direct access to edge functions is not allowed.'
          },
          metadata: {
            request_id: operationId,
            timestamp: new Date().toISOString()
          }
        }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Read request body for signature verification
    const requestBody = req.method !== 'GET' ? await req.text() : '';
    
    // Verify signature
    const isValidSignature = await verifyInternalSignature(
      requestBody,
      internalSignature,
      timestamp,
      internalSecret || ''
    );
    
    if (!isValidSignature) {
      return new Response(
        JSON.stringify({
          success: false,
          error: {
            code: 'INVALID_SIGNATURE',
            message: 'Invalid internal signature.'
          },
          metadata: {
            request_id: operationId,
            timestamp: new Date().toISOString()
          }
        }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Re-parse body for JSON requests
    if (req.method !== 'GET' && requestBody) {
      try {
        const parsedBody = JSON.parse(requestBody);
        (req as any).json = () => Promise.resolve(parsedBody);
      } catch (e) {
        // Not JSON
      }
    }
    
    // Extract user ID from JWT
    const userId = extractUserIdFromJWT(authHeader);
    
    // Detect environment
    const isLive = detectEnvironment(req);

    // Create Supabase client
    const supabase = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { 
        persistSession: false, 
        autoRefreshToken: false 
      }
    });

    // Initialize database handler
    const database = new ServiceCatalogDatabase(supabase);

    // Parse URL and route requests
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    
    console.log(`Service Catalog - ${req.method} ${url.pathname}`, {
      tenantId: tenantIdHeader,
      userId,
      isLive,
      operationId
    });

    // Route handlers
    if (pathSegments.includes('health')) {
      return handleHealthCheck(operationId, startTime);
    }

    if (pathSegments.includes('master-data')) {
      return await handleMasterData(database, tenantIdHeader, isLive, operationId, startTime);
    }

    if (pathSegments.includes('services')) {
      return await handleServicesEndpoints(
        req, 
        database, 
        tenantIdHeader, 
        userId, 
        isLive, 
        pathSegments, 
        url, 
        operationId, 
        startTime
      );
    }

    return createErrorResponse('Route not found', 'ROUTE_NOT_FOUND', 404, operationId);

  } catch (error: any) {
    console.error('Service Catalog - Unhandled error:', error);
    return createErrorResponse('Internal server error', 'INTERNAL_ERROR', 500, operationId);
  }
});

// ==========================================
// SECURITY FUNCTIONS
// ==========================================

async function verifyInternalSignature(
  body: string, 
  providedSignature: string, 
  timestamp: string,
  secret: string
): Promise<boolean> {
  if (!secret) {
    console.error('CRITICAL: INTERNAL_SIGNING_SECRET not configured');
    return false;
  }
  
  try {
    const data = body + timestamp + secret;
    const encoder = new TextEncoder();
    const dataBuffer = encoder.encode(data);
    const hashBuffer = await crypto.subtle.digest('SHA-256', dataBuffer);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    const base64Hash = btoa(String.fromCharCode(...hashArray));
    const expectedSignature = base64Hash.substring(0, 32);
    
    return providedSignature === expectedSignature;
  } catch (error) {
    console.error('Signature verification error:', error);
    return false;
  }
}

// ==========================================
// ROUTE HANDLERS
// ==========================================

function handleHealthCheck(operationId: string, startTime: number): Response {
  return createSuccessResponse({
    status: 'healthy',
    service: 'service-catalog',
    security: 'signature-required',
    timestamp: new Date().toISOString()
  }, operationId, startTime);
}

async function handleMasterData(
  database: ServiceCatalogDatabase,
  tenantId: string,
  isLive: boolean,
  operationId: string,
  startTime: number
): Promise<Response> {
  try {
    const masterData = {
      categories: [],
      industries: [], 
      currencies: getAllCurrencies(),
      tax_rates: []
    };

    return createSuccessResponse(masterData, operationId, startTime);
  } catch (error) {
    console.error('Master data fetch error:', error);
    return createErrorResponse('Failed to fetch master data', 'MASTER_DATA_ERROR', 500, operationId);
  }
}

async function handleServicesEndpoints(
  req: Request,
  database: ServiceCatalogDatabase,
  tenantId: string,
  userId: string,
  isLive: boolean,
  pathSegments: string[],
  url: URL,
  operationId: string,
  startTime: number
): Promise<Response> {
  const serviceIndex = pathSegments.indexOf('services');
  const serviceId = pathSegments[serviceIndex + 1];
  const subResource = pathSegments[serviceIndex + 2];

  try {
    // GET /services (list)
    if (req.method === 'GET' && !serviceId) {
      return await handleGetServices(database, tenantId, isLive, url.searchParams, operationId, startTime);
    }

    // GET /services/statistics
    if (req.method === 'GET' && serviceId === 'statistics') {
      return await handleGetStatistics(database, tenantId, isLive, operationId, startTime);
    }

    // GET /services/:id (single)
    if (req.method === 'GET' && serviceId && !subResource) {
      return await handleGetSingleService(database, tenantId, serviceId, isLive, operationId, startTime);
    }

    // GET /services/:id/resources
    if (req.method === 'GET' && serviceId && subResource === 'resources') {
      return await handleGetServiceResources(database, tenantId, serviceId, isLive, operationId, startTime);
    }

    // GET /services/:id/versions
    if (req.method === 'GET' && serviceId && subResource === 'versions') {
      return await handleGetVersionHistory(database, tenantId, serviceId, isLive, operationId, startTime);
    }

    // POST /services (create)
    if (req.method === 'POST' && !serviceId) {
      return await handleCreateService(req, database, tenantId, userId, isLive, operationId, startTime);
    }

    // POST /services/:id/activate
    if (req.method === 'POST' && serviceId && subResource === 'activate') {
      return await handleActivateService(database, tenantId, userId, serviceId, isLive, operationId, startTime);
    }

    // PUT /services/:id (update)
    if (req.method === 'PUT' && serviceId) {
      return await handleUpdateService(req, database, tenantId, userId, serviceId, isLive, operationId, startTime);
    }

    // PATCH /services/:id/status (toggle status)
    if (req.method === 'PATCH' && serviceId && subResource === 'status') {
      return await handleToggleServiceStatus(req, database, tenantId, userId, serviceId, isLive, operationId, startTime);
    }

    // DELETE /services/:id (deactivate)
    if (req.method === 'DELETE' && serviceId) {
      return await handleDeleteService(database, tenantId, userId, serviceId, isLive, operationId, startTime);
    }

    return createErrorResponse('Invalid service endpoint', 'INVALID_ENDPOINT', 404, operationId);

  } catch (error: any) {
    console.error('Services endpoint error:', error);
    return createErrorResponse('Service operation failed', 'SERVICE_ERROR', 500, operationId);
  }
}

async function handleGetServices(
  database: ServiceCatalogDatabase,
  tenantId: string,
  isLive: boolean,
  searchParams: URLSearchParams,
  operationId: string,
  startTime: number
): Promise<Response> {
  try {
    const filters = {
      search_term: searchParams.get('search_term') || undefined,
      category_id: searchParams.get('category_id') || undefined,
      industry_id: searchParams.get('industry_id') || undefined,
      is_active: searchParams.get('is_active') === 'true' ? true : 
                 searchParams.get('is_active') === 'false' ? false : undefined,
      price_min: searchParams.get('price_min') ? parseFloat(searchParams.get('price_min')!) : undefined,
      price_max: searchParams.get('price_max') ? parseFloat(searchParams.get('price_max')!) : undefined,
      currency: searchParams.get('currency') || undefined,
      has_resources: searchParams.get('has_resources') === 'true' ? true :
                    searchParams.get('has_resources') === 'false' ? false : undefined,
      sort_by: searchParams.get('sort_by') || 'created_at',
      sort_direction: searchParams.get('sort_direction') || 'desc',
      limit: Math.min(1000, Math.max(1, parseInt(searchParams.get('limit') || '50'))),
      offset: Math.max(0, parseInt(searchParams.get('offset') || '0'))
    };

    const validation = ServiceCatalogValidator.validateServiceFilters(filters);
    if (!validation.isValid) {
      return createValidationErrorResponse(validation.errors, operationId);
    }

    const sanitizedFilters = ServiceCatalogValidator.sanitizeFilters(filters);
    const result = await database.queryServiceCatalogItems(sanitizedFilters, tenantId, isLive);

    const response = {
      items: result.items.map(transformServiceForAPI),
      total_count: result.total_count,
      page_info: calculatePaginationInfo(result.total_count, sanitizedFilters.limit, sanitizedFilters.offset),
      filters_applied: sanitizedFilters
    };

    return createSuccessResponse(response, operationId, startTime);

  } catch (error: any) {
    console.error('Get services error:', error);
    return createErrorResponse('Failed to fetch services', 'QUERY_ERROR', 500, operationId);
  }
}

async function handleGetSingleService(
  database: ServiceCatalogDatabase,
  tenantId: string,
  serviceId: string,
  isLive: boolean,
  operationId: string,
  startTime: number
): Promise<Response> {
  try {
    if (!ServiceCatalogValidator.isValidUUID(serviceId)) {
      return createErrorResponse('Invalid service ID format', 'INVALID_SERVICE_ID', 400, operationId);
    }

    const service = await database.getServiceCatalogItemById(serviceId, tenantId, isLive);

    if (!service) {
      return createErrorResponse('Service not found', 'NOT_FOUND', 404, operationId);
    }

    return createSuccessResponse(transformServiceForAPI(service), operationId, startTime);

  } catch (error: any) {
    console.error('Get single service error:', error);
    return createErrorResponse('Failed to fetch service', 'FETCH_ERROR', 500, operationId);
  }
}

async function handleGetServiceResources(
  database: ServiceCatalogDatabase,
  tenantId: string,
  serviceId: string,
  isLive: boolean,
  operationId: string,
  startTime: number
): Promise<Response> {
  try {
    if (!ServiceCatalogValidator.isValidUUID(serviceId)) {
      return createErrorResponse('Invalid service ID format', 'INVALID_SERVICE_ID', 400, operationId);
    }

    const result = await database.getServiceResources(serviceId, tenantId, isLive);
    return createSuccessResponse(result, operationId, startTime);

  } catch (error: any) {
    console.error('Get service resources error:', error);
    return createErrorResponse('Failed to fetch service resources', 'RESOURCES_ERROR', 500, operationId);
  }
}

async function handleGetStatistics(
  database: ServiceCatalogDatabase,
  tenantId: string,
  isLive: boolean,
  operationId: string,
  startTime: number
): Promise<Response> {
  try {
    const stats = await database.getServiceStatistics(tenantId, isLive);
    return createSuccessResponse(stats, operationId, startTime);
  } catch (error: any) {
    console.error('Get statistics error:', error);
    return createErrorResponse('Failed to fetch statistics', 'STATS_ERROR', 500, operationId);
  }
}

async function handleGetVersionHistory(
  database: ServiceCatalogDatabase,
  tenantId: string,
  serviceId: string,
  isLive: boolean,
  operationId: string,
  startTime: number
): Promise<Response> {
  try {
    if (!ServiceCatalogValidator.isValidUUID(serviceId)) {
      return createErrorResponse('Invalid service ID format', 'INVALID_SERVICE_ID', 400, operationId);
    }

    // Get all versions where id = serviceId OR parent_id = serviceId
    const filters = {
      limit: 100,
      offset: 0,
      sort_by: 'created_at',
      sort_direction: 'desc' as 'desc'
    };

    const result = await database.queryServiceCatalogItems(filters, tenantId, isLive);
    const versions = result.items.filter(
      (item: any) => item.id === serviceId || item.parent_id === serviceId
    );

    return createSuccessResponse({
      service_id: serviceId,
      versions: versions.map(transformServiceForAPI),
      total_versions: versions.length
    }, operationId, startTime);

  } catch (error: any) {
    console.error('Get version history error:', error);
    return createErrorResponse('Failed to fetch version history', 'VERSION_HISTORY_ERROR', 500, operationId);
  }
}

async function handleCreateService(
  req: Request,
  database: ServiceCatalogDatabase,
  tenantId: string,
  userId: string,
  isLive: boolean,
  operationId: string,
  startTime: number
): Promise<Response> {
  try {
    const requestBody = await req.json();
    
    console.log('Creating service:', {
      operationId,
      tenantId,
      userId,
      hasServiceName: !!requestBody.service_name,
      serviceType: requestBody.service_type,
      hasPricingRecords: !!requestBody.pricing_records?.length,
      hasResources: !!requestBody.resource_requirements?.length
    });

    const validation = ServiceCatalogValidator.validateServiceCatalogItem(requestBody);
    if (!validation.isValid) {
      return createValidationErrorResponse(validation.errors, operationId);
    }

    const serviceData = transformAPIToDatabase(requestBody);
    const createdService = await database.createServiceCatalogItem(serviceData, tenantId, userId, isLive);
    const apiResponse = transformServiceForAPI(createdService);

    console.log('Service created successfully:', {
      serviceId: createdService.id,
      serviceName: createdService.name,
      status: createdService.status
    });

    return createSuccessResponse(apiResponse, operationId, startTime);

  } catch (error: any) {
    console.error('Create service error:', error);
    
    if (error.code === '23505') {
      return createErrorResponse('Service with this SKU already exists', 'DUPLICATE_SKU', 409, operationId);
    }
    
    return createErrorResponse('Failed to create service', 'CREATE_ERROR', 500, operationId);
  }
}

async function handleUpdateService(
  req: Request,
  database: ServiceCatalogDatabase,
  tenantId: string,
  userId: string,
  serviceId: string,
  isLive: boolean,
  operationId: string,
  startTime: number
): Promise<Response> {
  try {
    if (!ServiceCatalogValidator.isValidUUID(serviceId)) {
      return createErrorResponse('Invalid service ID format', 'INVALID_SERVICE_ID', 400, operationId);
    }

    const hasAccess = await database.verifyServiceAccess(serviceId, tenantId, isLive);
    if (!hasAccess) {
      return createErrorResponse('Service not found or access denied', 'NOT_FOUND', 404, operationId);
    }

    const requestBody = await req.json();
    
    const validation = ServiceCatalogValidator.validateServiceCatalogItem(requestBody);
    if (!validation.isValid) {
      return createValidationErrorResponse(validation.errors, operationId);
    }

    const serviceData = transformAPIToDatabase(requestBody);
    const updatedService = await database.updateServiceCatalogItem(serviceId, serviceData, tenantId, userId, isLive);
    const apiResponse = transformServiceForAPI(updatedService);

    console.log('Service updated successfully:', {
      newServiceId: updatedService.id,
      serviceName: updatedService.name,
      status: updatedService.status
    });

    return createSuccessResponse(apiResponse, operationId, startTime);

  } catch (error: any) {
    console.error('Update service error:', error);
    return createErrorResponse('Failed to update service', 'UPDATE_ERROR', 500, operationId);
  }
}

/**
 * ✅ FIXED: Toggle service status - Direct boolean flip (NO versioning)
 */
async function handleToggleServiceStatus(
  req: Request,
  database: ServiceCatalogDatabase,
  tenantId: string,
  userId: string,
  serviceId: string,
  isLive: boolean,
  operationId: string,
  startTime: number
): Promise<Response> {
  try {
    if (!ServiceCatalogValidator.isValidUUID(serviceId)) {
      return createErrorResponse('Invalid service ID format', 'INVALID_SERVICE_ID', 400, operationId);
    }

    const hasAccess = await database.verifyServiceAccess(serviceId, tenantId, isLive);
    if (!hasAccess) {
      return createErrorResponse('Service not found or access denied', 'NOT_FOUND', 404, operationId);
    }

    const requestBody = await req.json();
    const newStatus = requestBody.status;

    if (typeof newStatus !== 'boolean') {
      return createErrorResponse('Invalid status. Must be boolean (true or false)', 'INVALID_STATUS', 400, operationId);
    }

    console.log('Toggling service status:', {
      serviceId,
      newStatus
    });

    // ✅ FIXED: Call direct toggle method (NOT updateServiceCatalogItem)
    const updatedService = await database.toggleServiceStatusDirect(
      serviceId, 
      newStatus, 
      tenantId, 
      userId, 
      isLive
    );
    
    const apiResponse = transformServiceForAPI(updatedService);

    console.log('Service status toggled successfully:', {
      serviceId: updatedService.id,
      newStatus: updatedService.status
    });

    return createSuccessResponse({
      message: `Service ${newStatus ? 'activated' : 'deactivated'} successfully`,
      service: apiResponse
    }, operationId, startTime);

  } catch (error: any) {
    console.error('Toggle service status error:', error);
    return createErrorResponse('Failed to toggle service status', 'TOGGLE_STATUS_ERROR', 500, operationId);
  }
}

async function handleDeleteService(
  database: ServiceCatalogDatabase,
  tenantId: string,
  userId: string,
  serviceId: string,
  isLive: boolean,
  operationId: string,
  startTime: number
): Promise<Response> {
  try {
    if (!ServiceCatalogValidator.isValidUUID(serviceId)) {
      return createErrorResponse('Invalid service ID format', 'INVALID_SERVICE_ID', 400, operationId);
    }

    const hasAccess = await database.verifyServiceAccess(serviceId, tenantId, isLive);
    if (!hasAccess) {
      return createErrorResponse('Service not found or access denied', 'NOT_FOUND', 404, operationId);
    }

    const result = await database.deleteServiceCatalogItem(serviceId, tenantId, userId, isLive);

    return createSuccessResponse({
      message: 'Service deactivated successfully',
      service: {
        id: result.deletedService.id,
        name: result.deletedService.name,
        status: result.deletedService.status
      }
    }, operationId, startTime);

  } catch (error: any) {
    console.error('Deactivate service error:', error);
    return createErrorResponse('Failed to deactivate service', 'DEACTIVATE_ERROR', 500, operationId);
  }
}

async function handleActivateService(
  database: ServiceCatalogDatabase,
  tenantId: string,
  userId: string,
  serviceId: string,
  isLive: boolean,
  operationId: string,
  startTime: number
): Promise<Response> {
  try {
    if (!ServiceCatalogValidator.isValidUUID(serviceId)) {
      return createErrorResponse('Invalid service ID format', 'INVALID_SERVICE_ID', 400, operationId);
    }

    const hasAccess = await database.verifyServiceAccess(serviceId, tenantId, isLive);
    if (!hasAccess) {
      return createErrorResponse('Service not found or access denied', 'NOT_FOUND', 404, operationId);
    }

    const activatedService = await database.restoreServiceCatalogItem(serviceId, tenantId, userId, isLive);
    const apiResponse = transformServiceForAPI(activatedService);

    return createSuccessResponse({
      message: 'Service activated successfully',
      service: apiResponse
    }, operationId, startTime);

  } catch (error: any) {
    console.error('Activate service error:', error);
    return createErrorResponse('Failed to activate service', 'ACTIVATE_ERROR', 500, operationId);
  }
}

// ==========================================
// UTILITY FUNCTIONS
// ==========================================

function detectEnvironment(req: Request): boolean {
  const envHeader = req.headers.get('x-environment')?.toLowerCase();
  if (envHeader === 'test' || envHeader === 'staging' || envHeader === 'dev') {
    return false;
  }
  return true;
}

function extractUserIdFromJWT(authHeader: string): string {
  try {
    const token = authHeader.replace('Bearer ', '');
    const payload = JSON.parse(atob(token.split('.')[1]));
    return payload.sub || 'system-user';
  } catch (error) {
    return 'system-user';
  }
}

/**
 * ✅ FIXED: Transform database record to API format
 * - Returns pricing_records array
 * - Returns resource_requirements array
 * - Boolean status
 */
function transformServiceForAPI(dbRecord: any): any {
  // ✅ Extract pricing_records from JSONB
  const pricingRecords = dbRecord.price_attributes?.pricing_records || [];
  
  // ✅ Extract resource_requirements from JSONB
  const resourceDetails = dbRecord.resource_requirements?.resource_details || [];
  
  const serviceType = dbRecord.service_attributes?.service_type || 'independent';
  const imageUrl = dbRecord.metadata?.image_url || null;
  
  return {
    id: dbRecord.id,
    tenant_id: dbRecord.tenant_id,
    service_name: dbRecord.name,
    description: dbRecord.description_content || dbRecord.short_description,
    short_description: dbRecord.short_description,
    sku: dbRecord.service_attributes?.sku || null,
    category_id: dbRecord.category_id,
    industry_id: dbRecord.industry_id,
    
    // ✅ Boolean status
    status: dbRecord.status,
    is_active: dbRecord.status === true,
    is_inactive: dbRecord.status === false,
    
    // ✅ Variant tracking
    is_variant: dbRecord.is_variant || false,
    parent_id: dbRecord.parent_id || null,
    
    // ✅ FIXED: Return pricing_records array
    pricing_records: pricingRecords,
    
    // Backward compatibility - pricing_config with first record
    pricing_config: {
      base_price: dbRecord.price_attributes?.base_amount || 0,
      currency: dbRecord.price_attributes?.currency || 'INR',
      pricing_model: dbRecord.price_attributes?.type || 'fixed',
      billing_cycle: dbRecord.price_attributes?.billing_mode || 'manual',
      tax_inclusive: dbRecord.tax_config?.use_tenant_default || false
    },
    
    service_attributes: dbRecord.service_attributes || {},
    duration_minutes: dbRecord.service_attributes?.duration_minutes,
    sort_order: dbRecord.metadata?.sort_order || 0,
    
    // Service type
    service_type: serviceType,
    
    // ✅ FIXED: Return resource_requirements array
    resource_requirements: resourceDetails,
    required_resources: resourceDetails, // Alias for compatibility
    
    // Terms
    terms: dbRecord.terms_content,
    terms_format: dbRecord.terms_format || 'html',
    
    // Description format
    description_format: dbRecord.description_format || 'html',
    
    // Image
    image_url: imageUrl,
    
    // Tags
    tags: dbRecord.metadata?.tags || [],
    
    // Metadata
    metadata: dbRecord.metadata || {},
    specifications: dbRecord.specifications || {},
    variant_attributes: dbRecord.variant_attributes || {},
    
    slug: ServiceCatalogValidator.generateSlug(dbRecord.name || ''),
    created_at: dbRecord.created_at,
    updated_at: dbRecord.updated_at,
    created_by: dbRecord.created_by,
    updated_by: dbRecord.updated_by,
    is_live: dbRecord.is_live,
    
    display_name: dbRecord.name,
    formatted_price: formatCurrency(
      dbRecord.price_attributes?.base_amount || 0, 
      dbRecord.price_attributes?.currency || 'INR'
    ),
    has_resources: dbRecord.resource_requirements?.requires_resources || false,
    resource_count: dbRecord.resource_requirements?.resource_count || 0
  };
}

function transformAPIToDatabase(apiData: any): any {
  return {
    service_name: apiData.service_name,
    short_description: apiData.short_description,
    description: apiData.description,
    description_format: apiData.description_format || 'html',
    sku: apiData.sku,
    category_id: apiData.category_id,
    industry_id: apiData.industry_id,
    
    is_variant: apiData.is_variant || false,
    parent_id: apiData.parent_id || null,
    
    service_type: apiData.service_type || 'independent',
    duration_minutes: apiData.duration_minutes,
    terms: apiData.terms,
    terms_format: apiData.terms_format || 'html',
    
    // ✅ Accept pricing_records array
    pricing_records: apiData.pricing_records || [],
    
    // ✅ Accept resource_requirements array
    resource_requirements: apiData.resource_requirements || apiData.required_resources || [],
    
    service_attributes: apiData.service_attributes || {},
    specifications: apiData.specifications || {},
    variant_attributes: apiData.variant_attributes || {},
    sort_order: apiData.sort_order || 0,
    
    image_url: apiData.image_url,
    
    tags: apiData.tags || [],
    metadata: apiData.metadata || {}
  };
}

function calculatePaginationInfo(totalCount: number, limit: number, offset: number) {
  const currentPage = Math.floor(offset / limit) + 1;
  const totalPages = Math.ceil(totalCount / limit);
  const hasNextPage = currentPage < totalPages;
  const hasPrevPage = currentPage > 1;

  return {
    has_next_page: hasNextPage,
    has_prev_page: hasPrevPage,
    current_page: currentPage,
    total_pages: totalPages
  };
}

function createSuccessResponse(data: any, operationId: string, startTime: number): Response {
  const executionTime = Date.now() - startTime;
  
  return new Response(
    JSON.stringify({
      success: true,
      data,
      metadata: {
        request_id: operationId,
        execution_time_ms: executionTime,
        timestamp: new Date().toISOString()
      }
    }),
    {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json', 'X-Operation-ID': operationId }
    }
  );
}

function createErrorResponse(message: string, code: string, status: number, operationId: string): Response {
  return new Response(
    JSON.stringify({
      success: false,
      error: {
        code,
        message
      },
      metadata: {
        request_id: operationId,
        timestamp: new Date().toISOString()
      }
    }),
    {
      status,
      headers: { ...corsHeaders, 'Content-Type': 'application/json', 'X-Operation-ID': operationId }
    }
  );
}

function createValidationErrorResponse(errors: any[], operationId: string): Response {
  return new Response(
    JSON.stringify({
      success: false,
      error: {
        code: 'VALIDATION_ERROR',
        message: 'Input validation failed',
        details: errors.map(e => ({
          field: e.field,
          message: e.message,
          code: e.code
        }))
      },
      metadata: {
        request_id: operationId,
        timestamp: new Date().toISOString()
      }
    }),
    {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json', 'X-Operation-ID': operationId }
    }
  );
}

console.log('Service Catalog Edge Function - Ready');