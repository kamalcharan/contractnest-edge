import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { corsHeaders } from '../_shared/cors.ts';
import { ServiceCatalogService } from '../_shared/serviceCatalog/serviceCatalogService.ts';
import { ServiceCatalogSecurity } from '../_shared/serviceCatalog/serviceCatalogSecurity.ts';
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

console.log('🚀 Service Catalog Edge Function - Starting up');

serve(async (req: Request) => {
  const startTime = Date.now();
  const requestId = ServiceCatalogUtils.generateRequestId();
  
  console.log('📨 Service Catalog - Incoming request:', {
    method: req.method,
    url: req.url,
    requestId,
    timestamp: new Date().toISOString()
  });

  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    console.log('✅ Service Catalog - CORS preflight response');
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const internalSigningSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');

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

    // Extract security headers
    const securityHeaders = ServiceCatalogSecurity.extractSecurityHeaders(req);
    const { tenantId, userId, ipAddress, userAgent } = securityHeaders;

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

    // HMAC verification
    const hmacVerification = await ServiceCatalogSecurity.verifyHMACSignature(
      req, 
      body, 
      internalSigningSecret
    );

    if (!hmacVerification.isValid) {
      console.warn('⚠️ Service Catalog - HMAC verification failed:', hmacVerification.error);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: { code: 'HMAC_VERIFICATION_FAILED', message: hmacVerification.error } 
        }),
        { 
          status: 401, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Rate limiting
    const database = new ServiceCatalogDatabase(supabase);
    const url = new URL(req.url);
    const operation = url.pathname.split('/').pop() || 'unknown';
    const rateLimit = ServiceCatalogSecurity.getRateLimitForOperation(operation);
    
    const rateLimitInfo = await database.checkRateLimit(
      tenantId, 
      userId, 
      operation, 
      rateLimit.requests, 
      rateLimit.windowMinutes
    );

    if (rateLimitInfo.is_limited) {
      console.warn('⚠️ Service Catalog - Rate limit exceeded:', {
        tenantId,
        userId,
        operation,
        requestsMade: rateLimitInfo.requests_made,
        limit: rateLimitInfo.requests_limit
      });

      return new Response(
        JSON.stringify({ 
          success: false, 
          error: { 
            code: 'RATE_LIMIT_EXCEEDED', 
            message: 'Rate limit exceeded',
            metadata: {
              requests_made: rateLimitInfo.requests_made,
              requests_limit: rateLimitInfo.requests_limit,
              reset_time: rateLimitInfo.reset_time
            }
          } 
        }),
        { 
          status: 429, 
          headers: { 
            ...corsHeaders, 
            'Content-Type': 'application/json',
            'X-RateLimit-Remaining': String(rateLimitInfo.requests_limit - rateLimitInfo.requests_made),
            'X-RateLimit-Reset': rateLimitInfo.reset_time
          } 
        }
      );
    }

    // Record rate limit request
    await database.recordRateLimitRequest(tenantId, userId, operation, ipAddress);

    // Create environment context
    const environmentContext = ServiceCatalogUtils.createEnvironmentContext(
      tenantId,
      userId,
      true, // assuming live environment, adjust based on your logic
      requestId,
      ipAddress,
      userAgent
    );

    // Initialize services
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
      userId
    });

    let response: ServiceCatalogApiResponse;

    // Handle different routes and methods
    if (pathname.includes('/services') && method === 'POST' && !pathname.includes('/bulk')) {
      // Create single service
      const validation = ServiceCatalogValidator.validateServiceCatalogItem(requestData);
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
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.createService(requestData, environmentContext);

    } else if (pathname.includes('/services/') && method === 'GET') {
      // Get single service
      const serviceId = pathname.split('/').pop();
      if (!serviceId || !ServiceCatalogSecurity.validateUUID(serviceId)) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { code: 'INVALID_SERVICE_ID', message: 'Invalid service ID format' } 
          }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.getService(serviceId, environmentContext);

    } else if (pathname.includes('/services/') && method === 'PUT') {
      // Update single service
      const serviceId = pathname.split('/').pop();
      if (!serviceId || !ServiceCatalogSecurity.validateUUID(serviceId)) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { code: 'INVALID_SERVICE_ID', message: 'Invalid service ID format' } 
          }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      const validation = ServiceCatalogValidator.validateServiceCatalogItem(requestData);
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
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.updateService(serviceId, requestData, environmentContext);

    } else if (pathname.includes('/services/') && method === 'DELETE') {
      // Delete single service
      const serviceId = pathname.split('/').pop();
      if (!serviceId || !ServiceCatalogSecurity.validateUUID(serviceId)) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { code: 'INVALID_SERVICE_ID', message: 'Invalid service ID format' } 
          }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.deleteService(serviceId, environmentContext);

    } else if (pathname.includes('/services') && method === 'GET') {
      // Query services
      const filters = ServiceCatalogSecurity.sanitizeFilters(Object.fromEntries(url.searchParams));
      const validation = ServiceCatalogValidator.validateServiceFilters(filters);
      
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
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.queryServices(filters, environmentContext);

    } else if (pathname.includes('/services/bulk') && method === 'POST') {
      // Bulk operations
      const validation = ServiceCatalogValidator.validateBulkOperation(requestData);
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
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
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
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

    } else if (pathname.includes('/master-data') && method === 'GET') {
      // Get master data
      response = await serviceCatalogService.getMasterData(environmentContext);

    } else if (pathname.includes('/resources') && method === 'GET') {
      // Get available resources
      const filters = ServiceCatalogSecurity.sanitizeFilters(Object.fromEntries(url.searchParams));
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
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      response = await serviceCatalogService.associateServiceResources([requestData], environmentContext);

    } else if (pathname.includes('/services/') && pathname.includes('/resources') && method === 'GET') {
      // Get service resources
      const pathParts = pathname.split('/');
      const serviceId = pathParts[pathParts.indexOf('services') + 1];
      
      if (!serviceId || !ServiceCatalogSecurity.validateUUID(serviceId)) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: { code: 'INVALID_SERVICE_ID', message: 'Invalid service ID format' } 
          }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
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
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
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
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Add execution metadata
    const executionTime = Date.now() - startTime;
    response.metadata = {
      ...response.metadata,
      request_id: requestId,
      execution_time_ms: executionTime,
      environment: environmentContext.is_live ? 'live' : 'test',
      rate_limit: {
        remaining: rateLimitInfo.requests_limit - rateLimitInfo.requests_made - 1,
        reset_time: rateLimitInfo.reset_time
      }
    };

    console.log('✅ Service Catalog - Request completed successfully:', {
      requestId,
      executionTime,
      success: response.success,
      statusCode: response.success ? 200 : (response.error?.code === 'NOT_FOUND' ? 404 : 400)
    });

    // Return response
    const statusCode = response.success ? 200 : (response.error?.code === 'NOT_FOUND' ? 404 : 400);
    
    return new Response(
      JSON.stringify(response),
      {
        status: statusCode,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json',
          'X-Request-ID': requestId,
          'X-Execution-Time': String(executionTime),
          'X-RateLimit-Remaining': String(rateLimitInfo.requests_limit - rateLimitInfo.requests_made - 1),
          'X-RateLimit-Reset': rateLimitInfo.reset_time
        }
      }
    );

  } catch (error) {
    const executionTime = Date.now() - startTime;
    console.error('❌ Service Catalog - Unhandled error:', error);

    return new Response(
      JSON.stringify({ 
        success: false, 
        error: { 
          code: 'INTERNAL_ERROR', 
          message: 'Internal server error' 
        },
        metadata: {
          request_id: requestId,
          execution_time_ms: executionTime,
          environment: 'unknown'
        }
      }),
      { 
        status: 500, 
        headers: { 
          ...corsHeaders, 
          'Content-Type': 'application/json',
          'X-Request-ID': requestId,
          'X-Execution-Time': String(executionTime)
        } 
      }
    );
  }
});

console.log('🎯 Service Catalog Edge Function - Ready to serve requests');