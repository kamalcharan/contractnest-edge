// supabase/functions/_shared/catalog/catalogValidation.ts
// ✅ ENHANCED: Catalog validation with essential resource support

import { 
  CreateCatalogItemRequest, 
  UpdateCatalogItemRequest,
  CreateMultiCurrencyPricingRequest,
  RestoreCatalogItemRequest,
  CurrencyPricingUpdate,
  CatalogItem,
  CatalogServiceConfig,
  ValidationError,
  validateCurrency,
  validatePrice,
  validateCatalogType,
  validatePriceType,
  validateMultiCurrencyPricing,
  SUPPORTED_CURRENCIES
} from './catalogTypes.ts';

// =================================================================
// ESSENTIAL RESOURCE CONSTANTS
// =================================================================

// =================================================================
// SHARED CONSTANTS (for use across catalog files)
// =================================================================

export const RESOURCE_CONTACT_CLASSIFICATIONS = {
  TEAM_MEMBER: { display: 'Team Member', alias: 'team_member' },
  PARTNER: { display: 'Partner', alias: 'partner' },
  VENDOR: { display: 'Vendor', alias: 'vendor' },
  BUYER: { display: 'Buyer', alias: 'buyer' },
  SELLER: { display: 'Seller', alias: 'seller' }
} as const;

// Resource type to contact classification mapping
const RESOURCE_CONTACT_ELIGIBILITY = {
  'team_staff': ['team_member'],
  'partner': ['partner', 'vendor']
} as const;

export class CatalogValidationService {
  constructor(
    private supabase: any,
    private config: CatalogServiceConfig
  ) {}

  // =================================================================
  // ENHANCED CATALOG ITEM VALIDATION
  // =================================================================

  async validateCreateRequest(data: CreateCatalogItemRequest): Promise<{
    is_valid: boolean;
    errors: Array<{ field: string; message: string }>;
    warnings?: Array<{ field: string; message: string }>;
  }> {
    const errors: Array<{ field: string; message: string }> = [];
    const warnings: Array<{ field: string; message: string }> = [];

    // Validate catalog type
    const catalogTypeValidation = validateCatalogType(data.catalog_type);
    if (!catalogTypeValidation.isValid) {
      errors.push({ field: 'catalog_type', message: catalogTypeValidation.error! });
    }

    // Validate name
    if (!data.name || data.name.trim().length === 0) {
      errors.push({ field: 'name', message: 'Name is required' });
    } else if (data.name.length > 255) {
      errors.push({ field: 'name', message: 'Name must be 255 characters or less' });
    }

    // Validate description
    if (!data.description_content || data.description_content.trim().length === 0) {
      errors.push({ field: 'description_content', message: 'Description is required' });
    } else if (data.description_content.length > 10000) {
      errors.push({ field: 'description_content', message: 'Description must be 10000 characters or less' });
    }

    // Validate service terms (optional)
    if (data.terms_content && data.terms_content.length > 20000) {
      errors.push({ field: 'terms_content', message: 'Service terms must be 20000 characters or less' });
    }

    // ✅ ESSENTIAL: Validate team_staff resources have valid contacts
    if (data.resources && data.resources.length > 0) {
      for (let i = 0; i < data.resources.length; i++) {
        const resource = data.resources[i];
        if (resource.resource_type_id === 'team_staff' || resource.resource_type_id === 'partner') {
          if (!resource.contact_id) {
            errors.push({ 
              field: `resources[${i}].contact_id`, 
              message: `Contact is required for ${resource.resource_type_id} resources` 
            });
          } else {
            const contactValid = await this.validateContactForResource(resource.contact_id, resource.resource_type_id);
            if (!contactValid.is_valid) {
              errors.push({ 
                field: `resources[${i}].contact_id`, 
                message: contactValid.error || 'Invalid contact' 
              });
            }
          }
        }
      }
    }

    // Original pricing validation
    if (data.pricing && data.pricing.length > 0) {
      data.pricing.forEach((price, index) => {
        // Validate price type
        const priceTypeValidation = validatePriceType(price.price_type);
        if (!priceTypeValidation.isValid) {
          errors.push({ 
            field: `pricing[${index}].price_type`, 
            message: priceTypeValidation.error!
          });
        }

        // Validate currency
        const currencyValidation = validateCurrency(price.currency);
        if (!currencyValidation.isValid) {
          errors.push({ 
            field: `pricing[${index}].currency`, 
            message: currencyValidation.error!
          });
        }

        // Validate price
        const priceValidation = validatePrice(price.price);
        if (!priceValidation.isValid) {
          errors.push({ 
            field: `pricing[${index}].price`, 
            message: priceValidation.error!
          });
        }
      });

      // Check for duplicate currencies in pricing
      const currencies = data.pricing.map(p => p.currency.toUpperCase());
      const uniqueCurrencies = new Set(currencies);
      if (currencies.length !== uniqueCurrencies.size) {
        errors.push({ field: 'pricing', message: 'Duplicate currencies are not allowed' });
      }
    }

    // Check for duplicate names
    const { data: existing } = await this.supabase
      .from('t_catalog_items')
      .select('id')
      .eq('tenant_id', this.config.tenant_id)
      .eq('is_live', this.config.is_live)
      .eq('name', data.name.trim())
      .eq('status', 'active')
      .single();

    if (existing) {
      warnings.push({ 
        field: 'name', 
        message: 'An item with this name already exists' 
      });
    }

    return {
      is_valid: errors.length === 0,
      errors,
      warnings: warnings.length > 0 ? warnings : undefined
    };
  }

  async validateUpdateRequest(
    currentItem: CatalogItem,
    updateData: UpdateCatalogItemRequest
  ): Promise<{
    is_valid: boolean;
    errors: Array<{ field: string; message: string }>;
    warnings?: Array<{ field: string; message: string }>;
  }> {
    const errors: Array<{ field: string; message: string }> = [];
    const warnings: Array<{ field: string; message: string }> = [];

    // Name validation
    if (updateData.name !== undefined) {
      if (!updateData.name || updateData.name.trim().length === 0) {
        errors.push({ field: 'name', message: 'Name cannot be empty' });
      } else if (updateData.name.length > 255) {
        errors.push({ field: 'name', message: 'Name must be 255 characters or less' });
      }
    }

    // Description validation
    if (updateData.description_content !== undefined) {
      if (!updateData.description_content || updateData.description_content.trim().length === 0) {
        errors.push({ field: 'description_content', message: 'Description cannot be empty' });
      } else if (updateData.description_content.length > 10000) {
        errors.push({ field: 'description_content', message: 'Description must be 10000 characters or less' });
      }
    }

    // Service terms validation
    if (updateData.terms_content !== undefined && updateData.terms_content && updateData.terms_content.length > 20000) {
      errors.push({ field: 'terms_content', message: 'Service terms must be 20000 characters or less' });
    }

    // ✅ ESSENTIAL: Validate resource updates for human resources
    if (updateData.add_resources && updateData.add_resources.length > 0) {
      for (let i = 0; i < updateData.add_resources.length; i++) {
        const resource = updateData.add_resources[i];
        if ((resource.resource_type_id === 'team_staff' || resource.resource_type_id === 'partner') && !resource.contact_id) {
          errors.push({ 
            field: `add_resources[${i}].contact_id`, 
            message: `Contact is required for ${resource.resource_type_id} resources` 
          });
        }
      }
    }

    // Check for duplicate names (if name is being changed)
    if (updateData.name && updateData.name !== currentItem.name) {
      const { data: existing } = await this.supabase
        .from('t_catalog_items')
        .select('id')
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live)
        .eq('name', updateData.name.trim())
        .eq('status', 'active')
        .neq('id', currentItem.id);

      if (existing) {
        warnings.push({ 
          field: 'name', 
          message: 'Another item with this name already exists' 
        });
      }
    }

    return {
      is_valid: errors.length === 0,
      errors,
      warnings: warnings.length > 0 ? warnings : undefined
    };
  }

  // =================================================================
  // ✅ ESSENTIAL: Contact validation for human resources
  // =================================================================

  /**
   * Validate contact eligibility for team_staff and partner resources
   */
  private async validateContactForResource(contactId: string, resourceType: string): Promise<{
    is_valid: boolean;
    error?: string;
  }> {
    try {
      const requiredClassifications = RESOURCE_CONTACT_ELIGIBILITY[resourceType as keyof typeof RESOURCE_CONTACT_ELIGIBILITY];
      if (!requiredClassifications || requiredClassifications.length === 0) {
        return { is_valid: true };
      }

      const { data: contact, error } = await this.supabase
        .from('t_contacts')
        .select('id, company_name, name, classifications, status')
        .eq('id', contactId)
        .eq('tenant_id', this.config.tenant_id)
        .single();

      if (error || !contact) {
        return { is_valid: false, error: 'Contact not found' };
      }

      if (contact.status !== 'active') {
        return { is_valid: false, error: 'Contact must be active' };
      }

      // STRICT validation: contact.classifications must include required classification
      const hasRequiredClassification = requiredClassifications.some(classification =>
        contact.classifications && contact.classifications.includes(classification)
      );

      if (!hasRequiredClassification) {
        return { 
          is_valid: false, 
          error: `Contact must have classification: ${requiredClassifications.join(' or ')}` 
        };
      }

      return { is_valid: true };

    } catch (error) {
      return { is_valid: false, error: 'Failed to validate contact' };
    }
  }

  // =================================================================
  // EXISTING METHODS (unchanged)
  // =================================================================

  async validateRestoreRequest(data: RestoreCatalogItemRequest): Promise<{
    is_valid: boolean;
    errors: Array<{ field: string; message: string }>;
    warnings?: Array<{ field: string; message: string }>;
  }> {
    const errors: Array<{ field: string; message: string }> = [];
    const warnings: Array<{ field: string; message: string }> = [];

    // Validate catalog_id
    if (!data.catalog_id || typeof data.catalog_id !== 'string') {
      errors.push({ field: 'catalog_id', message: 'Catalog ID is required and must be a string' });
    } else {
      // Check if catalog item exists
      const { data: catalogItem, error } = await this.supabase
        .from('t_catalog_items')
        .select('id, name, status')
        .eq('id', data.catalog_id)
        .eq('tenant_id', this.config.tenant_id)
        .eq('is_live', this.config.is_live)
        .single();

      if (error || !catalogItem) {
        errors.push({ field: 'catalog_id', message: 'Catalog item not found' });
      } else if (catalogItem.status === 'active') {
        errors.push({ field: 'catalog_id', message: 'Catalog item is already active' });
      }
    }

    return {
      is_valid: errors.length === 0,
      errors,
      warnings: warnings.length > 0 ? warnings : undefined
    };
  }

  async validateMultiCurrencyPricingData(data: CreateMultiCurrencyPricingRequest): Promise<{
    is_valid: boolean;
    errors: Array<{ field: string; message: string }>;
    warnings?: Array<{ field: string; message: string }>;
  }> {
    const warnings: Array<{ field: string; message: string }> = [];

    // Use the comprehensive validation function from types
    const validation = validateMultiCurrencyPricing(data);
    
    if (!validation.isValid) {
      return {
        is_valid: false,
        errors: validation.errors,
        warnings: warnings.length > 0 ? warnings : undefined
      };
    }

    // Check if catalog item exists and is active
    const { data: catalogItem, error } = await this.supabase
      .from('t_catalog_items')
      .select('id, name, status')
      .eq('id', data.catalog_id)
      .eq('tenant_id', this.config.tenant_id)
      .eq('is_live', this.config.is_live)
      .single();

    if (error || !catalogItem) {
      validation.errors.push({ field: 'catalog_id', message: 'Catalog item not found' });
    } else if (catalogItem.status !== 'active') {
      validation.errors.push({ field: 'catalog_id', message: 'Cannot update pricing for inactive catalog item' });
    }

    return {
      is_valid: validation.errors.length === 0,
      errors: validation.errors,
      warnings: warnings.length > 0 ? warnings : undefined
    };
  }

  async validateTenantAccess(catalogId: string): Promise<{
    is_valid: boolean;
    error?: string;
  }> {
    try {
      const { data: catalogItem, error } = await this.supabase
        .from('t_catalog_items')
        .select('id, tenant_id')
        .eq('id', catalogId)
        .eq('is_live', this.config.is_live)
        .single();

      if (error || !catalogItem) {
        return { is_valid: false, error: 'Catalog item not found' };
      }

      if (catalogItem.tenant_id !== this.config.tenant_id) {
        return { is_valid: false, error: 'Access denied: catalog item belongs to different tenant' };
      }

      return { is_valid: true };
    } catch (error) {
      return { is_valid: false, error: 'Failed to validate tenant access' };
    }
  }

  validateBulkOperationLimits(itemCount: number, operation: string): {
    is_valid: boolean;
    errors: Array<{ field: string; message: string }>;
    warnings?: Array<{ field: string; message: string }>;
  } {
    const errors: Array<{ field: string; message: string }> = [];
    const warnings: Array<{ field: string; message: string }> = [];

    const limits = {
      create: 100,
      update: 100,
      delete: 50,
      restore: 50,
      pricing: 200
    };

    const limit = limits[operation as keyof typeof limits] || 50;

    if (itemCount > limit) {
      errors.push({ 
        field: 'items', 
        message: `Bulk ${operation} operations are limited to ${limit} items. Received ${itemCount} items.` 
      });
    } else if (itemCount > limit * 0.8) {
      warnings.push({
        field: 'items',
        message: `Processing ${itemCount} items may take longer than usual`
      });
    }

    if (itemCount === 0) {
      errors.push({ field: 'items', message: 'At least one item is required for bulk operations' });
    }

    return {
      is_valid: errors.length === 0,
      errors,
      warnings: warnings.length > 0 ? warnings : undefined
    };
  }
}