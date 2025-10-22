// supabase/functions/_shared/contacts/contactService.ts - FIXED VERSION with Tenant Filtering

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';

export class ContactService {
  constructor(
    private supabase: SupabaseClient,
    private auditLogger: any,
    private auditActions: any,
    private auditResources: any,
    private isLive: boolean = true,
    private tenantId: string | null = null // ADDED: Tenant ID for filtering
  ) {
    // Log initialization for debugging
    console.log('ContactService initialized with:', {
      isLive: this.isLive,
      tenantId: this.tenantId,
      hasAuditLogger: !!this.auditLogger
    });
  }

  // ==========================================================
  // MAIN CRUD OPERATIONS
  // ==========================================================

  /**
   * Create contact using atomic RPC function
   */
  async createContact(contactData: any) {
    try {
      // Ensure tenant_id is set
      if (!this.tenantId && !contactData.tenant_id) {
        throw new Error('Tenant ID is required for creating contacts');
      }

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
        tenant_id: contactData.tenant_id || this.tenantId, // Use provided or instance tenant_id
       auth_user_id: contactData.auth_user_id || null,
t_userprofile_id: null,  // Force null, don't use the passed value
created_by: contactData.created_by || null,
is_live: contactData.is_live !== undefined ? contactData.is_live : this.isLive 
      };

      // Call atomic RPC function
      const { data: rpcResult, error: rpcError } = await this.supabase.rpc('create_contact_transaction', {
        p_contact_data: rpcContactData,
        p_contact_channels: contactData.contact_channels || [],
        p_addresses: contactData.addresses || [],
        p_contact_persons: contactData.contact_persons || []
      });

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
  async updateContact(contactId: string, updateData: any) {
    try {
      console.log('=== UPDATE CONTACT DEBUG START ===');
      console.log('Contact ID:', contactId);
      console.log('Tenant ID:', this.tenantId);
      console.log('Is Live:', this.isLive);

      // Get existing contact first (with tenant check)
      const existing = await this.getContactById(contactId);
      if (!existing) {
        console.log('ERROR: Contact not found or not accessible');
        throw new Error('Contact not found');
      }
      if (existing.status === 'archived') {
        console.log('ERROR: Contact is archived');
        throw new Error('Cannot update archived contact');
      }

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
is_live: updateData.is_live !== undefined ? updateData.is_live : this.isLive
      };

      // Call atomic RPC function
      const { data: rpcResult, error: rpcError } = await this.supabase.rpc('update_contact_transaction', {
        p_contact_id: contactId,
        p_contact_data: rpcContactData,
        p_contact_channels: updateData.contact_channels,
        p_addresses: updateData.addresses,
        p_contact_persons: updateData.contact_persons
      });

      if (rpcError) {
        console.error('RPC Error in updateContact:', rpcError);
        throw new Error(`RPC call failed: ${rpcError.message}`);
      }

      if (!rpcResult.success) {
        console.error('Business logic error in updateContact:', rpcResult.error);
        throw new Error(rpcResult.error);
      }

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
   * Get contact by ID using RPC function with tenant filtering
   */
  async getContactById(contactId: string) {
    try {
      console.log('Getting contact:', { 
        contactId, 
        tenantId: this.tenantId, 
        isLive: this.isLive 
      });

      // First check if contact exists and belongs to tenant using direct query
      if (this.tenantId) {
        const { data: contactCheck, error: checkError } = await this.supabase
          .from('t_contacts')
          .select('id, tenant_id')
          .eq('id', contactId)
          .eq('tenant_id', this.tenantId)
          .eq('is_live', this.isLive)
          .single();

        if (checkError || !contactCheck) {
          console.log('Contact not found or not accessible for tenant');
          return null;
        }
      }

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

      // Additional tenant check on the result
      if (this.tenantId && rpcResult.data.tenant_id !== this.tenantId) {
        console.log('Contact belongs to different tenant');
        return null;
      }

      return rpcResult.data;

    } catch (error) {
      console.error('Error in getContactById:', error);
      throw error;
    }
  }

  /**
   * List contacts with filtering and pagination - WITH TENANT FILTERING
   */
  async listContacts(filters: any) {
    try {
      console.log('Listing contacts with filters:', {
        tenantId: this.tenantId,
        isLive: this.isLive,
        filters
      });

      let query = this.supabase
        .from('t_contacts')
        .select(`
          *,
          contact_channels:t_contact_channels(*),
          contact_addresses:t_contact_addresses(*)
        `, { count: 'exact' });

      // CRITICAL: Apply tenant filter FIRST
      if (this.tenantId) {
        query = query.eq('tenant_id', this.tenantId);
      }

      // Apply environment filter
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

      // Classifications filter - handle both string and array
      if (filters.classifications) {
        // Convert string to array if needed
        const classificationsArray = typeof filters.classifications === 'string' 
          ? filters.classifications.split(',').filter(Boolean)
          : filters.classifications;
        
        if (classificationsArray && classificationsArray.length > 0) {
          query = query.overlaps('classifications', classificationsArray.map(String));
        }
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

      if (error) {
        console.error('Query error in listContacts:', error);
        throw new Error(`Failed to list contacts: ${error.message}`);
      }

      console.log(`Found ${contacts?.length || 0} contacts, total count: ${count}`);

      // For each contact, add parent and child information efficiently
      const enrichedContacts = await Promise.all(
        (contacts || []).map(async (contact) => {
          // Get parent contacts
          let parentContacts = [];
          if (contact.parent_contact_ids && Array.isArray(contact.parent_contact_ids) && contact.parent_contact_ids.length > 0) {
            const parentQuery = this.supabase
              .from('t_contacts')
              .select('id, name, company_name, type')
              .in('id', contact.parent_contact_ids)
              .eq('is_live', this.isLive);
            
            // Add tenant filter for parent contacts too
            if (this.tenantId) {
              parentQuery.eq('tenant_id', this.tenantId);
            }
            
            const { data: parents } = await parentQuery;
            parentContacts = parents || [];
          }

          // Get child contacts (contact persons)
          const childQuery = this.supabase
            .from('t_contacts')
            .select('id, name, designation, department, type')
            .contains('parent_contact_ids', JSON.stringify([contact.id]))
            .eq('is_live', this.isLive);
          
          // Add tenant filter for child contacts too
          if (this.tenantId) {
            childQuery.eq('tenant_id', this.tenantId);
          }
          
          const { data: children } = await childQuery;

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
   * Search contacts with parent-child relationship handling - WITH TENANT FILTERING
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
        `);

      // CRITICAL: Apply tenant filter FIRST
      if (this.tenantId) {
        query = query.eq('tenant_id', this.tenantId);
      }

      query = query.eq('is_live', this.isLive);

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
      
      // Handle classifications filter
      if (filters.classifications) {
        const classificationsArray = typeof filters.classifications === 'string' 
          ? filters.classifications.split(',').filter(Boolean)
          : filters.classifications;
        
        if (classificationsArray && classificationsArray.length > 0) {
          query = query.overlaps('classifications', classificationsArray.map(String));
        }
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
          const parentQuery = this.supabase
            .from('t_contacts')
            .select(`
              *,
              contact_channels:t_contact_channels(*),
              contact_addresses:t_contact_addresses(*)
            `)
            .in('id', contact.parent_contact_ids)
            .eq('is_live', this.isLive);

          // Add tenant filter for parent contacts
          if (this.tenantId) {
            parentQuery.eq('tenant_id', this.tenantId);
          }

          const { data: parents } = await parentQuery;

          for (const parent of parents || []) {
            if (!processedIds.has(parent.id)) {
              results.push({ ...parent, isRelatedContact: true, relationshipType: 'parent' });
              processedIds.add(parent.id);
            }
          }
        }

        // If this is a parent contact, add its children
        if (!contact.parent_contact_ids || contact.parent_contact_ids.length === 0) {
          const childQuery = this.supabase
            .from('t_contacts')
            .select(`
              *,
              contact_channels:t_contact_channels(*),
              contact_addresses:t_contact_addresses(*)
            `)
            .contains('parent_contact_ids', JSON.stringify([contact.id]))
            .eq('is_live', this.isLive);

          // Add tenant filter for child contacts
          if (this.tenantId) {
            childQuery.eq('tenant_id', this.tenantId);
          }

          const { data: children } = await childQuery;

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
   * Update contact status using direct query (simple operation) - WITH TENANT CHECK
   */
  async updateContactStatus(contactId: string, newStatus: string) {
    try {
      // First verify contact belongs to tenant
      const existing = await this.getContactById(contactId);
      if (!existing) throw new Error('Contact not found');
      if (existing.status === 'archived') throw new Error('Cannot change status of archived contact');

      const updateQuery = this.supabase
        .from('t_contacts')
        .update({ status: newStatus })
        .eq('id', contactId)
        .eq('is_live', this.isLive);

      // Add tenant filter
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

  /**
   * Delete contact using atomic RPC function - WITH TENANT CHECK
   */
  async deleteContact(contactId: string, force: boolean = false) {
    try {
      // First verify contact belongs to tenant
      const existing = await this.getContactById(contactId);
      if (!existing) {
        return { 
          success: false, 
          error: 'Contact not found or not accessible',
          code: 'CONTACT_NOT_FOUND'
        };
      }

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
   * Check for duplicates using RPC function - WITH TENANT FILTERING
   */
  async checkForDuplicates(contactData: any) {
    try {
      if (!contactData.contact_channels || contactData.contact_channels.length === 0) {
        return { hasDuplicates: false, duplicates: [] };
      }

      // Call RPC function with tenant context
      const { data: rpcResult, error: rpcError } = await this.supabase.rpc('check_contact_duplicates', {
        p_contact_channels: contactData.contact_channels,
        p_exclude_contact_id: contactData.id || null,
        p_is_live: this.isLive,
        p_tenant_id: this.tenantId // Pass tenant_id if RPC supports it
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

      // Filter duplicates by tenant if RPC doesn't do it
      if (this.tenantId && rpcResult.data.duplicates) {
        const filteredDuplicates = rpcResult.data.duplicates.filter((dup: any) => 
          dup.existing_contact?.tenant_id === this.tenantId
        );
        return {
          hasDuplicates: filteredDuplicates.length > 0,
          duplicates: filteredDuplicates
        };
      }

      return rpcResult.data;

    } catch (error) {
      console.error('Error in checkForDuplicates:', error);
      // Non-critical operation, return safe defaults
      return { hasDuplicates: false, duplicates: [] };
    }
  }

  /**
   * Get contact statistics - WITH TENANT FILTERING
   */
  async getContactStats(filters: any) {
    try {
      let query = this.supabase
        .from('t_contacts')
        .select('status, type, classifications, potential_duplicate');

      // CRITICAL: Apply tenant filter FIRST
      if (this.tenantId) {
        query = query.eq('tenant_id', this.tenantId);
      }

      query = query.eq('is_live', this.isLive);

      if (filters.type) query = query.eq('type', filters.type);
      
      // Handle classifications filter
      if (filters.classifications) {
        const classificationsArray = typeof filters.classifications === 'string' 
          ? filters.classifications.split(',').filter(Boolean)
          : filters.classifications;
        
        if (classificationsArray && classificationsArray.length > 0) {
          query = query.overlaps('classifications', classificationsArray.map(String));
        }
      }

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
        by_classification: { buyer: 0, seller: 0, vendor: 0, partner: 0, team_member: 0 },
        duplicates: 0
      };

      contacts?.forEach(contact => {
        // Status counts
        if (contact.status === 'active') stats.active++;
        else if (contact.status === 'inactive') stats.inactive++;
        else if (contact.status === 'archived') stats.archived++;
        
        // Type counts
        if (contact.type) stats.by_type[contact.type]++;
        
        // Classification counts
        contact.classifications?.forEach((c: string) => {
          if (stats.by_classification[c] !== undefined) {
            stats.by_classification[c]++;
          }
        });
        
        // Duplicate count
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
    // First verify contact belongs to tenant
    const contact = await this.getContactById(contactId);
    if (!contact) throw new Error('Contact not found or not accessible');
    
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

    // Tenant ID validation
    if (!data.tenant_id && !this.tenantId) {
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