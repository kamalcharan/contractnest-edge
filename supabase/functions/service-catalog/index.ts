import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { corsHeaders } from '../_shared/cors.ts';

// Import shared global configuration modules
import { TenantConfigManager } from '../_shared/globalConfig/tenantConfigManager.ts';
import { GlobalRateLimits } from '../_shared/globalConfig/globalRateLimits.ts';
import { GlobalSecuritySettings } from '../_shared/globalConfig/globalSecuritySettings.ts';
import { GlobalMonitoring } from '../_shared/globalConfig/globalMonitoring.ts';
import type { EdgeFunction } from '../_shared/globalConfig/types.ts';

// Import service-catalog specific modules (simplified)
import { ServiceCatalogService } from '../_shared/serviceCatalog/serviceCatalogService.ts';
import { ServiceCatalogValidator } from '../_shared/serviceCatalog/serviceCatalogValidation.ts';
import { ServiceCatalogUtils } from '../_shared/serviceCatalog/serviceCatalogUtils.ts';
import { ServiceCatalogDatabase } from '../_shared/serviceCatalog/serviceCatalogDatabase.ts';
import { CacheManager } from '../_shared/serviceCatalog/serviceCatalogCache.ts';
import type { 
  ServiceCatalogItemData, 
  ServiceCatalogFilters, 
  ServiceResourceAssociation,
  BulkServiceOperation,
  ServicePricingUpdate,
  ServiceCatalogApiResponse
} from '../_shared/serviceCatalog/serviceCatalogTypes.ts';

console.log('🚀 Service Catalog Edge Function - Starting up with global configuration');

serve(async (req: Request) => {
  const startTime = Date.now();
  const operationId = `op_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
  
  console.log('📨 Service Catalog - Incoming request:', {
    method: req.method,
    url: req.url,
    operationId,
    timestamp: new Date().toISOString()
  });

  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    console.log('✅ Service Catalog - CORS preflight response');
    return new Response('ok', { headers: corsHeaders });
  }

  let tenantId: string | undefined;
  let userId: string | undefined;
  let securityHeaders: Record<string, string> = {};

  try {
    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    if (!supabaseUrl || !supabaseServiceKey) {
      console.error('❌ Service Catalog - Missing environment variables');
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: { code: 'CONFIGURATION_ERROR', message: 'Missing required environment variables' } 
        }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Initialize global configuration managers
    const configManager = TenantConfigManager.getInstance(supabase);
    GlobalRateLimits.initialize(supabase);
    GlobalSecuritySettings.initialize(configManager);
    GlobalMonitoring.initialize(supabase, configManager);

    // Extract security headers
    tenantId = req.headers.get('x-tenant-id') || undefined;
    userId = req.headers.get('x-user-id') || undefined;
    const ipAddress = req.headers.get('x-forwarded-for') || 
                     req.headers.get('x-real-ip') || 
                     req.headers.get('cf-connecting-ip');
    const userAgent = req.headers.get('user-agent');

    if (!tenantId || !userId) {
      console.warn('⚠️ Service Catalog - Missing required headers');
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: { code: 'MISSING_HEADERS', message: 'Missing tenant ID or user ID headers' } 
        }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Read request body
    const body = await req.text();
    let requestData: any = {};
    
    if (body) {
      try {
        requestData = JSON.parse(body);
      } catch (error) {
        console.error('❌ Service Catalog - Invalid JSON in request body:', error);
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { code: 'INVALID_JSON', message: 'Invalid JSON in request body' } 
          }),
          { 
            status: 400, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        );
      }
    }

    // Define edge function
    const edgeFunction: EdgeFunction = 'service-catalog';

    // 1. SECURITY VALIDATION
    console.log('🔐 Service Catalog - Validating security requirements');
    
    const securityValidation = await GlobalSecuritySettings.validateRequest({
      tenant_id: tenantId,
      user_id: userId,
      edge_function: edgeFunction,
      request: req,
      body,
      ip_address: ipAddress || undefined,
      user_agent: userAgent || undefined
    });

    if (!securityValidation.isValid) {
      await GlobalMonitoring.logOperation({
        operation_id: operationId,
        tenant_id: tenantId,
        user_id: userId,
        edge_function: edgeFunction,
        operation_type: 'security_validation',
        execution_time_ms: Date.now() - startTime,
        success: false,
        error_code: 'SECURITY_VALIDATION_FAILED',
        error_message: securityValidation.errors.join(', '),
        ip_address: ipAddress || undefined,
        user_agent: userAgent || undefined,
        created_at: new Date().toISOString()
      });

      return new Response(
        JSON.stringify({ 
          success: false, 
          error: { 
            code: 'SECURITY_VALIDATION_FAILED', 
            message: 'Security validation failed',
            details: securityValidation.errors
          } 
        }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Get security headers for response
    securityHeaders = await GlobalSecuritySettings.getSecurityHeaders(tenantId, edgeFunction);

    // 2. RATE LIMITING
    console.log('🚦 Service Catalog - Checking rate limits');
    
    const url = new URL(req.url);
    const operation = url.pathname.split('/').pop() || 'unknown';
    
    const rateLimitResult = await GlobalRateLimits.checkRateLimit(supabase, {
      tenant_id: tenantId,
      user_id: userId,
      edge_function: edgeFunction,
      operation,
      ip_address: ipAddress || undefined,
      user_agent: userAgent || undefined
    });

    if (!rateLimitResult.isAllowed) {
      await GlobalMonitoring.logOperation({
        operation_id: operationId,
        tenant_id: tenantId,
        user_id: userId,
        edge_function: edgeFunction,
        operation_type: operation,
        execution_time_ms: Date.now() - startTime,
        success: false,
        error_code: 'RATE_LIMIT_EXCEEDED',
        error_message: 'Rate limit exceeded',
        ip_address: ipAddress || undefined,
        user_agent: userAgent || undefined,
        created_at: new Date().toISOString()
      });

      return new Response(
        JSON.stringify({ 
          success: false, 
          error: { 
            code: 'RATE_LIMIT_EXCEEDED', 
            message: 'Rate limit exceeded',
            context: {
              requests_remaining: rateLimitResult.requestsRemaining,
              reset_time: rateLimitResult.resetTime
            }
          } 
        }),
        { 
          status: 429, 
          headers: { 
            ...corsHeaders, 
            ...securityHeaders,
            'Content-Type': 'application/json',
            'X-RateLimit-Remaining': String(rateLimitResult.requestsRemaining),
            'X-RateLimit-Reset': rateLimitResult.resetTime
          } 
        }
      );
    }

    // Record the rate limit request
    await GlobalRateLimits.recordRequest(supabase, {
      tenant_id: tenantId,
      user_id: userId,
      edge_function: edgeFunction,
      operation,
      ip_address: ipAddress || undefined,
      user_agent: userAgent || undefined
    });

    // 3. GET TENANT CONFIGURATION
    console.log('🏢 Service Catalog - Loading tenant configuration');
    
    const { config, globalSettings, planType } = await configManager.getConfig(tenantId, edgeFunction);
    
    console.log('✅ Service Catalog - Configuration loaded:', {
      tenantId,
      planType,
      securityLevel: globalSettings.security_level,
      maxBulkItems: config.bulk_operation_limits?.max_items_per_bulk || 'unlimited'
    });

    // 4. DYNAMIC ENVIRONMENT DETECTION
    const environmentInfo = ServiceCatalogUtils.detectEnvironment(req);
    
    console.log('🌍 Service Catalog - Environment detected:', {
      isLive: environmentInfo.is_live,
      environmentName: environmentInfo.environment_name,
      detectedFrom: environmentInfo.detected_from,
      confidence: environmentInfo.confidence_level
    });

    // 5. CREATE ENVIRONMENT CONTEXT
    const environmentContext = ServiceCatalogUtils.createEnvironmentContext(
      tenantId,
      userId,
      environmentInfo,
      operationId,
      ipAddress || undefined,
      userAgent || undefined
    );

    // Initialize services
    const database = new ServiceCatalogDatabase(supabase);
    const cacheManager = new CacheManager();
    const serviceCatalogService = new ServiceCatalogService(supabase, database, cacheManager);

    // Route handling
    const method = req.method;
    const pathname = url.pathname;

    console.log('🎯 Service Catalog - Processing request:', {
      method,
      pathname,
      operation,
      tenantId,
      userId,
      environment: environmentInfo.environment_name,
      planType
    });

    let response: ServiceCatalogApiResponse;

    // Handle different routes and methods
    if (pathname.includes('/services') && method === 'POST' && !pathname.includes('/bulk')) {
      // Create single service
      const validation = ServiceCatalogValidator.validateServiceCatalogItem(requestData, config);
      if (!validation.isValid) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { 
              code: 'VALIDATION_ERROR', 
              message: 'Validation failed',
              details: validation.errors.map(e => ({ field: e.field, message: e.message }))
            } 
          }),
          { status: 400, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.createService(requestData, environmentContext);

    } else if (pathname.includes('/services/') && method === 'GET') {
      // Get single service
      const serviceId = pathname.split('/').pop();
      if (!serviceId || !GlobalSecuritySettings.sanitizeInput(serviceId).match(/^[0-9a-f-]{36}$/)) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { code: 'INVALID_SERVICE_ID', message: 'Invalid service ID format' } 
          }),
          { status: 400, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.getService(serviceId, environmentContext);

    } else if (pathname.includes('/services/') && method === 'PUT') {
      // Update single service
      const serviceId = pathname.split('/').pop();
      if (!serviceId || !GlobalSecuritySettings.sanitizeInput(serviceId).match(/^[0-9a-f-]{36}$/)) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { code: 'INVALID_SERVICE_ID', message: 'Invalid service ID format' } 
          }),
          { status: 400, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }

      const validation = ServiceCatalogValidator.validateServiceCatalogItem(requestData, config);
      if (!validation.isValid) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { 
              code: 'VALIDATION_ERROR', 
              message: 'Validation failed',
              details: validation.errors.map(e => ({ field: e.field, message: e.message }))
            } 
          }),
          { status: 400, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.updateService(serviceId, requestData, environmentContext);

    } else if (pathname.includes('/services/') && method === 'DELETE') {
      // Delete single service
      const serviceId = pathname.split('/').pop();
      if (!serviceId || !GlobalSecuritySettings.sanitizeInput(serviceId).match(/^[0-9a-f-]{36}$/)) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { code: 'INVALID_SERVICE_ID', message: 'Invalid service ID format' } 
          }),
          { status: 400, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.deleteService(serviceId, environmentContext);

    } else if (pathname.includes('/services') && method === 'GET') {
      // Query services with global validation
      const rawFilters = Object.fromEntries(url.searchParams);
      const filters = this.sanitizeFiltersWithGlobalConfig(rawFilters, config);
      
      const validation = ServiceCatalogValidator.validateServiceFilters(filters, config);
      if (!validation.isValid) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { 
              code: 'VALIDATION_ERROR', 
              message: 'Filter validation failed',
              details: validation.errors.map(e => ({ field: e.field, message: e.message }))
            } 
          }),
          { status: 400, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.queryServices(filters, environmentContext);

    } else if (pathname.includes('/services/bulk') && method === 'POST') {
      // Enhanced bulk operations with global limits
      console.log('📦 Service Catalog - Processing bulk operation:', {
        itemsCount: requestData.items?.length || 0,
        operationType: requestData.operation_type,
        planType,
        maxAllowed: config.bulk_operation_limits?.max_items_per_bulk || 'unlimited'
      });

      // Validate bulk operation limits using global config
      if (config.bulk_operation_limits && requestData.items?.length > config.bulk_operation_limits.max_items_per_bulk) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { 
              code: 'BULK_LIMIT_EXCEEDED', 
              message: `Bulk operation exceeds plan limit. Max allowed: ${config.bulk_operation_limits.max_items_per_bulk}, requested: ${requestData.items?.length}`,
              context: {
                plan_type: planType,
                max_allowed: config.bulk_operation_limits.max_items_per_bulk,
                requested: requestData.items?.length || 0
              }
            } 
          }),
          { status: 400, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Validate bulk operation structure
      const validation = ServiceCatalogValidator.validateBulkOperation(requestData, config);
      if (!validation.isValid) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { 
              code: 'VALIDATION_ERROR', 
              message: 'Bulk operation validation failed',
              details: validation.errors.map(e => ({ field: e.field, message: e.message }))
            } 
          }),
          { status: 400, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }

      if (requestData.operation_type === 'create') {
        response = await serviceCatalogService.bulkCreateServices(requestData, environmentContext);
      } else if (requestData.operation_type === 'update') {
        response = await serviceCatalogService.bulkUpdateServices(requestData, environmentContext);
      } else {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { code: 'INVALID_OPERATION', message: 'Invalid bulk operation type' } 
          }),
          { status: 400, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }

    } else if (pathname.includes('/master-data') && method === 'GET') {
      // Get master data
      response = await serviceCatalogService.getMasterData(environmentContext);

    } else if (pathname.includes('/resources') && method === 'GET') {
      // Get available resources
      const rawFilters = Object.fromEntries(url.searchParams);
      const filters = this.sanitizeFiltersWithGlobalConfig(rawFilters, config);
      response = await serviceCatalogService.getAvailableResources(filters, environmentContext);

    } else if (pathname.includes('/resources/associate') && method === 'POST') {
      // Associate service resources
      const validation = ServiceCatalogValidator.validateServiceResourceAssociation(requestData);
      if (!validation.isValid) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { 
              code: 'VALIDATION_ERROR', 
              message: 'Resource association validation failed',
              details: validation.errors.map(e => ({ field: e.field, message: e.message }))
            } 
          }),
          { status: 400, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.associateServiceResources([requestData], environmentContext);

    } else if (pathname.includes('/services/') && pathname.includes('/resources') && method === 'GET') {
      // Get service resources
      const pathParts = pathname.split('/');
      const serviceId = pathParts[pathParts.indexOf('services') + 1];
      
      if (!serviceId || !GlobalSecuritySettings.sanitizeInput(serviceId).match(/^[0-9a-f-]{36}$/)) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { code: 'INVALID_SERVICE_ID', message: 'Invalid service ID format' } 
          }),
          { status: 400, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.getServiceResources(serviceId, environmentContext);

    } else if (pathname.includes('/pricing') && method === 'PUT') {
      // Update service pricing
      const validation = ServiceCatalogValidator.validateServicePricingUpdate(requestData);
      if (!validation.isValid) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { 
              code: 'VALIDATION_ERROR', 
              message: 'Pricing update validation failed',
              details: validation.errors.map(e => ({ field: e.field, message: e.message }))
            } 
          }),
          { status: 400, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.updateServicePricing(requestData, environmentContext);

    } else {
      // Unknown route
      console.warn('⚠️ Service Catalog - Unknown route:', { method, pathname });
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: { code: 'ROUTE_NOT_FOUND', message: 'Route not found' } 
        }),
        { status: 404, headers: { ...corsHeaders, ...securityHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 6. LOG SUCCESSFUL OPERATION
    const executionTime = Date.now() - startTime;
    
    await GlobalMonitoring.logOperation({
      operation_id: operationId,
      tenant_id: tenantId,
      user_id: userId,
      edge_function: edgeFunction,
      operation_type: operation,
      execution_time_ms: executionTime,
      success: response.success,
      error_code: response.error?.code,
      error_message: response.error?.message,
      request_size_bytes: body ? new Blob([body]).size : 0,
      response_size_bytes: new Blob([JSON.stringify(response)]).size,
      ip_address: ipAddress || undefined,
      user_agent: userAgent || undefined,
      created_at: new Date().toISOString()
    });

    // Record custom metrics
    if (response.success) {
      await GlobalMonitoring.recordCustomMetric(
        tenantId,
        edgeFunction,
        'successful_operations',
        1,
        'count',
        { operation, plan_type: planType }
      );
    }

    // Add execution metadata
    response.metadata = {
      ...response.metadata,
      request_id: operationId,
      execution_time_ms: executionTime,
      environment: environmentContext.is_live ? 'live' : 'test',
      rate_limit: {
        remaining: rateLimitResult.requestsRemaining,
        reset_time: rateLimitResult.resetTime
      }
    };

    console.log('✅ Service Catalog - Request completed successfully:', {
      operationId,
      executionTime,
      success: response.success,
      statusCode: response.success ? 200 : (response.error?.code === 'NOT_FOUND' ? 404 : 400),
      planType,
      environment: environmentInfo.environment_name,
      detectionConfidence: environmentInfo.confidence_level
    });

    // Return response with security headers
    const statusCode = response.success ? 200 : (response.error?.code === 'NOT_FOUND' ? 404 : 400);
    
    return new Response(
      JSON.stringify(response),
      {
        status: statusCode,
        headers: {
          ...corsHeaders,
          ...securityHeaders,
          'Content-Type': 'application/json',
          'X-Operation-ID': operationId,
          'X-Execution-Time': String(executionTime),
          'X-Environment': environmentInfo.environment_name,
          'X-Environment-Detection': environmentInfo.detected_from,
          'X-Environment-Confidence': environmentInfo.confidence_level,
          'X-Tenant-Plan': planType,
          'X-RateLimit-Remaining': String(rateLimitResult.requestsRemaining),
          'X-RateLimit-Reset': rateLimitResult.resetTime
        }
      }
    );

  } catch (error) {
    const executionTime = Date.now() - startTime;
    console.error('❌ Service Catalog - Unhandled error:', error);

    // Log error if we have tenant info
    if (tenantId && userId) {
      await GlobalMonitoring.logOperation({
        operation_id: operationId,
        tenant_id: tenantId,
        user_id: userId,
        edge_function: 'service-catalog',
        operation_type: 'error',
        execution_time_ms: executionTime,
        success: false,
        error_code: 'INTERNAL_ERROR',
        error_message: error instanceof Error ? error.message : 'Unknown error',
        created_at: new Date().toISOString()
      });
    }

    return new Response(
      JSON.stringify({ 
        success: false, 
        error: { 
          code: 'INTERNAL_ERROR', 
          message: 'Internal server error' 
        },
        metadata: {
          request_id: operationId,
          execution_time_ms: executionTime,
          environment: 'unknown'
        }
      }),
      { 
        status: 500, 
        headers: { 
          ...corsHeaders, 
          ...securityHeaders,
          'Content-Type': 'application/json',
          'X-Operation-ID': operationId,
          'X-Execution-Time': String(executionTime)
        } 
      }
    );
  }

  // Helper function for sanitizing filters with global config
  function sanitizeFiltersWithGlobalConfig(filters: any, config: any): any {
    const sanitized: any = {};

    if (filters.search_term) {
      sanitized.search_term = GlobalSecuritySettings.sanitizeInput(
        filters.search_term,
        { 
          maxLength: config.validation_limits.max_name_length,
          allowedPattern: /^[a-zA-Z0-9\s\-_.]+$/,
          removeHtml: true,
          removeScripts: true
        }
      );
    }

    if (filters.category_id) {
      sanitized.category_id = GlobalSecuritySettings.sanitizeInput(filters.category_id);
    }

    if (filters.industry_id) {
      sanitized.industry_id = GlobalSecuritySettings.sanitizeInput(filters.industry_id);
    }

    if (typeof filters.is_active === 'boolean') {
      sanitized.is_active = filters.is_active;
    }

    if (typeof filters.price_min === 'number' && filters.price_min >= 0) {
      sanitized.price_min = Math.max(0, Math.min(config.validation_limits.max_number_value, filters.price_min));
    }

    if (typeof filters.price_max === 'number' && filters.price_max >= 0) {
      sanitized.price_max = Math.max(0, Math.min(config.validation_limits.max_number_value, filters.price_max));
    }

    if (filters.currency) {
      sanitized.currency = GlobalSecuritySettings.sanitizeInput(filters.currency, {
        maxLength: 3,
        allowedPattern: /^[A-Z]{3}$/
      });
    }

    if (typeof filters.has_resources === 'boolean') {
      sanitized.has_resources = filters.has_resources;
    }

    if (typeof filters.duration_min === 'number' && filters.duration_min > 0) {
      sanitized.duration_min = Math.max(1, Math.min(525600, filters.duration_min));
    }

    if (typeof filters.duration_max === 'number' && filters.duration_max > 0) {
      sanitized.duration_max = Math.max(1, Math.min(525600, filters.duration_max));
    }

    if (Array.isArray(filters.tags)) {
      sanitized.tags = filters.tags
        .filter(tag => typeof tag === 'string')
        .map(tag => GlobalSecuritySettings.sanitizeInput(tag, { maxLength: 50 }))
        .filter(tag => tag.length > 0)
        .slice(0, config.validation_limits.max_items_per_request || 10);
    }

    if (filters.sort_by) {
      const allowedSorts = ['name', 'price', 'created_at', 'sort_order', 'usage_count', 'avg_rating'];
      if (allowedSorts.includes(filters.sort_by)) {
        sanitized.sort_by = filters.sort_by;
      }
    }

    if (filters.sort_direction) {
      const allowedDirections = ['asc', 'desc'];
      if (allowedDirections.includes(filters.sort_direction)) {
        sanitized.sort_direction = filters.sort_direction;
      }
    }

    sanitized.limit = Math.min(
      config.validation_limits.max_search_results, 
      Math.max(1, parseInt(filters.limit) || 50)
    );
    sanitized.offset = Math.max(0, parseInt(filters.offset) || 0);

    return sanitized;
  }
});

console.log('🎯 Service Catalog Edge Function - Ready with global configuration system');