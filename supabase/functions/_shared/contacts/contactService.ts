// supabase/functions/_shared/contacts/contactService.ts - COMPLETE VERSION with RPC Functions

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';

export class ContactService {
  constructor(
    private supabase: SupabaseClient,
    private auditLogger: any,
    private auditActions: any,
    private auditResources: any,
    private isLive: boolean = true
  ) {}

  // ==========================================================
  // MAIN CRUD OPERATIONS
  // ==========================================================

  /**
   * Create contact using atomic RPC function
   */
  async createContact(contactData: any) {
    try {
      // Validate first
      this.validateContact(contactData);
      
      // Check duplicates if not forcing creation
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

      // Prepare data for RPC function
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
        tenant_id: contactData.tenant_id,
        auth_user_id: contactData.auth_user_id,
        t_userprofile_id: contactData.t_userprofile_id,
        created_by: contactData.created_by,
        is_live: this.isLive
      };

      // Call atomic RPC function
      const { data: rpcResult, error: rpcError } = await this.supabase.rpc('create_contact_transaction', {
        p_contact_data: rpcContactData,
        p_contact_channels: contactData.contact_channels || [],
        p_addresses: contactData.addresses || [],
        p_contact_persons: contactData.contact_persons || []
      });

      console.log('=== CREATE RPC DEBUG START ===');
      console.log('RPC Error:', rpcError);
      console.log('RPC Result:', rpcResult);
      console.log('RPC Result Success:', rpcResult?.success);
      console.log('=== CREATE RPC DEBUG END ===');

      if (rpcError) {
        console.error('RPC Error in createContact:', rpcError);
        throw new Error(`RPC call failed: ${rpcError.message}`);
      }

      if (!rpcResult.success) {
        console.error('Business logic error in createContact:', rpcResult.error);
        throw new Error(rpcResult.error);
      }

      // Audit log
      this.logAudit('CREATE', rpcResult.data, contactData);

      // Return complete contact with relationships
      return await this.getContactById(rpcResult.data.id);

    } catch (error) {
      console.error('Error in createContact:', error);
      throw error;
    }
  }

  /**
   * Update contact using atomic RPC function
   */
/**
 * Update contact using atomic RPC function - WITH DEBUG LOGGING
 */
async updateContact(contactId: string, updateData: any) {
  try {
    console.log('=== UPDATE CONTACT DEBUG START ===');
    console.log('Contact ID:', contactId);
    console.log('Update Data Keys:', Object.keys(updateData));
    console.log('Addresses Count:', updateData.addresses?.length || 0);
    
    if (updateData.addresses) {
      console.log('First Address:', JSON.stringify(updateData.addresses[0], null, 2));
      console.log('Addresses have address_line1:', updateData.addresses.some(a => a.address_line1));
    }

    // Get existing contact first
    const existing = await this.getContactById(contactId);
    if (!existing) {
      console.log('ERROR: Contact not found');
      throw new Error('Contact not found');
    }
    if (existing.status === 'archived') {
      console.log('ERROR: Contact is archived');
      throw new Error('Cannot update archived contact');
    }

    console.log('Existing contact found, preparing RPC data...');

    // Prepare data for RPC function
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
      updated_by: updateData.updated_by,
      is_live: this.isLive
    };

    console.log('RPC Contact Data prepared');
    console.log('Calling RPC update_contact_transaction...');

    // Call atomic RPC function
    const { data: rpcResult, error: rpcError } = await this.supabase.rpc('update_contact_transaction', {
      p_contact_id: contactId,
      p_contact_data: rpcContactData,
      p_contact_channels: updateData.contact_channels,
      p_addresses: updateData.addresses,
      p_contact_persons: updateData.contact_persons
    });

    console.log('RPC Call completed');
    console.log('RPC Error:', rpcError);
    console.log('RPC Success:', rpcResult?.success);
    
    if (rpcError) {
      console.error('RPC Error in updateContact:', rpcError);
      throw new Error(`RPC call failed: ${rpcError.message}`);
    }

    if (!rpcResult.success) {
      console.error('Business logic error in updateContact:', rpcResult.error);
      throw new Error(rpcResult.error);
    }

    console.log('RPC Update successful, fetching updated contact...');

    // Audit log
    this.logAudit('UPDATE', rpcResult.data, updateData);

    // Return complete contact with relationships
    const updatedContact = await this.getContactById(contactId);
    
    console.log('=== UPDATE CONTACT DEBUG END ===');
    return updatedContact;

  } catch (error) {
    console.error('Error in updateContact:', error);
    console.log('=== UPDATE CONTACT DEBUG END (ERROR) ===');
    throw error;
  }
}

  /**
 * Get contact by ID using RPC function - FIXED VERSION
 */
/**
 * Get contact by ID using RPC function - FINAL FIX
 */
async getContactById(contactId: string) {
  try {
    console.log('=== GET CONTACT DEBUG START ===');
    
    // Call RPC function to get complete contact with relationships
    const { data: rpcResult, error: rpcError } = await this.supabase.rpc('get_contact_with_relationships', {
      p_contact_id: contactId,
      p_is_live: this.isLive
    });

    if (rpcError) {
      console.error('RPC Error in getContactById:', rpcError);
      throw new Error(`RPC call failed: ${rpcError.message}`);
    }

    if (!rpcResult.success) {
      console.error('Business logic error in getContactById:', rpcResult.error);
      return null;
    }

    // CRITICAL FIX: Ensure addresses are preserved
    const contactData = rpcResult.data;
    
    // Debug the address fields specifically
    if (contactData.addresses && contactData.addresses.length > 0) {
      const firstAddress = contactData.addresses[0];
      console.log('First address has address_line1:', !!firstAddress.address_line1);
      console.log('address_line1 value:', firstAddress.address_line1);
      console.log('address_line2 value:', firstAddress.address_line2);
    }

    // Return the data directly with no transformation
    return contactData;

  } catch (error) {
    console.error('Error in getContactById:', error);
    throw error;
  }
}

  /**
   * List contacts with filtering and pagination
   */
  async listContacts(filters: any) {
    try {
      let query = this.supabase
        .from('t_contacts')
        .select(`
          *,
          contact_channels:t_contact_channels(*),
          contact_addresses:t_contact_addresses(*)
        `, { count: 'exact' });

      query = query.eq('is_live', this.isLive);

      // Search
      if (filters.search?.trim()) {
        const searchTerm = filters.search.trim();
        query = query.or(`
          name.ilike.%${searchTerm}%,
          company_name.ilike.%${searchTerm}%,
          designation.ilike.%${searchTerm}%,
          department.ilike.%${searchTerm}%
        `);
      }

      // Status filter
      if (filters.status && filters.status !== 'all') {
        query = query.eq('status', filters.status);
      } else if (!filters.includeInactive && !filters.includeArchived) {
        query = query.eq('status', 'active');
      } else {
        const statuses = ['active'];
        if (filters.includeInactive) statuses.push('inactive');
        if (filters.includeArchived) statuses.push('archived');
        query = query.in('status', statuses);
      }

      // Type filter
      if (filters.type) {
        query = query.eq('type', filters.type);
      }

      // Classifications filter
      if (filters.classifications?.length > 0) {
        query = query.overlaps('classifications', filters.classifications);
      }

      // User status filter
      if (filters.user_status === 'user') {
        query = query.not('auth_user_id', 'is', null);
      } else if (filters.user_status === 'not_user') {
        query = query.is('auth_user_id', null);
      }

      // Duplicates filter
      if (filters.show_duplicates) {
        query = query.eq('potential_duplicate', true);
      }

      // Sorting and pagination
      const sortBy = filters.sort_by || 'created_at';
      const sortOrder = { ascending: filters.sort_order === 'asc' };
      query = query.order(sortBy, sortOrder);

      const page = Math.max(1, filters.page || 1);
      const limit = Math.min(Math.max(1, filters.limit || 20), 100);
      const offset = (page - 1) * limit;
      query = query.range(offset, offset + limit - 1);

      const { data: contacts, error, count } = await query;

      if (error) throw new Error(`Failed to list contacts: ${error.message}`);

      // For each contact, add parent and child information efficiently
      const enrichedContacts = await Promise.all(
        (contacts || []).map(async (contact) => {
          // Get parent contacts
          let parentContacts = [];
          if (contact.parent_contact_ids && Array.isArray(contact.parent_contact_ids) && contact.parent_contact_ids.length > 0) {
            const { data: parents } = await this.supabase
              .from('t_contacts')
              .select('id, name, company_name, type')
              .in('id', contact.parent_contact_ids)
              .eq('is_live', this.isLive);
            parentContacts = parents || [];
          }

          // Get child contacts (contact persons)
          const { data: children } = await this.supabase
            .from('t_contacts')
            .select('id, name, designation, department, type')
            .contains('parent_contact_ids', JSON.stringify([contact.id]))
            .eq('is_live', this.isLive);

          return {
            ...contact,
            parent_contacts: parentContacts,
            contact_persons: children || []
          };
        })
      );

      return {
        contacts: enrichedContacts,
        pagination: {
          page,
          limit,
          total: count || 0,
          totalPages: Math.ceil((count || 0) / limit)
        }
      };
    } catch (error) {
      console.error('Error in listContacts:', error);
      throw error;
    }
  }

  /**
   * Search contacts with parent-child relationship handling
   */
  async searchContacts(searchQuery: string, filters: any = {}) {
    try {
      if (!searchQuery?.trim()) {
        return { contacts: [], pagination: null };
      }

      const searchTerm = searchQuery.trim();
      
      // Build base query for direct matches
      let query = this.supabase
        .from('t_contacts')
        .select(`
          *,
          contact_channels:t_contact_channels(*),
          contact_addresses:t_contact_addresses(*)
        `)
        .eq('is_live', this.isLive);

      // Search in all relevant fields
      query = query.or(`
        name.ilike.%${searchTerm}%,
        company_name.ilike.%${searchTerm}%,
        designation.ilike.%${searchTerm}%,
        department.ilike.%${searchTerm}%,
        notes.ilike.%${searchTerm}%
      `);

      // Apply additional filters
      if (filters.type) {
        query = query.eq('type', filters.type);
      }
      if (filters.status && filters.status !== 'all') {
        query = query.eq('status', filters.status);
      }
      if (filters.classifications?.length > 0) {
        query = query.overlaps('classifications', filters.classifications);
      }

      const { data: directMatches, error } = await query;
      
      if (error) {
        throw new Error(`Search failed: ${error.message}`);
      }

      // Process results to include related contacts
      const results = [];
      const processedIds = new Set();

      for (const contact of directMatches || []) {
        if (processedIds.has(contact.id)) continue;

        // Add the direct match first
        results.push({ ...contact, isDirectMatch: true });
        processedIds.add(contact.id);

        // If this contact has parents, add them after the direct match
        if (contact.parent_contact_ids && Array.isArray(contact.parent_contact_ids) && contact.parent_contact_ids.length > 0) {
          const { data: parents } = await this.supabase
            .from('t_contacts')
            .select(`
              *,
              contact_channels:t_contact_channels(*),
              contact_addresses:t_contact_addresses(*)
            `)
            .in('id', contact.parent_contact_ids)
            .eq('is_live', this.isLive);

          for (const parent of parents || []) {
            if (!processedIds.has(parent.id)) {
              results.push({ ...parent, isRelatedContact: true, relationshipType: 'parent' });
              processedIds.add(parent.id);
            }
          }
        }

        // If this is a parent contact, add its children
        if (!contact.parent_contact_ids || contact.parent_contact_ids.length === 0) {
          const { data: children } = await this.supabase
            .from('t_contacts')
            .select(`
              *,
              contact_channels:t_contact_channels(*),
              contact_addresses:t_contact_addresses(*)
            `)
            .contains('parent_contact_ids', JSON.stringify([contact.id]))
            .eq('is_live', this.isLive);

          for (const child of children || []) {
            if (!processedIds.has(child.id)) {
              results.push({ ...child, isRelatedContact: true, relationshipType: 'child' });
              processedIds.add(child.id);
            }
          }
        }
      }

      return {
        contacts: results,
        pagination: {
          total: results.length,
          page: 1,
          limit: results.length,
          totalPages: 1
        }
      };
    } catch (error) {
      console.error('Error in searchContacts:', error);
      throw error;
    }
  }

  /**
   * Update contact status using direct query (simple operation)
   */
  async updateContactStatus(contactId: string, newStatus: string) {
    try {
      const existing = await this.getContactById(contactId);
      if (!existing) throw new Error('Contact not found');
      if (existing.status === 'archived') throw new Error('Cannot change status of archived contact');

      const { data: updated, error } = await this.supabase
        .from('t_contacts')
        .update({ status: newStatus })
        .eq('id', contactId)
        .eq('is_live', this.isLive)
        .select()
        .single();

      if (error) throw new Error(`Failed to update status: ${error.message}`);

      this.logAudit(`contact.${newStatus}`, updated, { old_status: existing.status });
      return updated;
    } catch (error) {
      console.error('Error in updateContactStatus:', error);
      throw error;
    }
  }

  /**
   * Delete contact using atomic RPC function
   */
  async deleteContact(contactId: string, force: boolean = false) {
    try {
      // Call atomic RPC function
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

  /**
   * Check for duplicates using RPC function
   */
  async checkForDuplicates(contactData: any) {
    try {
      if (!contactData.contact_channels || contactData.contact_channels.length === 0) {
        return { hasDuplicates: false, duplicates: [] };
      }

      // Call RPC function
      const { data: rpcResult, error: rpcError } = await this.supabase.rpc('check_contact_duplicates', {
        p_contact_channels: contactData.contact_channels,
        p_exclude_contact_id: contactData.id || null,
        p_is_live: this.isLive
      });

      if (rpcError) {
        console.error('RPC Error in checkForDuplicates:', rpcError);
        console.warn('Duplicate check failed (non-critical):', rpcError);
        return { hasDuplicates: false, duplicates: [] };
      }

      if (!rpcResult.success) {
        console.warn('Duplicate check failed (non-critical):', rpcResult.error);
        return { hasDuplicates: false, duplicates: [] };
      }

      return rpcResult.data;

    } catch (error) {
      console.error('Error in checkForDuplicates:', error);
      // Non-critical operation, return safe defaults
      return { hasDuplicates: false, duplicates: [] };
    }
  }

  /**
   * Get contact statistics
   */
  async getContactStats(filters: any) {
    try {
      let query = this.supabase
        .from('t_contacts')
        .select('status, type, classifications, potential_duplicate');

      query = query.eq('is_live', this.isLive);

      if (filters.type) query = query.eq('type', filters.type);
      if (filters.classifications?.length > 0) {
        query = query.overlaps('classifications', filters.classifications);
      }
      if (filters.search) {
        query = query.or(`name.ilike.%${filters.search}%,company_name.ilike.%${filters.search}%`);
      }

      const { data: contacts, error } = await query;
      if (error) throw new Error(`Failed to get stats: ${error.message}`);

      const stats = {
        total: contacts?.length || 0,
        by_status: { active: 0, inactive: 0, archived: 0 },
        by_type: { individual: 0, corporate: 0 },
        by_classification: { buyer: 0, seller: 0, vendor: 0, partner: 0, team_member: 0 },
        duplicates: 0
      };

      contacts?.forEach(contact => {
        if (contact.status) stats.by_status[contact.status]++;
        if (contact.type) stats.by_type[contact.type]++;
        contact.classifications?.forEach((c: string) => {
          if (stats.by_classification[c] !== undefined) {
            stats.by_classification[c]++;
          }
        });
        if (contact.potential_duplicate) stats.duplicates++;
      });

      return stats;
    } catch (error) {
      console.error('Error in getContactStats:', error);
      throw error;
    }
  }

  /**
   * Send invitation (placeholder implementation)
   */
  async sendInvitation(contactId: string) {
    const contact = await this.getContactById(contactId);
    if (!contact) throw new Error('Contact not found');
    
    return { success: true, message: 'Invitation sent successfully' };
  }

  // ==========================================================
  // HELPER METHODS
  // ==========================================================

  /**
   * Normalize parent contact IDs to array format
   */
  private normalizeParentContactIds(parentContactIds: any): string[] {
    if (!parentContactIds) return [];
    if (Array.isArray(parentContactIds)) return parentContactIds;
    if (typeof parentContactIds === 'string') return [parentContactIds];
    return [];
  }

  /**
   * Validate contact data
   */
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

    // Auto-set primary flags if missing
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

    if (!data.tenant_id) {
      throw new Error('Tenant ID is required');
    }
  }

  private validateClassifications(classifications: string[]) {
    const valid = ['buyer', 'seller', 'vendor', 'partner', 'team_member'];
    const invalid = classifications.filter(c => !valid.includes(c));
    if (invalid.length > 0) {
      throw new Error(`Invalid classifications: ${invalid.join(', ')}`);
    }
  }

  private logAudit(action: string, resource: any, metadata: any = {}) {
    try {
      if (this.auditLogger?.log) {
        this.auditLogger.log({
          tenantId: resource.tenant_id,
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