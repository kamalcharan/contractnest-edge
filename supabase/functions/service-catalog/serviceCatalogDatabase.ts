// supabase/functions/service-catalog/serviceCatalogDatabase.ts
// Service Catalog Database Operations - FINAL VERSION
// ✅ Lists only show status=true by default
// ✅ Update with versioning (partial unique index compatible)
// ✅ Keeps name unchanged, keeps is_live unchanged
// ✅ Pricing properly updated from request
// ✅ Status = BOOLEAN (true/false)
// ✅ Edit = Create New Version (marks old as inactive)
// ✅ Delete = Set status: false (Soft Delete)

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { ServiceCatalogFilters } from './serviceCatalogValidation.ts';

export class ServiceCatalogDatabase {
  
  constructor(private supabase: SupabaseClient) {}

  /**
   * Get a single service catalog item by ID with resources
   */
  async getServiceCatalogItemById(serviceId: string, tenantId: string, isLive: boolean) {
    console.log('Database - Fetching service by ID:', {
      serviceId,
      tenantId,
      isLive
    });

    try {
      const { data, error } = await this.supabase
        .from('t_catalog_items')
        .select('*')
        .eq('id', serviceId)
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive)
        .single();

      if (error) {
        if (error.code === 'PGRST116') {
          console.log('Service not found');
          return null;
        }
        console.error('Service fetch error:', error);
        throw error;
      }

      // Get service resources if any
      const { data: resources, error: resourcesError } = await this.supabase
        .from('t_catalog_service_resources')
        .select('*')
        .eq('service_id', serviceId)
        .eq('tenant_id', tenantId)
        .eq('is_active', true);

      if (resourcesError) {
        console.warn('Resources fetch warning:', resourcesError);
      }

      // Extract pricing_records from JSONB
      const pricingRecords = data.price_attributes?.pricing_records || [];

      const serviceData = {
        ...data,
        pricing_type: data.price_attributes?.type || 'fixed',
        base_amount: data.price_attributes?.base_amount || 0,
        currency: data.price_attributes?.currency || 'INR',
        pricing_records: pricingRecords,
        total_pricing_options: pricingRecords.length,
        service_type: data.service_attributes?.service_type || 'independent',
        requires_resources: data.resource_requirements?.requires_resources || false,
        resource_count: data.resource_requirements?.resource_count || 0,
        resources: resources || [],
        resource_count_actual: (resources || []).length
      };

      console.log('Service fetched successfully:', {
        serviceId: data.id,
        serviceName: data.name,
        status: data.status,
        isActive: data.status === true,
        pricingRecordsCount: pricingRecords.length,
        hasResources: serviceData.requires_resources,
        resourceCount: serviceData.resource_count_actual,
        isVariant: data.is_variant,
        hasParent: !!data.parent_id
      });

      return serviceData;
    } catch (error) {
      console.error('Service fetch failed:', error);
      throw error;
    }
  }

  async queryServiceCatalogItems(filters: any, tenantId: string, isLive: boolean) {
  console.log('Database - Querying service catalog items:', {
    tenantId,
    isLive,
    filters
  });

  try {
    let query = this.supabase
      .from('t_catalog_items')
      .select('*', { count: 'exact' })
      .eq('tenant_id', tenantId)
      .eq('is_live', isLive)
      .eq('type', 'service');

    // ✅ FIXED: Dynamic status filter
    // If is_active filter is explicitly provided, use it
    // Otherwise, default to showing only active records (status=true)
    if (filters.is_active !== undefined) {
      query = query.eq('status', filters.is_active);
      console.log('Filtering by status:', filters.is_active);
    } else {
      // Default: show only active records
      query = query.eq('status', true);
      console.log('Default filter: showing only active records');
    }

    // Apply other filters
    if (filters.search_term) {
      query = query.or(`name.ilike.%${filters.search_term}%,short_description.ilike.%${filters.search_term}%,description_content.ilike.%${filters.search_term}%`);
    }

    if (filters.category_id) {
      query = query.eq('category_id', filters.category_id);
    }

    if (filters.industry_id) {
      query = query.eq('industry_id', filters.industry_id);
    }

    if (filters.price_min !== undefined) {
      query = query.gte('price_attributes->base_amount', filters.price_min);
    }

    if (filters.price_max !== undefined) {
      query = query.lte('price_attributes->base_amount', filters.price_max);
    }

    if (filters.currency) {
      query = query.eq('price_attributes->currency', filters.currency);
    }

    if (filters.has_resources !== undefined) {
      query = query.eq('resource_requirements->requires_resources', filters.has_resources);
    }

    // Sorting
    const sortBy = filters.sort_by || 'created_at';
    const sortDirection = filters.sort_direction === 'asc';
    query = query.order(sortBy, { ascending: sortDirection });

    // Pagination
    const limit = filters.limit || 50;
    const offset = filters.offset || 0;
    query = query.range(offset, offset + limit - 1);
const { data: items, error, count } = await query;

if (error) {
  console.error('Query error:', error);
  throw error;
}

// ✅ FIXED: Build parent_id set from ALL records (not just filtered ones)
// This ensures we correctly identify old versions even when their children have different status
const { data: allRecordsForParentMapping } = await this.supabase
  .from('t_catalog_items')
  .select('id, parent_id')
  .eq('tenant_id', tenantId)
  .eq('is_live', isLive)
  .eq('type', 'service');

// Build set of all parent_ids from ALL records
const parentIdSet = new Set(
  (allRecordsForParentMapping || [])
    .map(item => item.parent_id)
    .filter(pid => pid !== null)
);

// Filter to show only latest versions (records not in parent_id set)
const allItems = items || [];
const latestVersionsOnly = allItems.filter(item => {
  return !parentIdSet.has(item.id);
});

console.log('Query results:', {
  rawItemCount: allItems.length,
  latestVersionsCount: latestVersionsOnly.length,
  filteredOutOldVersions: allItems.length - latestVersionsOnly.length,
  statusFilter: filters.is_active !== undefined ? filters.is_active : 'active_only',
  totalRecordsInDB: allRecordsForParentMapping?.length || 0
});

return {
  items: latestVersionsOnly,
  total_count: latestVersionsOnly.length
};

  } catch (error: any) {
    console.error('Query service catalog items failed:', error);
    throw error;
  }
}
  /**
   * Get service resources by service ID
   */
  async getServiceResources(serviceId: string, tenantId: string, isLive: boolean) {
    console.log('Database - Fetching service resources:', {
      serviceId,
      tenantId,
      isLive
    });

    try {
      const { data, error } = await this.supabase
        .from('t_catalog_service_resources')
        .select('*')
        .eq('service_id', serviceId)
        .eq('tenant_id', tenantId)
        .eq('is_active', true);

      if (error) {
        console.error('Service resources fetch error:', error);
        throw error;
      }

      const resources = (data || []).map(resource => ({
        resource_id: resource.id,
        resource_type_id: resource.resource_type_id,
        quantity_required: resource.quantity_required || 1,
        duration_hours: resource.duration_hours,
        unit_cost: resource.unit_cost,
        currency_code: resource.currency_code || 'INR',
        is_billable: resource.is_billable,
        required_skills: resource.required_skills || [],
        required_attributes: resource.required_attributes || {},
        sequence_order: resource.sequence_order || 0
      }));

      const totalEstimatedCost = resources.reduce((sum, resource) => {
        const cost = (resource.unit_cost || 0) * (resource.quantity_required || 1) * (resource.duration_hours || 1);
        return sum + cost;
      }, 0);

      console.log('Service resources fetched:', {
        resourcesCount: resources.length,
        totalEstimatedCost
      });

      return {
        service_id: serviceId,
        associated_resources: resources,
        total_resources: resources.length,
        total_estimated_cost: totalEstimatedCost,
        resource_availability_score: 0.8,
        available_alternatives: []
      };
    } catch (error) {
      console.error('Service resources fetch failed:', error);
      throw error;
    }
  }

  /**
   * Create new service - Always saves with status: true
   */
  async createServiceCatalogItem(serviceData: any, tenantId: string, userId: string, isLive: boolean) {
    console.log('Database - Creating service:', {
      serviceName: serviceData.service_name,
      serviceType: serviceData.service_type,
      tenantId,
      userId,
      isLive,
      pricingRecordsCount: serviceData.pricing_records?.length || 0,
      hasResources: serviceData.resource_requirements?.length > 0,
      isVariant: serviceData.is_variant || false
    });

    try {
      // Store ALL pricing records in price_attributes JSONB
      const pricingRecords = serviceData.pricing_records || [];
      const firstPricing = pricingRecords[0] || {};

      // Prepare main service data
      const serviceInsert = {
        tenant_id: tenantId,
        name: serviceData.service_name,
        short_description: serviceData.short_description || null,
        description_content: serviceData.description || null,
        description_format: serviceData.description_format || 'html',
        type: 'service',
        industry_id: serviceData.industry_id || null,
        category_id: serviceData.category_id || null,
        
        status: true,
        is_live: isLive,
        
        is_variant: serviceData.is_variant || false,
        parent_id: serviceData.parent_id || null,
        
        price_attributes: {
          base_amount: firstPricing.amount || 0,
          currency: firstPricing.currency || 'INR',
          type: firstPricing.price_type || 'fixed',
          billing_mode: firstPricing.billing_cycle || 'manual',
          pricing_records: pricingRecords,
          total_pricing_options: pricingRecords.length,
          has_multiple_pricing: pricingRecords.length > 1,
          currencies: [...new Set(pricingRecords.map(p => p.currency))],
        },
        
        tax_config: {
          use_tenant_default: firstPricing.tax_inclusion === 'inclusive',
          display_mode: firstPricing.tax_inclusion || 'exclusive',
          tax_rate_ids: firstPricing.tax_rate_ids || [],
          all_tax_rates: pricingRecords
            .flatMap(p => p.tax_rate_ids || [])
            .filter((v, i, a) => a.indexOf(v) === i),
          has_multiple_tax_configs: pricingRecords.some(p => 
            JSON.stringify(p.tax_rate_ids) !== JSON.stringify(firstPricing.tax_rate_ids)
          )
        },
        
        service_attributes: {
          sku: serviceData.sku || null,
          duration_minutes: serviceData.duration_minutes || null,
          service_type: serviceData.service_type || 'independent',
          ...serviceData.service_attributes
        },
        
        resource_requirements: {
          requires_resources: serviceData.service_type === 'resource_based',
          resource_count: serviceData.resource_requirements?.length || 0,
          resource_details: serviceData.resource_requirements || []
        },
        
        specifications: serviceData.specifications || {},
        terms_content: serviceData.terms || null,
        terms_format: serviceData.terms_format || 'html',
        variant_attributes: serviceData.variant_attributes || {},
        
        metadata: {
          sort_order: serviceData.sort_order || 0,
          image_url: serviceData.image_url || null,
          tags: serviceData.tags || [],
          ...serviceData.metadata
        },
        
        created_by: userId,
        updated_by: userId
      };

      // Insert main service record
      const { data: service, error: serviceError } = await this.supabase
        .from('t_catalog_items')
        .insert(serviceInsert)
        .select()
        .single();

      if (serviceError) {
        console.error('Service creation error:', serviceError);
        throw serviceError;
      }

      console.log('Service created successfully:', {
        serviceId: service.id,
        serviceName: service.name,
        status: service.status,
        pricingRecordsSaved: pricingRecords.length,
        isVariant: service.is_variant
      });

      let resources = [];

      // Create resource associations if service requires resources
      if (serviceData.service_type === 'resource_based' && serviceData.resource_requirements?.length > 0) {
        console.log('Creating resource associations:', {
          serviceId: service.id,
          resourceCount: serviceData.resource_requirements.length
        });

        const resourceInserts = serviceData.resource_requirements.map((resource: any, index: number) => ({
          service_id: service.id,
          tenant_id: tenantId,
          resource_type_id: resource.resource_type_id || resource.resource_id,
          allocation_type_id: resource.allocation_type_id || null,
          quantity_required: resource.quantity || 1,
          duration_hours: resource.duration_hours || null,
          unit_cost: resource.unit_cost || 0,
          currency_code: resource.currency || 'INR',
          is_billable: resource.is_billable !== false,
          required_skills: resource.required_skills || [],
          required_attributes: resource.required_attributes || {},
          sequence_order: resource.sequence_order || index,
          is_active: true
        }));

        const { data: resourcesData, error: resourcesError } = await this.supabase
          .from('t_catalog_service_resources')
          .insert(resourceInserts)
          .select();

        if (resourcesError) {
          console.error('Resource associations creation error:', resourcesError);
          await this.supabase
            .from('t_catalog_items')
            .delete()
            .eq('id', service.id);
          throw resourcesError;
        }

        resources = resourcesData || [];
        console.log('Resource associations created:', {
          resourceAssociationsCount: resources.length
        });
      }

      return {
        ...service,
        resources: resources
      };

    } catch (error: any) {
      console.error('Service creation failed:', error);
      throw error;
    }
  }

  /**
   * ✅ Update service with VERSIONING - Works with partial unique index
   * Old version: status=false (archived, same name, same is_live)
   * New version: status=true (active, same name, same is_live)
   */
  async updateServiceCatalogItem(serviceId: string, serviceData: any, tenantId: string, userId: string, isLive: boolean) {
    console.log('Database - Updating service (versioning):', {
      serviceId,
      serviceName: serviceData.service_name,
      tenantId,
      isLive
    });

    try {
      // STEP 1: Get current service
      const { data: currentService, error: fetchError } = await this.supabase
        .from('t_catalog_items')
        .select('*')
        .eq('id', serviceId)
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive)
        .single();

      if (fetchError || !currentService) {
        throw new Error('Service not found');
      }

      // STEP 2: Archive old version
      // ✅ Keep name unchanged, keep is_live unchanged, ONLY set status=false
      const { error: archiveError } = await this.supabase
        .from('t_catalog_items')
        .update({
          status: false,  // ✅ Deactivate (removes from unique index)
          updated_by: userId,
          updated_at: new Date().toISOString()
        })
        .eq('id', serviceId)
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive);

      if (archiveError) {
        console.error('Archive error:', archiveError);
        throw archiveError;
      }

      console.log('Old version archived:', { serviceId, name: currentService.name });

      // STEP 3: Prepare pricing
      const pricingRecords = serviceData.pricing_records && Array.isArray(serviceData.pricing_records) && serviceData.pricing_records.length > 0
        ? serviceData.pricing_records
        : currentService.price_attributes?.pricing_records || [];
      
      const firstPricing = pricingRecords[0] || {};

      // STEP 4: Create new version
      const newServiceData = {
        tenant_id: tenantId,
        name: serviceData.service_name || currentService.name,
        short_description: serviceData.short_description !== undefined ? serviceData.short_description : currentService.short_description,
        description_content: serviceData.description !== undefined ? serviceData.description : currentService.description_content,
        description_format: serviceData.description_format || currentService.description_format || 'html',
        type: 'service',
        industry_id: serviceData.industry_id !== undefined ? serviceData.industry_id : currentService.industry_id,
        category_id: serviceData.category_id !== undefined ? serviceData.category_id : currentService.category_id,
        
        status: true,    // ✅ Active (enforced by unique index)
        is_live: isLive, // ✅ Same environment
        
        parent_id: serviceId,  // Link to old version
        is_variant: currentService.is_variant || false,
        
        price_attributes: {
          base_amount: firstPricing.amount || 0,
          currency: firstPricing.currency || 'INR',
          type: firstPricing.price_type || 'fixed',
          billing_mode: firstPricing.billing_cycle || 'manual',
          pricing_records: pricingRecords,
          total_pricing_options: pricingRecords.length,
          has_multiple_pricing: pricingRecords.length > 1,
          currencies: [...new Set(pricingRecords.map((p: any) => p.currency))],
        },

        tax_config: {
          use_tenant_default: firstPricing.tax_inclusion === 'inclusive',
          display_mode: firstPricing.tax_inclusion || 'exclusive',
          tax_rate_ids: firstPricing.tax_rate_ids || [],
          all_tax_rates: pricingRecords
            .flatMap((p: any) => p.tax_rate_ids || [])
            .filter((v: any, i: any, a: any) => a.indexOf(v) === i),
          has_multiple_tax_configs: pricingRecords.some((p: any) => 
            JSON.stringify(p.tax_rate_ids) !== JSON.stringify(firstPricing.tax_rate_ids)
          )
        },
        
        service_attributes: {
          sku: serviceData.sku !== undefined ? serviceData.sku : currentService.service_attributes?.sku,
          duration_minutes: serviceData.duration_minutes !== undefined ? serviceData.duration_minutes : currentService.service_attributes?.duration_minutes,
          service_type: serviceData.service_type || currentService.service_attributes?.service_type || 'independent',
          ...(serviceData.service_attributes || {})
        },
        
        resource_requirements: serviceData.resource_requirements !== undefined ? {
          requires_resources: serviceData.service_type === 'resource_based',
          resource_count: serviceData.resource_requirements?.length || 0,
          resource_details: serviceData.resource_requirements || []
        } : currentService.resource_requirements,
        
        specifications: serviceData.specifications !== undefined ? serviceData.specifications : currentService.specifications,
        terms_content: serviceData.terms !== undefined ? serviceData.terms : currentService.terms_content,
        terms_format: serviceData.terms_format || currentService.terms_format || 'html',
        variant_attributes: serviceData.variant_attributes || currentService.variant_attributes || {},
        
        metadata: {
          sort_order: serviceData.sort_order !== undefined ? serviceData.sort_order : currentService.metadata?.sort_order || 0,
          image_url: serviceData.image_url !== undefined ? serviceData.image_url : currentService.metadata?.image_url,
          tags: serviceData.tags || currentService.metadata?.tags || [],
          ...(serviceData.metadata || {})
        },
        
        created_by: userId,
        updated_by: userId
      };

      const { data: newService, error: createError } = await this.supabase
        .from('t_catalog_items')
        .insert(newServiceData)
        .select()
        .single();

      if (createError) {
        console.error('Create new version error:', createError);
        
        // Rollback
        await this.supabase
          .from('t_catalog_items')
          .update({ status: true })
          .eq('id', serviceId);
        
        throw createError;
      }

      console.log('✅ New version created:', {
        oldId: serviceId,
        newId: newService.id,
        name: newService.name
      });

      return newService;

    } catch (error: any) {
      console.error('Update failed:', error);
      throw error;
    }
  }

  /**
   * DELETE = Set status: false (soft delete)
   */
  async deleteServiceCatalogItem(serviceId: string, tenantId: string, userId: string, isLive: boolean) {
    console.log('Database - Deactivating service (soft delete):', {
      serviceId,
      tenantId,
      userId,
      isLive
    });

    try {
      const { data: service, error: serviceError } = await this.supabase
        .from('t_catalog_items')
        .update({
          status: false,
          updated_by: userId,
          updated_at: new Date().toISOString()
        })
        .eq('id', serviceId)
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive)
        .eq('status', true)
        .select()
        .single();

      if (serviceError) {
        if (serviceError.code === 'PGRST116') {
          throw new Error('Service not found or already inactive');
        }
        console.error('Service deactivation error:', serviceError);
        throw serviceError;
      }

      console.log('Service deactivated successfully:', {
        serviceId: service.id,
        serviceName: service.name,
        newStatus: service.status
      });

      return { success: true, deletedService: service };

    } catch (error: any) {
      console.error('Service deactivation failed:', error);
      throw error;
    }
  }

  /**
   * Restore/Activate service
   */
  async restoreServiceCatalogItem(serviceId: string, tenantId: string, userId: string, isLive: boolean) {
    console.log('Database - Activating service:', {
      serviceId,
      tenantId,
      userId,
      isLive
    });

    try {
      const { data: service, error: serviceError } = await this.supabase
        .from('t_catalog_items')
        .update({
          status: true,
          updated_by: userId,
          updated_at: new Date().toISOString()
        })
        .eq('id', serviceId)
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive)
        .eq('status', false)
        .select()
        .single();

      if (serviceError) {
        if (serviceError.code === 'PGRST116') {
          throw new Error('Service not found or already active');
        }
        console.error('Service activation error:', serviceError);
        throw serviceError;
      }

      console.log('Service activated successfully:', {
        serviceId: service.id,
        serviceName: service.name,
        newStatus: service.status
      });

      return service;

    } catch (error: any) {
      console.error('Service activation failed:', error);
      throw error;
    }
  }

  /**
   * ✅ Toggle service status directly WITHOUT creating new version
   */
  async toggleServiceStatusDirect(
    serviceId: string,
    newStatus: boolean,
    tenantId: string,
    userId: string,
    isLive: boolean
  ) {
    console.log('Database - Toggling service status directly (no versioning):', {
      serviceId,
      tenantId,
      userId,
      isLive,
      newStatus
    });

    try {
      const { data: service, error: serviceError } = await this.supabase
        .from('t_catalog_items')
        .update({
          status: newStatus,
          updated_by: userId,
          updated_at: new Date().toISOString()
        })
        .eq('id', serviceId)
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive)
        .select()
        .single();

      if (serviceError) {
        if (serviceError.code === 'PGRST116') {
          throw new Error('Service not found');
        }
        console.error('Service status toggle error:', serviceError);
        throw serviceError;
      }

      console.log('Service status toggled successfully (direct update):', {
        serviceId: service.id,
        serviceName: service.name,
        newStatus: service.status
      });

      return service;

    } catch (error: any) {
      console.error('Service status toggle failed:', error);
      throw error;
    }
  }

  /**
   * Check if service exists and user has access
   */
  async verifyServiceAccess(serviceId: string, tenantId: string, isLive: boolean): Promise<boolean> {
    try {
      const { data, error } = await this.supabase
        .from('t_catalog_items')
        .select('id')
        .eq('id', serviceId)
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive)
        .single();

      return !error && !!data;
    } catch (error) {
      return false;
    }
  }

  /**
   * Get service statistics
   */
  async getServiceStatistics(tenantId: string, isLive: boolean) {
  try {
    // Get ALL records first for parent mapping
    const { data: allRecords } = await this.supabase
      .from('t_catalog_items')
      .select('id, parent_id, status')
      .eq('tenant_id', tenantId)
      .eq('is_live', isLive)
      .eq('type', 'service');

    // Build parent_id set to identify old versions
    const parentIdSet = new Set(
      (allRecords || [])
        .map(item => item.parent_id)
        .filter(pid => pid !== null)
    );

    // Filter to latest versions only
    const latestVersions = (allRecords || []).filter(item => {
      return !parentIdSet.has(item.id);
    });

    // Count by status
    const activeCount = latestVersions.filter(s => s.status === true).length;
    const inactiveCount = latestVersions.filter(s => s.status === false).length;

    // Get services with resources
    const { count: withResourcesCount } = await this.supabase
      .from('t_catalog_items')
      .select('*', { count: 'exact', head: true })
      .eq('tenant_id', tenantId)
      .eq('is_live', isLive)
      .eq('type', 'service')
      .eq('resource_requirements->requires_resources', true);

    // Get variants
    const { count: variantsCount } = await this.supabase
      .from('t_catalog_items')
      .select('*', { count: 'exact', head: true })
      .eq('tenant_id', tenantId)
      .eq('is_live', isLive)
      .eq('type', 'service')
      .eq('is_variant', true);

    return {
      total_services: latestVersions.length,
      active_services: activeCount,
      inactive_services: inactiveCount,
      services_with_resources: withResourcesCount || 0,
      service_variants: variantsCount || 0
    };
  } catch (error) {
    console.error('Service statistics failed:', error);
    return {
      total_services: 0,
      active_services: 0,
      inactive_services: 0,
      services_with_resources: 0,
      service_variants: 0
    };
  }
}
  /**
   * Health check
   */
  async healthCheck(): Promise<boolean> {
    try {
      const { data, error } = await this.supabase
        .from('t_catalog_items')
        .select('id')
        .limit(1);

      return !error;
    } catch (error) {
      console.error('Database health check failed:', error);
      return false;
    }
  }
}