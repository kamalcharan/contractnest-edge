import { ServiceCatalogItemData, ServiceCatalogFilters, ServiceResourceAssociation, BulkServiceOperation, ServicePricingUpdate } from './serviceCatalogTypes.ts';

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
  
  private static readonly VALIDATION_RULES = {
    SERVICE_NAME: {
      MIN_LENGTH: 2,
      MAX_LENGTH: 255,
      PATTERN: /^[a-zA-Z0-9\s\-_.,()&]+$/
    },
    DESCRIPTION: {
      MAX_LENGTH: 2000
    },
    PRICE: {
      MIN: 0,
      MAX: 999999999.99,
      DECIMAL_PLACES: 2
    },
    SKU: {
      MAX_LENGTH: 100,
      PATTERN: /^[A-Za-z0-9\-_]+$/
    },
    CATEGORY: {
      MIN_LENGTH: 1,
      MAX_LENGTH: 100
    },
    DURATION: {
      MIN: 1,
      MAX: 365 * 24 * 60
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
    }
  };

  static validateServiceCatalogItem(data: Partial<ServiceCatalogItemData>): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    console.log('🔍 Service validation - validating service catalog item:', {
      hasName: !!data.service_name,
      hasCategory: !!data.category_id,
      hasIndustry: !!data.industry_id,
      hasPricing: !!data.pricing_config,
      resourceCount: data.required_resources?.length || 0
    });

    if (data.service_name !== undefined) {
      const nameValidation = this.validateServiceName(data.service_name);
      if (!nameValidation.isValid) {
        errors.push(...nameValidation.errors);
      }
    }

    if (data.description !== undefined && data.description) {
      const descValidation = this.validateDescription(data.description);
      if (!descValidation.isValid) {
        errors.push(...descValidation.errors);
      }
    }

    if (data.sku !== undefined && data.sku) {
      const skuValidation = this.validateSKU(data.sku);
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
      const pricingValidation = this.validatePricingConfig(data.pricing_config);
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
      const durationValidation = this.validateDuration(data.duration_minutes);
      if (!durationValidation.isValid) {
        errors.push(...durationValidation.errors);
      }
    }

    if (data.sort_order !== undefined && data.sort_order !== null) {
      const sortValidation = this.validateSortOrder(data.sort_order);
      if (!sortValidation.isValid) {
        errors.push(...sortValidation.errors);
      }
    }

    if (data.required_resources !== undefined) {
      const resourcesValidation = this.validateRequiredResources(data.required_resources);
      if (!resourcesValidation.isValid) {
        errors.push(...resourcesValidation.errors);
      }
    }

    console.log('✅ Service validation - validation complete:', {
      isValid: errors.length === 0,
      errorCount: errors.length,
      errors: errors.map(e => ({ field: e.field, code: e.code, message: e.message }))
    });

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  static validateServiceFilters(filters: ServiceCatalogFilters): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    console.log('🔍 Filter validation - validating service catalog filters:', {
      hasSearchTerm: !!filters.search_term,
      hasCategoryId: !!filters.category_id,
      hasIndustryId: !!filters.industry_id,
      hasIsActive: filters.is_active !== undefined,
      hasLimit: !!filters.limit,
      hasOffset: !!filters.offset
    });

    if (filters.search_term && filters.search_term.length > 255) {
      errors.push(new ServiceCatalogValidationError(
        'Search term is too long',
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
      if (filters.limit < 1 || filters.limit > 1000) {
        errors.push(new ServiceCatalogValidationError(
          'Limit must be between 1 and 1000',
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
      errorCount: errors.length
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

  static validateBulkOperation(data: BulkServiceOperation): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    console.log('🔍 Bulk operation validation - validating bulk operation:', {
      hasItems: !!data.items,
      itemCount: data.items?.length || 0,
      hasBatchId: !!data.batch_id
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
      } else if (data.items.length > 100) {
        errors.push(new ServiceCatalogValidationError(
          'Maximum 100 items allowed in bulk operation',
          'items',
          'TOO_MANY_ITEMS',
          data.items.length
        ));
      } else {
        data.items.forEach((item, index) => {
          const itemValidation = this.validateServiceCatalogItem(item);
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
      errorCount: errors.length
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
      const pricingValidation = this.validatePricingConfig(data.pricing_config);
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

  private static validateServiceName(name: string): ValidationResult {
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
      
      if (trimmedName.length < this.VALIDATION_RULES.SERVICE_NAME.MIN_LENGTH) {
        errors.push(new ServiceCatalogValidationError(
          `Service name must be at least ${this.VALIDATION_RULES.SERVICE_NAME.MIN_LENGTH} characters`,
          'service_name',
          'NAME_TOO_SHORT',
          name
        ));
      }

      if (trimmedName.length > this.VALIDATION_RULES.SERVICE_NAME.MAX_LENGTH) {
        errors.push(new ServiceCatalogValidationError(
          `Service name must not exceed ${this.VALIDATION_RULES.SERVICE_NAME.MAX_LENGTH} characters`,
          'service_name',
          'NAME_TOO_LONG',
          name
        ));
      }

      if (!this.VALIDATION_RULES.SERVICE_NAME.PATTERN.test(trimmedName)) {
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

  private static validateDescription(description: string): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (description && description.length > this.VALIDATION_RULES.DESCRIPTION.MAX_LENGTH) {
      errors.push(new ServiceCatalogValidationError(
        `Description must not exceed ${this.VALIDATION_RULES.DESCRIPTION.MAX_LENGTH} characters`,
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

  private static validateSKU(sku: string): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (sku.length > this.VALIDATION_RULES.SKU.MAX_LENGTH) {
      errors.push(new ServiceCatalogValidationError(
        `SKU must not exceed ${this.VALIDATION_RULES.SKU.MAX_LENGTH} characters`,
        'sku',
        'SKU_TOO_LONG',
        sku
      ));
    }

    if (!this.VALIDATION_RULES.SKU.PATTERN.test(sku)) {
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
    } else if (industryId.length > this.VALIDATION_RULES.CATEGORY.MAX_LENGTH) {
      errors.push(new ServiceCatalogValidationError(
        `Industry ID must not exceed ${this.VALIDATION_RULES.CATEGORY.MAX_LENGTH} characters`,
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

  private static validatePricingConfig(pricingConfig: any): ValidationResult {
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
      const priceValidation = this.validatePrice(pricingConfig.base_price, 'base_price');
      if (!priceValidation.isValid) {
        errors.push(...priceValidation.errors);
      }
    }

    if (pricingConfig.currency) {
      const currencyValidation = this.validateCurrency(pricingConfig.currency);
      if (!currencyValidation.isValid) {
        errors.push(...currencyValidation.errors);
      }
    }

    if (pricingConfig.tiers && Array.isArray(pricingConfig.tiers)) {
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
          const tierPriceValidation = this.validatePrice(tier.price, `tiers[${index}].price`);
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

  private static validatePrice(price: number, fieldName: string): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (price < this.VALIDATION_RULES.PRICE.MIN) {
      errors.push(new ServiceCatalogValidationError(
        `${fieldName} must be non-negative`,
        fieldName,
        'PRICE_TOO_LOW',
        price
      ));
    }

    if (price > this.VALIDATION_RULES.PRICE.MAX) {
      errors.push(new ServiceCatalogValidationError(
        `${fieldName} exceeds maximum allowed value`,
        fieldName,
        'PRICE_TOO_HIGH',
        price
      ));
    }

    const decimalPlaces = (price.toString().split('.')[1] || '').length;
    if (decimalPlaces > this.VALIDATION_RULES.PRICE.DECIMAL_PLACES) {
      errors.push(new ServiceCatalogValidationError(
        `${fieldName} can have maximum ${this.VALIDATION_RULES.PRICE.DECIMAL_PLACES} decimal places`,
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

  private static validateCurrency(currency: string): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (!this.VALIDATION_RULES.CURRENCY.PATTERN.test(currency)) {
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

  private static validateDuration(duration: number): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (duration < this.VALIDATION_RULES.DURATION.MIN || duration > this.VALIDATION_RULES.DURATION.MAX) {
      errors.push(new ServiceCatalogValidationError(
        `Duration must be between ${this.VALIDATION_RULES.DURATION.MIN} and ${this.VALIDATION_RULES.DURATION.MAX} minutes`,
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

  private static validateSortOrder(sortOrder: number): ValidationResult {
    const errors: ServiceCatalogValidationError[] = [];

    if (sortOrder < this.VALIDATION_RULES.SORT_ORDER.MIN || sortOrder > this.VALIDATION_RULES.SORT_ORDER.MAX) {
      errors.push(new ServiceCatalogValidationError(
        `Sort order must be between ${this.VALIDATION_RULES.SORT_ORDER.MIN} and ${this.VALIDATION_RULES.SORT_ORDER.MAX}`,
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

  private static validateRequiredResources(resources: any[]): ValidationResult {
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

    if (resources.length > 50) {
      errors.push(new ServiceCatalogValidationError(
        'Maximum 50 required resources allowed',
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
}