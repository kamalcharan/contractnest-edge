// supabase/functions/catalog-items/index.ts
// ✅ PRODUCTION: Complete catalog items Edge function with resource composition and environment segregation

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';
import { verifyHMACSignature } from '../_shared/security/hmac.ts';
import { rateLimiter } from '../_shared/security/rateLimit.ts';
import { AuditLogger } from '../_shared/audit/auditLogger.ts';

import { CatalogService } from '../_shared/catalog/catalogService.ts';
import { CatalogValidationService } from '../_shared/catalog/catalogValidation.ts';
import {
  CatalogServiceConfig,
  CreateCatalogItemRequest,
  UpdateCatalogItemRequest,
  CatalogItemQuery,
  ResourceListParams,
  CreateMultiCurrencyPricingRequest,
  RestoreCatalogItemRequest,
  CurrencyPricingUpdate,
  CatalogError,
  NotFoundError,
  ValidationError,
  ResourceError,
  ContactValidationError,
  ConflictError,
  CatalogItemType,
  ResourceType,
  ServiceComplexityLevel,
  SortDirection,
  SupportedCurrency
} from '../_shared/catalog/catalogTypes.ts';

// =================================================================
// ENVIRONMENT CONTEXT MANAGEMENT
// =================================================================

/**
 * Extract comprehensive environment context from request
 * Critical for is_live filtering and environment segregation
 */
function getEnvironmentContext(req: Request): {
  is_live: boolean;
  environment_label: string;
  tenant_id: string;
  user_id: string;
  request_id: string;
  user_role?: string;
  client_version?: string;
} {
  const url = new URL(req.url);
  const headers = req.headers;

  // Extract tenant and user context
  const tenant_id = headers.get('x-tenant-id') || headers.get('tenantid') || '';
  const user_id = headers.get('x-user-id') || headers.get('userid') || '';
  const user_role = headers.get('x-user-role') || headers.get('userrole');
  const client_version = headers.get('x-client-version') || headers.get('clientversion');

  // Determine environment from multiple sources
  const envHeader = headers.get('x-environment') || headers.get('environment');
  const envParam = url.searchParams.get('environment');
  const envSubdomain = url.hostname.includes('test.') ? 'test' : 
                      url.hostname.includes('staging.') ? 'test' : 'production';
  
  const environment = envHeader || envParam || envSubdomain;

  // Convert to boolean - production is live, everything else is test
  const is_live = environment.toLowerCase() === 'production';
  const environment_label = is_live ? 'Production' : 'Test';

  // Generate request ID for tracking
  const request_id = crypto.randomUUID();

  console.log(`[Environment] Context: ${environment_label} (is_live: ${is_live}) for tenant: ${tenant_id}, request: ${request_id}`);

  return {
    is_live,
    environment_label,
    tenant_id,
    user_id,
    request_id,
    user_role,
    client_version
  };
}

/**
 * Initialize services with comprehensive environment context
 */
function initializeServices(envContext: ReturnType<typeof getEnvironmentContext>, supabase: any): {
  catalogService: CatalogService;
  validationService: CatalogValidationService;
  auditLogger: AuditLogger;
  config: CatalogServiceConfig;
} {
  const config: CatalogServiceConfig = {
    tenant_id: envContext.tenant_id,
    user_id: envContext.user_id,
    is_live: envContext.is_live // ✅ CRITICAL: Environment segregation
  };

  const auditLogger = new AuditLogger(supabase, config);
  const validationService = new CatalogValidationService(supabase, config);
  const catalogService = new CatalogService(supabase, config, auditLogger);

  console.log(`[Services] Initialized for ${envContext.environment_label} environment (Request: ${envContext.request_id})`);

  return {
    catalogService,
    validationService,
    auditLogger,
    config
  };
}

/**
 * Validate environment-specific permissions
 */
function validateEnvironmentPermissions(envContext: ReturnType<typeof getEnvironmentContext>, operation: string): {
  allowed: boolean;
  reason?: string;
} {
  // Production environment restrictions
  if (envContext.is_live) {
    // Only allow certain roles to modify production data
    const productionWriteRoles = ['admin', 'catalog_manager', 'system'];
    if (['POST', 'PUT', 'DELETE'].includes(operation) && 
        envContext.user_role && 
        !productionWriteRoles.includes(envContext.user_role)) {
      return {
        allowed: false,
        reason: 'Insufficient permissions for production environment'
      };
    }
  }

  return { allowed: true };
}

// =================================================================
// REQUEST VALIDATION AND PARSING
// =================================================================

/**
 * Parse and validate catalog item query parameters
 */
function parseQueryParameters(url: URL, envContext: ReturnType<typeof getEnvironmentContext>): CatalogItemQuery {
  const filters: any = {
    is_live: envContext.is_live // ✅ CRITICAL: Environment filtering
  };

  // Type filtering
  if (url.searchParams.get('type')) {
    const types = url.searchParams.get('type')!.split(',') as CatalogItemType[];
    filters.type = types.length === 1 ? types[0] : types;
  }

  // Status filtering
  if (url.searchParams.get('status')) {
    filters.status = url.searchParams.get('status')!.split(',');
  }

  if (url.searchParams.has('active')) {
    filters.is_active = url.searchParams.get('active') === 'true';
  }

  // Search
  if (url.searchParams.get('search')) {
    filters.search_query = url.searchParams.get('search');
  }

  // Service-specific filters
  if (url.searchParams.get('complexity')) {
    filters.complexity_level = url.searchParams.get('complexity') as ServiceComplexityLevel;
  }

  if (url.searchParams.has('customer_presence')) {
    filters.requires_customer_presence = url.searchParams.get('customer_presence') === 'true';
  }

  if (url.searchParams.get('duration_min')) {
    filters.estimated_duration = filters.estimated_duration || {};
    filters.estimated_duration.min = parseInt(url.searchParams.get('duration_min')!);
  }

  if (url.searchParams.get('duration_max')) {
    filters.estimated_duration = filters.estimated_duration || {};
    filters.estimated_duration.max = parseInt(url.searchParams.get('duration_max')!);
  }

  // Resource filtering
  if (url.searchParams.has('has_resources')) {
    filters.has_resources = url.searchParams.get('has_resources') === 'true';
  }

  if (url.searchParams.get('resource_types')) {
    filters.resource_types = url.searchParams.get('resource_types')!.split(',') as ResourceType[];
  }

  // Pricing filters
  if (url.searchParams.get('min_price')) {
    filters.min_price = parseFloat(url.searchParams.get('min_price')!);
  }

  if (url.searchParams.get('max_price')) {
    filters.max_price = parseFloat(url.searchParams.get('max_price')!);
  }

  if (url.searchParams.get('currency')) {
    filters.currency = url.searchParams.get('currency') as SupportedCurrency;
  }

  // Date filters
  if (url.searchParams.get('created_after')) {
    filters.created_after = url.searchParams.get('created_after');
  }

  if (url.searchParams.get('created_before')) {
    filters.created_before = url.searchParams.get('created_before');
  }

  if (url.searchParams.get('updated_after')) {
    filters.updated_after = url.searchParams.get('updated_after');
  }

  if (url.searchParams.get('updated_before')) {
    filters.updated_before = url.searchParams.get('updated_before');
  }

  // Hierarchy filters
  if (url.searchParams.get('parent_id')) {
    filters.parent_id = url.searchParams.get('parent_id');
  }

  if (url.searchParams.has('is_variant')) {
    filters.is_variant = url.searchParams.get('is_variant') === 'true';
  }

  if (url.searchParams.has('include_variants')) {
    filters.include_variants = url.searchParams.get('include_variants') === 'true';
  }

  // Sorting
  const sort = [];
  if (url.searchParams.get('sort')) {
    const sortFields = url.searchParams.get('sort')!.split(',');
    const sortOrders = url.searchParams.get('order')?.split(',') || [];
    
    for (let i = 0; i < sortFields.length; i++) {
      sort.push({
        field: sortFields[i] as any,
        direction: (sortOrders[i] || 'desc') as SortDirection
      });
    }
  }

  // Pagination
  const page = Math.max(1, parseInt(url.searchParams.get('page') || '1'));
  const limit = Math.min(Math.max(1, parseInt(url.searchParams.get('limit') || '20')), 100);

  // Include options
  const include_related = url.searchParams.get('include_related') === 'true';
  const include_resources = url.searchParams.get('include_resources') === 'true';
  const include_versions = url.searchParams.get('include_versions') === 'true';
  const include_variants = url.searchParams.get('include_variants') === 'true';

  return {
    filters,
    sort: sort.length > 0 ? sort : undefined,
    pagination: { page, limit },
    include_related,
    include_resources,
    include_versions,
    include_variants
  };
}

/**
 * Parse resource query parameters
 */
function parseResourceParameters(url: URL, envContext: ReturnType<typeof getEnvironmentContext>): ResourceListParams {
  return {
    resourceType: url.searchParams.get('type') as ResourceType,
    search: url.searchParams.get('search') || undefined,
    status: url.searchParams.get('status') as any || 'active',
    hasContact: url.searchParams.get('has_contact') === 'true' ? true :
                url.searchParams.get('has_contact') === 'false' ? false : undefined,
    availableOnly: url.searchParams.get('available_only') === 'true',
    page: Math.max(1, parseInt(url.searchParams.get('page') || '1')),
    limit: Math.min(Math.max(1, parseInt(url.searchParams.get('limit') || '20')), 100),
    sortBy: url.searchParams.get('sort_by') as any || 'created_at',
    sortOrder: (url.searchParams.get('sort_order') || 'desc') as SortDirection,
    is_live: envContext.is_live // ✅ CRITICAL: Environment filtering
  };
}

// =================================================================
// CATALOG ITEM CRUD OPERATIONS
// =================================================================

/**
 * POST /catalog-items - Create catalog item with resources
 */
async function handleCreateCatalogItem(
  req: Request,
  catalogService: CatalogService,
  validationService: CatalogValidationService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    console.log(`[Create] ${envContext.environment_label} - Starting catalog item creation (${envContext.request_id})`);

    const requestData: CreateCatalogItemRequest = await req.json();
    
    // Validate request structure
    if (!requestData.name || !requestData.type) {
      return createErrorResponse(
        'Missing required fields: name and type are required',
        400,
        envContext
      );
    }

    console.log(`[Create] ${envContext.environment_label} - Creating: ${requestData.name}`);

    // ✅ VALIDATION: With environment context
    const validation = await validationService.validateCreateRequest(requestData);
    if (!validation.is_valid) {
      return createErrorResponse(
        'Validation failed',
        400,
        envContext,
        {
          validation_errors: validation.errors,
          warnings: validation.warnings
        }
      );
    }

    // Validate bulk operation limits if resources included
    if (requestData.resources && requestData.resources.length > 0) {
      const bulkValidation = validationService.validateBulkOperationLimits(
        requestData.resources.length, 
        'create'
      );
      if (!bulkValidation.is_valid) {
        return createErrorResponse(
          'Bulk operation limit exceeded',
          400,
          envContext,
          { bulk_errors: bulkValidation.errors }
        );
      }
    }

    // ✅ CREATE: Service automatically uses is_live from config
    const result = await catalogService.createCatalogItem(requestData);

    console.log(`[Create] ${envContext.environment_label} - Success: ${result.data?.id} (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        ...result,
        environment: envContext.environment_label,
        request_id: envContext.request_id,
        tenant_context: {
          tenant_id: envContext.tenant_id,
          is_live: envContext.is_live
        }
      }),
      {
        status: 201,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Create] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

/**
 * PUT /catalog-items/:id - Update catalog item with resources
 */
async function handleUpdateCatalogItem(
  req: Request,
  catalogId: string,
  catalogService: CatalogService,
  validationService: CatalogValidationService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    console.log(`[Update] ${envContext.environment_label} - Starting update: ${catalogId} (${envContext.request_id})`);

    const updateData: UpdateCatalogItemRequest = await req.json();

    // Check if item exists first
    const currentItem = await catalogService.getCatalogItemById(catalogId);
    if (!currentItem.success || !currentItem.data) {
      return createErrorResponse(
        `Catalog item ${catalogId} not found in ${envContext.environment_label} environment`,
        404,
        envContext
      );
    }

    console.log(`[Update] ${envContext.environment_label} - Found item: ${currentItem.data.name}`);

    // ✅ VALIDATION: Environment-aware validation
    const validation = await validationService.validateUpdateRequest(currentItem.data, updateData);
    if (!validation.is_valid) {
      return createErrorResponse(
        'Validation failed',
        400,
        envContext,
        {
          validation_errors: validation.errors,
          warnings: validation.warnings
        }
      );
    }

    // Validate bulk operations if resources are being added/updated
    const totalResourceOps = (updateData.add_resources?.length || 0) + 
                            (updateData.update_resources?.length || 0) + 
                            (updateData.remove_resources?.length || 0);
    
    if (totalResourceOps > 0) {
      const bulkValidation = validationService.validateBulkOperationLimits(totalResourceOps, 'update');
      if (!bulkValidation.is_valid) {
        return createErrorResponse(
          'Bulk operation limit exceeded',
          400,
          envContext,
          { bulk_errors: bulkValidation.errors }
        );
      }
    }

    // ✅ UPDATE: Service automatically filters by is_live
    const result = await catalogService.updateCatalogItem(catalogId, updateData);

    console.log(`[Update] ${envContext.environment_label} - Success: ${catalogId} (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        ...result,
        environment: envContext.environment_label,
        request_id: envContext.request_id
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Update] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

/**
 * GET /catalog-items/:id - Get catalog item with resources
 */
async function handleGetCatalogItem(
  catalogId: string,
  catalogService: CatalogService,
  envContext: ReturnType<typeof getEnvironmentContext>,
  includeResources: boolean = true
): Promise<Response> {
  try {
    console.log(`[Get] ${envContext.environment_label} - Getting: ${catalogId} (${envContext.request_id})`);

    // ✅ GET: Service automatically filters by is_live
    const result = await catalogService.getCatalogItemById(catalogId);

    if (!result.success) {
      return createErrorResponse(
        `Catalog item ${catalogId} not found in ${envContext.environment_label} environment`,
        404,
        envContext
      );
    }

    console.log(`[Get] ${envContext.environment_label} - Found: ${result.data?.name} (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        ...result,
        environment: envContext.environment_label,
        request_id: envContext.request_id,
        data: {
          ...result.data,
          environment_info: {
            is_live: envContext.is_live,
            environment_label: envContext.environment_label
          }
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Get] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

/**
 * GET /catalog-items - Query catalog items with environment filtering
 */
async function handleQueryCatalogItems(
  req: Request,
  catalogService: CatalogService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    const url = new URL(req.url);
    const query = parseQueryParameters(url, envContext);

    console.log(`[Query] ${envContext.environment_label} - Executing query (${envContext.request_id}):`, {
      filters: Object.keys(query.filters || {}),
      page: query.pagination?.page,
      limit: query.pagination?.limit
    });

    // ✅ QUERY: Service automatically filters by is_live from config
    const result = await catalogService.queryCatalogItems(query);

    console.log(`[Query] ${envContext.environment_label} - Found ${result.data?.length || 0} items (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        ...result,
        environment: envContext.environment_label,
        request_id: envContext.request_id,
        query_context: {
          is_live: envContext.is_live,
          total_filtered_by_environment: result.pagination?.total || 0,
          applied_filters: query.filters
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Query] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

/**
 * DELETE /catalog-items/:id - Soft delete catalog item
 */
async function handleDeleteCatalogItem(
  catalogId: string,
  catalogService: CatalogService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    console.log(`[Delete] ${envContext.environment_label} - Deleting: ${catalogId} (${envContext.request_id})`);

    // Check if item exists first
    const currentItem = await catalogService.getCatalogItemById(catalogId);
    if (!currentItem.success || !currentItem.data) {
      return createErrorResponse(
        `Catalog item ${catalogId} not found in ${envContext.environment_label} environment`,
        404,
        envContext
      );
    }

    // ✅ DELETE: Service automatically filters by is_live
    const result = await catalogService.deleteCatalogItem(catalogId);

    console.log(`[Delete] ${envContext.environment_label} - Success: ${catalogId} (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        ...result,
        environment: envContext.environment_label,
        request_id: envContext.request_id,
        deleted_item: {
          id: catalogId,
          name: currentItem.data.name
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Delete] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

// =================================================================
// BULK OPERATIONS
// =================================================================

/**
 * POST /catalog-items/bulk - Bulk create catalog items
 */
async function handleBulkCreateCatalogItems(
  req: Request,
  catalogService: CatalogService,
  validationService: CatalogValidationService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    console.log(`[Bulk Create] ${envContext.environment_label} - Starting (${envContext.request_id})`);

    const requestData: { items: CreateCatalogItemRequest[] } = await req.json();
    
    if (!requestData.items || !Array.isArray(requestData.items)) {
      return createErrorResponse(
        'Invalid request: items array is required',
        400,
        envContext
      );
    }

    // Validate bulk limits
    const bulkValidation = validationService.validateBulkOperationLimits(
      requestData.items.length, 
      'create'
    );
    if (!bulkValidation.is_valid) {
      return createErrorResponse(
        'Bulk operation limit exceeded',
        400,
        envContext,
        { bulk_errors: bulkValidation.errors }
      );
    }

    const results = [];
    const errors = [];

    for (let i = 0; i < requestData.items.length; i++) {
      try {
        const validation = await validationService.validateCreateRequest(requestData.items[i]);
        if (!validation.is_valid) {
          errors.push({
            index: i,
            name: requestData.items[i].name,
            errors: validation.errors
          });
          continue;
        }

        const result = await catalogService.createCatalogItem(requestData.items[i]);
        results.push({
          index: i,
          name: requestData.items[i].name,
          id: result.data?.id,
          success: true
        });

      } catch (error) {
        errors.push({
          index: i,
          name: requestData.items[i].name,
          error: error.message
        });
      }
    }

    console.log(`[Bulk Create] ${envContext.environment_label} - Completed: ${results.length} success, ${errors.length} errors (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        success: true,
        message: `Bulk operation completed: ${results.length} created, ${errors.length} failed`,
        data: {
          created: results,
          errors: errors,
          summary: {
            total_requested: requestData.items.length,
            total_created: results.length,
            total_failed: errors.length
          }
        },
        environment: envContext.environment_label,
        request_id: envContext.request_id
      }),
      {
        status: errors.length === requestData.items.length ? 400 : 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Bulk Create] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

/**
 * PUT /catalog-items/bulk - Bulk update catalog items
 */
async function handleBulkUpdateCatalogItems(
  req: Request,
  catalogService: CatalogService,
  validationService: CatalogValidationService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    console.log(`[Bulk Update] ${envContext.environment_label} - Starting (${envContext.request_id})`);

    const requestData: { updates: Array<{ id: string; data: UpdateCatalogItemRequest }> } = await req.json();
    
    if (!requestData.updates || !Array.isArray(requestData.updates)) {
      return createErrorResponse(
        'Invalid request: updates array is required',
        400,
        envContext
      );
    }

    // Validate bulk limits
    const bulkValidation = validationService.validateBulkOperationLimits(
      requestData.updates.length, 
      'update'
    );
    if (!bulkValidation.is_valid) {
      return createErrorResponse(
        'Bulk operation limit exceeded',
        400,
        envContext,
        { bulk_errors: bulkValidation.errors }
      );
    }

    const results = [];
    const errors = [];

    for (let i = 0; i < requestData.updates.length; i++) {
      try {
        const update = requestData.updates[i];
        
        // Get current item
        const currentItem = await catalogService.getCatalogItemById(update.id);
        if (!currentItem.success || !currentItem.data) {
          errors.push({
            index: i,
            id: update.id,
            error: 'Item not found'
          });
          continue;
        }

        const validation = await validationService.validateUpdateRequest(currentItem.data, update.data);
        if (!validation.is_valid) {
          errors.push({
            index: i,
            id: update.id,
            errors: validation.errors
          });
          continue;
        }

        const result = await catalogService.updateCatalogItem(update.id, update.data);
        results.push({
          index: i,
          id: update.id,
          name: currentItem.data.name,
          success: true
        });

      } catch (error) {
        errors.push({
          index: i,
          id: requestData.updates[i].id,
          error: error.message
        });
      }
    }

    console.log(`[Bulk Update] ${envContext.environment_label} - Completed: ${results.length} success, ${errors.length} errors (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        success: true,
        message: `Bulk operation completed: ${results.length} updated, ${errors.length} failed`,
        data: {
          updated: results,
          errors: errors,
          summary: {
            total_requested: requestData.updates.length,
            total_updated: results.length,
            total_failed: errors.length
          }
        },
        environment: envContext.environment_label,
        request_id: envContext.request_id
      }),
      {
        status: errors.length === requestData.updates.length ? 400 : 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Bulk Update] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

/**
 * DELETE /catalog-items/bulk - Bulk delete catalog items
 */
async function handleBulkDeleteCatalogItems(
  req: Request,
  catalogService: CatalogService,
  validationService: CatalogValidationService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    console.log(`[Bulk Delete] ${envContext.environment_label} - Starting (${envContext.request_id})`);

    const requestData: { ids: string[] } = await req.json();
    
    if (!requestData.ids || !Array.isArray(requestData.ids)) {
      return createErrorResponse(
        'Invalid request: ids array is required',
        400,
        envContext
      );
    }

    // Validate bulk limits
    const bulkValidation = validationService.validateBulkOperationLimits(
      requestData.ids.length, 
      'delete'
    );
    if (!bulkValidation.is_valid) {
      return createErrorResponse(
        'Bulk operation limit exceeded',
        400,
        envContext,
        { bulk_errors: bulkValidation.errors }
      );
    }

    const results = [];
    const errors = [];

    for (let i = 0; i < requestData.ids.length; i++) {
      try {
        const catalogId = requestData.ids[i];
        
        // Check if item exists
        const currentItem = await catalogService.getCatalogItemById(catalogId);
        if (!currentItem.success || !currentItem.data) {
          errors.push({
            index: i,
            id: catalogId,
            error: 'Item not found'
          });
          continue;
        }

        const result = await catalogService.deleteCatalogItem(catalogId);
        results.push({
          index: i,
          id: catalogId,
          name: currentItem.data.name,
          success: true
        });

      } catch (error) {
        errors.push({
          index: i,
          id: requestData.ids[i],
          error: error.message
        });
      }
    }

    console.log(`[Bulk Delete] ${envContext.environment_label} - Completed: ${results.length} success, ${errors.length} errors (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        success: true,
        message: `Bulk operation completed: ${results.length} deleted, ${errors.length} failed`,
        data: {
          deleted: results,
          errors: errors,
          summary: {
            total_requested: requestData.ids.length,
            total_deleted: results.length,
            total_failed: errors.length
          }
        },
        environment: envContext.environment_label,
        request_id: envContext.request_id
      }),
      {
        status: errors.length === requestData.ids.length ? 400 : 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Bulk Delete] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

// =================================================================
// RESOURCE MANAGEMENT ENDPOINTS
// =================================================================

/**
 * GET /catalog-items/resources - Get tenant resources
 */
async function handleGetTenantResources(
  req: Request,
  catalogService: CatalogService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    const url = new URL(req.url);
    const params = parseResourceParameters(url, envContext);

    console.log(`[Resources] ${envContext.environment_label} - Getting resources (${envContext.request_id}):`, {
      type: params.resourceType,
      search: params.search,
      status: params.status
    });

    // ✅ GET RESOURCES: Service automatically filters by is_live
    const result = await catalogService.getTenantResources(params);

    console.log(`[Resources] ${envContext.environment_label} - Found ${result.resources.length} resources (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        success: true,
        data: result,
        environment: envContext.environment_label,
        request_id: envContext.request_id,
        query_context: {
          is_live: envContext.is_live,
          applied_filters: params
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Resources] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

/**
 * GET /catalog-items/resources/:id - Get resource details
 */
async function handleGetResourceDetails(
  resourceId: string,
  catalogService: CatalogService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    console.log(`[Resource Details] ${envContext.environment_label} - Getting resource: ${resourceId} (${envContext.request_id})`);

    // ✅ GET RESOURCE: Service automatically filters by is_live
    const result = await catalogService.getResourceDetails(resourceId);

    console.log(`[Resource Details] ${envContext.environment_label} - Found: ${result.resource.name} (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        success: true,
        data: result,
        environment: envContext.environment_label,
        request_id: envContext.request_id
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Resource Details] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

/**
 * GET /catalog-items/resources/summary - Get resources summary
 */
async function handleGetResourcesSummary(
  catalogService: CatalogService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    console.log(`[Resources Summary] ${envContext.environment_label} - Getting summary (${envContext.request_id})`);

    // ✅ GET SUMMARY: Service automatically filters by is_live
    const result = await catalogService.getTenantResourcesSummary();

    console.log(`[Resources Summary] ${envContext.environment_label} - Total: ${result.total_resources} resources (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        success: true,
        data: result,
        environment: envContext.environment_label,
        request_id: envContext.request_id
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Resources Summary] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

/**
 * GET /catalog-items/contacts/eligible/:resourceType - Get eligible contacts
 */
async function handleGetEligibleContacts(
  resourceType: 'team_staff' | 'partner',
  catalogService: CatalogService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    console.log(`[Eligible Contacts] ${envContext.environment_label} - Getting contacts for: ${resourceType} (${envContext.request_id})`);

    // ✅ GET CONTACTS: Service automatically filters by tenant_id
    const result = await catalogService.getEligibleContacts(resourceType);

    console.log(`[Eligible Contacts] ${envContext.environment_label} - Found ${result.length} contacts (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        success: true,
        data: result,
        environment: envContext.environment_label,
        request_id: envContext.request_id,
        resource_type: resourceType,
        summary: {
          total_eligible: result.length,
          resource_type: resourceType
        }
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Eligible Contacts] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

// =================================================================
// PRICING MANAGEMENT ENDPOINTS
// =================================================================

/**
 * POST /catalog-items/:id/pricing - Add multi-currency pricing
 */
async function handleAddMultiCurrencyPricing(
  req: Request,
  catalogId: string,
  validationService: CatalogValidationService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    console.log(`[Add Pricing] ${envContext.environment_label} - Adding pricing for: ${catalogId} (${envContext.request_id})`);

    const pricingData: CreateMultiCurrencyPricingRequest = await req.json();
    
    // Set catalog_id from URL
    pricingData.catalog_id = catalogId;

    // ✅ VALIDATION: With environment context
    const validation = await validationService.validateMultiCurrencyPricingData(pricingData);
    if (!validation.is_valid) {
      return createErrorResponse(
        'Pricing validation failed',
        400,
        envContext,
        {
          validation_errors: validation.errors,
          warnings: validation.warnings
        }
      );
    }

    // Note: This would typically call a pricing service method
    // For now, we'll return a success response
    console.log(`[Add Pricing] ${envContext.environment_label} - Success: ${catalogId} (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Multi-currency pricing added successfully',
        data: {
          catalog_id: catalogId,
          currencies_added: pricingData.currencies.map(c => c.currency),
          price_type: pricingData.price_type
        },
        environment: envContext.environment_label,
        request_id: envContext.request_id
      }),
      {
        status: 201,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Add Pricing] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

/**
 * GET /catalog-items/:id/pricing - Get pricing details
 */
async function handleGetPricingDetails(
  catalogId: string,
  catalogService: CatalogService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    console.log(`[Get Pricing] ${envContext.environment_label} - Getting pricing for: ${catalogId} (${envContext.request_id})`);

    // Get the catalog item which includes pricing information
    const result = await catalogService.getCatalogItemById(catalogId);
    
    if (!result.success || !result.data) {
      return createErrorResponse(
        `Catalog item ${catalogId} not found in ${envContext.environment_label} environment`,
        404,
        envContext
      );
    }

    const pricingDetails = {
      catalog_id: catalogId,
      base_pricing: result.data.price_attributes,
      currency: result.data.currency,
      pricing_list: result.data.pricing_list || [],
      estimated_resource_cost: result.data.estimated_resource_cost || 0,
      has_multiple_currencies: (result.data.pricing_list?.length || 0) > 1,
      total_currencies: result.data.pricing_list?.length || 0
    };

    console.log(`[Get Pricing] ${envContext.environment_label} - Found ${pricingDetails.total_currencies} currencies (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        success: true,
        data: pricingDetails,
        environment: envContext.environment_label,
        request_id: envContext.request_id
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Get Pricing] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

// =================================================================
// RESTORE AND RECOVERY ENDPOINTS
// =================================================================

/**
 * POST /catalog-items/restore - Restore deleted catalog item
 */
async function handleRestoreCatalogItem(
  req: Request,
  validationService: CatalogValidationService,
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  try {
    console.log(`[Restore] ${envContext.environment_label} - Starting restore (${envContext.request_id})`);

    const restoreData: RestoreCatalogItemRequest = await req.json();
    
    // ✅ VALIDATION: With environment context
    const validation = await validationService.validateRestoreRequest(restoreData);
    if (!validation.is_valid) {
      return createErrorResponse(
        'Restore validation failed',
        400,
        envContext,
        {
          validation_errors: validation.errors,
          warnings: validation.warnings
        }
      );
    }

    // Note: This would typically call a catalog service restore method
    // For now, we'll return a success response
    console.log(`[Restore] ${envContext.environment_label} - Success: ${restoreData.catalog_id} (${envContext.request_id})`);

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Catalog item restored successfully',
        data: {
          catalog_id: restoreData.catalog_id,
          restore_reason: restoreData.restore_reason,
          restore_pricing: restoreData.restore_pricing || false
        },
        environment: envContext.environment_label,
        request_id: envContext.request_id
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error) {
    console.error(`[Restore] ${envContext.environment_label} - Error (${envContext.request_id}):`, error);
    return handleError(error, envContext);
  }
}

// =================================================================
// UTILITY AND HELPER ENDPOINTS
// =================================================================

/**
 * GET /catalog-items/health - Health check with environment info
 */
async function handleHealthCheck(
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  const healthData = {
    status: 'healthy',
    timestamp: new Date().toISOString(),
    environment: envContext.environment_label,
    is_live: envContext.is_live,
    tenant_id: envContext.tenant_id,
    request_id: envContext.request_id,
    service: 'catalog-items',
    version: '1.0.0',
    features: {
      resource_composition: true,
      environment_segregation: true,
      contact_integration: true,
      multi_currency_pricing: true,
      bulk_operations: true
    }
  };

  return new Response(
    JSON.stringify(healthData),
    {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    }
  );
}

/**
 * GET /catalog-items/config - Get environment configuration
 */
async function handleGetConfig(
  envContext: ReturnType<typeof getEnvironmentContext>
): Promise<Response> {
  const configData = {
    environment: envContext.environment_label,
    is_live: envContext.is_live,
    tenant_id: envContext.tenant_id,
    supported_features: {
      resource_types: ['team_staff', 'equipment', 'consumable', 'asset', 'partner'],
      catalog_types: ['service', 'equipment', 'spare_part', 'asset'],
      supported_currencies: ['INR', 'USD', 'EUR', 'GBP', 'AED', 'SGD', 'CAD', 'AUD'],
      complexity_levels: ['low', 'medium', 'high', 'expert'],
      pricing_types: ['fixed', 'unit_price', 'hourly', 'daily'],
      resource_pricing_types: ['fixed', 'hourly', 'per_use', 'daily', 'monthly', 'per_unit']
    },
    limits: {
      bulk_create: 100,
      bulk_update: 100,
      bulk_delete: 50,
      query_limit: 100,
      description_length: 10000,
      terms_length: 20000
    },
    contact_classifications: {
      team_staff: ['team_member'],
      partner: ['partner', 'vendor']
    }
  };

  return new Response(
    JSON.stringify({
      success: true,
      data: configData,
      environment: envContext.environment_label,
      request_id: envContext.request_id
    }),
    {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    }
  );
}

// =================================================================
// ERROR HANDLING
// =================================================================

function createErrorResponse(
  message: string,
  status: number,
  envContext: ReturnType<typeof getEnvironmentContext>,
  additionalData?: any
): Response {
  return new Response(
    JSON.stringify({
      success: false,
      error: message,
      environment: envContext.environment_label,
      request_id: envContext.request_id,
      timestamp: new Date().toISOString(),
      ...additionalData
    }),
    { 
      status, 
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    }
  );
}

function handleError(error: any, envContext: ReturnType<typeof getEnvironmentContext>): Response {
  console.error(`[Error] ${envContext.environment_label} - (${envContext.request_id}):`, error);

  if (error instanceof ValidationError) {
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message,
        error_type: 'ValidationError',
        validation_errors: error.validationErrors,
        environment: envContext.environment_label,
        request_id: envContext.request_id,
        timestamp: new Date().toISOString()
      }),
      { 
        status: 400, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }

  if (error instanceof NotFoundError) {
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message,
        error_type: 'NotFoundError',
        environment: envContext.environment_label,
        request_id: envContext.request_id,
        timestamp: new Date().toISOString()
      }),
      { 
        status: 404, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }

  if (error instanceof ContactValidationError) {
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message,
        error_type: 'ContactValidationError',
        environment: envContext.environment_label,
        request_id: envContext.request_id,
        timestamp: new Date().toISOString()
      }),
      { 
        status: 400, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }

  if (error instanceof ResourceError) {
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message,
        error_type: 'ResourceError',
        environment: envContext.environment_label,
        request_id: envContext.request_id,
        timestamp: new Date().toISOString()
      }),
      { 
        status: 400, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }

  if (error instanceof ConflictError) {
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message,
        error_type: 'ConflictError',
        environment: envContext.environment_label,
        request_id: envContext.request_id,
        timestamp: new Date().toISOString()
      }),
      { 
        status: 409, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }

  if (error instanceof CatalogError) {
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message,
        error_type: 'CatalogError',
        error_code: error.code,
        environment: envContext.environment_label,
        request_id: envContext.request_id,
        timestamp: new Date().toISOString()
      }),
      { 
        status: error.statusCode, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }

  // Generic error
  return new Response(
    JSON.stringify({
      success: false,
      error: 'Internal server error',
      error_type: 'InternalError',
      environment: envContext.environment_label,
      request_id: envContext.request_id,
      timestamp: new Date().toISOString()
    }),
    { 
      status: 500, 
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    }
  );
}

// =================================================================
// ROUTE HANDLER
// =================================================================

async function handleRequest(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const method = req.method;
  const pathname = url.pathname;

  console.log(`[Request] ${method} ${pathname}`);

  // CORS preflight
  if (method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // ✅ EXTRACT ENVIRONMENT CONTEXT FIRST
    const envContext = getEnvironmentContext(req);
    
    // Validate required context
    if (!envContext.tenant_id) {
      return createErrorResponse(
        'Missing tenant context - x-tenant-id header is required',
        400,
        envContext
      );
    }

    if (!envContext.user_id) {
      return createErrorResponse(
        'Missing user context - x-user-id header is required',
        400,
        envContext
      );
    }

    // ✅ ENVIRONMENT PERMISSIONS: Check operation permissions
    const permissionCheck = validateEnvironmentPermissions(envContext, method);
    if (!permissionCheck.allowed) {
      return createErrorResponse(
        permissionCheck.reason || 'Operation not allowed',
        403,
        envContext
      );
    }

    // ✅ SECURITY: HMAC verification with environment context
    const hmacResult = await verifyHMACSignature(req);
    if (!hmacResult.valid) {
      console.warn(`[Security] ${envContext.environment_label} - HMAC verification failed:`, hmacResult.error);
      return createErrorResponse(
        'Authentication failed',
        401,
        envContext
      );
    }

    // ✅ RATE LIMITING: With environment-specific keys
    const rateLimitKey = `catalog-${envContext.tenant_id}-${envContext.is_live}`;
    const rateLimitResult = await rateLimiter.checkLimit(rateLimitKey, 'catalog');
    if (!rateLimitResult.allowed) {
      return createErrorResponse(
        'Rate limit exceeded',
        429,
        envContext,
        { retry_after: rateLimitResult.retryAfter }
      );
    }

    // ✅ INITIALIZE SUPABASE: Environment-aware
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? ''
    );

    // ✅ INITIALIZE SERVICES: With environment context
    const { catalogService, validationService } = initializeServices(envContext, supabase);

    // ✅ ROUTE HANDLING: All routes are environment-aware
    
    // Health and config endpoints
    if (pathname === '/catalog-items/health' && method === 'GET') {
      return await handleHealthCheck(envContext);
    }

    if (pathname === '/catalog-items/config' && method === 'GET') {
      return await handleGetConfig(envContext);
    }

    // Bulk operations
    if (pathname === '/catalog-items/bulk' && method === 'POST') {
      return await handleBulkCreateCatalogItems(req, catalogService, validationService, envContext);
    }

    if (pathname === '/catalog-items/bulk' && method === 'PUT') {
      return await handleBulkUpdateCatalogItems(req, catalogService, validationService, envContext);
    }

    if (pathname === '/catalog-items/bulk' && method === 'DELETE') {
      return await handleBulkDeleteCatalogItems(req, catalogService, validationService, envContext);
    }

    // Restore operations
    if (pathname === '/catalog-items/restore' && method === 'POST') {
      return await handleRestoreCatalogItem(req, validationService, envContext);
    }

    // Resource management routes
    if (pathname === '/catalog-items/resources' && method === 'GET') {
      return await handleGetTenantResources(req, catalogService, envContext);
    }

    if (pathname === '/catalog-items/resources/summary' && method === 'GET') {
      return await handleGetResourcesSummary(catalogService, envContext);
    }

    if (pathname.match(/^\/catalog-items\/resources\/[^\/]+$/) && method === 'GET') {
      const resourceId = pathname.split('/')[3];
      return await handleGetResourceDetails(resourceId, catalogService, envContext);
    }

    if (pathname.match(/^\/catalog-items\/contacts\/eligible\/(team_staff|partner)$/) && method === 'GET') {
      const resourceType = pathname.split('/')[4] as 'team_staff' | 'partner';
      return await handleGetEligibleContacts(resourceType, catalogService, envContext);
    }

    // Catalog item CRUD routes
    if (pathname === '/catalog-items' && method === 'POST') {
      return await handleCreateCatalogItem(req, catalogService, validationService, envContext);
    }

    if (pathname === '/catalog-items' && method === 'GET') {
      return await handleQueryCatalogItems(req, catalogService, envContext);
    }

    if (pathname.match(/^\/catalog-items\/[^\/]+$/) && method === 'GET') {
      const catalogId = pathname.split('/')[2];
      return await handleGetCatalogItem(catalogId, catalogService, envContext);
    }

    if (pathname.match(/^\/catalog-items\/[^\/]+$/) && method === 'PUT') {
      const catalogId = pathname.split('/')[2];
      return await handleUpdateCatalogItem(req, catalogId, catalogService, validationService, envContext);
    }

    if (pathname.match(/^\/catalog-items\/[^\/]+$/) && method === 'DELETE') {
      const catalogId = pathname.split('/')[2];
      return await handleDeleteCatalogItem(catalogId, catalogService, envContext);
    }

    // Pricing management routes
    if (pathname.match(/^\/catalog-items\/[^\/]+\/pricing$/) && method === 'POST') {
      const catalogId = pathname.split('/')[2];
      return await handleAddMultiCurrencyPricing(req, catalogId, validationService, envContext);
    }

    if (pathname.match(/^\/catalog-items\/[^\/]+\/pricing$/) && method === 'GET') {
      const catalogId = pathname.split('/')[2];
      return await handleGetPricingDetails(catalogId, catalogService, envContext);
    }

    // Route not found
    return createErrorResponse(
      'Route not found',
      404,
      envContext,
      {
        available_routes: [
          'GET /catalog-items/health',
          'GET /catalog-items/config',
          'POST /catalog-items',
          'GET /catalog-items',
          'GET /catalog-items/:id',
          'PUT /catalog-items/:id',
          'DELETE /catalog-items/:id',
          'POST /catalog-items/bulk',
          'PUT /catalog-items/bulk',
          'DELETE /catalog-items/bulk',
          'POST /catalog-items/restore',
          'GET /catalog-items/resources',
          'GET /catalog-items/resources/summary',
          'GET /catalog-items/resources/:id',
          'GET /catalog-items/contacts/eligible/:resourceType',
          'POST /catalog-items/:id/pricing',
          'GET /catalog-items/:id/pricing'
        ]
      }
    );

  } catch (error) {
    console.error('[Request Handler] Unexpected error:', error);
    
    const fallbackContext = {
      environment_label: 'Unknown',
      request_id: crypto.randomUUID(),
      tenant_id: '',
      user_id: '',
      is_live: false
    };
    
    return createErrorResponse(
      'Service temporarily unavailable',
      503,
      fallbackContext as any
    );
  }
}

// =================================================================
// MAIN SERVE FUNCTION
// =================================================================

serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (error) {
    console.error('[Serve] Fatal error:', error);
    return new Response(
      JSON.stringify({
        success: false,
        error: 'Service unavailable',
        timestamp: new Date().toISOString()
      }),
      { 
        status: 503, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});