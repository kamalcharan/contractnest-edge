// supabase/functions/_shared/contacts/contactValidation.ts - PRODUCTION READY COMPLETE VERSION
import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';

const CONTACT_TYPES = ['individual', 'corporate', 'contact_person'];
const CONTACT_STATUS = ['active', 'inactive', 'archived'];
const CONTACT_CLASSIFICATIONS = ['buyer', 'seller', 'vendor', 'partner', 'team_member']; // FIXED: Added team_member
const CHANNEL_TYPES = ['mobile', 'phone', 'email', 'whatsapp', 'linkedin', 'website', 'telegram', 'skype'];
const ADDRESS_TYPES = ['home', 'office', 'billing', 'shipping', 'factory', 'warehouse', 'other'];

const VALIDATION_RULES = {
  NAME_MIN_LENGTH: 2,
  NAME_MAX_LENGTH: 100,
  PHONE_MIN_LENGTH: 10,
  PHONE_MAX_LENGTH: 15,
  EMAIL_MAX_LENGTH: 200,
  NOTES_MAX_LENGTH: 1000
};

interface ValidationResult {
  isValid: boolean;
  errors: string[];
}

export class ContactValidationService {
  constructor(private supabase: SupabaseClient) {}

  async validateCreateRequest(data: any): Promise<ValidationResult> {
    const errors: string[] = [];

    // Basic required fields
    if (!data.tenant_id) {
      errors.push('Tenant ID is required');
    }

    // Contact type validation
    if (!data.type || !CONTACT_TYPES.includes(data.type)) {
      errors.push(`Contact type must be one of: ${CONTACT_TYPES.join(', ')}`);
    }

    // Type-specific validation
    if (data.type === 'individual') {
      if (!data.name || data.name.trim().length < VALIDATION_RULES.NAME_MIN_LENGTH) {
        errors.push(`Name is required and must be at least ${VALIDATION_RULES.NAME_MIN_LENGTH} characters`);
      }
      if (data.name && data.name.length > VALIDATION_RULES.NAME_MAX_LENGTH) {
        errors.push(`Name must not exceed ${VALIDATION_RULES.NAME_MAX_LENGTH} characters`);
      }
    }

    if (data.type === 'corporate') {
      if (!data.company_name || data.company_name.trim().length < VALIDATION_RULES.NAME_MIN_LENGTH) {
        errors.push(`Company name is required and must be at least ${VALIDATION_RULES.NAME_MIN_LENGTH} characters`);
      }
      if (data.company_name && data.company_name.length > VALIDATION_RULES.NAME_MAX_LENGTH) {
        errors.push(`Company name must not exceed ${VALIDATION_RULES.NAME_MAX_LENGTH} characters`);
      }
    }

    // Status validation
    if (data.status && !CONTACT_STATUS.includes(data.status)) {
      errors.push(`Status must be one of: ${CONTACT_STATUS.join(', ')}`);
    }

    // Classifications validation with team_member included
    if (!data.classifications || !Array.isArray(data.classifications) || data.classifications.length === 0) {
      errors.push('At least one classification is required');
    } else {
      const invalidClassifications = data.classifications.filter((c: string) => !CONTACT_CLASSIFICATIONS.includes(c));
      if (invalidClassifications.length > 0) {
        errors.push(`Invalid classifications: ${invalidClassifications.join(', ')}`);
      }
    }

    // Contact channels validation
    if (!data.contact_channels || !Array.isArray(data.contact_channels) || data.contact_channels.length === 0) {
      errors.push('At least one contact channel is required');
    } else {
      const channelErrors = this.validateContactChannels(data.contact_channels);
      errors.push(...channelErrors);
    }

    // Addresses validation
    if (data.addresses && Array.isArray(data.addresses)) {
      const addressErrors = this.validateAddresses(data.addresses);
      errors.push(...addressErrors);
    }

    // Notes validation
    if (data.notes && data.notes.length > VALIDATION_RULES.NOTES_MAX_LENGTH) {
      errors.push(`Notes must not exceed ${VALIDATION_RULES.NOTES_MAX_LENGTH} characters`);
    }

    // Tags validation
    if (data.tags && Array.isArray(data.tags)) {
      if (data.tags.length > 10) {
        errors.push('Maximum 10 tags allowed');
      }
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  async validateUpdateRequest(contactId: string, data: any): Promise<ValidationResult> {
    const errors: string[] = [];

    // Check if contact exists
    const { data: existingContact, error } = await this.supabase
      .from('t_contacts')
      .select('id, status')
      .eq('id', contactId)
      .single();

    if (error || !existingContact) {
      errors.push('Contact not found');
      return { isValid: false, errors };
    }

    // Business rule: Cannot update archived contacts
    if (existingContact.status === 'archived') {
      errors.push('Cannot update archived contact');
      return { isValid: false, errors };
    }

    // Run same validations as create (excluding required fields)
    const createValidation = await this.validateCreateRequest({
      ...data,
      tenant_id: 'dummy', // Skip tenant validation for updates
      type: data.type || 'individual' // Provide default to skip type validation
    });

    // Filter out tenant and type errors for updates
    const filteredErrors = createValidation.errors.filter(error => 
      !error.includes('Tenant ID is required') &&
      !error.includes('Contact type must be one of')
    );

    errors.push(...filteredErrors);

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private validateContactChannels(channels: any[]): string[] {
    const errors: string[] = [];
    let hasPrimary = false;
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    const phoneRegex = /^[0-9]{10,15}$/;

    for (let i = 0; i < channels.length; i++) {
      const channel = channels[i];

      // Channel type validation
      if (!channel.channel_type || !CHANNEL_TYPES.includes(channel.channel_type)) {
        errors.push(`Channel ${i + 1}: Invalid channel type`);
        continue;
      }

      // Value validation
      if (!channel.value || channel.value.trim().length === 0) {
        errors.push(`Channel ${i + 1}: Value is required`);
        continue;
      }

      // Type-specific validation
      if (channel.channel_type === 'email') {
        if (!emailRegex.test(channel.value)) {
          errors.push(`Channel ${i + 1}: Invalid email format`);
        }
        if (channel.value.length > VALIDATION_RULES.EMAIL_MAX_LENGTH) {
          errors.push(`Channel ${i + 1}: Email too long`);
        }
      }

      if (channel.channel_type === 'mobile' || channel.channel_type === 'phone') {
        const cleanPhone = channel.value.replace(/[^0-9]/g, '');
        if (!phoneRegex.test(cleanPhone)) {
          errors.push(`Channel ${i + 1}: Invalid ${channel.channel_type} number format`);
        }
      }

      // Primary channel tracking
      if (channel.is_primary) {
        if (hasPrimary) {
          errors.push('Only one contact channel can be marked as primary');
        }
        hasPrimary = true;
      }
    }

    if (!hasPrimary) {
      errors.push('At least one contact channel must be marked as primary');
    }

    return errors;
  }

  private validateAddresses(addresses: any[]): string[] {
    const errors: string[] = [];
    let hasPrimary = false;

    for (let i = 0; i < addresses.length; i++) {
      const address = addresses[i];

      // Address type validation
      if (!address.type || !ADDRESS_TYPES.includes(address.type)) {
        errors.push(`Address ${i + 1}: Invalid address type`);
      }

      // Required fields
      if (!address.address_line1 || address.address_line1.trim().length === 0) {
        errors.push(`Address ${i + 1}: Address line 1 is required`);
      }

      if (!address.city || address.city.trim().length === 0) {
        errors.push(`Address ${i + 1}: City is required`);
      }

      if (!address.country_code || address.country_code.trim().length === 0) {
        errors.push(`Address ${i + 1}: Country code is required`);
      }

      // Primary address tracking
      if (address.is_primary) {
        if (hasPrimary) {
          errors.push('Only one address can be marked as primary');
        }
        hasPrimary = true;
      }

      // Length validations
      if (address.address_line1 && address.address_line1.length > 200) {
        errors.push(`Address ${i + 1}: Address line 1 too long`);
      }

      if (address.city && address.city.length > 100) {
        errors.push(`Address ${i + 1}: City name too long`);
      }
    }

    return errors;
  }

  // Validate specific business rules
  async validateBusinessRules(contactData: any, operation: 'create' | 'update'): Promise<ValidationResult> {
    const errors: string[] = [];

    // Business rule: Check if user account exists for invitation
    if (contactData.send_invitation) {
      const primaryMobile = contactData.contact_channels?.find(
        (ch: any) => ch.channel_type === 'mobile' && ch.is_primary
      );

      if (primaryMobile) {
        const userExists = await this.checkUserExists(primaryMobile.value);
        if (userExists) {
          errors.push('User account already exists for this mobile number');
        }
      }
    }

    // Business rule: Corporate-specific validations
    if (contactData.type === 'corporate') {
      if (contactData.compliance_numbers && Array.isArray(contactData.compliance_numbers)) {
        for (const compliance of contactData.compliance_numbers) {
          if (!compliance.type_value || !compliance.number) {
            errors.push('Compliance numbers must have type and number');
          }
        }
      }
    }

    return {
      isValid: errors.length === 0,
      errors
    };
  }

  private async checkUserExists(mobileNumber: string): Promise<boolean> {
    try {
      // This would check auth.users table for existing user
      const { data, error } = await this.supabase
        .from('auth.users')
        .select('id')
        .eq('phone', mobileNumber)
        .single();

      return !error && !!data;
    } catch {
      return false;
    }
  }
}