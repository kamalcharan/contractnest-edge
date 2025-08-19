import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { ServiceCatalogDatabase } from './serviceCatalogDatabase.ts';
import { CacheManager, ServiceCatalogCacheKeys } from './serviceCatalogCache.ts';
import { ServiceCatalogValidator } from './serviceCatalogValidation.ts';
import { ServiceCatalogUtils } from './serviceCatalogUtils.ts';
import { ServiceCatalogSecurity } from './serviceCatalogSecurity.ts';
import type {
  ServiceCatalogItemData,
  ServiceCatalogItem,
  ServiceCatalogFilters,
  ServiceCatalogResponse,
  ServiceResourceAssociation,
  BulkServiceOperation,
  BulkOperationResult,
  ServicePricingUpdate,
  MasterDataResponse,
  ResourceSearchResponse,
  ServiceResourceSummary,
  EnvironmentContext,
  ServiceCatalogApiResponse,
  ServiceCatalogError
} from './serviceCatalogTypes.ts';

export class ServiceCatalogService {
  
  constructor(
    private supabase: SupabaseClient,
    private database: ServiceCatalogDatabase,
    private cacheManager: CacheManager
  ) {
    console.log('🏗️ ServiceCatalogService - initialized');
  }

  async createService(
    serviceData: ServiceCatalogItemData,
    context: EnvironmentContext
  ): Promise<ServiceCatalogApiResponse<ServiceCatalogItem>> {
    console.log('🔨 ServiceCatalogService - creating service:', {
      serviceName: serviceData.service_name,
      tenantId: context.tenant_id,
      userId: context.user_id
    });

    const startTime = Date.now();

    try {
      // Generate slug and prepare data
      const slug = ServiceCatalogUtils.generateSlug(serviceData.service_name);
      const serviceId = crypto.randomUUID();

      const serviceRecord = {
        id: serviceId,
        tenant_id: context.tenant_id,
        slug,
        service_name: serviceData.service_name,
        description: serviceData.description,
        sku: serviceData.sku,
        category_id: serviceData.category_id,
        industry_id: serviceData.industry_id,
        pricing_config: serviceData.pricing_config,
        service_attributes: serviceData.service_attributes || {},
        duration_minutes: serviceData.duration_minutes,
        is_active: serviceData.is_active !== false,
        sort_order: serviceData.sort_order || 1,
        required_resources: serviceData.required_resources || [],
        tags: serviceData.tags || [],
        is_live: context.is_live,
        created_by: context.user_id,
        updated_by: context.user_id,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      };

      // Check for duplicate SKU or name
      const duplicateCheck = await this.checkDuplicates(
        serviceData.service_name,
        serviceData.sku,
        context.tenant_id,
        context.is_live
      );

      if (!duplicateCheck.isUnique) {
        return {
          success: false,
          error: {
            code: duplicateCheck.duplicateType === 'sku' ? 'DUPLICATE_SKU' : 'DUPLICATE_NAME',
            message: `Service with this ${duplicateCheck.duplicateType} already exists`
          }
        };
      }

      // Insert service record
      const { data, error } = await this.supabase
        .from('t_catalog_items')
        .insert(serviceRecord)
        .select()
        .single();

      if (error) {
        console.error('❌ ServiceCatalogService - service creation error:', error);
        throw error;
      }

      // Invalidate related cache
      await this.cacheManager.invalidateServiceCache(serviceId, context.tenant_id);

      // Create audit trail
      const executionTime = Date.now() - startTime;
      const auditTrail = ServiceCatalogUtils.createAuditTrail(
        ServiceCatalogUtils.generateRequestId(),
        'create_service',
        't_catalog_items',
        serviceId,
        context,
        executionTime,
        true,
        undefined,
        serviceRecord
      );

      await this.database.storeAuditTrail(auditTrail);

      console.log('✅ ServiceCatalogService - service created successfully:', {
        serviceId,
        serviceName: data.service_name,
        executionTime
      });

      return {
        success: true,
        data: data as ServiceCatalogItem
      };

    } catch (error) {
      const executionTime = Date.now() - startTime;
      console.error('❌ ServiceCatalogService - service creation failed:', error);

      return {
        success: false,
        error: {
          code: 'CREATION_ERROR',
          message: 'Failed to create service'
        }
      };
    }
  }

  async getService(
    serviceId: string,
    context: EnvironmentContext
  ): Promise<ServiceCatalogApiResponse<ServiceCatalogItem>> {
    console.log('🔍 ServiceCatalogService - getting service:', {
      serviceId,
      tenantId: context.tenant_id
    });

    try {
      const cacheKey = ServiceCatalogCacheKeys.service(serviceId, context.tenant_id, context.is_live);
      
      const service = await this.cacheManager.cacheWithFallback(
        cacheKey,
        async () => {
          return await this.database.getServiceCatalogItemById(
            serviceId,
            context.tenant_id,
            context.is_live
          );
        },
        15 * 60 * 1000, // 15 minutes
        ServiceCatalogCacheKeys.getTags(context.tenant_id, context.is_live, 'service')
      );

      if (!service) {
        return {
          success: false,
          error: {
            code: 'NOT_FOUND',
            message: 'Service not found'
          }
        };
      }

      console.log('✅ ServiceCatalogService - service retrieved successfully');

      return {
        success: true,
        data: service as ServiceCatalogItem
      };

    } catch (error) {
      console.error('❌ ServiceCatalogService - service retrieval failed:', error);

      return {
        success: false,
        error: {
          code: 'RETRIEVAL_ERROR',
          message: 'Failed to retrieve service'
        }
      };
    }
  }

  async updateService(
    serviceId: string,
    serviceData: Partial<ServiceCatalogItemData>,
    context: EnvironmentContext
  ): Promise<ServiceCatalogApiResponse<ServiceCatalogItem>> {
    console.log('🔄 ServiceCatalogService - updating service:', {
      serviceId,
      tenantId: context.tenant_id
    });

    const startTime = Date.now();

    try {
      // Get existing service
      const existingService = await this.database.getServiceCatalogItemById(
        serviceId,
        context.tenant_id,
        context.is_live
      );

      if (!existingService) {
        return {
          success: false,
          error: {
            code: 'NOT_FOUND',
            message: 'Service not found'
          }
        };
      }

      // Prepare update data
      const updateData: any = {
        ...serviceData,
        updated_by: context.user_id,
        updated_at: new Date().toISOString()
      };

      // Update slug if name changed
      if (serviceData.service_name && serviceData.service_name !== existingService.service_name) {
        updateData.slug = ServiceCatalogUtils.generateSlug(serviceData.service_name);
      }

      // Update service record
      const { data, error } = await this.supabase
        .from('t_catalog_items')
        .update(updateData)
        .eq('id', serviceId)
        .eq('tenant_id', context.tenant_id)
        .eq('is_live', context.is_live)
        .select()
        .single();

      if (error) {
        console.error('❌ ServiceCatalogService - service update error:', error);
        throw error;
      }

      // Invalidate cache
      await this.cacheManager.invalidateServiceCache(serviceId, context.tenant_id);

      // Create audit trail
      const executionTime = Date.now() - startTime;
      const auditTrail = ServiceCatalogUtils.createAuditTrail(
        ServiceCatalogUtils.generateRequestId(),
        'update_service',
        't_catalog_items',
        serviceId,
        context,
        executionTime,
        true,
        existingService,
        updateData
      );

      await this.database.storeAuditTrail(auditTrail);

      console.log('✅ ServiceCatalogService - service updated successfully');

      return {
        success: true,
        data: data as ServiceCatalogItem
      };

    } catch (error) {
      console.error('❌ ServiceCatalogService - service update failed:', error);

      return {
        success: false,
        error: {
          code: 'UPDATE_ERROR',
          message: 'Failed to update service'
        }
      };
    }
  }

  async deleteService(
    serviceId: string,
    context: EnvironmentContext
  ): Promise<ServiceCatalogApiResponse<boolean>> {
    console.log('🗑️ ServiceCatalogService - deleting service:', {
      serviceId,
      tenantId: context.tenant_id
    });

    const startTime = Date.now();

    try {
      // Check if service exists
      const existingService = await this.database.getServiceCatalogItemById(
        serviceId,
        context.tenant_id,
        context.is_live
      );

      if (!existingService) {
        return {
          success: false,
          error: {
            code: 'NOT_FOUND',
            message: 'Service not found'
          }
        };
      }

      // Soft delete by setting is_active to false
      const { error } = await this.supabase
        .from('t_catalog_items')
        .update({
          is_active: false,
          updated_by: context.user_id,
          updated_at: new Date().toISOString()
        })
        .eq('id', serviceId)
        .eq('tenant_id', context.tenant_id)
        .eq('is_live', context.is_live);

      if (error) {
        console.error('❌ ServiceCatalogService - service deletion error:', error);
        throw error;
      }

      // Invalidate cache
      await this.cacheManager.invalidateServiceCache(serviceId, context.tenant_id);

      // Create audit trail
      const executionTime = Date.now() - startTime;
      const auditTrail = ServiceCatalogUtils.createAuditTrail(
        ServiceCatalogUtils.generateRequestId(),
        'delete_service',
        't_catalog_items',
        serviceId,
        context,
        executionTime,
        true,
        existingService,
        { is_active: false }
      );

      await this.database.storeAuditTrail(auditTrail);

      console.log('✅ ServiceCatalogService - service deleted successfully');

      return {
        success: true,
        data: true
      };

    } catch (error) {
      console.error('❌ ServiceCatalogService - service deletion failed:', error);

      return {
        success: false,
        error: {
          code: 'DELETION_ERROR',
          message: 'Failed to delete service'
        }
      };
    }
  }

  async queryServices(
    filters: ServiceCatalogFilters,
    context: EnvironmentContext
  ): Promise<ServiceCatalogApiResponse<ServiceCatalogResponse>> {
    console.log('🔍 ServiceCatalogService - querying services:', {
      tenantId: context.tenant_id,
      hasFilters: Object.keys(filters).length > 0
    });

    try {
      const filtersHash = ServiceCatalogUtils.hashObject(filters);
      const cacheKey = ServiceCatalogCacheKeys.servicesList(context.tenant_id, context.is_live, filtersHash);

      const result = await this.cacheManager.cacheWithFallback(
        cacheKey,
        async () => {
          return await this.database.queryServiceCatalogItems(filters, context.tenant_id, context.is_live);
        },
        10 * 60 * 1000, // 10 minutes
        ServiceCatalogCacheKeys.getTags(context.tenant_id, context.is_live, 'services_list')
      );

      const response = ServiceCatalogUtils.formatServiceResponse(
        result.items,
        result.total_count,
        filters
      );

      console.log('✅ ServiceCatalogService - services queried successfully:', {
        itemsCount: result.items.length,
        totalCount: result.total_count
      });

      return {
        success: true,
        data: response
      };

    } catch (error) {
      console.error('❌ ServiceCatalogService - services query failed:', error);

      return {
        success: false,
        error: {
          code: 'QUERY_ERROR',
          message: 'Failed to query services'
        }
      };
    }
  }

  async bulkCreateServices(
    bulkOperation: BulkServiceOperation,
    context: EnvironmentContext
  ): Promise<ServiceCatalogApiResponse<BulkOperationResult>> {
    console.log('📦 ServiceCatalogService - bulk creating services:', {
      itemsCount: bulkOperation.items.length,
      tenantId: context.tenant_id
    });

    const startTime = Date.now();
    const batchId = bulkOperation.batch_id || ServiceCatalogUtils.generateBatchId();
    const results: BulkOperationResult = {
      success_count: 0,
      error_count: 0,
      total_count: bulkOperation.items.length,
      successful_items: [],
      failed_items: [],
      batch_id: batchId,
      processing_time_ms: 0
    };

    try {
      for (let i = 0; i < bulkOperation.items.length; i++) {
        const item = bulkOperation.items[i];
        
        try {
          const createResult = await this.createService(item, context);
          
          if (createResult.success && createResult.data) {
            results.successful_items.push(createResult.data.id);
            results.success_count++;
          } else {
            results.failed_items.push({
              item_index: i,
              item_data: item,
              error_code: createResult.error?.code || 'UNKNOWN_ERROR',
              error_message: createResult.error?.message || 'Unknown error occurred'
            });
            results.error_count++;
          }
        } catch (error) {
          results.failed_items.push({
            item_index: i,
            item_data: item,
            error_code: 'PROCESSING_ERROR',
            error_message: error instanceof Error ? error.message : 'Processing error'
          });
          results.error_count++;

          if (!bulkOperation.continue_on_error) {
            break;
          }
        }
      }

      results.processing_time_ms = Date.now() - startTime;

      console.log('✅ ServiceCatalogService - bulk creation completed:', {
        successCount: results.success_count,
        errorCount: results.error_count,
        processingTime: results.processing_time_ms
      });

      return {
        success: true,
        data: results
      };

    } catch (error) {
      console.error('❌ ServiceCatalogService - bulk creation failed:', error);

      return {
        success: false,
        error: {
          code: 'BULK_CREATION_ERROR',
          message: 'Bulk creation operation failed'
        }
      };
    }
  }

  async bulkUpdateServices(
    bulkOperation: BulkServiceOperation,
    context: EnvironmentContext
  ): Promise<ServiceCatalogApiResponse<BulkOperationResult>> {
    console.log('📦 ServiceCatalogService - bulk updating services:', {
      itemsCount: bulkOperation.items.length,
      tenantId: context.tenant_id
    });

    // Implementation similar to bulkCreateServices but for updates
    // For brevity, returning a placeholder response
    return {
      success: false,
      error: {
        code: 'NOT_IMPLEMENTED',
        message: 'Bulk update not yet implemented'
      }
    };
  }

  async getMasterData(
    context: EnvironmentContext
  ): Promise<ServiceCatalogApiResponse<MasterDataResponse>> {
    console.log('📋 ServiceCatalogService - getting master data:', {
      tenantId: context.tenant_id
    });

    try {
      const cacheKey = ServiceCatalogCacheKeys.masterData(context.tenant_id, context.is_live);

      const masterData = await this.cacheManager.cacheWithFallback(
        cacheKey,
        async () => {
          return await this.database.getMasterData(context.tenant_id, context.is_live);
        },
        30 * 60 * 1000, // 30 minutes
        ServiceCatalogCacheKeys.getTags(context.tenant_id, context.is_live, 'master_data')
      );

      console.log('✅ ServiceCatalogService - master data retrieved successfully');

      return {
        success: true,
        data: masterData as MasterDataResponse
      };

    } catch (error) {
      console.error('❌ ServiceCatalogService - master data retrieval failed:', error);

      return {
        success: false,
        error: {
          code: 'MASTER_DATA_ERROR',
          message: 'Failed to retrieve master data'
        }
      };
    }
  }

  async getAvailableResources(
    filters: any,
    context: EnvironmentContext
  ): Promise<ServiceCatalogApiResponse<ResourceSearchResponse>> {
    console.log('🔍 ServiceCatalogService - getting available resources:', {
      tenantId: context.tenant_id,
      hasFilters: Object.keys(filters).length > 0
    });

    try {
      const filtersHash = ServiceCatalogUtils.hashObject(filters);
      const cacheKey = ServiceCatalogCacheKeys.resources(context.tenant_id, context.is_live, filtersHash);

      const result = await this.cacheManager.cacheWithFallback(
        cacheKey,
        async () => {
          return await this.database.getAvailableResources(filters, context.tenant_id, context.is_live);
        },
        5 * 60 * 1000, // 5 minutes
        ServiceCatalogCacheKeys.getTags(context.tenant_id, context.is_live, 'resources')
      );

      console.log('✅ ServiceCatalogService - available resources retrieved successfully');

      return {
        success: true,
        data: result as ResourceSearchResponse
      };

    } catch (error) {
      console.error('❌ ServiceCatalogService - available resources retrieval failed:', error);

      return {
        success: false,
        error: {
          code: 'RESOURCES_ERROR',
          message: 'Failed to retrieve available resources'
        }
      };
    }
  }

  async associateServiceResources(
    associations: ServiceResourceAssociation[],
    context: EnvironmentContext
  ): Promise<ServiceCatalogApiResponse<boolean>> {
    console.log('🔗 ServiceCatalogService - associating service resources:', {
      associationsCount: associations.length,
      tenantId: context.tenant_id
    });

    // Implementation placeholder
    return {
      success: false,
      error: {
        code: 'NOT_IMPLEMENTED',
        message: 'Resource association not yet implemented'
      }
    };
  }

  async getServiceResources(
    serviceId: string,
    context: EnvironmentContext
  ): Promise<ServiceCatalogApiResponse<ServiceResourceSummary>> {
    console.log('🔍 ServiceCatalogService - getting service resources:', {
      serviceId,
      tenantId: context.tenant_id
    });

    try {
      const cacheKey = ServiceCatalogCacheKeys.serviceResources(serviceId, context.tenant_id, context.is_live);

      const result = await this.cacheManager.cacheWithFallback(
        cacheKey,
        async () => {
          return await this.database.getServiceResources(serviceId, context.tenant_id, context.is_live);
        },
        10 * 60 * 1000, // 10 minutes
        ServiceCatalogCacheKeys.getTags(context.tenant_id, context.is_live, 'service_resources')
      );

      console.log('✅ ServiceCatalogService - service resources retrieved successfully');

      return {
        success: true,
        data: result as ServiceResourceSummary
      };

    } catch (error) {
      console.error('❌ ServiceCatalogService - service resources retrieval failed:', error);

      return {
        success: false,
        error: {
          code: 'SERVICE_RESOURCES_ERROR',
          message: 'Failed to retrieve service resources'
        }
      };
    }
  }

  async updateServicePricing(
    pricingUpdate: ServicePricingUpdate,
    context: EnvironmentContext
  ): Promise<ServiceCatalogApiResponse<boolean>> {
    console.log('💰 ServiceCatalogService - updating service pricing:', {
      serviceId: pricingUpdate.service_id,
      tenantId: context.tenant_id
    });

    // Implementation placeholder
    return {
      success: false,
      error: {
        code: 'NOT_IMPLEMENTED',
        message: 'Pricing update not yet implemented'
      }
    };
  }

  private async checkDuplicates(
    serviceName: string,
    sku: string | undefined,
    tenantId: string,
    isLive: boolean
  ): Promise<{ isUnique: boolean; duplicateType?: 'name' | 'sku' }> {
    console.log('🔍 ServiceCatalogService - checking duplicates');

    try {
      // Check for duplicate name
      const nameCheck = await this.supabase
        .from('t_catalog_items')
        .select('id')
        .eq('service_name', serviceName)
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive)
        .eq('is_active', true)
        .limit(1);

      if (nameCheck.data && nameCheck.data.length > 0) {
        return { isUnique: false, duplicateType: 'name' };
      }

      // Check for duplicate SKU if provided
      if (sku) {
        const skuCheck = await this.supabase
          .from('t_catalog_items')
          .select('id')
          .eq('sku', sku)
          .eq('tenant_id', tenantId)
          .eq('is_live', isLive)
          .eq('is_active', true)
          .limit(1);

        if (skuCheck.data && skuCheck.data.length > 0) {
          return { isUnique: false, duplicateType: 'sku' };
        }
      }

      return { isUnique: true };

    } catch (error) {
      console.error('❌ ServiceCatalogService - duplicate check failed:', error);
      // On error, assume not unique to be safe
      return { isUnique: false };
    }
  }
}