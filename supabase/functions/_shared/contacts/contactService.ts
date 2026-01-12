// supabase/functions/_shared/contacts/contactService.ts - OPTIMIZED VERSION
// Performance improvements:
// 1. listContacts: Uses RPC for DB-level pagination and classification filtering
// 2. getContactStats: Uses RPC for single-query statistics
// 3. Removed duplicate method definitions
// 4. Fallback to JS-filtering when RPC is unavailable

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
  // OPTIMIZED LIST CONTACTS - Uses RPC for DB-level operations
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

      // Try optimized RPC first
      try {
        const { data: rpcResult, error: rpcError } = await this.supabase.rpc('list_contacts_filtered', {
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

        if (!rpcError && rpcResult?.success) {
          console.log('Using optimized RPC for list contacts');
          const contacts = rpcResult.data.contacts || [];
          const pagination = rpcResult.data.pagination;

          // Fetch related data for the paginated results
          if (contacts.length > 0) {
            const contactIds = contacts.map((c: any) => c.id);
            const enrichedContacts = await this.enrichContactsWithRelatedData(contacts, contactIds);

            console.log(`=== ENVIRONMENT VERIFICATION ===`);
            console.log(`Showing ${enrichedContacts.length} contacts for ${this.isLive ? 'LIVE' : 'TEST'} environment`);
            console.log(`Total count: ${pagination.total}`);
            console.log('==================================');

            return {
              contacts: enrichedContacts,
              pagination
            };
          }

          return {
            contacts: [],
            pagination
          };
        }

        console.warn('RPC list_contacts_filtered not available or failed, falling back to JS filtering');
      } catch (rpcErr) {
        console.warn('RPC call failed, using fallback:', rpcErr);
      }

      // FALLBACK: Original JS-based filtering (for backwards compatibility)
      return await this.listContactsFallback(filters, page, limit, classificationsArray);

    } catch (error) {
      console.error('Error in listContacts:', error);
      throw error;
    }
  }

  // Fallback method using original JS-based filtering
  private async listContactsFallback(
    filters: any,
    page: number,
    limit: number,
    classificationsArray: string[] | null
  ) {
    // Build main query WITHOUT classifications filter
    let query = this.supabase
      .from('t_contacts')
      .select(`
        id, name, company_name, type, status, classifications,
        created_at, updated_at, parent_contact_ids, tenant_id,
        potential_duplicate, notes, salutation, designation, department
      `, { count: 'exact' });

    // Apply tenant filter FIRST (most selective)
    if (this.tenantId) {
      query = query.eq('tenant_id', this.tenantId);
    }

    // CRITICAL: Apply environment filter
    query = query.eq('is_live', this.isLive);

    // Search filter
    if (filters.search?.trim()) {
      const searchTerm = filters.search.trim();
      query = query.or(`name.ilike.%${searchTerm}%,company_name.ilike.%${searchTerm}%`);
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

    // Sorting
    const sortBy = filters.sort_by || 'created_at';
    const sortOrder = { ascending: filters.sort_order === 'asc' };
    query = query.order(sortBy, sortOrder);

    // If NO classification filter, use DB-level pagination with .range()
    if (!classificationsArray || classificationsArray.length === 0) {
      const offset = (page - 1) * limit;
      query = query.range(offset, offset + limit - 1);

      const { data: contacts, error, count } = await query;

      if (error) {
        console.error('Query error in listContacts:', error);
        throw new Error(`Failed to list contacts: ${error.message}`);
      }

      const totalCount = count || 0;
      const enrichedContacts = contacts && contacts.length > 0
        ? await this.enrichContactsWithRelatedData(contacts, contacts.map((c: any) => c.id))
        : [];

      return {
        contacts: enrichedContacts,
        pagination: {
          page,
          limit,
          total: totalCount,
          totalPages: Math.ceil(totalCount / limit)
        }
      };
    }

    // WITH classification filter: Fetch all, filter in JS, then paginate
    const { data: allContacts, error, count } = await query;

    if (error) {
      console.error('Query error in listContacts:', error);
      throw new Error(`Failed to list contacts: ${error.message}`);
    }

    let filteredContacts = allContacts || [];
    let totalCount = count || 0;

    // Apply classification filter in JavaScript
    filteredContacts = allContacts.filter((contact: any) => {
      if (!contact.classifications || !Array.isArray(contact.classifications)) return false;
      return classificationsArray.some((requestedClassification: string) =>
        contact.classifications.includes(requestedClassification)
      );
    });
    totalCount = filteredContacts.length;
    console.log(`Filtered to ${filteredContacts.length} contacts matching classifications:`, classificationsArray);

    // Apply pagination to filtered results
    const offset = (page - 1) * limit;
    const paginatedContacts = filteredContacts.slice(offset, offset + limit);

    if (paginatedContacts.length === 0) {
      return {
        contacts: [],
        pagination: {
          page,
          limit,
          total: totalCount,
          totalPages: Math.ceil(totalCount / limit)
        }
      };
    }

    const enrichedContacts = await this.enrichContactsWithRelatedData(
      paginatedContacts,
      paginatedContacts.map((c: any) => c.id)
    );

    return {
      contacts: enrichedContacts,
      pagination: {
        page,
        limit,
        total: totalCount,
        totalPages: Math.ceil(totalCount / limit)
      }
    };
  }

  // Helper method to enrich contacts with related data
  private async enrichContactsWithRelatedData(contacts: any[], contactIds: string[]) {
    const { data: primaryChannels } = await this.supabase
      .from('t_contact_channels')
      .select('contact_id, channel_type, value, country_code, is_primary, is_verified')
      .in('contact_id', contactIds)
      .eq('is_primary', true);

    const { data: primaryAddresses } = await this.supabase
      .from('t_contact_addresses')
      .select('contact_id, address_type, line1, line2, city, state, country, is_primary, is_verified')
      .in('contact_id', contactIds)
      .eq('is_primary', true);

    // Create lookup maps
    const channelMap = (primaryChannels || []).reduce((acc: any, ch: any) => {
      acc[ch.contact_id] = ch;
      return acc;
    }, {});

    const addressMap = (primaryAddresses || []).reduce((acc: any, addr: any) => {
      acc[addr.contact_id] = addr;
      return acc;
    }, {});

    // Enrich contacts
    return contacts.map((contact: any) => {
      const primaryChannel = channelMap[contact.id];
      const primaryAddress = addressMap[contact.id];

      const displayName = contact.type === 'corporate'
        ? contact.company_name || 'Unnamed Company'
        : contact.name
          ? `${contact.salutation ? contact.salutation + '. ' : ''}${contact.name}`.trim()
          : 'Unnamed Contact';

      return {
        ...contact,
        displayName,
        contact_channels: primaryChannel ? [primaryChannel] : [],
        addresses: primaryAddress ? [primaryAddress] : [],
        contact_addresses: primaryAddress ? [primaryAddress] : [] // Backward compatibility
      };
    });
  }

  // ==========================================================
  // OPTIMIZED SEARCH CONTACTS
  // ==========================================================

  async searchContacts(searchQuery: string, filters: any = {}) {
    try {
      if (!searchQuery?.trim()) {
        return { contacts: [], pagination: null };
      }

      const searchTerm = searchQuery.trim();

      let query = this.supabase
        .from('t_contacts')
        .select(`
          id, name, company_name, type, status, classifications,
          created_at, tenant_id, salutation, designation, department
        `);

      // Apply tenant filter FIRST
      if (this.tenantId) {
        query = query.eq('tenant_id', this.tenantId);
      }

      query = query.eq('is_live', this.isLive);

      // Search filter
      query = query.or(`name.ilike.%${searchTerm}%,company_name.ilike.%${searchTerm}%,designation.ilike.%${searchTerm}%,department.ilike.%${searchTerm}%`);

      // Apply other filters
      if (filters.type) {
        query = query.eq('type', filters.type);
      }
      if (filters.status && filters.status !== 'all') {
        query = query.eq('status', filters.status);
      } else {
        query = query.in('status', ['active', 'inactive']);
      }

      query = query.limit(50);

      const { data: contacts, error } = await query;

      if (error) {
        throw new Error(`Search failed: ${error.message}`);
      }

      const enrichedContacts = (contacts || []).map((contact: any) => ({
        ...contact,
        displayName: contact.type === 'corporate'
          ? contact.company_name || 'Unnamed Company'
          : contact.name
            ? `${contact.salutation ? contact.salutation + '. ' : ''}${contact.name}`.trim()
            : 'Unnamed Contact',
        isDirectMatch: true
      }));

      return {
        contacts: enrichedContacts,
        pagination: {
          total: enrichedContacts.length,
          page: 1,
          limit: enrichedContacts.length,
          totalPages: 1
        }
      };

    } catch (error) {
      console.error('Error in searchContacts:', error);
      throw error;
    }
  }

  // ==========================================================
  // OPTIMIZED STATS - Uses RPC for single-query statistics
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

      // Try optimized RPC first
      try {
        const { data: rpcResult, error: rpcError } = await this.supabase.rpc('get_contact_stats', {
          p_tenant_id: this.tenantId,
          p_is_live: this.isLive,
          p_type: filters.type || null,
          p_search: filters.search?.trim() || null,
          p_classifications: classificationsArray
        });

        if (!rpcError && rpcResult?.success) {
          console.log('Using optimized RPC for contact stats');
          return rpcResult.data;
        }

        console.warn('RPC get_contact_stats not available or failed, falling back to JS calculation');
      } catch (rpcErr) {
        console.warn('RPC call failed, using fallback:', rpcErr);
      }

      // FALLBACK: Original JS-based stats calculation
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

    // Apply tenant filter FIRST
    if (this.tenantId) {
      query = query.eq('tenant_id', this.tenantId);
    }

    query = query.eq('is_live', this.isLive);

    // Apply filters
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
  // GET CONTACT BY ID - UNCHANGED
  // ==========================================================

  async getContactById(contactId: string) {
    try {
      console.log('Getting contact:', {
        contactId,
        tenantId: this.tenantId,
        isLive: this.isLive
      });

      const { data: contact, error: contactError } = await this.supabase
        .from('t_contacts')
        .select('*')
        .eq('id', contactId)
        .eq('tenant_id', this.tenantId)
        .eq('is_live', this.isLive)
        .single();

      if (contactError || !contact) {
        console.log('Contact not found or not accessible for tenant');
        return null;
      }

      const [
        { data: contactChannels },
        { data: addresses },
        { data: complianceNumbers },
        { data: tags }
      ] = await Promise.all([
        this.supabase
          .from('t_contact_channels')
          .select('*')
          .eq('contact_id', contactId)
          .order('is_primary', { ascending: false }),

        this.supabase
          .from('t_contact_addresses')
          .select('*')
          .eq('contact_id', contactId)
          .order('is_primary', { ascending: false }),

        this.supabase
          .from('t_contact_compliance_numbers')
          .select('*')
          .eq('contact_id', contactId),

        this.supabase
          .from('t_contact_tags')
          .select('*')
          .eq('contact_id', contactId)
      ]);

      let parentContacts: any[] = [];
      if (contact.parent_contact_ids && Array.isArray(contact.parent_contact_ids) && contact.parent_contact_ids.length > 0) {
        const { data: parents } = await this.supabase
          .from('t_contacts')
          .select('id, name, company_name, type, status')
          .in('id', contact.parent_contact_ids)
          .eq('is_live', this.isLive)
          .eq('tenant_id', this.tenantId);

        parentContacts = parents || [];
      }

      const { data: childContacts } = await this.supabase
        .from('t_contacts')
        .select(`
          id, name, salutation, designation, department, type, status,
          contact_channels:t_contact_channels(*)
        `)
        .filter('parent_contact_ids', 'ov', [contactId])
        .eq('is_live', this.isLive)
        .eq('tenant_id', this.tenantId);

      const displayName = contact.type === 'corporate'
        ? contact.company_name || 'Unnamed Company'
        : contact.name
          ? `${contact.salutation ? contact.salutation + '. ' : ''}${contact.name}`.trim()
          : 'Unnamed Contact';

      return {
        ...contact,
        displayName,
        contact_channels: contactChannels || [],
        addresses: addresses || [],
        contact_addresses: addresses || [],
        compliance_numbers: complianceNumbers || [],
        tags: tags || [],
        parent_contacts: parentContacts,
        contact_persons: childContacts || []
      };

    } catch (error) {
      console.error('Error in getContactById:', error);
      throw error;
    }
  }

  // ==========================================================
  // ALL OTHER METHODS REMAIN UNCHANGED
  // ==========================================================

  async createContact(contactData: any) {
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
        t_userprofile_id: null,
        created_by: contactData.created_by || null,
        is_live: contactData.is_live !== undefined ? contactData.is_live : this.isLive
      };

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

      this.logAudit('CREATE', rpcResult.data, contactData);
      return await this.getContactById(rpcResult.data.id);

    } catch (error) {
      console.error('Error in createContact:', error);
      throw error;
    }
  }

  async updateContact(contactId: string, updateData: any) {
    try {
      const existing = await this.getContactById(contactId);
      if (!existing) {
        throw new Error('Contact not found');
      }
      if (existing.status === 'archived') {
        throw new Error('Cannot update archived contact');
      }

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

      this.logAudit('UPDATE', rpcResult.data, updateData);
      return await this.getContactById(contactId);

    } catch (error) {
      console.error('Error in updateContact:', error);
      throw error;
    }
  }

  async updateContactStatus(contactId: string, newStatus: string) {
    try {
      const existing = await this.getContactById(contactId);
      if (!existing) throw new Error('Contact not found');
      if (existing.status === 'archived') throw new Error('Cannot change status of archived contact');

      const updateQuery = this.supabase
        .from('t_contacts')
        .update({ status: newStatus })
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

  async checkForDuplicates(contactData: any) {
    try {
      if (!contactData.contact_channels || contactData.contact_channels.length === 0) {
        return { hasDuplicates: false, duplicates: [] };
      }

      const { data: rpcResult, error: rpcError } = await this.supabase.rpc('check_contact_duplicates', {
        p_contact_channels: contactData.contact_channels,
        p_exclude_contact_id: contactData.id || null,
        p_is_live: this.isLive,
        p_tenant_id: this.tenantId
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
      return { hasDuplicates: false, duplicates: [] };
    }
  }

  async sendInvitation(contactId: string) {
    const contact = await this.getContactById(contactId);
    if (!contact) throw new Error('Contact not found or not accessible');

    return { success: true, message: 'Invitation sent successfully' };
  }

  // Helper methods
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
