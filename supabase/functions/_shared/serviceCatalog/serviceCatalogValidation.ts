
//supabase/functions/_shared/serviceCatalog/serviceCatalogValidations.ts
import { ServiceCatalogItemData, ServiceCatalogFilters, ServiceResourceAssociation, BulkServiceOperation, ServicePricingUpdate, TenantConfiguration, TenantValidationLimits, DEFAULT_VALIDATION_LIMITS } from './serviceCatalogTypes.ts';

export class ServiceCatalogValidationError extends Error {
  constructor(
    message: string,
    public field: string,
    public code: string,
    public value?: any
  ) {
    super(message);
    this.name = 'ServiceCatalogValidationError';
  }
}

export interface ValidationResult {
  isValid: boolean;
  errors: ServiceCatalogValidationError[];
}

export class ServiceCatalogValidator {
  
  // UPDATED: Dynamic validation rules based on tenant configuration
  private static getValidationRules(tenantConfig?: TenantConfiguration | null) {
    const limits = tenantConfig?.validation_limits || DEFAULT_VALIDATION_LIMITS.professional;
    
    return {
      SERVICE_NAME: {
        MIN_LENGTH: 2,
        MAX_LENGTH: limits.max_service_name_length,
        PATTERN: /^[a-zA-Z0-9\s\-_.,()&]+$/
      },
      DESCRIPTION: {
        MAX_LENGTH: limits.max_description_length
      },
      PRICE: {
        MIN: 0,
        MAX: limits.max_price_value,
        DECIMAL_PLACES: 2
      },
      SKU: {
        MAX_LENGTH: limits.max_sku_length,
        PATTERN: /^[A-Za-z0-9\-_]+$/
      },
      CATEGORY: {
        MIN_LENGTH: 1,
        MAX_LENGTH: 100
      },
      DURATION: {
        MIN: 1,
        MAX: limits.max_duration_minutes
      },
      SORT_ORDER: {
        MIN: 1,
        MAX: 999999
      },
      CURRENCY: {
        PATTERN: /^[A-Z]{3}$/
      },
      SLUG: {
        MIN_LENGTH: 2,
        MAX_LENGTH: 100,
        PATTERN: /^[a-z0-9]+(?:-[a-z0-9]+)*$/
      },
      RESOURCES: {
        MAX_PER_SERVICE: limits.max_resources_per_service
      },
      PRICING_TIERS: {
        MAX_COUNT: limits.max_pricing_tiers
      },
      TAGS: {
        MAX_COUNT: limits.max_tags_per_service
      }
    };
  }

  // UPDATED: Now accepts tenant configuration for dynamic validation
  static validateServiceCatalogItem(
    data: Partial<ServiceCatalogItemData>, 
    tenantConfig?: TenantConfiguration | null
  ): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];
    const rules = this.getValidationRules(tenantConfig);

    console.log('🔍 Service validation - validating service catalog item:', {
      hasName: !!data.service_name,
      hasCategory: !!data.category_id,
      hasIndustry: !!data.industry_id,
      hasPricing: !!data.pricing_config,
      resourceCount: data.required_resources?.length || 0,
      tenantPlan: tenantConfig?.plan_type || 'default',
      maxNameLength: rules.SERVICE_NAME.MAX_LENGTH,
      maxDescLength: rules.DESCRIPTION.MAX_LENGTH,
      maxResources: rules.RESOURCES.MAX_PER_SERVICE
    });

    if (data.service_name !== undefined) {
      const nameValidation = this.validateServiceName(data.service_name, rules);
      if (!nameValidation.isValid) {
        errors.push(...nameValidation.errors);
      }
    }

    if (data.description !== undefined && data.description) {
      const descValidation = this.validateDescription(data.description, rules);
      if (!descValidation.isValid) {
        errors.push(...descValidation.errors);
      }
    }

    if (data.sku !== undefined && data.sku) {
      const skuValidation = this.validateSKU(data.sku, rules);
      if (!skuValidation.isValid) {
        errors.push(...skuValidation.errors);
      }
    }

    if (data.category_id !== undefined) {
      const categoryValidation = this.validateUUID(data.category_id, 'category_id');
      if (!categoryValidation.isValid) {
        errors.push(...categoryValidation.errors);
      }
    }

    if (data.industry_id !== undefined) {
      const industryValidation = this.validateIndustryId(data.industry_id);
      if (!industryValidation.isValid) {
        errors.push(...industryValidation.errors);
      }
    }

    if (data.pricing_config !== undefined) {
      const pricingValidation = this.validatePricingConfig(data.pricing_config, rules);
      if (!pricingValidation.isValid) {
        errors.push(...pricingValidation.errors);
      }
    }

    if (data.service_attributes !== undefined) {
      const attributesValidation = this.validateServiceAttributes(data.service_attributes);
      if (!attributesValidation.isValid) {
        errors.push(...attributesValidation.errors);
      }
    }

    if (data.duration_minutes !== undefined && data.duration_minutes !== null) {
      const durationValidation = this.validateDuration(data.duration_minutes, rules);
      if (!durationValidation.isValid) {
        errors.push(...durationValidation.errors);
      }
    }

    if (data.sort_order !== undefined && data.sort_order !== null) {
      const sortValidation = this.validateSortOrder(data.sort_order, rules);
      if (!sortValidation.isValid) {
        errors.push(...sortValidation.errors);
      }
    }

    if (data.required_resources !== undefined) {
      const resourcesValidation = this.validateRequiredResources(data.required_resources, rules);
      if (!resourcesValidation.isValid) {
        errors.push(...resourcesValidation.errors);
      }
    }

    if (data.tags !== undefined) {
      const tagsValidation = this.validateTags(data.tags, rules);
      if (!tagsValidation.isValid) {
        errors.push(...tagsValidation.errors);
      }
    }

    console.log('✅ Service validation - validation complete:', {
      isValid: errors.length === 0,
      errorCount: errors.length,
      tenantPlan: tenantConfig?.plan_type || 'default',
      errors: errors.map(e => ({ field: e.field, code: e.code, message: e.message }))
    });

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  // UPDATED: Enhanced filter validation with tenant limits
  static validateServiceFilters(
    filters: ServiceCatalogFilters, 
    tenantConfig?: TenantConfiguration | null
  ): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];
    const limits = tenantConfig?.validation_limits || DEFAULT_VALIDATION_LIMITS.professional;

    console.log('🔍 Filter validation - validating service catalog filters:', {
      hasSearchTerm: !!filters.search_term,
      hasCategoryId: !!filters.category_id,
      hasIndustryId: !!filters.industry_id,
      hasIsActive: filters.is_active !== undefined,
      hasLimit: !!filters.limit,
      hasOffset: !!filters.offset,
      tenantPlan: tenantConfig?.plan_type || 'default',
      maxSearchResults: limits.max_search_results
    });

    if (filters.search_term && filters.search_term.length > limits.max_service_name_length) {
      errors.push(new ServiceCatalogValidationError(
        `Search term is too long. Maximum ${limits.max_service_name_length} characters allowed`,
        'search_term',
        'SEARCH_TERM_TOO_LONG',
        filters.search_term
      ));
    }

    if (filters.category_id) {
      const categoryValidation = this.validateUUID(filters.category_id, 'category_id');
      if (!categoryValidation.isValid) {
        errors.push(...categoryValidation.errors);
      }
    }

    if (filters.industry_id) {
      const industryValidation = this.validateIndustryId(filters.industry_id);
      if (!industryValidation.isValid) {
        errors.push(...industryValidation.errors);
      }
    }

    if (filters.limit !== undefined) {
      if (filters.limit < 1 || filters.limit > limits.max_search_results) {
        errors.push(new ServiceCatalogValidationError(
          `Limit must be between 1 and ${limits.max_search_results} (tenant limit)`,
          'limit',
          'INVALID_LIMIT',
          filters.limit
        ));
      }
    }

    if (filters.offset !== undefined && filters.offset < 0) {
      errors.push(new ServiceCatalogValidationError(
        'Offset must be non-negative',
        'offset',
        'INVALID_OFFSET',
        filters.offset
      ));
    }

    console.log('✅ Filter validation - validation complete:', {
      isValid: errors.length === 0,
      errorCount: errors.length,
      tenantPlan: tenantConfig?.plan_type || 'default'
    });

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  static validateServiceResourceAssociation(data: ServiceResourceAssociation): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    console.log('🔍 Resource association validation - validating association:', {
      hasServiceId: !!data.service_id,
      hasResourceId: !!data.resource_id,
      hasQuantity: data.quantity !== undefined
    });

    if (!data.service_id) {
      errors.push(new ServiceCatalogValidationError(
        'Service ID is required',
        'service_id',
        'REQUIRED_FIELD'
      ));
    } else {
      const serviceValidation = this.validateUUID(data.service_id, 'service_id');
      if (!serviceValidation.isValid) {
        errors.push(...serviceValidation.errors);
      }
    }

    if (!data.resource_id) {
      errors.push(new ServiceCatalogValidationError(
        'Resource ID is required',
        'resource_id',
        'REQUIRED_FIELD'
      ));
    } else {
      const resourceValidation = this.validateUUID(data.resource_id, 'resource_id');
      if (!resourceValidation.isValid) {
        errors.push(...resourceValidation.errors);
      }
    }

    if (data.quantity !== undefined) {
      if (data.quantity < 1 || data.quantity > 1000) {
        errors.push(new ServiceCatalogValidationError(
          'Quantity must be between 1 and 1000',
          'quantity',
          'INVALID_QUANTITY',
          data.quantity
        ));
      }
    }

    console.log('✅ Resource association validation - validation complete:', {
      isValid: errors.length === 0,
      errorCount: errors.length
    });

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  // UPDATED: Enhanced bulk operation validation with tenant limits
  static validateBulkOperation(
    data: BulkServiceOperation, 
    tenantConfig?: TenantConfiguration | null
  ): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];
    const bulkLimits = tenantConfig?.bulk_operation_limits || {
      max_services_per_bulk: 1000,
      max_bulk_operations_per_hour: 25,
      max_concurrent_bulk_jobs: 3,
      max_file_size_mb: 50,
      supported_formats: ['json', 'csv']
    };

    console.log('🔍 Bulk operation validation - validating bulk operation:', {
      hasItems: !!data.items,
      itemCount: data.items?.length || 0,
      hasBatchId: !!data.batch_id,
      tenantPlan: tenantConfig?.plan_type || 'default',
      maxItemsAllowed: bulkLimits.max_services_per_bulk
    });

    if (!data.items || !Array.isArray(data.items)) {
      errors.push(new ServiceCatalogValidationError(
        'Items array is required',
        'items',
        'REQUIRED_FIELD'
      ));
    } else {
      if (data.items.length === 0) {
        errors.push(new ServiceCatalogValidationError(
          'At least one item is required',
          'items',
          'EMPTY_ARRAY'
        ));
      } else if (data.items.length > bulkLimits.max_services_per_bulk) {
        errors.push(new ServiceCatalogValidationError(
          `Maximum ${bulkLimits.max_services_per_bulk} items allowed in bulk operation (tenant limit)`,
          'items',
          'TOO_MANY_ITEMS',
          data.items.length
        ));
      } else {
        // Validate each item with tenant configuration
        data.items.forEach((item, index) => {
          const itemValidation = this.validateServiceCatalogItem(item, tenantConfig);
          if (!itemValidation.isValid) {
            itemValidation.errors.forEach(error => {
              errors.push(new ServiceCatalogValidationError(
                `Item ${index + 1}: ${error.message}`,
                `items[${index}].${error.field}`,
                error.code,
                error.value
              ));
            });
          }
        });
      }
    }

    if (data.batch_id && data.batch_id.length > 100) {
      errors.push(new ServiceCatalogValidationError(
        'Batch ID is too long',
        'batch_id',
        'BATCH_ID_TOO_LONG',
        data.batch_id
      ));
    }

    console.log('✅ Bulk operation validation - validation complete:', {
      isValid: errors.length === 0,
      errorCount: errors.length,
      tenantPlan: tenantConfig?.plan_type || 'default',
      maxItemsAllowed: bulkLimits.max_services_per_bulk
    });

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  static validateServicePricingUpdate(data: ServicePricingUpdate): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    console.log('🔍 Pricing update validation - validating pricing update:', {
      hasServiceId: !!data.service_id,
      hasPricingConfig: !!data.pricing_config
    });

    if (!data.service_id) {
      errors.push(new ServiceCatalogValidationError(
        'Service ID is required',
        'service_id',
        'REQUIRED_FIELD'
      ));
    } else {
      const serviceValidation = this.validateUUID(data.service_id, 'service_id');
      if (!serviceValidation.isValid) {
        errors.push(...serviceValidation.errors);
      }
    }

    if (!data.pricing_config) {
      errors.push(new ServiceCatalogValidationError(
        'Pricing configuration is required',
        'pricing_config',
        'REQUIRED_FIELD'
      ));
    } else {
      // Use default rules for pricing validation
      const defaultRules = this.getValidationRules();
      const pricingValidation = this.validatePricingConfig(data.pricing_config, defaultRules);
      if (!pricingValidation.isValid) {
        errors.push(...pricingValidation.errors);
      }
    }

    console.log('✅ Pricing update validation - validation complete:', {
      isValid: errors.length === 0,
      errorCount: errors.length
    });

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private static validateServiceName(name: string, rules: any): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (!name || name.trim().length === 0) {
      errors.push(new ServiceCatalogValidationError(
        'Service name is required',
        'service_name',
        'REQUIRED_FIELD',
        name
      ));
    } else {
      const trimmedName = name.trim();
      
      if (trimmedName.length < rules.SERVICE_NAME.MIN_LENGTH) {
        errors.push(new ServiceCatalogValidationError(
          `Service name must be at least ${rules.SERVICE_NAME.MIN_LENGTH} characters`,
          'service_name',
          'NAME_TOO_SHORT',
          name
        ));
      }

      if (trimmedName.length > rules.SERVICE_NAME.MAX_LENGTH) {
        errors.push(new ServiceCatalogValidationError(
          `Service name must not exceed ${rules.SERVICE_NAME.MAX_LENGTH} characters (tenant limit)`,
          'service_name',
          'NAME_TOO_LONG',
          name
        ));
      }

      if (!rules.SERVICE_NAME.PATTERN.test(trimmedName)) {
        errors.push(new ServiceCatalogValidationError(
          'Service name contains invalid characters',
          'service_name',
          'INVALID_CHARACTERS',
          name
        ));
      }
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private static validateDescription(description: string, rules: any): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (description && description.length > rules.DESCRIPTION.MAX_LENGTH) {
      errors.push(new ServiceCatalogValidationError(
        `Description must not exceed ${rules.DESCRIPTION.MAX_LENGTH} characters (tenant limit)`,
        'description',
        'DESCRIPTION_TOO_LONG',
        description
      ));
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private static validateSKU(sku: string, rules: any): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (sku.length > rules.SKU.MAX_LENGTH) {
      errors.push(new ServiceCatalogValidationError(
        `SKU must not exceed ${rules.SKU.MAX_LENGTH} characters (tenant limit)`,
        'sku',
        'SKU_TOO_LONG',
        sku
      ));
    }

    if (!rules.SKU.PATTERN.test(sku)) {
      errors.push(new ServiceCatalogValidationError(
        'SKU contains invalid characters. Only letters, numbers, hyphens, and underscores are allowed',
        'sku',
        'INVALID_SKU_FORMAT',
        sku
      ));
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private static validateUUID(value: string, fieldName: string): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];
    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

    if (!value) {
      errors.push(new ServiceCatalogValidationError(
        `${fieldName} is required`,
        fieldName,
        'REQUIRED_FIELD',
        value
      ));
    } else if (!uuidPattern.test(value)) {
      errors.push(new ServiceCatalogValidationError(
        `${fieldName} must be a valid UUID`,
        fieldName,
        'INVALID_UUID',
        value
      ));
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private static validateIndustryId(industryId: string): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (!industryId || industryId.trim().length === 0) {
      errors.push(new ServiceCatalogValidationError(
        'Industry ID is required',
        'industry_id',
        'REQUIRED_FIELD',
        industryId
      ));
    } else if (industryId.length > 100) {
      errors.push(new ServiceCatalogValidationError(
        'Industry ID must not exceed 100 characters',
        'industry_id',
        'INDUSTRY_ID_TOO_LONG',
        industryId
      ));
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private static validatePricingConfig(pricingConfig: any, rules: any): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (!pricingConfig || typeof pricingConfig !== 'object') {
      errors.push(new ServiceCatalogValidationError(
        'Pricing configuration must be a valid object',
        'pricing_config',
        'INVALID_PRICING_CONFIG',
        pricingConfig
      ));
      return { isValid: false, errors };
    }

    if (pricingConfig.base_price !== undefined) {
      const priceValidation = this.validatePrice(pricingConfig.base_price, 'base_price', rules);
      if (!priceValidation.isValid) {
        errors.push(...priceValidation.errors);
      }
    }

    if (pricingConfig.currency) {
      const currencyValidation = this.validateCurrency(pricingConfig.currency, rules);
      if (!currencyValidation.isValid) {
        errors.push(...currencyValidation.errors);
      }
    }

    if (pricingConfig.tiers && Array.isArray(pricingConfig.tiers)) {
      if (pricingConfig.tiers.length > rules.PRICING_TIERS.MAX_COUNT) {
        errors.push(new ServiceCatalogValidationError(
          `Maximum ${rules.PRICING_TIERS.MAX_COUNT} pricing tiers allowed (tenant limit)`,
          'pricing_config.tiers',
          'TOO_MANY_PRICING_TIERS',
          pricingConfig.tiers.length
        ));
      }

      pricingConfig.tiers.forEach((tier: any, index: number) => {
        if (tier.min_quantity !== undefined && (tier.min_quantity < 1 || tier.min_quantity > 10000)) {
          errors.push(new ServiceCatalogValidationError(
            `Tier ${index + 1}: minimum quantity must be between 1 and 10000`,
            `pricing_config.tiers[${index}].min_quantity`,
            'INVALID_TIER_MIN_QUANTITY',
            tier.min_quantity
          ));
        }

        if (tier.price !== undefined) {
          const tierPriceValidation = this.validatePrice(tier.price, `tiers[${index}].price`, rules);
          if (!tierPriceValidation.isValid) {
            tierPriceValidation.errors.forEach(error => {
              errors.push(new ServiceCatalogValidationError(
                `Tier ${index + 1}: ${error.message}`,
                `pricing_config.${error.field}`,
                error.code,
                error.value
              ));
            });
          }
        }
      });
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private static validatePrice(price: number, fieldName: string, rules: any): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (price < rules.PRICE.MIN) {
      errors.push(new ServiceCatalogValidationError(
        `${fieldName} must be non-negative`,
        fieldName,
        'PRICE_TOO_LOW',
        price
      ));
    }

    if (price > rules.PRICE.MAX) {
      errors.push(new ServiceCatalogValidationError(
        `${fieldName} exceeds maximum allowed value (tenant limit: ${rules.PRICE.MAX})`,
        fieldName,
        'PRICE_TOO_HIGH',
        price
      ));
    }

    const decimalPlaces = (price.toString().split('.')[1] || '').length;
    if (decimalPlaces > rules.PRICE.DECIMAL_PLACES) {
      errors.push(new ServiceCatalogValidationError(
        `${fieldName} can have maximum ${rules.PRICE.DECIMAL_PLACES} decimal places`,
        fieldName,
        'TOO_MANY_DECIMAL_PLACES',
        price
      ));
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private static validateCurrency(currency: string, rules: any): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (!rules.CURRENCY.PATTERN.test(currency)) {
      errors.push(new ServiceCatalogValidationError(
        'Currency must be a valid 3-letter ISO code',
        'currency',
        'INVALID_CURRENCY',
        currency
      ));
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private static validateServiceAttributes(attributes: any): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (attributes && typeof attributes !== 'object') {
      errors.push(new ServiceCatalogValidationError(
        'Service attributes must be a valid object',
        'service_attributes',
        'INVALID_ATTRIBUTES',
        attributes
      ));
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private static validateDuration(duration: number, rules: any): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (duration < rules.DURATION.MIN || duration > rules.DURATION.MAX) {
      errors.push(new ServiceCatalogValidationError(
        `Duration must be between ${rules.DURATION.MIN} and ${rules.DURATION.MAX} minutes (tenant limit)`,
        'duration_minutes',
        'INVALID_DURATION',
        duration
      ));
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private static validateSortOrder(sortOrder: number, rules: any): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (sortOrder < rules.SORT_ORDER.MIN || sortOrder > rules.SORT_ORDER.MAX) {
      errors.push(new ServiceCatalogValidationError(
        `Sort order must be between ${rules.SORT_ORDER.MIN} and ${rules.SORT_ORDER.MAX}`,
        'sort_order',
        'INVALID_SORT_ORDER',
        sortOrder
      ));
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private static validateRequiredResources(resources: any[], rules: any): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (!Array.isArray(resources)) {
      errors.push(new ServiceCatalogValidationError(
        'Required resources must be an array',
        'required_resources',
        'INVALID_RESOURCES_FORMAT',
        resources
      ));
      return { isValid: false, errors };
    }

    if (resources.length > rules.RESOURCES.MAX_PER_SERVICE) {
      errors.push(new ServiceCatalogValidationError(
        `Maximum ${rules.RESOURCES.MAX_PER_SERVICE} required resources allowed (tenant limit)`,
        'required_resources',
        'TOO_MANY_RESOURCES',
        resources.length
      ));
    }

    resources.forEach((resource, index) => {
      if (!resource.resource_id) {
        errors.push(new ServiceCatalogValidationError(
          `Resource ${index + 1}: resource_id is required`,
          `required_resources[${index}].resource_id`,
          'REQUIRED_FIELD'
        ));
      }

      if (resource.quantity !== undefined && (resource.quantity < 1 || resource.quantity > 1000)) {
        errors.push(new ServiceCatalogValidationError(
          `Resource ${index + 1}: quantity must be between 1 and 1000`,
          `required_resources[${index}].quantity`,
          'INVALID_RESOURCE_QUANTITY',
          resource.quantity
        ));
      }
    });

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  // NEW: Validate tags with tenant limits
  private static validateTags(tags: any[], rules: any): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (!Array.isArray(tags)) {
      errors.push(new ServiceCatalogValidationError(
        'Tags must be an array',
        'tags',
        'INVALID_TAGS_FORMAT',
        tags
      ));
      return { isValid: false, errors };
    }

    if (tags.length > rules.TAGS.MAX_COUNT) {
      errors.push(new ServiceCatalogValidationError(
        `Maximum ${rules.TAGS.MAX_COUNT} tags allowed (tenant limit)`,
        'tags',
        'TOO_MANY_TAGS',
        tags.length
      ));
    }

    tags.forEach((tag, index) => {
      if (typeof tag !== 'string') {
        errors.push(new ServiceCatalogValidationError(
          `Tag ${index + 1}: must be a string`,
          `tags[${index}]`,
          'INVALID_TAG_TYPE',
          tag
        ));
      } else if (tag.length === 0) {
        errors.push(new ServiceCatalogValidationError(
          `Tag ${index + 1}: cannot be empty`,
          `tags[${index}]`,
          'EMPTY_TAG',
          tag
        ));
      } else if (tag.length > 50) {
        errors.push(new ServiceCatalogValidationError(
          `Tag ${index + 1}: cannot exceed 50 characters`,
          `tags[${index}]`,
          'TAG_TOO_LONG',
          tag
        ));
      }
    });

    return {
      isValid: errors.length === 0,
      errors
    };
  }
}