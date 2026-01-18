// supabase/functions/_shared/contacts/contactService.ts - V2 RPC OPTIMIZED VERSION
// Uses new v2 RPCs with idempotency support and embedded relations
// Changes:
// 1. listContacts: Uses list_contacts_with_channels_v2 (embedded channels/addresses)
// 2. getContactById: Uses get_contact_full_v2 (single call, all relations)
// 3. createContact: Uses create_contact_idempotent_v2 (idempotent with bulk inserts)
// 4. updateContact: Uses update_contact_idempotent_v2 (idempotent updates)

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';

export class ContactService {
  constructor(
    private supabase: SupabaseClient,
    private auditLogger: any,
    private auditActions: any,
    private auditResources: any,
    private isLive: boolean = true,
    private tenantId: string | null = null
  ) {
    console.log('ContactService initialized with:', {
      isLive: this.isLive,
      tenantId: this.tenantId,
      hasAuditLogger: !!this.auditLogger
    });
  }

  // ==========================================================
  // LIST CONTACTS - Uses list_contacts_with_channels_v2
  // Single RPC call returns contacts with embedded primary channel/address
  // ==========================================================

  async listContacts(filters: any) {
    try {
      console.log('=== ENVIRONMENT DEBUG ===');
      console.log('ContactService isLive:', this.isLive);
      console.log('ContactService tenantId:', this.tenantId);
      console.log('Listing contacts with filters:', {
        tenantId: this.tenantId,
        isLive: this.isLive,
        filters
      });

      // Calculate pagination
      const page = Math.max(1, filters.page || 1);
      const limit = Math.min(Math.max(1, filters.limit || 20), 100);

      // Prepare classifications array for RPC
      let classificationsArray: string[] | null = null;
      if (filters.classifications) {
        classificationsArray = typeof filters.classifications === 'string'
          ? filters.classifications.split(',').filter(Boolean).map(String)
          : Array.isArray(filters.classifications)
            ? filters.classifications.map(String)
            : null;

        if (classificationsArray && classificationsArray.length === 0) {
          classificationsArray = null;
        }
      }

      // Use v2 RPC - returns embedded channels/addresses
      const { data: rpcResult, error: rpcError } = await this.supabase.rpc('list_contacts_with_channels_v2', {
        p_tenant_id: this.tenantId,
        p_is_live: this.isLive,
        p_page: page,
        p_limit: limit,
        p_type: filters.type || null,
        p_status: filters.status || null,
        p_search: filters.search?.trim() || null,
        p_classifications: classificationsArray,
        p_user_status: filters.user_status || null,
        p_show_duplicates: filters.show_duplicates || false,
        p_include_inactive: filters.includeInactive || false,
        p_include_archived: filters.includeArchived || false,
        p_sort_by: filters.sort_by || 'created_at',
        p_sort_order: filters.sort_order || 'desc'
      });

      if (rpcError) {
        console.error('RPC list_contacts_with_channels_v2 error:', rpcError);
        throw new Error(`Failed to list contacts: ${rpcError.message}`);
      }

      if (!rpcResult?.success) {
        console.error('RPC returned error:', rpcResult?.error);
        throw new Error(rpcResult?.error || 'Failed to list contacts');
      }

      // v2 RPC returns contacts with embedded primary_channel and primary_address
      // No additional enrichment needed!
      const contacts = rpcResult.data.contacts || [];
      const pagination = rpcResult.data.pagination;

      // Transform to expected format (map embedded fields to arrays for backward compatibility)
      const transformedContacts = contacts.map((contact: any) => ({
        ...contact,
        contact_channels: contact.primary_channel ? [contact.primary_channel] : [],
        addresses: contact.primary_address ? [contact.primary_address] : [],
        contact_addresses: contact.primary_address ? [contact.primary_address] : []
      }));

      console.log(`=== ENVIRONMENT VERIFICATION ===`);
      console.log(`Showing ${transformedContacts.length} contacts for ${this.isLive ? 'LIVE' : 'TEST'} environment`);
      console.log(`Total count: ${pagination.total}`);
      console.log('==================================');

      return {
        contacts: transformedContacts,
        pagination
      };

    } catch (error) {
      console.error('Error in listContacts:', error);
      throw error;
    }
  }

  // ==========================================================
  // SEARCH CONTACTS - Uses list_contacts_with_channels_v2 with search param
  // ==========================================================

  async searchContacts(searchQuery: string, filters: any = {}) {
    try {
      if (!searchQuery?.trim()) {
        return { contacts: [], pagination: null };
      }

      // Use listContacts with search filter
      return await this.listContacts({
        ...filters,
        search: searchQuery.trim(),
        limit: filters.limit || 50
      });

    } catch (error) {
      console.error('Error in searchContacts:', error);
      throw error;
    }
  }

  // ==========================================================
  // GET CONTACT STATS - Uses existing RPC (no v2 needed)
  // ==========================================================

  async getContactStats(filters: any) {
    try {
      // Prepare classifications array for RPC
      let classificationsArray: string[] | null = null;
      if (filters.classifications) {
        classificationsArray = typeof filters.classifications === 'string'
          ? filters.classifications.split(',').filter(Boolean).map(String)
          : Array.isArray(filters.classifications)
            ? filters.classifications.map(String)
            : null;

        if (classificationsArray && classificationsArray.length === 0) {
          classificationsArray = null;
        }
      }

      // Try optimized RPC
      const { data: rpcResult, error: rpcError } = await this.supabase.rpc('get_contact_stats', {
        p_tenant_id: this.tenantId,
        p_is_live: this.isLive,
        p_type: filters.type || null,
        p_search: filters.search?.trim() || null,
        p_classifications: classificationsArray
      });

      if (rpcError) {
        console.warn('RPC get_contact_stats failed, using fallback:', rpcError);
        return await this.getContactStatsFallback(filters);
      }

      if (rpcResult?.success) {
        console.log('Using optimized RPC for contact stats');
        return rpcResult.data;
      }

      return await this.getContactStatsFallback(filters);

    } catch (error) {
      console.error('Error in getContactStats:', error);
      throw error;
    }
  }

  // Fallback method using original JS-based stats calculation
  private async getContactStatsFallback(filters: any) {
    let query = this.supabase
      .from('t_contacts')
      .select('status, type, classifications, potential_duplicate');

    if (this.tenantId) {
      query = query.eq('tenant_id', this.tenantId);
    }

    query = query.eq('is_live', this.isLive);

    if (filters.type) query = query.eq('type', filters.type);

    if (filters.search) {
      query = query.or(`name.ilike.%${filters.search}%,company_name.ilike.%${filters.search}%`);
    }

    const { data: contacts, error } = await query;
    if (error) throw new Error(`Failed to get stats: ${error.message}`);

    const stats = {
      total: contacts?.length || 0,
      active: 0,
      inactive: 0,
      archived: 0,
      by_type: { individual: 0, corporate: 0 },
      by_classification: {
        buyer: 0, seller: 0, vendor: 0, partner: 0, team_member: 0,
        team_staff: 0, supplier: 0, customer: 0, lead: 0
      },
      duplicates: 0
    };

    contacts?.forEach((contact: any) => {
      (stats as any)[contact.status]++;
      if (contact.type) (stats.by_type as any)[contact.type]++;
      contact.classifications?.forEach((c: string) => {
        if ((stats.by_classification as any)[c] !== undefined) {
          (stats.by_classification as any)[c]++;
        }
      });
      if (contact.potential_duplicate) stats.duplicates++;
    });

    return stats;
  }

  // ==========================================================
  // GET CONTACT BY ID - Uses get_contact_full_v2
  // Single RPC call returns contact with ALL relations
  // ==========================================================

  async getContactById(contactId: string) {
    try {
      console.log('Getting contact:', {
        contactId,
        tenantId: this.tenantId,
        isLive: this.isLive
      });

      // Use v2 RPC - single call returns all relations
      const { data: rpcResult, error: rpcError } = await this.supabase.rpc('get_contact_full_v2', {
        p_contact_id: contactId,
        p_tenant_id: this.tenantId,
        p_is_live: this.isLive
      });

      if (rpcError) {
        console.error('RPC get_contact_full_v2 error:', rpcError);
        throw new Error(`Failed to get contact: ${rpcError.message}`);
      }

      if (!rpcResult?.success) {
        if (rpcResult?.code === 'NOT_FOUND') {
          console.log('Contact not found or not accessible for tenant');
          return null;
        }
        throw new Error(rpcResult?.error || 'Failed to get contact');
      }

      // v2 RPC returns contact with:
      // - contact_channels (array)
      // - addresses (array)
      // - contact_addresses (array, same as addresses for backward compat)
      // - parent_contacts (array)
      // - contact_persons (array with their channels)
      // - displayName (computed)
      // - tags, compliance_numbers (JSONB columns)

      return rpcResult.data;

    } catch (error) {
      console.error('Error in getContactById:', error);
      throw error;
    }
  }

  // ==========================================================
  // CREATE CONTACT - Uses create_contact_idempotent_v2
  // Idempotent creation with bulk inserts
  // ==========================================================

  async createContact(contactData: any, idempotencyKey?: string) {
    try {
      if (!this.tenantId && !contactData.tenant_id) {
        throw new Error('Tenant ID is required for creating contacts');
      }

      this.validateContact(contactData);

      if (!contactData.force_create) {
        const duplicateResult = await this.checkForDuplicates(contactData);
        if (duplicateResult.hasDuplicates) {
          return {
            success: false,
            code: 'DUPLICATE_CONTACTS_FOUND',
            duplicates: duplicateResult.duplicates,
            error: 'Potential duplicate contacts found'
          };
        }
      }

      // Generate idempotency key if not provided
      const idemKey = idempotencyKey || crypto.randomUUID();

      // Prepare contact data for v2 RPC
      const rpcContactData = {
        type: contactData.type,
        status: contactData.status || 'active',
        name: contactData.name,
        company_name: contactData.company_name,
        registration_number: contactData.registration_number,
        salutation: contactData.salutation,
        designation: contactData.designation,
        department: contactData.department,
        is_primary_contact: contactData.is_primary_contact || false,
        classifications: contactData.classifications || [],
        tags: contactData.tags || [],
        compliance_numbers: contactData.compliance_numbers || [],
        notes: contactData.notes,
        parent_contact_ids: this.normalizeParentContactIds(contactData.parent_contact_ids),
        tenant_id: contactData.tenant_id || this.tenantId,
        auth_user_id: contactData.auth_user_id || null,
        created_by: contactData.created_by || null,
        is_live: contactData.is_live !== undefined ? contactData.is_live : this.isLive
      };

      // Use v2 idempotent RPC
      const { data: rpcResult, error: rpcError } = await this.supabase.rpc('create_contact_idempotent_v2', {
        p_idempotency_key: idemKey,
        p_contact_data: rpcContactData,
        p_contact_channels: contactData.contact_channels || [],
        p_addresses: contactData.addresses || [],
        p_contact_persons: contactData.contact_persons || []
      });

      if (rpcError) {
        console.error('RPC create_contact_idempotent_v2 error:', rpcError);
        throw new Error(`RPC call failed: ${rpcError.message}`);
      }

      if (!rpcResult?.success) {
        console.error('Business logic error in createContact:', rpcResult?.error);
        throw new Error(rpcResult?.error || 'Failed to create contact');
      }

      // Log if this was a duplicate request
      if (rpcResult.was_duplicate) {
        console.log('Idempotent request detected - returning existing contact');
      }

      this.logAudit('CREATE', rpcResult.data, contactData);

      // Fetch full contact data for response
      return await this.getContactById(rpcResult.data.id);

    } catch (error) {
      console.error('Error in createContact:', error);
      throw error;
    }
  }

  // ==========================================================
  // UPDATE CONTACT - Uses update_contact_idempotent_v2
  // Idempotent update with replace semantics for channels/addresses
  // ==========================================================

  async updateContact(contactId: string, updateData: any, idempotencyKey?: string) {
    try {
      // Generate idempotency key if not provided
      const idemKey = idempotencyKey || crypto.randomUUID();

      // DEBUG: Log what data arrived from frontend
      console.log('=== DEBUG updateContact - Received Data ===');
      console.log('contactId:', contactId);
      console.log('idempotencyKey:', idemKey);
      console.log('tags:', JSON.stringify(updateData.tags));
      console.log('addresses:', JSON.stringify(updateData.addresses));
      console.log('contact_channels:', JSON.stringify(updateData.contact_channels));
      console.log('contact_persons:', JSON.stringify(updateData.contact_persons));
      console.log('==========================================');

      // Prepare contact data for v2 RPC
      const rpcContactData = {
        name: updateData.name,
        company_name: updateData.company_name,
        registration_number: updateData.company_registration_number || updateData.registration_number,
        salutation: updateData.salutation,
        designation: updateData.designation,
        department: updateData.department,
        is_primary_contact: updateData.is_primary_contact,
        classifications: updateData.classifications,
        tags: updateData.tags,
        compliance_numbers: updateData.compliance_numbers,
        notes: updateData.notes,
        parent_contact_ids: this.normalizeParentContactIds(updateData.parent_contact_ids),
        updated_by: updateData.updated_by
      };

      // Use v2 idempotent RPC
      // Note: Channels and addresses use REPLACE semantics (delete + insert)
      const { data: rpcResult, error: rpcError } = await this.supabase.rpc('update_contact_idempotent_v2', {
        p_idempotency_key: idemKey,
        p_contact_id: contactId,
        p_contact_data: rpcContactData,
        p_contact_channels: updateData.contact_channels || null,
        p_addresses: updateData.addresses || null,
        p_contact_persons: updateData.contact_persons || null
      });

      if (rpcError) {
        console.error('RPC update_contact_idempotent_v2 error:', rpcError);
        throw new Error(`RPC call failed: ${rpcError.message}`);
      }

      if (!rpcResult?.success) {
        // Handle specific error codes
        if (rpcResult?.code === 'NOT_FOUND') {
          throw new Error('Contact not found');
        }
        if (rpcResult?.code === 'CONTACT_ARCHIVED') {
          throw new Error('Cannot update archived contact');
        }
        console.error('Business logic error in updateContact:', rpcResult?.error);
        throw new Error(rpcResult?.error || 'Failed to update contact');
      }

      // Log if this was a duplicate request
      if (rpcResult.was_duplicate) {
        console.log('Idempotent request detected - update already processed');
      }

      this.logAudit('UPDATE', rpcResult.data, updateData);

      // Fetch full contact data for response
      return await this.getContactById(contactId);

    } catch (error) {
      console.error('Error in updateContact:', error);
      throw error;
    }
  }

  // ==========================================================
  // UPDATE CONTACT STATUS - Direct update (no idempotency needed)
  // ==========================================================

  async updateContactStatus(contactId: string, newStatus: string) {
    try {
      const existing = await this.getContactById(contactId);
      if (!existing) throw new Error('Contact not found');
      if (existing.status === 'archived') throw new Error('Cannot change status of archived contact');

      const updateQuery = this.supabase
        .from('t_contacts')
        .update({ status: newStatus, updated_at: new Date().toISOString() })
        .eq('id', contactId)
        .eq('is_live', this.isLive);

      if (this.tenantId) {
        updateQuery.eq('tenant_id', this.tenantId);
      }

      const { data: updated, error } = await updateQuery.select().single();

      if (error) throw new Error(`Failed to update status: ${error.message}`);

      this.logAudit(`contact.${newStatus}`, updated, { old_status: existing.status });
      return updated;
    } catch (error) {
      console.error('Error in updateContactStatus:', error);
      throw error;
    }
  }

  // ==========================================================
  // DELETE CONTACT - Uses existing RPC (no v2 needed)
  // ==========================================================

  async deleteContact(contactId: string, force: boolean = false) {
    try {
      const existing = await this.getContactById(contactId);
      if (!existing) {
        return {
          success: false,
          error: 'Contact not found or not accessible',
          code: 'CONTACT_NOT_FOUND'
        };
      }

      const { data: rpcResult, error: rpcError } = await this.supabase.rpc('delete_contact_transaction', {
        p_contact_id: contactId,
        p_force: force,
        p_is_live: this.isLive
      });

      if (rpcError) {
        console.error('RPC Error in deleteContact:', rpcError);
        throw new Error(`RPC call failed: ${rpcError.message}`);
      }

      if (!rpcResult.success) {
        console.error('Business logic error in deleteContact:', rpcResult.error);
        return {
          success: false,
          error: rpcResult.error,
          code: rpcResult.code
        };
      }

      this.logAudit('DELETE', { id: contactId }, { force });
      return { success: true };

    } catch (error) {
      console.error('Error in deleteContact:', error);
      throw error;
    }
  }

  // ==========================================================
  // CHECK FOR DUPLICATES - Enhanced with name-based detection
  // ==========================================================

  async checkForDuplicates(contactData: any) {
    try {
      const allDuplicates: any[] = [];

      // 1. Check for channel-based duplicates (email/phone)
      if (contactData.contact_channels && contactData.contact_channels.length > 0) {
        const { data: rpcResult, error: rpcError } = await this.supabase.rpc('check_contact_duplicates', {
          p_contact_channels: contactData.contact_channels,
          p_exclude_contact_id: contactData.id || null,
          p_is_live: this.isLive,
          p_tenant_id: this.tenantId
        });

        if (!rpcError && rpcResult?.success && rpcResult.data.duplicates) {
          const channelDuplicates = rpcResult.data.duplicates
            .filter((dup: any) => !this.tenantId || dup.existing_contact?.tenant_id === this.tenantId)
            .map((dup: any) => ({ ...dup, match_type: 'channel' }));
          allDuplicates.push(...channelDuplicates);
        }
      }

      // 2. Check for name-based duplicates (exact match on name or company_name)
      const nameToCheck = contactData.name?.trim().toLowerCase();
      const companyToCheck = contactData.company_name?.trim().toLowerCase();

      if (nameToCheck || companyToCheck) {
        let query = this.supabase
          .from('t_contacts')
          .select('id, name, company_name, type, status, classifications')
          .eq('tenant_id', this.tenantId)
          .eq('is_live', this.isLive)
          .neq('status', 'archived');

        if (contactData.id) {
          query = query.neq('id', contactData.id);
        }

        // Build OR condition for name matching
        const orConditions: string[] = [];
        if (nameToCheck) {
          orConditions.push(`name.ilike.${nameToCheck}`);
        }
        if (companyToCheck) {
          orConditions.push(`company_name.ilike.${companyToCheck}`);
        }

        if (orConditions.length > 0) {
          query = query.or(orConditions.join(','));
        }

        const { data: nameMatches, error: nameError } = await query.limit(5);

        if (!nameError && nameMatches && nameMatches.length > 0) {
          // Filter to avoid duplicating already found contacts
          const existingIds = new Set(allDuplicates.map(d => d.existing_contact?.id));
          const nameDuplicates = nameMatches
            .filter((contact: any) => !existingIds.has(contact.id))
            .map((contact: any) => ({
              match_type: 'name',
              match_value: contact.name || contact.company_name,
              existing_contact: contact
            }));
          allDuplicates.push(...nameDuplicates);
        }
      }

      return {
        hasDuplicates: allDuplicates.length > 0,
        duplicates: allDuplicates
      };

    } catch (error) {
      console.error('Error in checkForDuplicates:', error);
      return { hasDuplicates: false, duplicates: [] };
    }
  }

  // ==========================================================
  // SEND INVITATION - Placeholder
  // ==========================================================

  async sendInvitation(contactId: string) {
    const contact = await this.getContactById(contactId);
    if (!contact) throw new Error('Contact not found or not accessible');

    return { success: true, message: 'Invitation sent successfully' };
  }

  // ==========================================================
  // HELPER METHODS
  // ==========================================================

  private normalizeParentContactIds(parentContactIds: any): string[] {
    if (!parentContactIds) return [];
    if (Array.isArray(parentContactIds)) return parentContactIds;
    if (typeof parentContactIds === 'string') return [parentContactIds];
    return [];
  }

  private validateContact(data: any) {
    if (!data.type || !['individual', 'corporate'].includes(data.type)) {
      throw new Error('Invalid contact type');
    }

    if (!data.classifications?.length) {
      throw new Error('At least one classification is required');
    }

    this.validateClassifications(data.classifications);

    if (data.type === 'individual' && !data.name) {
      throw new Error('Name is required for individual contacts');
    }
    if (data.type === 'corporate' && !data.company_name) {
      throw new Error('Company name is required for corporate contacts');
    }

    if (!data.contact_channels?.length) {
      throw new Error('At least one contact channel is required');
    }

    const hasPrimaryChannel = data.contact_channels.some((ch: any) => ch.is_primary);
    if (!hasPrimaryChannel) {
      data.contact_channels[0].is_primary = true;
    }

    if (data.addresses?.length > 0) {
      const hasPrimaryAddress = data.addresses.some((a: any) => a.is_primary);
      if (!hasPrimaryAddress) {
        data.addresses[0].is_primary = true;
      }
    }

    if (!data.tenant_id && !this.tenantId) {
      throw new Error('Tenant ID is required');
    }
  }

  private validateClassifications(classifications: string[]) {
    const valid = ['buyer', 'seller', 'vendor', 'partner', 'team_member', 'team_staff', 'supplier', 'customer', 'lead'];
    const invalid = classifications.filter(c => !valid.includes(c));
    if (invalid.length > 0) {
      throw new Error(`Invalid classifications: ${invalid.join(', ')}`);
    }
  }

  private logAudit(action: string, resource: any, metadata: any = {}) {
    try {
      if (this.auditLogger?.log) {
        this.auditLogger.log({
          tenantId: resource.tenant_id || this.tenantId,
          action: this.auditActions?.[action] || action.toLowerCase(),
          resource: this.auditResources?.CONTACT || 'contact',
          resourceId: resource.id,
          success: true,
          metadata: {
            ...metadata,
            contact_name: resource.name || resource.company_name,
            environment: this.isLive ? 'live' : 'test'
          }
        });
      }
    } catch (error) {
      console.error('Audit logging failed (non-critical):', error);
    }
  }
}
