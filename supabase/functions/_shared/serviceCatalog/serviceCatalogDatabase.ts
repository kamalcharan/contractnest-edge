import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { ServiceCatalogItemData, ServiceCatalogFilters, EnvironmentContext, AuditTrail, IdempotencyRecord, RateLimitInfo } from './serviceCatalogTypes.ts';
import { ServiceCatalogUtils } from './serviceCatalogUtils.ts';

export class ServiceCatalogDatabase {
  
  constructor(private supabase: SupabaseClient) {}

  async checkIdempotency(key: string, tenantId: string, userId: string): Promise<IdempotencyRecord | null> {
    console.log('🗄️ Database - checking idempotency:', {
      key: key.substring(0, 50) + '...',
      tenantId,
      userId
    });

    try {
      const { data, error } = await this.supabase
        .from('idempotency_records')
        .select('*')
        .eq('key', key)
        .eq('tenant_id', tenantId)
        .eq('user_id', userId)
        .gte('expires_at', new Date().toISOString())
        .single();

      if (error && error.code !== 'PGRST116') {
        console.error('❌ Database - idempotency check error:', error);
        throw error;
      }

      console.log('✅ Database - idempotency check complete:', {
        found: !!data,
        expired: data ? new Date(data.expires_at) < new Date() : false
      });

      return data;
    } catch (error) {
      console.error('❌ Database - idempotency check failed:', error);
      throw error;
    }
  }

  async storeIdempotencyRecord(
    key: string,
    operationType: string,
    requestHash: string,
    responseData: any,
    tenantId: string,
    userId: string,
    expiresInHours = 24
  ): Promise<void> {
    console.log('🗄️ Database - storing idempotency record:', {
      key: key.substring(0, 50) + '...',
      operationType,
      tenantId,
      userId,
      expiresInHours
    });

    try {
      const expiresAt = new Date(Date.now() + (expiresInHours * 60 * 60 * 1000));

      const { error } = await this.supabase
        .from('idempotency_records')
        .insert({
          key,
          operation_type: operationType,
          request_hash: requestHash,
          response_data: responseData,
          tenant_id: tenantId,
          user_id: userId,
          expires_at: expiresAt.toISOString(),
          created_at: new Date().toISOString()
        });

      if (error) {
        console.error('❌ Database - idempotency record storage error:', error);
        throw error;
      }

      console.log('✅ Database - idempotency record stored successfully');
    } catch (error) {
      console.error('❌ Database - idempotency record storage failed:', error);
      throw error;
    }
  }

  async checkRateLimit(tenantId: string, userId: string, endpoint: string, limit: number, windowMinutes: number): Promise<RateLimitInfo> {
    console.log('🗄️ Database - checking rate limit:', {
      tenantId,
      userId,
      endpoint,
      limit,
      windowMinutes
    });

    try {
      const windowStart = new Date(Date.now() - (windowMinutes * 60 * 1000));
      const windowEnd = new Date();

      const { data, error } = await this.supabase
        .from('rate_limit_records')
        .select('*')
        .eq('tenant_id', tenantId)
        .eq('user_id', userId)
        .eq('endpoint', endpoint)
        .gte('created_at', windowStart.toISOString())
        .lte('created_at', windowEnd.toISOString());

      if (error) {
        console.error('❌ Database - rate limit check error:', error);
        throw error;
      }

      const requestsMade = data?.length || 0;
      const isLimited = requestsMade >= limit;
      const resetTime = new Date(windowStart.getTime() + (windowMinutes * 60 * 1000));

      const rateLimitInfo: RateLimitInfo = {
        requests_made: requestsMade,
        requests_limit: limit,
        window_start: windowStart.toISOString(),
        window_end: windowEnd.toISOString(),
        reset_time: resetTime.toISOString(),
        is_limited: isLimited
      };

      console.log('✅ Database - rate limit check complete:', {
        requestsMade,
        limit,
        isLimited
      });

      return rateLimitInfo;
    } catch (error) {
      console.error('❌ Database - rate limit check failed:', error);
      throw error;
    }
  }

  async recordRateLimitRequest(tenantId: string, userId: string, endpoint: string, ipAddress?: string): Promise<void> {
    console.log('🗄️ Database - recording rate limit request:', {
      tenantId,
      userId,
      endpoint,
      hasIpAddress: !!ipAddress
    });

    try {
      const { error } = await this.supabase
        .from('rate_limit_records')
        .insert({
          tenant_id: tenantId,
          user_id: userId,
          endpoint,
          ip_address: ipAddress,
          created_at: new Date().toISOString()
        });

      if (error) {
        console.error('❌ Database - rate limit record error:', error);
        throw error;
      }

      console.log('✅ Database - rate limit request recorded successfully');
    } catch (error) {
      console.error('❌ Database - rate limit request recording failed:', error);
      throw error;
    }
  }

  async storeAuditTrail(auditTrail: AuditTrail): Promise<void> {
    console.log('🗄️ Database - storing audit trail:', {
      operation_id: auditTrail.operation_id,
      operation_type: auditTrail.operation_type,
      table_name: auditTrail.table_name,
      record_id: auditTrail.record_id,
      success: auditTrail.success
    });

    try {
      const { error } = await this.supabase
        .from('audit_trails')
        .insert({
          operation_id: auditTrail.operation_id,
          operation_type: auditTrail.operation_type,
          table_name: auditTrail.table_name,
          record_id: auditTrail.record_id,
          old_values: auditTrail.old_values,
          new_values: auditTrail.new_values,
          tenant_id: auditTrail.environment_context.tenant_id,
          user_id: auditTrail.environment_context.user_id,
          is_live: auditTrail.environment_context.is_live,
          request_id: auditTrail.environment_context.request_id,
          ip_address: auditTrail.environment_context.ip_address,
          user_agent: auditTrail.environment_context.user_agent,
          execution_time_ms: auditTrail.execution_time_ms,
          success: auditTrail.success,
          error_details: auditTrail.error_details,
          created_at: new Date().toISOString()
        });

      if (error) {
        console.error('❌ Database - audit trail storage error:', error);
        throw error;
      }

      console.log('✅ Database - audit trail stored successfully');
    } catch (error) {
      console.error('❌ Database - audit trail storage failed:', error);
    }
  }

  async acquireRowLock(tableName: string, recordId: string, timeoutMs = 30000): Promise<boolean> {
    console.log('🗄️ Database - acquiring row lock:', {
      tableName,
      recordId,
      timeoutMs
    });

    try {
      const lockKey = `${tableName}:${recordId}`;
      const lockId = ServiceCatalogUtils.generateRequestId();
      const expiresAt = new Date(Date.now() + timeoutMs);

      const { data, error } = await this.supabase
        .from('row_locks')
        .insert({
          lock_key: lockKey,
          lock_id: lockId,
          expires_at: expiresAt.toISOString(),
          created_at: new Date().toISOString()
        });

      if (error) {
        if (error.code === '23505') {
          console.log('⚠️ Database - row already locked');
          return false;
        }
        console.error('❌ Database - row lock acquisition error:', error);
        throw error;
      }

      console.log('✅ Database - row lock acquired:', { lockId });
      return true;
    } catch (error) {
      console.error('❌ Database - row lock acquisition failed:', error);
      return false;
    }
  }

  async releaseRowLock(tableName: string, recordId: string): Promise<void> {
    console.log('🗄️ Database - releasing row lock:', {
      tableName,
      recordId
    });

    try {
      const lockKey = `${tableName}:${recordId}`;

      const { error } = await this.supabase
        .from('row_locks')
        .delete()
        .eq('lock_key', lockKey);

      if (error) {
        console.error('❌ Database - row lock release error:', error);
        throw error;
      }

      console.log('✅ Database - row lock released successfully');
    } catch (error) {
      console.error('❌ Database - row lock release failed:', error);
    }
  }

  async cleanupExpiredLocks(): Promise<void> {
    console.log('🗄️ Database - cleaning up expired locks');

    try {
      const { error } = await this.supabase
        .from('row_locks')
        .delete()
        .lt('expires_at', new Date().toISOString());

      if (error) {
        console.error('❌ Database - expired locks cleanup error:', error);
        throw error;
      }

      console.log('✅ Database - expired locks cleaned up successfully');
    } catch (error) {
      console.error('❌ Database - expired locks cleanup failed:', error);
    }
  }

  async getMasterData(tenantId: string, isLive: boolean) {
    console.log('🗄️ Database - fetching master data:', {
      tenantId,
      isLive
    });

    try {
      const [categoriesResult, industriesResult] = await Promise.all([
        this.supabase
          .from('m_category_master')
          .select('*')
          .eq('is_active', true)
          .order('sort_order', { ascending: true }),
        
        this.supabase
          .from('m_catalog_industries')
          .select('*')
          .eq('is_active', true)
          .order('sort_order', { ascending: true })
      ]);

      if (categoriesResult.error) {
        console.error('❌ Database - categories fetch error:', categoriesResult.error);
        throw categoriesResult.error;
      }

      if (industriesResult.error) {
        console.error('❌ Database - industries fetch error:', industriesResult.error);
        throw industriesResult.error;
      }

      const masterData = {
        categories: categoriesResult.data || [],
        industries: industriesResult.data || [],
        currencies: [
          { code: 'USD', name: 'US Dollar', symbol: '$', decimal_places: 2, is_default: false },
          { code: 'EUR', name: 'Euro', symbol: '€', decimal_places: 2, is_default: false },
          { code: 'INR', name: 'Indian Rupee', symbol: '₹', decimal_places: 2, is_default: true }
        ],
        tax_rates: []
      };

      console.log('✅ Database - master data fetched:', {
        categoriesCount: masterData.categories.length,
        industriesCount: masterData.industries.length,
        currenciesCount: masterData.currencies.length
      });

      return masterData;
    } catch (error) {
      console.error('❌ Database - master data fetch failed:', error);
      throw error;
    }
  }

  async getServiceCatalogItemById(serviceId: string, tenantId: string, isLive: boolean) {
    console.log('🗄️ Database - fetching service by ID:', {
      serviceId,
      tenantId,
      isLive
    });

    try {
      const { data, error } = await this.supabase
        .from('t_catalog_items')
        .select(`
          *,
          category:m_category_master!category_id(name),
          industry:m_catalog_industries!industry_id(name)
        `)
        .eq('id', serviceId)
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive)
        .single();

      if (error) {
        if (error.code === 'PGRST116') {
          console.log('⚠️ Database - service not found');
          return null;
        }
        console.error('❌ Database - service fetch error:', error);
        throw error;
      }

      console.log('✅ Database - service fetched successfully:', {
        serviceId: data.id,
        serviceName: data.service_name
      });

      return {
        ...data,
        category_name: data.category?.name,
        industry_name: data.industry?.name
      };
    } catch (error) {
      console.error('❌ Database - service fetch failed:', error);
      throw error;
    }
  }

  async queryServiceCatalogItems(filters: ServiceCatalogFilters, tenantId: string, isLive: boolean) {
    console.log('🗄️ Database - querying services with filters:', {
      tenantId,
      isLive,
      hasSearchTerm: !!filters.search_term,
      hasCategoryId: !!filters.category_id,
      hasIndustryId: !!filters.industry_id,
      limit: filters.limit,
      offset: filters.offset
    });

    try {
      let query = this.supabase
        .from('t_catalog_items')
        .select(`
          *,
          category:m_category_master!category_id(name),
          industry:m_catalog_industries!industry_id(name)
        `, { count: 'exact' })
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive);

      if (filters.search_term) {
        query = query.or(`service_name.ilike.%${filters.search_term}%,description.ilike.%${filters.search_term}%,sku.ilike.%${filters.search_term}%`);
      }

      if (filters.category_id) {
        query = query.eq('category_id', filters.category_id);
      }

      if (filters.industry_id) {
        query = query.eq('industry_id', filters.industry_id);
      }

      if (filters.is_active !== undefined) {
        query = query.eq('is_active', filters.is_active);
      }

      if (filters.has_resources !== undefined) {
        if (filters.has_resources) {
          query = query.not('required_resources', 'is', null);
        } else {
          query = query.is('required_resources', null);
        }
      }

      if (filters.duration_min !== undefined) {
        query = query.gte('duration_minutes', filters.duration_min);
      }

      if (filters.duration_max !== undefined) {
        query = query.lte('duration_minutes', filters.duration_max);
      }

      if (filters.sort_by) {
        const direction = filters.sort_direction === 'desc';
        switch (filters.sort_by) {
          case 'name':
            query = query.order('service_name', { ascending: !direction });
            break;
          case 'created_at':
            query = query.order('created_at', { ascending: !direction });
            break;
          case 'sort_order':
            query = query.order('sort_order', { ascending: !direction });
            break;
          default:
            query = query.order('sort_order', { ascending: true }).order('created_at', { ascending: false });
            break;
        }
      } else {
        query = query.order('sort_order', { ascending: true }).order('created_at', { ascending: false });
      }

      const limit = Math.min(1000, filters.limit || 50);
      const offset = Math.max(0, filters.offset || 0);

      query = query.range(offset, offset + limit - 1);

      const { data, error, count } = await query;

      if (error) {
        console.error('❌ Database - services query error:', error);
        throw error;
      }

      const services = (data || []).map(service => ({
        ...service,
        category_name: service.category?.name,
        industry_name: service.industry?.name
      }));

      console.log('✅ Database - services queried successfully:', {
        servicesCount: services.length,
        totalCount: count || 0,
        limit,
        offset
      });

      return {
        items: services,
        total_count: count || 0
      };
    } catch (error) {
      console.error('❌ Database - services query failed:', error);
      throw error;
    }
  }

  async getAvailableResources(filters: any, tenantId: string, isLive: boolean) {
    console.log('🗄️ Database - fetching available resources:', {
      tenantId,
      isLive,
      hasSkills: !!filters.skills,
      hasLocationType: !!filters.location_type,
      hasCostRange: !!(filters.cost_min || filters.cost_max)
    });

    try {
      let query = this.supabase
        .from('t_resources')
        .select('*')
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive)
        .eq('is_active', true)
        .eq('is_available', true);

      if (filters.location_type) {
        query = query.eq('location_type', filters.location_type);
      }

      if (filters.cost_min !== undefined) {
        query = query.gte('hourly_rate', filters.cost_min);
      }

      if (filters.cost_max !== undefined) {
        query = query.lte('hourly_rate', filters.cost_max);
      }

      if (filters.rating_min !== undefined) {
        query = query.gte('rating', filters.rating_min);
      }

      if (filters.experience_years !== undefined) {
        query = query.gte('experience_years', filters.experience_years);
      }

      const limit = Math.min(1000, filters.limit || 50);
      const offset = Math.max(0, filters.offset || 0);

      query = query.order('rating', { ascending: false }).range(offset, offset + limit - 1);

      const { data, error, count } = await query;

      if (error) {
        console.error('❌ Database - resources query error:', error);
        throw error;
      }

      const resources = (data || []).map(resource => ({
        ...resource,
        availability_score: this.calculateAvailabilityScore(resource),
        next_available_date: resource.next_available_date || null
      }));

      console.log('✅ Database - resources fetched successfully:', {
        resourcesCount: resources.length,
        totalCount: count || 0
      });

      return {
        resources,
        total_count: count || 0,
        matching_criteria: {
          skill_matches: resources.length,
          location_matches: resources.length,
          availability_matches: resources.length,
          cost_matches: resources.length
        }
      };
    } catch (error) {
      console.error('❌ Database - resources fetch failed:', error);
      throw error;
    }
  }

  async getServiceResources(serviceId: string, tenantId: string, isLive: boolean) {
    console.log('🗄️ Database - fetching service resources:', {
      serviceId,
      tenantId,
      isLive
    });

    try {
      const { data, error } = await this.supabase
        .from('t_service_resource_associations')
        .select(`
          *,
          resource:t_resources!resource_id(*)
        `)
        .eq('service_id', serviceId)
        .eq('tenant_id', tenantId)
        .eq('is_live', isLive)
        .eq('is_active', true);

      if (error) {
        console.error('❌ Database - service resources fetch error:', error);
        throw error;
      }

      const associatedResources = (data || []).map(association => ({
        resource_id: association.resource_id,
        resource_name: association.resource?.name || 'Unknown Resource',
        resource_type: association.resource?.type || 'Unknown',
        quantity: association.quantity || 1,
        is_required: association.is_required || false,
        skill_match_score: association.skill_match_score || 0,
        estimated_cost: association.estimated_cost || 0
      }));

      const totalEstimatedCost = associatedResources.reduce((sum, resource) => sum + resource.estimated_cost, 0);

      console.log('✅ Database - service resources fetched:', {
        associatedResourcesCount: associatedResources.length,
        totalEstimatedCost
      });

      return {
        service_id: serviceId,
        service_name: 'Service Name',
        associated_resources: associatedResources,
        total_resources: associatedResources.length,
        total_estimated_cost: totalEstimatedCost,
        resource_availability_score: this.calculateResourceAvailabilityScore(associatedResources),
        available_alternatives: []
      };
    } catch (error) {
      console.error('❌ Database - service resources fetch failed:', error);
      throw error;
    }
  }

  private calculateAvailabilityScore(resource: any): number {
    let score = 0.5;
    
    if (resource.is_available) score += 0.3;
    if (resource.rating >= 4.5) score += 0.2;
    if (resource.experience_years >= 5) score += 0.1;
    if (!resource.next_available_date) score += 0.2;
    
    return Math.min(1.0, Math.max(0.0, score));
  }

  private calculateResourceAvailabilityScore(resources: any[]): number {
    if (resources.length === 0) return 0;
    
    const totalScore = resources.reduce((sum, resource) => {
      return sum + (resource.skill_match_score || 0.5);
    }, 0);
    
    return totalScore / resources.length;
  }

  async executeInTransaction<T>(operations: (() => Promise<T>)[]): Promise<T[]> {
    console.log('🗄️ Database - executing transaction with operations:', operations.length);

    try {
      const results: T[] = [];
      
      for (const operation of operations) {
        const result = await operation();
        results.push(result);
      }

      console.log('✅ Database - transaction completed successfully');
      return results;
    } catch (error) {
      console.error('❌ Database - transaction failed:', error);
      throw error;
    }
  }

  async healthCheck(): Promise<boolean> {
    try {
      const { data, error } = await this.supabase
        .from('m_category_master')
        .select('id')
        .limit(1);

      return !error;
    } catch (error) {
      console.error('❌ Database - health check failed:', error);
      return false;
    }
  }
}