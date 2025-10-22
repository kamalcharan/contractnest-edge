// supabase/functions/service-catalog/serviceCatalogValidation.ts
// Service Catalog Validation - Production Grade
// ✅ UPDATED: Accepts BOTH pricing_config (old) AND pricing_records (new)
// ✅ Boolean status + variant support
// ✅ All security features, logging, error classes

export interface ServiceCatalogFilters {
  search_term?: string;
  category_id?: string;
  industry_id?: string;
  is_active?: boolean;
  price_min?: number;
  price_max?: number;
  currency?: string;
  has_resources?: boolean;
  sort_by?: string;
  sort_direction?: 'asc' | 'desc';
  limit?: number;
  offset?: number;
}

/**
 * Custom validation error class with enhanced tracking
 */
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

/**
 * Service Catalog Validator - Production Grade
 */
export class ServiceCatalogValidator {
  
  // Validation rules constants
  private static readonly VALIDATION_RULES = {
    SERVICE_NAME: {
      MIN_LENGTH: 2,
      MAX_LENGTH: 255,
      PATTERN: /^[a-zA-Z0-9\s\-_.,()&]+$/
    },
    DESCRIPTION: {
      MAX_LENGTH: 10000
    },
    SHORT_DESCRIPTION: {
      MAX_LENGTH: 500
    },
    SKU: {
      MAX_LENGTH: 100,
      PATTERN: /^[A-Za-z0-9\-_]+$/
    },
    PRICE: {
      MIN: 0,
      MAX: 999999999.99,
      DECIMAL_PLACES: 2
    },
    DURATION: {
      MIN: 1,
      MAX: 525600 // 1 year in minutes
    },
    SORT_ORDER: {
      MIN: 0,
      MAX: 999999
    },
    RESOURCES: {
      MAX_COUNT: 50
    },
    TAGS: {
      MAX_COUNT: 20,
      MAX_LENGTH: 50
    },
    TERMS: {
      MAX_LENGTH: 5000
    },
    PRICING_RECORDS: {
      MAX_COUNT: 10
    }
  };

  /**
   * ✅ UPDATED: Validate complete service catalog item
   * Accepts BOTH pricing_config (old) AND pricing_records (new)
   */
  static validateServiceCatalogItem(data: any): { isValid: boolean; errors: ServiceCatalogValidationError[] } {
    console.log('Validating service catalog item:', {
      hasName: !!data.service_name,
      hasCategory: !!data.category_id,
      hasIndustry: !!data.industry_id,
      hasPricingConfig: !!data.pricing_config,
      hasPricingRecords: !!data.pricing_records,
      pricingRecordsCount: data.pricing_records?.length || 0,
      hasStatus: data.status !== undefined,
      isVariant: data.is_variant
    });

    const errors: ServiceCatalogValidationError[] = [];

    // Validate all fields
    errors.push(...this.validateServiceName(data.service_name));
    errors.push(...this.validateDescription(data.description));
    errors.push(...this.validateShortDescription(data.short_description));
    errors.push(...this.validateSKU(data.sku));
    errors.push(...this.validateCategoryId(data.category_id));
    errors.push(...this.validateIndustryId(data.industry_id));
    
    // ✅ FIXED: Validate pricing - accept BOTH formats
    if (data.pricing_records && Array.isArray(data.pricing_records)) {
      // NEW FORMAT: Array of pricing records
      errors.push(...this.validatePricingRecords(data.pricing_records));
    } else if (data.pricing_config) {
      // OLD FORMAT: Single pricing config object
      errors.push(...this.validatePricingConfig(data.pricing_config));
    } else {
      // No pricing provided at all
      errors.push(new ServiceCatalogValidationError(
        'Pricing information is required. Provide either pricing_records or pricing_config',
        'pricing',
        'REQUIRED_FIELD'
      ));
    }
    
    errors.push(...this.validateServiceType(data.service_type));
    errors.push(...this.validateRequiredResources(data.required_resources || data.resource_requirements));
    errors.push(...this.validateDuration(data.duration_minutes));
    errors.push(...this.validateSortOrder(data.sort_order));
    errors.push(...this.validateTags(data.tags));
    errors.push(...this.validateTerms(data.terms));
    errors.push(...this.validateStatus(data.status));
    errors.push(...this.validateVariant(data.is_variant, data.parent_id));

    // Security checks
    errors.push(...this.performSecurityChecks(data));

    console.log('Service validation complete:', {
      isValid: errors.length === 0,
      errorCount: errors.length,
      errors: errors.map(e => ({ field: e.field, code: e.code }))
    });

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  /**
   * Validate service name
   */
  private static validateServiceName(serviceName: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];
    const rules = this.VALIDATION_RULES.SERVICE_NAME;

    if (!serviceName || typeof serviceName !== 'string' || serviceName.trim().length === 0) {
      errors.push(new ServiceCatalogValidationError(
        'Service name is required and must be a non-empty string',
        'service_name',
        'REQUIRED_FIELD',
        serviceName
      ));
      return errors;
    }

    if (serviceName.length < rules.MIN_LENGTH) {
      errors.push(new ServiceCatalogValidationError(
        `Service name must be at least ${rules.MIN_LENGTH} characters`,
        'service_name',
        'FIELD_TOO_SHORT',
        serviceName
      ));
    }

    if (serviceName.length > rules.MAX_LENGTH) {
      errors.push(new ServiceCatalogValidationError(
        `Service name must be ${rules.MAX_LENGTH} characters or less`,
        'service_name',
        'FIELD_TOO_LONG',
        serviceName
      ));
    }

    if (!rules.PATTERN.test(serviceName)) {
      errors.push(new ServiceCatalogValidationError(
        'Service name contains invalid characters. Only letters, numbers, spaces, and common punctuation are allowed.',
        'service_name',
        'INVALID_FORMAT',
        serviceName
      ));
    }

    return errors;
  }

  /**
   * Validate description
   */
  private static validateDescription(description: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];

    if (description !== undefined && description !== null) {
      if (typeof description !== 'string') {
        errors.push(new ServiceCatalogValidationError(
          'Description must be a string',
          'description',
          'INVALID_TYPE',
          typeof description
        ));
      } else if (description.length > this.VALIDATION_RULES.DESCRIPTION.MAX_LENGTH) {
        errors.push(new ServiceCatalogValidationError(
          `Description must be ${this.VALIDATION_RULES.DESCRIPTION.MAX_LENGTH} characters or less`,
          'description',
          'FIELD_TOO_LONG',
          description.length
        ));
      }
    }

    return errors;
  }

  /**
   * Validate short description
   */
  private static validateShortDescription(shortDescription: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];

    if (shortDescription !== undefined && shortDescription !== null) {
      if (typeof shortDescription !== 'string') {
        errors.push(new ServiceCatalogValidationError(
          'Short description must be a string',
          'short_description',
          'INVALID_TYPE',
          typeof shortDescription
        ));
      } else if (shortDescription.length > this.VALIDATION_RULES.SHORT_DESCRIPTION.MAX_LENGTH) {
        errors.push(new ServiceCatalogValidationError(
          `Short description must be ${this.VALIDATION_RULES.SHORT_DESCRIPTION.MAX_LENGTH} characters or less`,
          'short_description',
          'FIELD_TOO_LONG',
          shortDescription.length
        ));
      }
    }

    return errors;
  }

  /**
   * Validate SKU
   */
  private static validateSKU(sku: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];
    const rules = this.VALIDATION_RULES.SKU;

    if (sku !== undefined && sku !== null) {
      if (typeof sku !== 'string') {
        errors.push(new ServiceCatalogValidationError(
          'SKU must be a string',
          'sku',
          'INVALID_TYPE',
          typeof sku
        ));
      } else {
        if (sku.length > rules.MAX_LENGTH) {
          errors.push(new ServiceCatalogValidationError(
            `SKU must be ${rules.MAX_LENGTH} characters or less`,
            'sku',
            'FIELD_TOO_LONG',
            sku.length
          ));
        }

        if (sku && !rules.PATTERN.test(sku)) {
          errors.push(new ServiceCatalogValidationError(
            'SKU can only contain letters, numbers, hyphens, and underscores',
            'sku',
            'INVALID_FORMAT',
            sku
          ));
        }
      }
    }

    return errors;
  }

  /**
   * Category ID validation - OPTIONAL
   */
  private static validateCategoryId(categoryId: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];

    if (categoryId !== undefined && categoryId !== null) {
      if (typeof categoryId !== 'string' || categoryId.trim().length === 0) {
        errors.push(new ServiceCatalogValidationError(
          'category_id must be a non-empty string',
          'category_id',
          'INVALID_TYPE',
          categoryId
        ));
      }
    }

    return errors;
  }

  /**
   * Industry ID validation - OPTIONAL
   */
  private static validateIndustryId(industryId: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];

    if (industryId !== undefined && industryId !== null) {
      if (typeof industryId !== 'string' || industryId.trim().length === 0) {
        errors.push(new ServiceCatalogValidationError(
          'industry_id must be a non-empty string',
          'industry_id',
          'INVALID_TYPE',
          industryId
        ));
      }
    }

    return errors;
  }

  /**
   * Validate status as boolean
   */
  private static validateStatus(status: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];

    if (status !== undefined && typeof status !== 'boolean') {
      errors.push(new ServiceCatalogValidationError(
        'Status must be a boolean (true or false)',
        'status',
        'INVALID_TYPE',
        status
      ));
    }

    return errors;
  }

  /**
   * Validate variant fields (is_variant and parent_id)
   */
  private static validateVariant(isVariant: any, parentId: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];

    // Validate is_variant type
    if (isVariant !== undefined && typeof isVariant !== 'boolean') {
      errors.push(new ServiceCatalogValidationError(
        'is_variant must be a boolean (true or false)',
        'is_variant',
        'INVALID_TYPE',
        isVariant
      ));
    }

    // Validate parent_id format if provided
    if (parentId !== undefined && parentId !== null) {
      if (!this.isValidUUID(parentId)) {
        errors.push(new ServiceCatalogValidationError(
          'parent_id must be a valid UUID',
          'parent_id',
          'INVALID_UUID',
          parentId
        ));
      }
    }

    // If is_variant is true, parent_id should be provided
    if (isVariant === true && !parentId) {
      errors.push(new ServiceCatalogValidationError(
        'parent_id is required when is_variant is true',
        'parent_id',
        'REQUIRED_FIELD',
        parentId
      ));
    }

    return errors;
  }

  /**
   * ✅ OLD FORMAT: Validate pricing configuration object
   */
  private static validatePricingConfig(pricingConfig: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];

    if (!pricingConfig || typeof pricingConfig !== 'object') {
      errors.push(new ServiceCatalogValidationError(
        'Pricing configuration is required and must be an object',
        'pricing_config',
        'REQUIRED_FIELD',
        pricingConfig
      ));
      return errors;
    }

    const rules = this.VALIDATION_RULES.PRICE;

    // Validate base_price
    if (pricingConfig.base_price === undefined || pricingConfig.base_price === null) {
      errors.push(new ServiceCatalogValidationError(
        'Base price is required',
        'pricing_config.base_price',
        'REQUIRED_FIELD',
        pricingConfig.base_price
      ));
    } else {
      if (typeof pricingConfig.base_price !== 'number' || isNaN(pricingConfig.base_price)) {
        errors.push(new ServiceCatalogValidationError(
          'Base price must be a valid number',
          'pricing_config.base_price',
          'INVALID_NUMBER',
          pricingConfig.base_price
        ));
      } else {
        if (pricingConfig.base_price < rules.MIN) {
          errors.push(new ServiceCatalogValidationError(
            'Base price must be non-negative',
            'pricing_config.base_price',
            'PRICE_TOO_LOW',
            pricingConfig.base_price
          ));
        }

        if (pricingConfig.base_price > rules.MAX) {
          errors.push(new ServiceCatalogValidationError(
            'Base price exceeds maximum allowed value',
            'pricing_config.base_price',
            'PRICE_TOO_HIGH',
            pricingConfig.base_price
          ));
        }

        const decimalPlaces = (pricingConfig.base_price.toString().split('.')[1] || '').length;
        if (decimalPlaces > rules.DECIMAL_PLACES) {
          errors.push(new ServiceCatalogValidationError(
            `Base price can have maximum ${rules.DECIMAL_PLACES} decimal places`,
            'pricing_config.base_price',
            'TOO_MANY_DECIMAL_PLACES',
            pricingConfig.base_price
          ));
        }
      }
    }

    // Validate currency
    if (!pricingConfig.currency || typeof pricingConfig.currency !== 'string') {
      errors.push(new ServiceCatalogValidationError(
        'Currency is required and must be a string',
        'pricing_config.currency',
        'REQUIRED_FIELD',
        pricingConfig.currency
      ));
    }

    // Validate pricing_model
    if (!pricingConfig.pricing_model || typeof pricingConfig.pricing_model !== 'string') {
      errors.push(new ServiceCatalogValidationError(
        'Pricing model is required and must be a string',
        'pricing_config.pricing_model',
        'REQUIRED_FIELD',
        pricingConfig.pricing_model
      ));
    }

    // Validate tax_inclusive as boolean
    if (pricingConfig.tax_inclusive !== undefined && typeof pricingConfig.tax_inclusive !== 'boolean') {
      errors.push(new ServiceCatalogValidationError(
        'tax_inclusive must be a boolean',
        'pricing_config.tax_inclusive',
        'INVALID_TYPE',
        pricingConfig.tax_inclusive
      ));
    }

    // Validate billing_cycle if provided
    if (pricingConfig.billing_cycle !== undefined && pricingConfig.billing_cycle !== null) {
      if (typeof pricingConfig.billing_cycle !== 'string') {
        errors.push(new ServiceCatalogValidationError(
          'Billing cycle must be a string',
          'pricing_config.billing_cycle',
          'INVALID_TYPE',
          pricingConfig.billing_cycle
        ));
      }
    }

    return errors;
  }

  /**
   * ✅ NEW FORMAT: Validate pricing_records array (multi-currency)
   */
  private static validatePricingRecords(pricingRecords: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];

    if (!Array.isArray(pricingRecords)) {
      errors.push(new ServiceCatalogValidationError(
        'pricing_records must be an array',
        'pricing_records',
        'INVALID_TYPE',
        typeof pricingRecords
      ));
      return errors;
    }

    if (pricingRecords.length === 0) {
      errors.push(new ServiceCatalogValidationError(
        'At least one pricing record is required',
        'pricing_records',
        'REQUIRED_FIELD',
        pricingRecords.length
      ));
      return errors;
    }

    if (pricingRecords.length > this.VALIDATION_RULES.PRICING_RECORDS.MAX_COUNT) {
      errors.push(new ServiceCatalogValidationError(
        `Maximum ${this.VALIDATION_RULES.PRICING_RECORDS.MAX_COUNT} pricing records allowed`,
        'pricing_records',
        'TOO_MANY_ITEMS',
        pricingRecords.length
      ));
    }

    const rules = this.VALIDATION_RULES.PRICE;

    // Validate each pricing record
    pricingRecords.forEach((pricing: any, index: number) => {
      // Validate amount
      if (pricing.amount === undefined || pricing.amount === null) {
        errors.push(new ServiceCatalogValidationError(
          `Pricing record ${index + 1}: amount is required`,
          `pricing_records[${index}].amount`,
          'REQUIRED_FIELD',
          pricing.amount
        ));
      } else {
        if (typeof pricing.amount !== 'number' || isNaN(pricing.amount)) {
          errors.push(new ServiceCatalogValidationError(
            `Pricing record ${index + 1}: amount must be a valid number`,
            `pricing_records[${index}].amount`,
            'INVALID_NUMBER',
            pricing.amount
          ));
        } else {
          if (pricing.amount < rules.MIN) {
            errors.push(new ServiceCatalogValidationError(
              `Pricing record ${index + 1}: amount must be non-negative`,
              `pricing_records[${index}].amount`,
              'PRICE_TOO_LOW',
              pricing.amount
            ));
          }

          if (pricing.amount > rules.MAX) {
            errors.push(new ServiceCatalogValidationError(
              `Pricing record ${index + 1}: amount exceeds maximum allowed value`,
              `pricing_records[${index}].amount`,
              'PRICE_TOO_HIGH',
              pricing.amount
            ));
          }

          const decimalPlaces = (pricing.amount.toString().split('.')[1] || '').length;
          if (decimalPlaces > rules.DECIMAL_PLACES) {
            errors.push(new ServiceCatalogValidationError(
              `Pricing record ${index + 1}: amount can have maximum ${rules.DECIMAL_PLACES} decimal places`,
              `pricing_records[${index}].amount`,
              'TOO_MANY_DECIMAL_PLACES',
              pricing.amount
            ));
          }
        }
      }

      // Validate currency
      if (!pricing.currency || typeof pricing.currency !== 'string') {
        errors.push(new ServiceCatalogValidationError(
          `Pricing record ${index + 1}: currency is required and must be a string`,
          `pricing_records[${index}].currency`,
          'REQUIRED_FIELD',
          pricing.currency
        ));
      } else if (pricing.currency.length !== 3) {
        errors.push(new ServiceCatalogValidationError(
          `Pricing record ${index + 1}: currency must be a 3-character code (e.g., USD, INR)`,
          `pricing_records[${index}].currency`,
          'INVALID_FORMAT',
          pricing.currency
        ));
      }

      // Validate price_type
      if (!pricing.price_type || typeof pricing.price_type !== 'string') {
        errors.push(new ServiceCatalogValidationError(
          `Pricing record ${index + 1}: price_type is required and must be a string`,
          `pricing_records[${index}].price_type`,
          'REQUIRED_FIELD',
          pricing.price_type
        ));
      }

      // Validate tax_inclusion
      if (pricing.tax_inclusion !== undefined && 
          pricing.tax_inclusion !== 'inclusive' && 
          pricing.tax_inclusion !== 'exclusive') {
        errors.push(new ServiceCatalogValidationError(
          `Pricing record ${index + 1}: tax_inclusion must be either "inclusive" or "exclusive"`,
          `pricing_records[${index}].tax_inclusion`,
          'INVALID_VALUE',
          pricing.tax_inclusion
        ));
      }

      // Validate tax_rate_ids if provided
      if (pricing.tax_rate_ids !== undefined) {
        if (!Array.isArray(pricing.tax_rate_ids)) {
          errors.push(new ServiceCatalogValidationError(
            `Pricing record ${index + 1}: tax_rate_ids must be an array`,
            `pricing_records[${index}].tax_rate_ids`,
            'INVALID_TYPE',
            typeof pricing.tax_rate_ids
          ));
        } else if (pricing.tax_rate_ids.length > 5) {
          errors.push(new ServiceCatalogValidationError(
            `Pricing record ${index + 1}: maximum 5 tax rates allowed`,
            `pricing_records[${index}].tax_rate_ids`,
            'TOO_MANY_ITEMS',
            pricing.tax_rate_ids.length
          ));
        } else {
          // Validate each tax_rate_id is a UUID
          pricing.tax_rate_ids.forEach((taxRateId: any, taxIndex: number) => {
            if (!this.isValidUUID(taxRateId)) {
              errors.push(new ServiceCatalogValidationError(
                `Pricing record ${index + 1}, tax rate ${taxIndex + 1}: invalid UUID format`,
                `pricing_records[${index}].tax_rate_ids[${taxIndex}]`,
                'INVALID_UUID',
                taxRateId
              ));
            }
          });
        }
      }
    });

    // Check for duplicate currencies
    const currencies = pricingRecords.map((p: any) => p.currency).filter(Boolean);
    const uniqueCurrencies = new Set(currencies);
    if (currencies.length !== uniqueCurrencies.size) {
      errors.push(new ServiceCatalogValidationError(
        'Duplicate currencies found in pricing records. Each currency should appear only once.',
        'pricing_records',
        'DUPLICATE_CURRENCY',
        currencies
      ));
    }

    return errors;
  }

  /**
   * Validate service type
   */
  private static validateServiceType(serviceType: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];

    if (serviceType !== undefined) {
      if (!['independent', 'resource_based'].includes(serviceType)) {
        errors.push(new ServiceCatalogValidationError(
          'service_type must be either "independent" or "resource_based"',
          'service_type',
          'INVALID_VALUE',
          serviceType
        ));
      }
    }

    return errors;
  }

  /**
   * Validate required resources
   */
  private static validateRequiredResources(resources: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];

    if (resources !== undefined) {
      if (!Array.isArray(resources)) {
        errors.push(new ServiceCatalogValidationError(
          'required_resources must be an array',
          'required_resources',
          'INVALID_TYPE',
          typeof resources
        ));
        return errors;
      }

      if (resources.length > this.VALIDATION_RULES.RESOURCES.MAX_COUNT) {
        errors.push(new ServiceCatalogValidationError(
          `Maximum ${this.VALIDATION_RULES.RESOURCES.MAX_COUNT} required resources allowed`,
          'required_resources',
          'TOO_MANY_ITEMS',
          resources.length
        ));
      }

      resources.forEach((resource: any, index: number) => {
        if (!resource.resource_id) {
          errors.push(new ServiceCatalogValidationError(
            `Resource ${index + 1}: resource_id is required`,
            `required_resources[${index}].resource_id`,
            'REQUIRED_FIELD',
            resource
          ));
        }

        if (resource.quantity !== undefined) {
          if (typeof resource.quantity !== 'number' || resource.quantity < 1) {
            errors.push(new ServiceCatalogValidationError(
              `Resource ${index + 1}: quantity must be a positive number`,
              `required_resources[${index}].quantity`,
              'INVALID_NUMBER',
              resource.quantity
            ));
          }
        }

        if (resource.is_optional !== undefined && typeof resource.is_optional !== 'boolean') {
          errors.push(new ServiceCatalogValidationError(
            `Resource ${index + 1}: is_optional must be a boolean`,
            `required_resources[${index}].is_optional`,
            'INVALID_TYPE',
            resource.is_optional
          ));
        }
      });
    }

    return errors;
  }

  /**
   * Validate duration
   */
  private static validateDuration(duration: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];
    const rules = this.VALIDATION_RULES.DURATION;

    if (duration !== undefined && duration !== null) {
      if (typeof duration !== 'number' || !Number.isInteger(duration)) {
        errors.push(new ServiceCatalogValidationError(
          'duration_minutes must be an integer',
          'duration_minutes',
          'INVALID_TYPE',
          duration
        ));
      } else if (duration < rules.MIN || duration > rules.MAX) {
        errors.push(new ServiceCatalogValidationError(
          `duration_minutes must be between ${rules.MIN} and ${rules.MAX} minutes`,
          'duration_minutes',
          'INVALID_RANGE',
          duration
        ));
      }
    }

    return errors;
  }

  /**
   * Validate sort order
   */
  private static validateSortOrder(sortOrder: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];
    const rules = this.VALIDATION_RULES.SORT_ORDER;

    if (sortOrder !== undefined && sortOrder !== null) {
      if (typeof sortOrder !== 'number' || !Number.isInteger(sortOrder)) {
        errors.push(new ServiceCatalogValidationError(
          'sort_order must be an integer',
          'sort_order',
          'INVALID_TYPE',
          sortOrder
        ));
      } else if (sortOrder < rules.MIN || sortOrder > rules.MAX) {
        errors.push(new ServiceCatalogValidationError(
          `sort_order must be between ${rules.MIN} and ${rules.MAX}`,
          'sort_order',
          'INVALID_RANGE',
          sortOrder
        ));
      }
    }

    return errors;
  }

  /**
   * Validate tags
   */
  private static validateTags(tags: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];
    const rules = this.VALIDATION_RULES.TAGS;

    if (tags !== undefined) {
      if (!Array.isArray(tags)) {
        errors.push(new ServiceCatalogValidationError(
          'tags must be an array',
          'tags',
          'INVALID_TYPE',
          typeof tags
        ));
        return errors;
      }

      if (tags.length > rules.MAX_COUNT) {
        errors.push(new ServiceCatalogValidationError(
          `Maximum ${rules.MAX_COUNT} tags allowed`,
          'tags',
          'TOO_MANY_ITEMS',
          tags.length
        ));
      }

      tags.forEach((tag: any, index: number) => {
        if (typeof tag !== 'string') {
          errors.push(new ServiceCatalogValidationError(
            `Tag ${index + 1}: must be a string`,
            `tags[${index}]`,
            'INVALID_TYPE',
            typeof tag
          ));
        } else if (tag.length === 0) {
          errors.push(new ServiceCatalogValidationError(
            `Tag ${index + 1}: cannot be empty`,
            `tags[${index}]`,
            'EMPTY_TAG',
            tag
          ));
        } else if (tag.length > rules.MAX_LENGTH) {
          errors.push(new ServiceCatalogValidationError(
            `Tag ${index + 1}: cannot exceed ${rules.MAX_LENGTH} characters`,
            `tags[${index}]`,
            'TAG_TOO_LONG',
            tag.length
          ));
        }
      });
    }

    return errors;
  }

  /**
   * Validate terms
   */
  private static validateTerms(terms: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];

    if (terms !== undefined && terms !== null) {
      if (typeof terms !== 'string') {
        errors.push(new ServiceCatalogValidationError(
          'terms must be a string',
          'terms',
          'INVALID_TYPE',
          typeof terms
        ));
      } else if (terms.length > this.VALIDATION_RULES.TERMS.MAX_LENGTH) {
        errors.push(new ServiceCatalogValidationError(
          `Terms must be ${this.VALIDATION_RULES.TERMS.MAX_LENGTH} characters or less`,
          'terms',
          'FIELD_TOO_LONG',
          terms.length
        ));
      }
    }

    return errors;
  }

  /**
   * Perform security checks
   */
  private static performSecurityChecks(data: any): ServiceCatalogValidationError[] {
    const errors: ServiceCatalogValidationError[] = [];

    // Check for SQL injection in text fields
    const textFields = ['service_name', 'description', 'short_description', 'sku'];
    for (const field of textFields) {
      if (data[field] && typeof data[field] === 'string') {
        const sqlCheck = this.checkSQLInjection(data[field]);
        if (!sqlCheck.isSafe) {
          errors.push(new ServiceCatalogValidationError(
            `Potential SQL injection detected in ${field}`,
            field,
            'SECURITY_SQL_INJECTION',
            sqlCheck.threats
          ));
        }

        const xssCheck = this.checkXSSThreats(data[field]);
        if (!xssCheck.isSafe) {
          errors.push(new ServiceCatalogValidationError(
            `Potential XSS threat detected in ${field}`,
            field,
            'SECURITY_XSS_THREAT',
            xssCheck.threats
          ));
        }
      }
    }

    // Validate JSON payload structure
    const jsonValidation = this.validateJSONPayload(data);
    if (!jsonValidation.isValid) {
      errors.push(new ServiceCatalogValidationError(
        'JSON payload exceeds complexity limits',
        'payload',
        'PAYLOAD_TOO_COMPLEX',
        jsonValidation.reason
      ));
    }

    return errors;
  }

  /**
   * Validate service filters
   */
  static validateServiceFilters(filters: ServiceCatalogFilters): { isValid: boolean; errors: ServiceCatalogValidationError[] } {
    const errors: ServiceCatalogValidationError[] = [];

    if (filters.is_active !== undefined && typeof filters.is_active !== 'boolean') {
      errors.push(new ServiceCatalogValidationError(
        'is_active must be a boolean (true or false)',
        'is_active',
        'INVALID_TYPE',
        filters.is_active
      ));
    }

    if (filters.has_resources !== undefined && typeof filters.has_resources !== 'boolean') {
      errors.push(new ServiceCatalogValidationError(
        'has_resources must be a boolean (true or false)',
        'has_resources',
        'INVALID_TYPE',
        filters.has_resources
      ));
    }

    if (filters.search_term !== undefined) {
      if (typeof filters.search_term !== 'string') {
        errors.push(new ServiceCatalogValidationError(
          'search_term must be a string',
          'search_term',
          'INVALID_TYPE',
          typeof filters.search_term
        ));
      } else if (filters.search_term.length > 255) {
        errors.push(new ServiceCatalogValidationError(
          'search_term must be 255 characters or less',
          'search_term',
          'FIELD_TOO_LONG',
          filters.search_term.length
        ));
      }
    }

    if (filters.price_min !== undefined) {
      if (typeof filters.price_min !== 'number' || filters.price_min < 0) {
        errors.push(new ServiceCatalogValidationError(
          'price_min must be a non-negative number',
          'price_min',
          'INVALID_NUMBER',
          filters.price_min
        ));
      }
    }

    if (filters.price_max !== undefined) {
      if (typeof filters.price_max !== 'number' || filters.price_max < 0) {
        errors.push(new ServiceCatalogValidationError(
          'price_max must be a non-negative number',
          'price_max',
          'INVALID_NUMBER',
          filters.price_max
        ));
      }
    }

    if (filters.price_min !== undefined && filters.price_max !== undefined) {
      if (filters.price_min > filters.price_max) {
        errors.push(new ServiceCatalogValidationError(
          'price_min cannot be greater than price_max',
          'price_range',
          'INVALID_RANGE',
          { min: filters.price_min, max: filters.price_max }
        ));
      }
    }

    if (filters.currency !== undefined) {
      if (typeof filters.currency !== 'string' || filters.currency.length !== 3) {
        errors.push(new ServiceCatalogValidationError(
          'currency must be a 3-character currency code',
          'currency',
          'INVALID_FORMAT',
          filters.currency
        ));
      }
    }

    if (filters.sort_by !== undefined) {
      const validSortFields = ['name', 'created_at', 'updated_at', 'price', 'sort_order'];
      if (!validSortFields.includes(filters.sort_by)) {
        errors.push(new ServiceCatalogValidationError(
          `sort_by must be one of: ${validSortFields.join(', ')}`,
          'sort_by',
          'INVALID_VALUE',
          filters.sort_by
        ));
      }
    }

    if (filters.sort_direction !== undefined) {
      if (!['asc', 'desc'].includes(filters.sort_direction)) {
        errors.push(new ServiceCatalogValidationError(
          'sort_direction must be either "asc" or "desc"',
          'sort_direction',
          'INVALID_VALUE',
          filters.sort_direction
        ));
      }
    }

    if (filters.limit !== undefined) {
      if (typeof filters.limit !== 'number' || filters.limit < 1 || filters.limit > 1000) {
        errors.push(new ServiceCatalogValidationError(
          'limit must be a number between 1 and 1000',
          'limit',
          'INVALID_RANGE',
          filters.limit
        ));
      }
    }

    if (filters.offset !== undefined) {
      if (typeof filters.offset !== 'number' || filters.offset < 0) {
        errors.push(new ServiceCatalogValidationError(
          'offset must be a non-negative number',
          'offset',
          'INVALID_NUMBER',
          filters.offset
        ));
      }
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  /**
   * Sanitize filters
   */
  static sanitizeFilters(filters: ServiceCatalogFilters): ServiceCatalogFilters {
    const sanitized: ServiceCatalogFilters = {};

    if (filters.search_term !== undefined) {
      sanitized.search_term = this.sanitizeInput(filters.search_term, this.VALIDATION_RULES.SERVICE_NAME.MAX_LENGTH);
    }

    if (filters.category_id !== undefined) {
      sanitized.category_id = filters.category_id;
    }

    if (filters.industry_id !== undefined) {
      sanitized.industry_id = filters.industry_id;
    }

    if (filters.is_active !== undefined) {
      sanitized.is_active = filters.is_active;
    }

    if (filters.has_resources !== undefined) {
      sanitized.has_resources = filters.has_resources;
    }

    if (filters.price_min !== undefined) {
      sanitized.price_min = Math.max(0, Number(filters.price_min) || 0);
    }

    if (filters.price_max !== undefined) {
      sanitized.price_max = Math.max(0, Number(filters.price_max) || 0);
    }

    if (filters.currency !== undefined) {
      sanitized.currency = filters.currency.toUpperCase().substring(0, 3);
    }

    if (filters.sort_by !== undefined) {
      const validSortFields = ['name', 'created_at', 'updated_at', 'price', 'sort_order'];
      sanitized.sort_by = validSortFields.includes(filters.sort_by) ? filters.sort_by : 'created_at';
    }

    if (filters.sort_direction !== undefined) {
      sanitized.sort_direction = ['asc', 'desc'].includes(filters.sort_direction) ? filters.sort_direction : 'desc';
    }

    sanitized.limit = Math.min(1000, Math.max(1, Number(filters.limit) || 50));
    sanitized.offset = Math.max(0, Number(filters.offset) || 0);

    return sanitized;
  }

  /**
   * Security: Check for SQL injection patterns
   */
  static checkSQLInjection(input: string): { isSafe: boolean; threats: string[] } {
    const threats: string[] = [];
    const sqlPatterns = [
      /(\bor\b|\band\b).*?=.*?/i,
      /union.*?select/i,
      /insert.*?into/i,
      /delete.*?from/i,
      /drop.*?table/i,
      /update.*?set/i,
      /exec(\s|\+)+(s|x)p\w+/i,
      /;.*?--/,
      /\/\*.*?\*\//
    ];

    for (const pattern of sqlPatterns) {
      if (pattern.test(input)) {
        threats.push(pattern.toString());
      }
    }

    return {
      isSafe: threats.length === 0,
      threats
    };
  }

  /**
   * Security: Check for XSS threats
   */
  static checkXSSThreats(input: string): { isSafe: boolean; threats: string[] } {
    const threats: string[] = [];
    const xssPatterns = [
      /<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi,
      /<iframe\b[^<]*(?:(?!<\/iframe>)<[^<]*)*<\/iframe>/gi,
      /on\w+\s*=\s*["'][^"']*["']/gi,
      /javascript:/gi,
      /vbscript:/gi,
      /data:text\/html/gi
    ];

    for (const pattern of xssPatterns) {
      if (pattern.test(input)) {
        threats.push(pattern.toString());
      }
    }

    return {
      isSafe: threats.length === 0,
      threats
    };
  }

  /**
   * Validate JSON payload complexity
   */
  static validateJSONPayload(payload: any, maxDepth: number = 10, maxKeys: number = 100): { isValid: boolean; reason?: string } {
    let keyCount = 0;

    const checkDepth = (obj: any, currentDepth: number): boolean => {
      if (currentDepth > maxDepth) {
        return false;
      }

      if (typeof obj === 'object' && obj !== null) {
        const keys = Object.keys(obj);
        keyCount += keys.length;

        if (keyCount > maxKeys) {
          return false;
        }

        for (const key of keys) {
          if (!checkDepth(obj[key], currentDepth + 1)) {
            return false;
          }
        }
      }

      return true;
    };

    const isValid = checkDepth(payload, 0);

    if (!isValid) {
      if (keyCount > maxKeys) {
        return { isValid: false, reason: `Exceeds maximum key count (${maxKeys})` };
      }
      return { isValid: false, reason: `Exceeds maximum depth (${maxDepth})` };
    }

    return { isValid: true };
  }

  /**
   * Sanitize input string
   */
  static sanitizeInput(input: string, maxLength: number = 255): string {
    return input
      .replace(/[^\w\s\-_.@]/g, '')
      .substring(0, maxLength)
      .trim();
  }

  /**
   * Validate UUID format
   */
  static isValidUUID(uuid: string): boolean {
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    return uuidRegex.test(uuid);
  }

  /**
   * Enhanced UUID validation with result
   */
  static validateUUID(uuid: string, fieldName: string = 'id'): { isValid: boolean; error?: ServiceCatalogValidationError } {
    if (!this.isValidUUID(uuid)) {
      return {
        isValid: false,
        error: new ServiceCatalogValidationError(
          `${fieldName} must be a valid UUID`,
          fieldName,
          'INVALID_UUID',
          uuid
        )
      };
    }
    return { isValid: true };
  }

  /**
   * Generate URL-friendly slug
   */
  static generateSlug(name: string): string {
    return name
      .toLowerCase()
      .replace(/[^\w\s-]/g, '')
      .replace(/\s+/g, '-')
      .replace(/-+/g, '-')
      .trim();
  }

  /**
   * Generate unique request ID
   */
  static generateRequestId(): string {
    return `req_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
  }

  /**
   * Hash object for comparison
   */
  static hashObject(obj: any): string {
    return JSON.stringify(obj, Object.keys(obj).sort());
  }
}