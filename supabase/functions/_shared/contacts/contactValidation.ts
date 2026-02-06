// supabase/functions/_shared/contacts/contactValidation.ts - PRODUCTION READY COMPLETE VERSION
import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';

const CONTACT_TYPES = ['individual', 'corporate', 'contact_person'];
const CONTACT_STATUS = ['active', 'inactive', 'archived'];
const CONTACT_CLASSIFICATIONS = ['buyer', 'seller', 'vendor', 'partner', 'team_member', 'team_staff', 'supplier', 'customer', 'lead', 'client'];
const CHANNEL_TYPES = ['mobile', 'phone', 'email', 'whatsapp', 'linkedin', 'website', 'telegram', 'skype'];
const PHONE_CHANNEL_TYPES = ['mobile', 'phone', 'whatsapp'];
const ADDRESS_TYPES = ['home', 'office', 'billing', 'shipping', 'factory', 'warehouse', 'other'];

const VALIDATION_RULES = {
  NAME_MIN_LENGTH: 2,
  NAME_MAX_LENGTH: 100,
  PHONE_MIN_LENGTH: 7,
  PHONE_MAX_LENGTH: 15,
  EMAIL_MAX_LENGTH: 200,
  NOTES_MAX_LENGTH: 1000
};

// Country phone data for normalization and validation
// ISO code -> { phoneCode, minLength, maxLength }
const COUNTRY_PHONE_DATA: Record<string, { phoneCode: string; min: number; max: number }> = {
  'IN': { phoneCode: '91', min: 10, max: 10 },
  'US': { phoneCode: '1', min: 10, max: 10 },
  'GB': { phoneCode: '44', min: 10, max: 11 },
  'AE': { phoneCode: '971', min: 9, max: 9 },
  'SG': { phoneCode: '65', min: 8, max: 8 },
  'MY': { phoneCode: '60', min: 9, max: 10 },
  'AU': { phoneCode: '61', min: 9, max: 9 },
  'CA': { phoneCode: '1', min: 10, max: 10 },
  'DE': { phoneCode: '49', min: 10, max: 11 },
  'FR': { phoneCode: '33', min: 9, max: 9 },
  'JP': { phoneCode: '81', min: 10, max: 11 },
  'CN': { phoneCode: '86', min: 11, max: 11 },
  'SA': { phoneCode: '966', min: 9, max: 9 },
  'QA': { phoneCode: '974', min: 8, max: 8 },
  'KW': { phoneCode: '965', min: 8, max: 8 },
  'BH': { phoneCode: '973', min: 8, max: 8 },
  'OM': { phoneCode: '968', min: 8, max: 8 },
  'NZ': { phoneCode: '64', min: 9, max: 10 },
  'ZA': { phoneCode: '27', min: 9, max: 9 },
  'BR': { phoneCode: '55', min: 10, max: 11 },
  'MX': { phoneCode: '52', min: 10, max: 10 },
  'KR': { phoneCode: '82', min: 9, max: 10 },
  'IT': { phoneCode: '39', min: 9, max: 10 },
  'ES': { phoneCode: '34', min: 9, max: 9 },
  'NL': { phoneCode: '31', min: 9, max: 9 },
  'SE': { phoneCode: '46', min: 9, max: 10 },
  'NO': { phoneCode: '47', min: 8, max: 8 },
  'DK': { phoneCode: '45', min: 8, max: 8 },
  'FI': { phoneCode: '358', min: 9, max: 10 },
  'CH': { phoneCode: '41', min: 9, max: 9 },
  'AT': { phoneCode: '43', min: 10, max: 11 },
  'PH': { phoneCode: '63', min: 10, max: 10 },
  'TH': { phoneCode: '66', min: 9, max: 9 },
  'ID': { phoneCode: '62', min: 10, max: 12 },
  'VN': { phoneCode: '84', min: 9, max: 10 },
  'BD': { phoneCode: '880', min: 10, max: 10 },
  'PK': { phoneCode: '92', min: 10, max: 10 },
  'LK': { phoneCode: '94', min: 9, max: 9 },
  'NP': { phoneCode: '977', min: 10, max: 10 },
  'NG': { phoneCode: '234', min: 10, max: 10 },
  'KE': { phoneCode: '254', min: 9, max: 9 },
  'EG': { phoneCode: '20', min: 10, max: 10 },
  'GH': { phoneCode: '233', min: 9, max: 9 },
  'TZ': { phoneCode: '255', min: 9, max: 9 },
};

// Reverse lookup: phone code -> ISO code (first match)
const PHONE_CODE_TO_ISO: Record<string, string> = {};
for (const [iso, data] of Object.entries(COUNTRY_PHONE_DATA)) {
  if (!PHONE_CODE_TO_ISO[data.phoneCode]) {
    PHONE_CODE_TO_ISO[data.phoneCode] = iso;
  }
}

/**
 * Normalize a country_code value to ISO format.
 * Converts "+91" or "91" to "IN", passes "IN" through as-is.
 */
function normalizeCountryCodeToISO(countryCode: string): string {
  if (!countryCode) return countryCode;
  // Already an ISO code?
  if (COUNTRY_PHONE_DATA[countryCode]) return countryCode;
  // Try as phone code (strip leading +)
  const cleanCode = countryCode.replace(/^\+/, '');
  if (PHONE_CODE_TO_ISO[cleanCode]) return PHONE_CODE_TO_ISO[cleanCode];
  // Fallback: return as-is
  return countryCode;
}

/**
 * Normalize contact channels before storage:
 * - Ensures country_code is always ISO format ("IN", not "+91")
 * - Ensures phone values always have +{phoneCode} prefix
 * - Strips duplicate country code prefix from value
 */
export function normalizeContactChannels(channels: any[]): any[] {
  if (!channels || !Array.isArray(channels)) return channels;

  return channels.map((channel: any) => {
    const normalized = { ...channel };

    // Only process phone-type channels
    if (!PHONE_CHANNEL_TYPES.includes(channel.channel_type)) {
      return normalized;
    }

    // Step 1: Normalize country_code to ISO format
    if (channel.country_code) {
      normalized.country_code = normalizeCountryCodeToISO(channel.country_code);
    }

    // Step 2: Normalize the value to always have +{phoneCode}{localDigits}
    const isoCode = normalized.country_code;
    const countryData = isoCode ? COUNTRY_PHONE_DATA[isoCode] : null;

    if (countryData && channel.value) {
      // Strip all non-digits from the value
      let digits = channel.value.replace(/\D/g, '');

      // If digits start with the country phone code, strip it to get local number
      if (digits.startsWith(countryData.phoneCode)) {
        const localPart = digits.slice(countryData.phoneCode.length);
        if (localPart.length >= countryData.min && localPart.length <= countryData.max) {
          digits = localPart;
        }
      }

      // Rebuild with +{phoneCode}{localDigits}
      normalized.value = `+${countryData.phoneCode}${digits}`;
    }

    return normalized;
  });
}

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

      // Phone validation for mobile, phone, AND whatsapp
      if (PHONE_CHANNEL_TYPES.includes(channel.channel_type)) {
        const cleanPhone = channel.value.replace(/[^0-9]/g, '');

        // Country-specific validation if country_code is available
        const isoCode = channel.country_code ? normalizeCountryCodeToISO(channel.country_code) : null;
        const countryData = isoCode ? COUNTRY_PHONE_DATA[isoCode] : null;

        if (countryData) {
          // Strip country phone code prefix from digits for length check
          let localDigits = cleanPhone;
          if (cleanPhone.startsWith(countryData.phoneCode)) {
            const local = cleanPhone.slice(countryData.phoneCode.length);
            if (local.length >= countryData.min && local.length <= countryData.max) {
              localDigits = local;
            }
          }
          if (localDigits.length < countryData.min || localDigits.length > countryData.max) {
            const expected = countryData.min === countryData.max
              ? `exactly ${countryData.min}`
              : `${countryData.min}-${countryData.max}`;
            errors.push(`Channel ${i + 1}: ${channel.channel_type} number must be ${expected} digits for ${isoCode}`);
          }
        } else {
          // Fallback: generic validation (7-15 digits)
          if (cleanPhone.length < VALIDATION_RULES.PHONE_MIN_LENGTH || cleanPhone.length > VALIDATION_RULES.PHONE_MAX_LENGTH) {
            errors.push(`Channel ${i + 1}: Invalid ${channel.channel_type} number format (${VALIDATION_RULES.PHONE_MIN_LENGTH}-${VALIDATION_RULES.PHONE_MAX_LENGTH} digits required)`);
          }
        }
      }

      // Country code format validation for phone channels
      if (PHONE_CHANNEL_TYPES.includes(channel.channel_type) && channel.country_code) {
        if (typeof channel.country_code !== 'string' || channel.country_code.length > 5) {
          errors.push(`Channel ${i + 1}: Invalid country code format`);
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