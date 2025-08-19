import { ServiceCatalogItemData, ServiceCatalogFilters, ServicePricingConfig, EnvironmentContext, AuditTrail } from './serviceCatalogTypes.ts';
import { getCurrencyByCode, getDefaultCurrency } from './currencyUtils.ts';

export class ServiceCatalogUtils {
  
  static generateSlug(serviceName: string): string {
    console.log('🔧 Utils - generating slug for service name:', serviceName);
    
    const slug = serviceName
      .toLowerCase()
      .trim()
      .replace(/[^a-z0-9\s-]/g, '')
      .replace(/\s+/g, '-')
      .replace(/-+/g, '-')
      .replace(/^-+|-+$/g, '');
    
    console.log('✅ Utils - slug generated:', slug);
    return slug;
  }

  static generateRequestId(): string {
    const timestamp = Date.now();
    const random = Math.random().toString(36).substr(2, 9);
    const requestId = `req_${timestamp}_${random}`;
    
    console.log('🔧 Utils - generated request ID:', requestId);
    return requestId;
  }

  static generateBatchId(): string {
    const timestamp = Date.now();
    const random = Math.random().toString(36).substr(2, 9);
    const batchId = `batch_${timestamp}_${random}`;
    
    console.log('🔧 Utils - generated batch ID:', batchId);
    return batchId;
  }

  static generateIdempotencyKey(operation: string, data?: any): string {
    const timestamp = Date.now();
    const dataHash = data ? this.hashObject(data) : 'no-data';
    const random = Math.random().toString(36).substr(2, 6);
    const key = `${operation}_${timestamp}_${dataHash}_${random}`;
    
    console.log('🔧 Utils - generated idempotency key:', { operation, key: key.substring(0, 50) + '...' });
    return key;
  }

  static hashObject(obj: any): string {
    const str = JSON.stringify(obj, Object.keys(obj).sort());
    let hash = 0;
    
    for (let i = 0; i < str.length; i++) {
      const char = str.charCodeAt(i);
      hash = ((hash << 5) - hash) + char;
      hash = hash & hash;
    }
    
    return Math.abs(hash).toString(36);
  }

  static createEnvironmentContext(
    tenantId: string, 
    userId: string, 
    isLive: boolean,
    requestId?: string,
    ipAddress?: string,
    userAgent?: string
  ): EnvironmentContext {
    const context: EnvironmentContext = {
      tenant_id: tenantId,
      user_id: userId,
      is_live: isLive,
      request_id: requestId || this.generateRequestId(),
      timestamp: new Date().toISOString(),
      ip_address: ipAddress,
      user_agent: userAgent
    };

    console.log('🔧 Utils - created environment context:', {
      tenant_id: context.tenant_id,
      user_id: context.user_id,
      is_live: context.is_live,
      request_id: context.request_id
    });

    return context;
  }

  static createAuditTrail(
    operationId: string,
    operationType: string,
    tableName: string,
    recordId: string,
    environmentContext: EnvironmentContext,
    executionTimeMs: number,
    success: boolean,
    oldValues?: Record<string, any>,
    newValues?: Record<string, any>,
    errorDetails?: string
  ): AuditTrail {
    const auditTrail: AuditTrail = {
      operation_id: operationId,
      operation_type: operationType,
      table_name: tableName,
      record_id: recordId,
      old_values: oldValues,
      new_values: newValues,
      environment_context: environmentContext,
      execution_time_ms: executionTimeMs,
      success,
      error_details: errorDetails
    };

    console.log('🔧 Utils - created audit trail:', {
      operation_id: auditTrail.operation_id,
      operation_type: auditTrail.operation_type,
      table_name: auditTrail.table_name,
      record_id: auditTrail.record_id,
      success: auditTrail.success,
      execution_time_ms: auditTrail.execution_time_ms
    });

    return auditTrail;
  }

  static formatPrice(amount: number, currency: string): string {
    const currencyInfo = getCurrencyByCode(currency) || getDefaultCurrency();
    
    const formattedPrice = new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: currencyInfo.code,
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    }).format(amount);

    console.log('🔧 Utils - formatted price:', {
      amount,
      currency,
      formatted: formattedPrice
    });

    return formattedPrice;
  }

  static calculateTieredPrice(quantity: number, pricingConfig: ServicePricingConfig): { finalPrice: number; appliedTier?: any; discount?: number } {
    console.log('🔧 Utils - calculating tiered price:', {
      quantity,
      pricingModel: pricingConfig.pricing_model,
      basePrice: pricingConfig.base_price,
      tiersCount: pricingConfig.tiers?.length || 0
    });

    if (pricingConfig.pricing_model !== 'tiered' || !pricingConfig.tiers || pricingConfig.tiers.length === 0) {
      const totalPrice = pricingConfig.base_price * quantity;
      console.log('✅ Utils - fixed pricing calculated:', { totalPrice });
      return { finalPrice: totalPrice };
    }

    const sortedTiers = [...pricingConfig.tiers].sort((a, b) => a.min_quantity - b.min_quantity);
    let appliedTier = null;

    for (const tier of sortedTiers) {
      if (quantity >= tier.min_quantity && (!tier.max_quantity || quantity <= tier.max_quantity)) {
        appliedTier = tier;
        break;
      }
    }

    let finalPrice = pricingConfig.base_price * quantity;
    let discount = 0;

    if (appliedTier) {
      if (appliedTier.price) {
        finalPrice = appliedTier.price * quantity;
      } else if (appliedTier.discount_percentage) {
        discount = (finalPrice * appliedTier.discount_percentage) / 100;
        finalPrice -= discount;
      }
    }

    console.log('✅ Utils - tiered pricing calculated:', {
      finalPrice,
      appliedTier: appliedTier ? {
        min_quantity: appliedTier.min_quantity,
        max_quantity: appliedTier.max_quantity,
        price: appliedTier.price,
        discount_percentage: appliedTier.discount_percentage
      } : null,
      discount
    });

    return { finalPrice, appliedTier, discount };
  }

  static applyDiscountRules(basePrice: number, quantity: number, pricingConfig: ServicePricingConfig, context?: Record<string, any>): { finalPrice: number; appliedRules: any[] } {
    console.log('🔧 Utils - applying discount rules:', {
      basePrice,
      quantity,
      rulesCount: pricingConfig.discount_rules?.length || 0,
      hasContext: !!context
    });

    if (!pricingConfig.discount_rules || pricingConfig.discount_rules.length === 0) {
      console.log('✅ Utils - no discount rules to apply');
      return { finalPrice: basePrice, appliedRules: [] };
    }

    let finalPrice = basePrice;
    const appliedRules: any[] = [];

    for (const rule of pricingConfig.discount_rules) {
      if (!rule.is_active) continue;

      let conditionMet = false;
      
      try {
        conditionMet = this.evaluateDiscountCondition(rule.condition, { quantity, basePrice, ...context });
      } catch (error) {
        console.warn('⚠️ Utils - error evaluating discount condition:', rule.condition, error);
        continue;
      }

      if (conditionMet) {
        const discountAmount = this.calculateDiscountAmount(rule.action, finalPrice, rule.value);
        finalPrice -= discountAmount;
        
        appliedRules.push({
          rule_name: rule.rule_name,
          condition: rule.condition,
          action: rule.action,
          discount_amount: discountAmount
        });

        console.log('✅ Utils - discount rule applied:', {
          rule_name: rule.rule_name,
          condition: rule.condition,
          action: rule.action,
          discount_amount: discountAmount,
          new_price: finalPrice
        });
      }
    }

    console.log('✅ Utils - discount rules processing complete:', {
      originalPrice: basePrice,
      finalPrice,
      rulesApplied: appliedRules.length
    });

    return { finalPrice: Math.max(0, finalPrice), appliedRules };
  }

  private static evaluateDiscountCondition(condition: string, context: Record<string, any>): boolean {
    const safeCondition = condition
      .replace(/quantity/g, context.quantity || 0)
      .replace(/basePrice/g, context.basePrice || 0)
      .replace(/customer_years/g, context.customer_years || 0)
      .replace(/vehicles/g, context.vehicles || 0)
      .replace(/payment/g, `"${context.payment || ''}"`)
      .replace(/service_type/g, `"${context.service_type || ''}"`)
      .replace(/season/g, `"${context.season || ''}"`)
      .replace(/day/g, `"${context.day || ''}"`)
      .replace(/time/g, `"${context.time || ''}"`)
      .replace(/location/g, `"${context.location || ''}"`)
      .replace(/date/g, `"${context.date || ''}"`)
      .replace(/contract_type/g, `"${context.contract_type || ''}"`)
      .replace(/certification/g, `"${context.certification || ''}"`)
      .replace(/duration/g, context.duration || 0)
      .replace(/performance/g, `"${context.performance || ''}"`);

    const allowedOperators = /^[\d\s><=!()&|"'\w.+-]+$/;
    if (!allowedOperators.test(safeCondition)) {
      throw new Error('Invalid characters in condition');
    }

    try {
      return eval(safeCondition);
    } catch (error) {
      console.warn('⚠️ Utils - condition evaluation failed:', safeCondition, error);
      return false;
    }
  }

  private static calculateDiscountAmount(action: string, currentPrice: number, value?: number): number {
    if (action.includes('%')) {
      const percentage = parseFloat(action.replace(/[^\d.]/g, ''));
      return (currentPrice * percentage) / 100;
    } else if (action.includes('fixed')) {
      return value || 0;
    } else if (action.includes('-')) {
      const amount = parseFloat(action.replace(/[^\d.]/g, ''));
      return amount;
    }
    
    return 0;
  }

  static sanitizeFilters(filters: ServiceCatalogFilters): ServiceCatalogFilters {
    console.log('🔧 Utils - sanitizing filters:', {
      hasSearchTerm: !!filters.search_term,
      hasCategoryId: !!filters.category_id,
      hasIndustryId: !!filters.industry_id,
      hasLimit: !!filters.limit,
      hasOffset: !!filters.offset
    });

    const sanitized: ServiceCatalogFilters = {};

    if (filters.search_term) {
      sanitized.search_term = filters.search_term.trim().substring(0, 255);
    }

    if (filters.category_id) {
      sanitized.category_id = filters.category_id.trim();
    }

    if (filters.industry_id) {
      sanitized.industry_id = filters.industry_id.trim();
    }

    if (filters.is_active !== undefined) {
      sanitized.is_active = filters.is_active;
    }

    if (filters.price_min !== undefined && filters.price_min >= 0) {
      sanitized.price_min = Math.max(0, filters.price_min);
    }

    if (filters.price_max !== undefined && filters.price_max >= 0) {
      sanitized.price_max = Math.max(0, filters.price_max);
    }

    if (filters.currency) {
      sanitized.currency = filters.currency.toUpperCase().substring(0, 3);
    }

    if (filters.has_resources !== undefined) {
      sanitized.has_resources = filters.has_resources;
    }

    if (filters.duration_min !== undefined && filters.duration_min > 0) {
      sanitized.duration_min = Math.max(1, filters.duration_min);
    }

    if (filters.duration_max !== undefined && filters.duration_max > 0) {
      sanitized.duration_max = Math.max(1, filters.duration_max);
    }

    if (filters.tags && Array.isArray(filters.tags)) {
      sanitized.tags = filters.tags.filter(tag => tag && tag.trim()).slice(0, 10);
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

    sanitized.limit = Math.min(1000, Math.max(1, filters.limit || 50));
    sanitized.offset = Math.max(0, filters.offset || 0);

    console.log('✅ Utils - filters sanitized:', {
      originalKeysCount: Object.keys(filters).length,
      sanitizedKeysCount: Object.keys(sanitized).length,
      limit: sanitized.limit,
      offset: sanitized.offset
    });

    return sanitized;
  }

  static buildSearchQuery(filters: ServiceCatalogFilters): string {
    const conditions: string[] = [];
    
    console.log('🔧 Utils - building search query from filters:', {
      hasSearchTerm: !!filters.search_term,
      hasCategoryId: !!filters.category_id,
      hasIndustryId: !!filters.industry_id,
      hasIsActive: filters.is_active !== undefined
    });

    if (filters.search_term) {
      conditions.push(`(service_name ILIKE '%${filters.search_term}%' OR description ILIKE '%${filters.search_term}%' OR sku ILIKE '%${filters.search_term}%')`);
    }

    if (filters.category_id) {
      conditions.push(`category_id = '${filters.category_id}'`);
    }

    if (filters.industry_id) {
      conditions.push(`industry_id = '${filters.industry_id}'`);
    }

    if (filters.is_active !== undefined) {
      conditions.push(`is_active = ${filters.is_active}`);
    }

    if (filters.price_min !== undefined || filters.price_max !== undefined) {
      if (filters.price_min !== undefined && filters.price_max !== undefined) {
        conditions.push(`(pricing_config->>'base_price')::numeric BETWEEN ${filters.price_min} AND ${filters.price_max}`);
      } else if (filters.price_min !== undefined) {
        conditions.push(`(pricing_config->>'base_price')::numeric >= ${filters.price_min}`);
      } else if (filters.price_max !== undefined) {
        conditions.push(`(pricing_config->>'base_price')::numeric <= ${filters.price_max}`);
      }
    }

    if (filters.currency) {
      conditions.push(`pricing_config->>'currency' = '${filters.currency}'`);
    }

    if (filters.has_resources !== undefined) {
      if (filters.has_resources) {
        conditions.push(`required_resources IS NOT NULL AND jsonb_array_length(required_resources) > 0`);
      } else {
        conditions.push(`(required_resources IS NULL OR jsonb_array_length(required_resources) = 0)`);
      }
    }

    if (filters.duration_min !== undefined || filters.duration_max !== undefined) {
      if (filters.duration_min !== undefined && filters.duration_max !== undefined) {
        conditions.push(`duration_minutes BETWEEN ${filters.duration_min} AND ${filters.duration_max}`);
      } else if (filters.duration_min !== undefined) {
        conditions.push(`duration_minutes >= ${filters.duration_min}`);
      } else if (filters.duration_max !== undefined) {
        conditions.push(`duration_minutes <= ${filters.duration_max}`);
      }
    }

    if (filters.tags && filters.tags.length > 0) {
      const tagConditions = filters.tags.map(tag => `tags ? '${tag}'`);
      conditions.push(`(${tagConditions.join(' OR ')})`);
    }

    const whereClause = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
    
    console.log('✅ Utils - search query built:', {
      conditionsCount: conditions.length,
      whereClause: whereClause.substring(0, 200) + (whereClause.length > 200 ? '...' : '')
    });

    return whereClause;
  }

  static buildSortClause(sortBy?: string, sortDirection?: string): string {
    const defaultSort = 'ORDER BY sort_order ASC, created_at DESC';
    
    if (!sortBy) {
      console.log('🔧 Utils - using default sort clause');
      return defaultSort;
    }

    const direction = (sortDirection === 'desc') ? 'DESC' : 'ASC';
    let sortClause = '';

    switch (sortBy) {
      case 'name':
        sortClause = `ORDER BY service_name ${direction}`;
        break;
      case 'price':
        sortClause = `ORDER BY (pricing_config->>'base_price')::numeric ${direction}`;
        break;
      case 'created_at':
        sortClause = `ORDER BY created_at ${direction}`;
        break;
      case 'sort_order':
        sortClause = `ORDER BY sort_order ${direction}`;
        break;
      case 'usage_count':
        sortClause = `ORDER BY usage_count ${direction} NULLS LAST`;
        break;
      case 'avg_rating':
        sortClause = `ORDER BY avg_rating ${direction} NULLS LAST`;
        break;
      default:
        sortClause = defaultSort;
        break;
    }

    console.log('✅ Utils - sort clause built:', { sortBy, sortDirection, sortClause });
    return sortClause;
  }

  static calculatePaginationInfo(totalCount: number, limit: number, offset: number) {
    const currentPage = Math.floor(offset / limit) + 1;
    const totalPages = Math.ceil(totalCount / limit);
    const hasNextPage = currentPage < totalPages;
    const hasPrevPage = currentPage > 1;

    const paginationInfo = {
      has_next_page: hasNextPage,
      has_prev_page: hasPrevPage,
      current_page: currentPage,
      total_pages: totalPages
    };

    console.log('🔧 Utils - calculated pagination info:', {
      totalCount,
      limit,
      offset,
      ...paginationInfo
    });

    return paginationInfo;
  }

  static extractTaxSettings(serviceData: ServiceCatalogItemData, taxRatesData?: any[], taxDisplayMode?: 'including_tax' | 'excluding_tax') {
    console.log('🔧 Utils - extracting tax settings:', {
      hasServiceData: !!serviceData,
      hasTaxRates: !!taxRatesData && taxRatesData.length > 0,
      taxDisplayMode
    });

    const result = {
      tax_inclusive: serviceData.pricing_config?.tax_inclusive || (taxDisplayMode === 'including_tax'),
      applicable_tax_rates: [],
      effective_tax_rate: 0
    };

    if (taxRatesData && taxRatesData.length > 0) {
      const defaultTaxRate = taxRatesData.find(rate => rate.is_default && rate.is_active);
      if (defaultTaxRate) {
        result.applicable_tax_rates = [defaultTaxRate];
        result.effective_tax_rate = defaultTaxRate.rate;
      }
    }

    console.log('✅ Utils - tax settings extracted:', result);
    return result;
  }

  static formatServiceResponse(services: any[], totalCount: number, filters: ServiceCatalogFilters) {
    const paginationInfo = this.calculatePaginationInfo(
      totalCount,
      filters.limit || 50,
      filters.offset || 0
    );

    const response = {
      items: services,
      total_count: totalCount,
      page_info: paginationInfo,
      filters_applied: filters
    };

    console.log('✅ Utils - service response formatted:', {
      itemsCount: services.length,
      totalCount,
      pageInfo: paginationInfo
    });

    return response;
  }

  static sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  static isValidUUID(uuid: string): boolean {
    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    return uuidPattern.test(uuid);
  }

  static measureExecutionTime<T>(operation: () => Promise<T>): Promise<{ result: T; executionTime: number }> {
    const startTime = Date.now();
    
    return operation().then(result => {
      const executionTime = Date.now() - startTime;
      return { result, executionTime };
    }).catch(error => {
      const executionTime = Date.now() - startTime;
      console.error('🔧 Utils - operation failed with execution time:', { executionTime, error });
      throw error;
    });
  }

  static deepClone<T>(obj: T): T {
    return JSON.parse(JSON.stringify(obj));
  }

  static isEmpty(value: any): boolean {
    if (value == null) return true;
    if (typeof value === 'string') return value.trim().length === 0;
    if (Array.isArray(value)) return value.length === 0;
    if (typeof value === 'object') return Object.keys(value).length === 0;
    return false;
  }
}