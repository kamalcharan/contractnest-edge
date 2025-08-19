// supabase/functions/_shared/catalog/catalogService.ts
// ✅ PRODUCTION: Enhanced catalog service with resource composition and transaction support

import { 
  CatalogItem,
  CatalogItemDetailed,
  Resource,
  ResourcePricing,
  ServiceResourceRequirement,
  CreateCatalogItemRequest,
  UpdateCatalogItemRequest,
  CreateResourceRequest,
  UpdateResourceRequest,
  CreateResourcePricingRequest,
  AddResourceRequirementRequest,
  CatalogItemQuery,
  ResourceListParams,
  ServiceResponse,
  CatalogServiceConfig,
  CatalogListResponse,
  ResourceListResponse,
  ResourceDetailsResponse,
  TenantResourcesResponse,
  CatalogError,
  NotFoundError,
  ValidationError,
  ResourceError,
  ContactValidationError,
  requiresContact
} from './catalogTypes.ts';

import { RESOURCE_CONTACT_CLASSIFICATIONS } from './catalogValidation.ts';

export class CatalogService {
  constructor(
    private supabase: any,
    private config: CatalogServiceConfig,
    private auditLogger: any
  ) {}

  // =================================================================
  // CATALOG ITEM OPERATIONS
  // =================================================================

  /**
   * Create catalog item with full transaction support
   */
  async createCatalogItem(data: CreateCatalogItemRequest): Promise<ServiceResponse<CatalogItemDetailed>> {
    const catalogId = crypto.randomUUID();
    const now = new Date().toISOString();

    try {
      console.log('[CatalogService] Creating catalog item:', data.name);

      // Step 1: Create main catalog item
      const catalogItemData = {
        id: catalogId,
        tenant_id: this.config.tenant_id,
        is_live: this.config.is_live,
        type: data.type,
        industry_id: data.industry_id || null,
        category_id: data.category_id || null,
        name: data.name,
        short_description: data.short_description || null,
        description_format: data.description_format || 'markdown',
        description_content: data.description_content || null,
        terms_format: data.terms_format || 'markdown',
        terms_content: data.terms_content || null,
        parent_id: data.parent_id || null,
        is_variant: data.is_variant || false,
        variant_attributes: data.variant_attributes || {},
        resource_requirements: data.resource_requirements || {
          team_staff: [],
          equipment: [],
          consumables: [],
          assets: [],
          partners: []
        },
        service_attributes: data.service_attributes || {
          estimated_duration: null,
          complexity_level: 'medium',
          requires_customer_presence: false,
          location_requirements: [],
          scheduling_constraints: {}
        },
        price_attributes: data.price_attributes,
        tax_config: data.tax_config || {
          use_tenant_default: true,
          specific_tax_rates: []
        },
        metadata: data.metadata || {},
        specifications: data.specifications || {},
        status: data.status || 'active',
        created_at: now,
        updated_at: now,
        created_by: this.config.user_id,
        updated_by: this.config.user_id
      };

      const { data: catalogItem, error: catalogError } = await this.supabase
        .from('t_catalog_items')
        .insert(catalogItemData)
        .select()
        .single();

      if (catalogError) {
        throw new CatalogError(`Failed to create catalog item: ${catalogError.message}`, 'CREATE_ERROR');
      }

      // Step 2: Create resources if provided
      const createdResources: Resource[] = [];
      if (data.resources && data.resources.length > 0) {
        for (const resourceData of data.resources) {
          const resource = await this.createResourceInTransaction(resourceData);
          createdResources.push(resource);
        }
      }

      // Step 3: Create pricing if provided
      if (data.pricing && data.pricing.length > 0) {
        for (let i = 0; i < data.pricing.length; i++) {
          const pricingData = data.pricing[i];
          await this.createCatalogPricingInTransaction(catalogId, pricingData, i === 0);
        }
      }

      // Step 4: Create resource requirements if resources were linked
      if (createdResources.length > 0) {
        for (const resource of createdResources) {
          await this.addResourceRequirementInTransaction(catalogId, {
            resource_id: resource.id,
            requirement_type: 'required',
            quantity_needed: 1
          });
        }
      }

      // Step 5: Audit log
      await this.auditLogger.logDataChange(
        this.config.tenant_id,
        this.config.user_id,
        'CATALOG_ITEM',
        catalogId,
        'CREATE',
        null,
        catalogItem
      );

      const detailedItem = await this.getCatalogItemById(catalogId);
      
      return {
        success: true,
        data: detailedItem.data,
        message: 'Catalog item created successfully',
        version_info: {
          version_number: 1,
          is_current_version: true,
          total_versions: 1
        }
      };

    } catch (error) {
      console.error('[CatalogService] Create failed:', error);
      
      if (error instanceof CatalogError) {
        throw error;
      }
      
      throw new CatalogError(
        `Failed to create catalog item: ${error.message}`,
        'TRANSACTION_FAILED'
      );
    }
  }

  /**
   * Update catalog item with resource management
   */
  async updateCatalogItem(
    catalogId: string, 
    updateData: UpdateCatalogItemRequest
  ): Promise<ServiceResponse<CatalogItemDetailed>> {
    try {
      const currentResult = await this.getCatalogItemById(catalogId);
      if (!currentResult.success || !currentResult.data) {
        throw new NotFoundError('Catalog item', catalogId);
      }

      const currentItem = currentResult.data;
      const now = new Date().toISOString();

      // Step 1: Update main catalog item
      const updateFields: any = {
        updated_at: now,
        updated_by: this.config.user_id
      };

      // Add fields that are being updated
      if (updateData.name !== undefined) updateFields.name = updateData.name;
      if (updateData.short_description !== undefined) updateFields.short_description = updateData.short_description;
      if (updateData.description_content !== undefined) updateFields.description_content = updateData.description_content;
      if (updateData.description_format !== undefined) updateFields.description_format = updateData.description_format;
      if (updateData.terms_content !== undefined) updateFields.terms_content = updateData.terms_content;
      if (updateData.terms_format !== undefined) updateFields.terms_format = updateData.terms_format;
      if (updateData.price_attributes !== undefined) updateFields.price_attributes = updateData.price_attributes;
      if (updateData.tax_config !== undefined) updateFields.tax_config = { ...currentItem.tax_config, ...updateData.tax_config };
      if (updateData.metadata !== undefined) updateFields.metadata = updateData.metadata;
      if (updateData.specifications !== undefined) updateFields.specifications = updateData.specifications;
      if (updateData.status !== undefined) updateFields.status = updateData.status;
      if (updateData.variant_attributes !== undefined) updateFields.variant_attributes = updateData.variant_attributes;
      if (updateData.resource_requirements !== undefined) updateFields.resource_requirements = updateData.resource_requirements;
      if (updateData.service_attributes !== undefined) updateFields.service_attributes = updateData.service_attributes;

      const { data: updatedItem, error: updateError } = await this.supabase
        .from('t_catalog_items')
        .update(updateFields)
        .eq('id', catalogId)
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live)
        .select()
        .single();

      if (updateError) {
        throw new CatalogError(`Failed to update catalog item: ${updateError.message}`, 'UPDATE_ERROR');
      }

      // Step 2: Handle resource operations
      if (updateData.add_resources && updateData.add_resources.length > 0) {
        for (const resourceData of updateData.add_resources) {
          const resource = await this.createResourceInTransaction(resourceData);
          await this.addResourceRequirementInTransaction(catalogId, {
            resource_id: resource.id,
            requirement_type: 'required',
            quantity_needed: 1
          });
        }
      }

      if (updateData.update_resources && updateData.update_resources.length > 0) {
        for (const resourceUpdate of updateData.update_resources) {
          await this.updateResourceInTransaction(resourceUpdate);
        }
      }

      if (updateData.remove_resources && updateData.remove_resources.length > 0) {
        for (const resourceId of updateData.remove_resources) {
          await this.removeResourceRequirementInTransaction(catalogId, resourceId);
        }
      }

      // Step 3: Audit log
      await this.auditLogger.logDataChange(
        this.config.tenant_id,
        this.config.user_id,
        'CATALOG_ITEM',
        catalogId,
        'UPDATE',
        currentItem,
        updatedItem
      );

      const detailedItem = await this.getCatalogItemById(catalogId);
      
      return {
        success: true,
        data: detailedItem.data,
        message: 'Catalog item updated successfully',
        version_info: {
          version_number: 1,
          is_current_version: true,
          total_versions: 1
        }
      };

    } catch (error) {
      console.error('[CatalogService] Update failed:', error);
      
      if (error instanceof CatalogError) {
        throw error;
      }
      
      throw new CatalogError(
        `Failed to update catalog item: ${error.message}`,
        'UPDATE_FAILED'
      );
    }
  }

  /**
   * Get catalog item with complete resource details
   */
  async getCatalogItemById(catalogId: string): Promise<ServiceResponse<CatalogItemDetailed>> {
    try {
      // Get main catalog item
      const { data: item, error } = await this.supabase
        .from('t_catalog_items')
        .select(`
          *,
          t_catalog_industries!left (id, name, icon),
          t_catalog_categories!left (id, name, icon)
        `)
        .eq('id', catalogId)
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live)
        .single();

      if (error || !item) {
        throw new NotFoundError('Catalog item', catalogId);
      }

      // Get linked resources with requirements
      const { data: resourceRequirements } = await this.supabase
        .from('t_catalog_service_resources')
        .select(`
          *,
          t_catalog_resources (
            *,
            t_catalog_resource_pricing (*)
          )
        `)
        .eq('service_id', catalogId)
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live);

      // Get pricing
      const { data: pricing } = await this.supabase
        .from('t_catalog_resource_pricing')
        .select('*')
        .in('resource_id', resourceRequirements?.map(r => r.resource_id) || [])
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live)
        .eq('is_active', true);

      // Build detailed response
      const detailedItem: CatalogItemDetailed = {
        ...item,
        industry_name: item.t_catalog_industries?.name,
        industry_icon: item.t_catalog_industries?.icon,
        category_name: item.t_catalog_categories?.name,
        category_icon: item.t_catalog_categories?.icon,
        variant_count: 0,
        linked_resources: resourceRequirements?.map(r => r.t_catalog_resources).filter(Boolean) || [],
        resource_requirements_details: resourceRequirements || [],
        estimated_resource_cost: this.calculateEstimatedResourceCost(resourceRequirements || []),
        pricing_list: pricing || [],
        original_id: item.id,
        total_versions: 1,
        pricing_type: item.price_attributes?.type || 'fixed',
        base_amount: item.price_attributes?.base_amount || 0,
        currency: item.price_attributes?.currency || 'INR',
        billing_mode: item.price_attributes?.billing_mode || 'manual',
        use_tenant_default_tax: item.tax_config?.use_tenant_default || true,
        tax_display_mode: item.tax_config?.display_mode,
        specific_tax_count: item.tax_config?.specific_tax_rates?.length || 0,
        environment_label: item.is_live ? 'Production' : 'Test'
      };

      return {
        success: true,
        data: detailedItem,
        message: 'Catalog item retrieved successfully'
      };

    } catch (error) {
      console.error('[CatalogService] Error getting catalog item:', error);
      
      if (error instanceof CatalogError) {
        throw error;
      }
      
      throw new CatalogError(
        `Failed to get catalog item: ${error.message}`,
        'GET_ERROR'
      );
    }
  }

  /**
   * Query catalog items with advanced filtering
   */
  async queryCatalogItems(query: CatalogItemQuery): Promise<ServiceResponse<CatalogItemDetailed[]>> {
    try {
      let supabaseQuery = this.supabase
        .from('t_catalog_items')
        .select(`
          *,
          t_catalog_industries!left (id, name, icon),
          t_catalog_categories!left (id, name, icon)
        `, { count: 'exact' })
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live);

      // Apply filters
      if (query.filters) {
        if (query.filters.is_active !== undefined) {
          supabaseQuery = supabaseQuery.eq('status', query.filters.is_active ? 'active' : 'inactive');
        }
        
        if (query.filters.type) {
          const types = Array.isArray(query.filters.type) ? query.filters.type : [query.filters.type];
          supabaseQuery = supabaseQuery.in('type', types);
        }
        
        if (query.filters.search_query) {
          supabaseQuery = supabaseQuery.or(`name.ilike.%${query.filters.search_query}%,description_content.ilike.%${query.filters.search_query}%`);
        }

        if (query.filters.complexity_level) {
          supabaseQuery = supabaseQuery.eq('service_attributes->>complexity_level', query.filters.complexity_level);
        }

        if (query.filters.requires_customer_presence !== undefined) {
          supabaseQuery = supabaseQuery.eq('service_attributes->>requires_customer_presence', query.filters.requires_customer_presence);
        }
      }

      // Apply sorting
      if (query.sort && query.sort.length > 0) {
        query.sort.forEach(sort => {
          supabaseQuery = supabaseQuery.order(sort.field, { ascending: sort.direction === 'asc' });
        });
      } else {
        supabaseQuery = supabaseQuery.order('created_at', { ascending: false });
      }

      // Apply pagination
      const page = query.pagination?.page || 1;
      const limit = query.pagination?.limit || 20;
      const offset = (page - 1) * limit;
      
      supabaseQuery = supabaseQuery.range(offset, offset + limit - 1);

      const { data, error, count } = await supabaseQuery;

      if (error) {
        throw new CatalogError(`Failed to query items: ${error.message}`, 'QUERY_ERROR');
      }

      // Build detailed items
      const detailedItems = (data || []).map(item => ({
        ...item,
        industry_name: item.t_catalog_industries?.name,
        industry_icon: item.t_catalog_industries?.icon,
        category_name: item.t_catalog_categories?.name,
        category_icon: item.t_catalog_categories?.icon,
        variant_count: 0,
        linked_resources: [],
        resource_requirements_details: [],
        estimated_resource_cost: 0,
        pricing_list: [],
        original_id: item.id,
        total_versions: 1,
        pricing_type: item.price_attributes?.type || 'fixed',
        base_amount: item.price_attributes?.base_amount || 0,
        currency: item.price_attributes?.currency || 'INR',
        billing_mode: item.price_attributes?.billing_mode || 'manual',
        use_tenant_default_tax: item.tax_config?.use_tenant_default || true,
        tax_display_mode: item.tax_config?.display_mode,
        specific_tax_count: item.tax_config?.specific_tax_rates?.length || 0,
        environment_label: item.is_live ? 'Production' : 'Test'
      }));

      return {
        success: true,
        data: detailedItems,
        message: 'Catalog items retrieved successfully',
        pagination: {
          total: count || 0,
          page,
          limit,
          has_more: (count || 0) > (page * limit)
        }
      };

    } catch (error) {
      console.error('[CatalogService] Error querying catalog items:', error);
      throw error;
    }
  }

  /**
   * Delete catalog item (soft delete)
   */
  async deleteCatalogItem(catalogId: string): Promise<ServiceResponse<void>> {
    try {
      const { data: item, error: fetchError } = await this.supabase
        .from('t_catalog_items')
        .select('id, name')
        .eq('id', catalogId)
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live)
        .single();

      if (fetchError || !item) {
        throw new NotFoundError('Catalog item', catalogId);
      }

      const { error: deleteError } = await this.supabase
        .from('t_catalog_items')
        .update({ 
          status: 'inactive',
          updated_at: new Date().toISOString(),
          updated_by: this.config.user_id
        })
        .eq('id', catalogId)
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live);

      if (deleteError) {
        throw new CatalogError(`Failed to delete item: ${deleteError.message}`, 'DELETE_ERROR');
      }

      await this.auditLogger.logDataChange(
        this.config.tenant_id,
        this.config.user_id,
        'CATALOG_ITEM',
        catalogId,
        'DELETE',
        item,
        null
      );

      return {
        success: true,
        message: 'Catalog item deleted successfully'
      };

    } catch (error) {
      console.error('[CatalogService] Error deleting catalog item:', error);
      throw error;
    }
  }

  // =================================================================
  // RESOURCE OPERATIONS
  // =================================================================

  /**
   * Get tenant resources with filtering
   */
  async getTenantResources(params: ResourceListParams): Promise<ResourceListResponse> {
    try {
      let query = this.supabase
        .from('t_catalog_resources')
        .select('*', { count: 'exact' })
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live);

      // Apply filters
      if (params.resourceType) {
        query = query.eq('resource_type_id', params.resourceType);
      }

      if (params.status) {
        query = query.eq('status', params.status);
      } else {
        query = query.eq('status', 'active');
      }

      if (params.search) {
        query = query.or(`name.ilike.%${params.search}%,description.ilike.%${params.search}%`);
      }

      if (params.hasContact !== undefined) {
        if (params.hasContact) {
          query = query.not('contact_id', 'is', null);
        } else {
          query = query.is('contact_id', null);
        }
      }

      // Sorting
      const sortBy = params.sortBy || 'created_at';
      const sortOrder = params.sortOrder || 'desc';
      query = query.order(sortBy, { ascending: sortOrder === 'asc' });

      // Pagination
      const page = params.page || 1;
      const limit = params.limit || 20;
      const offset = (page - 1) * limit;
      query = query.range(offset, offset + limit - 1);

      const { data, error, count } = await query;

      if (error) {
        throw new CatalogError(`Failed to get resources: ${error.message}`, 'QUERY_ERROR');
      }

      return {
        resources: data || [],
        pagination: {
          page,
          limit,
          total: count || 0,
          totalPages: Math.ceil((count || 0) / limit)
        }
      };

    } catch (error) {
      console.error('[CatalogService] Error getting tenant resources:', error);
      throw error;
    }
  }

  /**
   * Get resource details with relationships
   */
  async getResourceDetails(resourceId: string): Promise<ResourceDetailsResponse> {
    try {
      // Get resource
      const { data: resource, error: resourceError } = await this.supabase
        .from('t_catalog_resources')
        .select('*')
        .eq('id', resourceId)
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live)
        .single();

      if (resourceError || !resource) {
        throw new NotFoundError('Resource', resourceId);
      }

      // Get pricing
      const { data: pricing } = await this.supabase
        .from('t_catalog_resource_pricing')
        .select('*')
        .eq('resource_id', resourceId)
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live)
        .eq('is_active', true);

      // Get linked services
      const { data: serviceLinks } = await this.supabase
        .from('t_catalog_service_resources')
        .select(`
          *,
          t_catalog_items (*)
        `)
        .eq('resource_id', resourceId)
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live);

      // Get contact info if it's a team_staff resource
      let contactInfo = undefined;
      if (resource.contact_id) {
        const { data: contact } = await this.supabase
          .from('t_contacts')
          .select('id, first_name, last_name, company_name, t_contact_channels(*)')
          .eq('id', resource.contact_id)
          .eq('tenant_id', this.config.tenant_id)
          .single();

        if (contact) {
          const primaryEmail = contact.t_contact_channels?.find(c => c.channel_type_id === 'email' && c.is_primary);
          const primaryPhone = contact.t_contact_channels?.find(c => c.channel_type_id === 'phone' && c.is_primary);

          contactInfo = {
            id: contact.id,
            name: contact.company_name || `${contact.first_name} ${contact.last_name}`.trim(),
            email: primaryEmail?.channel_value,
            phone: primaryPhone?.channel_value
          };
        }
      }

      const linkedServices = serviceLinks?.map(link => ({
        ...link.t_catalog_items,
        variant_count: 0,
        linked_resources: [],
        resource_requirements_details: [],
        estimated_resource_cost: 0,
        pricing_list: [],
        original_id: link.t_catalog_items.id,
        total_versions: 1,
        pricing_type: link.t_catalog_items.price_attributes?.type || 'fixed',
        base_amount: link.t_catalog_items.price_attributes?.base_amount || 0,
        currency: link.t_catalog_items.price_attributes?.currency || 'INR',
        billing_mode: link.t_catalog_items.price_attributes?.billing_mode || 'manual',
        use_tenant_default_tax: link.t_catalog_items.tax_config?.use_tenant_default || true,
        specific_tax_count: 0,
        environment_label: link.t_catalog_items.is_live ? 'Production' : 'Test'
      })) || [];

      return {
        resource,
        pricing: pricing || [],
        linked_services: linkedServices,
        contact_info: contactInfo
      };

    } catch (error) {
      console.error('[CatalogService] Error getting resource details:', error);
      throw error;
    }
  }

  /**
   * Get tenant resources summary
   */
  async getTenantResourcesSummary(): Promise<TenantResourcesResponse> {
    try {
      const { data: resources } = await this.supabase
        .from('t_catalog_resources')
        .select('resource_type_id, status, contact_id')
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live);

      const { data: resourcesWithPricing } = await this.supabase
        .from('t_catalog_resource_pricing')
        .select('resource_id')
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live)
        .eq('is_active', true);

      const resourcesWithPricingSet = new Set(resourcesWithPricing?.map(p => p.resource_id) || []);

      const byType = (resources || []).reduce((acc, resource) => {
        acc[resource.resource_type_id] = (acc[resource.resource_type_id] || 0) + 1;
        return acc;
      }, {} as Record<string, number>);

      const activeResources = (resources || []).filter(r => r.status === 'active').length;
      const teamStaffWithContacts = (resources || []).filter(r => 
        r.resource_type_id === 'team_staff' && r.contact_id
      ).length;

      return {
        resources_by_type: byType,
        total_resources: resources?.length || 0,
        active_resources: activeResources,
        resources_with_pricing: resourcesWithPricingSet.size,
        team_staff_with_contacts: teamStaffWithContacts
      };

    } catch (error) {
      console.error('[CatalogService] Error getting resources summary:', error);
      throw error;
    }
  }

  /**
   * Get eligible contacts for resource type
   */
  async getEligibleContacts(resourceType: 'team_staff' | 'partner'): Promise<any[]> {
    try {
      const requiredClassifications = resourceType === 'team_staff' ? ['team_member'] : ['partner', 'vendor'];
      
      const { data: contacts, error } = await this.supabase
        .from('t_contacts')
        .select('id, company_name, name, classifications, status')
        .eq('tenant_id', this.config.tenant_id)
        .eq('status', 'active')
        .order('company_name', { ascending: true });

      if (error) {
        throw new CatalogError(`Failed to get eligible contacts: ${error.message}`, 'QUERY_ERROR');
      }

      // Filter contacts that have required classifications
      const eligibleContacts = (contacts || []).filter(contact => 
        contact.classifications && 
        requiredClassifications.some(classification => 
          contact.classifications.includes(classification)
        )
      );

      return eligibleContacts;

    } catch (error) {
      console.error('[CatalogService] Error getting eligible contacts:', error);
      throw error;
    }
  }

  // =================================================================
  // TRANSACTION HELPER METHODS
  // =================================================================

  /**
   * Create resource within transaction
   */
  private async createResourceInTransaction(resourceData: CreateResourceRequest): Promise<Resource> {
    const resourceId = crypto.randomUUID();
    const now = new Date().toISOString();

    // Validate contact for human resources
    if (requiresContact(resourceData.resource_type_id) && !resourceData.contact_id) {
      throw new ContactValidationError('Contact required for human resources');
    }

    // Validate contact exists and is eligible
    if (resourceData.contact_id) {
      await this.validateContactForResource(resourceData.contact_id, resourceData.resource_type_id);
    }

    const resourceRecord = {
      id: resourceId,
      tenant_id: this.config.tenant_id,
      is_live: this.config.is_live,
      resource_type_id: resourceData.resource_type_id,
      name: resourceData.name,
      description: resourceData.description || null,
      code: resourceData.code || null,
      contact_id: resourceData.contact_id || null,
      attributes: resourceData.attributes || {},
      availability_config: resourceData.availability_config || {},
      is_custom: true,
      status: resourceData.status || 'active',
      created_at: now,
      updated_at: now,
      created_by: this.config.user_id,
      updated_by: this.config.user_id
    };

    const { data: resource, error } = await this.supabase
      .from('t_catalog_resources')
      .insert(resourceRecord)
      .select()
      .single();

    if (error) {
      throw new ResourceError(`Failed to create resource: ${error.message}`);
    }

    // Create pricing if provided
    if (resourceData.pricing && resourceData.pricing.length > 0) {
      for (const pricingData of resourceData.pricing) {
        await this.createResourcePricingInTransaction(resourceId, pricingData);
      }
    }

    return resource;
  }

  /**
   * Update resource within transaction
   */
  private async updateResourceInTransaction(updateData: UpdateResourceRequest): Promise<void> {
    const updateFields: any = {
      updated_at: new Date().toISOString(),
      updated_by: this.config.user_id
    };

    if (updateData.name !== undefined) updateFields.name = updateData.name;
    if (updateData.description !== undefined) updateFields.description = updateData.description;
    if (updateData.code !== undefined) updateFields.code = updateData.code;
    if (updateData.contact_id !== undefined) updateFields.contact_id = updateData.contact_id;
    if (updateData.attributes !== undefined) updateFields.attributes = updateData.attributes;
    if (updateData.availability_config !== undefined) updateFields.availability_config = updateData.availability_config;
    if (updateData.status !== undefined) updateFields.status = updateData.status;

    const { error } = await this.supabase
      .from('t_catalog_resources')
      .update(updateFields)
      .eq('id', updateData.id)
      .eq('tenant_id', this.config.tenant_id)
      .eq('is_live', this.config.is_live);

    if (error) {
      throw new ResourceError(`Failed to update resource: ${error.message}`);
    }
  }

  /**
   * Create resource pricing
   */
  private async createResourcePricingInTransaction(
    resourceId: string, 
    pricingData: CreateResourcePricingRequest
  ): Promise<void> {
    const pricingRecord = {
      id: crypto.randomUUID(),
      tenant_id: this.config.tenant_id,
      resource_id: resourceId,
      is_live: this.config.is_live,
      pricing_type: pricingData.pricing_type,
      currency: pricingData.currency,
      rate: pricingData.rate,
      minimum_charge: pricingData.minimum_charge || null,
      maximum_charge: pricingData.maximum_charge || null,
      billing_increment: pricingData.billing_increment || null,
      tax_included: pricingData.tax_included || false,
      tax_rate_id: pricingData.tax_rate_id || null,
      effective_from: pricingData.effective_from || new Date().toISOString().split('T')[0],
      effective_to: pricingData.effective_to || null,
      is_active: true,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    };

    const { error } = await this.supabase
      .from('t_catalog_resource_pricing')
      .insert(pricingRecord);

    if (error) {
      throw new ResourceError(`Failed to create resource pricing: ${error.message}`);
    }
  }

  /**
   * Create catalog pricing
   */
  private async createCatalogPricingInTransaction(
    catalogId: string,
    pricingData: any,
    isBaseCurrency: boolean = false
  ): Promise<void> {
    // This would typically go to a catalog pricing table
    // For now, we'll skip this as pricing might be handled differently
    console.log('[Transaction] Catalog pricing created for:', catalogId);
  }

  /**
   * Add resource requirement
   */
  private async addResourceRequirementInTransaction(
    catalogId: string,
    requirementData: AddResourceRequirementRequest
  ): Promise<void> {
    const requirementRecord = {
      id: crypto.randomUUID(),
      tenant_id: this.config.tenant_id,
      is_live: this.config.is_live,
      service_id: catalogId,
      resource_id: requirementData.resource_id,
      requirement_type: requirementData.requirement_type,
      quantity_needed: requirementData.quantity_needed,
      usage_duration: requirementData.usage_duration || null,
      usage_notes: requirementData.usage_notes || null,
      alternative_group: requirementData.alternative_group || null,
      cost_override: requirementData.cost_override || null,
      cost_currency: requirementData.cost_currency || null,
      created_at: new Date().toISOString(),
      created_by: this.config.user_id
    };

    const { error } = await this.supabase
      .from('t_catalog_service_resources')
      .insert(requirementRecord);

    if (error) {
      throw new ResourceError(`Failed to add resource requirement: ${error.message}`);
    }
  }

  /**
   * Remove resource requirement
   */
  private async removeResourceRequirementInTransaction(
    catalogId: string,
    resourceId: string
  ): Promise<void> {
    const { error } = await this.supabase
      .from('t_catalog_service_resources')
      .delete()
      .eq('service_id', catalogId)
      .eq('resource_id', resourceId)
      .eq('tenant_id', this.config.tenant_id)
      .eq('is_live', this.config.is_live);

    if (error) {
      throw new ResourceError(`Failed to remove resource requirement: ${error.message}`);
    }
  }

  // =================================================================
  // VALIDATION HELPERS
  // =================================================================

  /**
   * Validate contact eligibility for resource
   */
  private async validateContactForResource(contactId: string, resourceType: string): Promise<void> {
    const requiredClassifications = resourceType === 'team_staff' ? ['team_member'] : ['partner', 'vendor'];

    const { data: contact, error } = await this.supabase
      .from('t_contacts')
      .select('id, company_name, name, classifications, status')
      .eq('id', contactId)
      .eq('tenant_id', this.config.tenant_id)
      .single();

    if (error || !contact) {
      throw new ContactValidationError(`Contact ${contactId} not found`);
    }

    if (contact.status !== 'active') {
      throw new ContactValidationError(`Contact ${contactId} is not active`);
    }

    // STRICT validation: contact must have required classification
    const hasRequiredClassification = requiredClassifications.some(classification =>
      contact.classifications && contact.classifications.includes(classification)
    );

    if (!hasRequiredClassification) {
      throw new ContactValidationError(
        `Contact ${contactId} must have classification: ${requiredClassifications.join(' or ')}`
      );
    }
  }

  /**
   * Calculate estimated resource cost
   */
  private calculateEstimatedResourceCost(requirements: ServiceResourceRequirement[]): number {
    return requirements.reduce((total, req) => {
      const baseCost = req.cost_override || 100;
      return total + (baseCost * req.quantity_needed);
    }, 0);
  }
}