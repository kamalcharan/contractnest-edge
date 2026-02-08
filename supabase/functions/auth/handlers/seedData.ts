// supabase/functions/auth/handlers/seedData.ts
// Default seed data for new tenants: Tags, Compliance Numbers

/**
 * Create default Tags category with VIP tag for a new tenant
 */
export async function createDefaultTagsForTenant(supabase: any, tenantId: string) {
  try {
    // Check if tags already exist
    const { data: existingTags } = await supabase
      .from('t_category_master')
      .select('id')
      .eq('tenant_id', tenantId)
      .eq('category_name', 'Tags')
      .single();

    if (existingTags) {
      console.log('Tags already exist for tenant');
      return;
    }

    // Create Tags category
    const { data: tagCategory, error: categoryError } = await supabase
      .from('t_category_master')
      .insert({
        category_name: 'Tags',
        display_name: 'Tags',
        is_active: true,
        description: 'Contact and entity tags',
        tenant_id: tenantId
      })
      .select()
      .single();

    if (categoryError) {
      console.error('Tag category creation error:', categoryError.message);
      throw new Error(`Error creating tags category: ${categoryError.message}`);
    }

    console.log('Tag category created successfully:', tagCategory.id);

    // Create default tags
    const defaultTags = [
      {
        sub_cat_name: 'VIP',
        display_name: 'VIP',
        category_id: tagCategory.id,
        hexcolor: '#F59E0B',
        is_active: true,
        sequence_no: 1,
        tenant_id: tenantId,
        is_deletable: true
      }
    ];

    const { data: createdTags, error: tagsError } = await supabase
      .from('t_category_details')
      .insert(defaultTags)
      .select();

    if (tagsError) {
      console.error('Tags creation error:', tagsError.message);
      throw new Error(`Error creating default tags: ${tagsError.message}`);
    }

    console.log('Default tags created successfully:', createdTags.map((t: any) => t.sub_cat_name).join(', '));
  } catch (error: any) {
    console.error('Error creating default tags:', error.message);
    // Non-fatal: don't throw, log and continue
    // Tags can be created manually later
  }
}

/**
 * Create default Compliance Numbers category with GST, PAN for a new tenant
 */
export async function createDefaultComplianceForTenant(supabase: any, tenantId: string) {
  try {
    // Check if compliance numbers already exist
    const { data: existingCompliance } = await supabase
      .from('t_category_master')
      .select('id')
      .eq('tenant_id', tenantId)
      .eq('category_name', 'Compliance Numbers')
      .single();

    if (existingCompliance) {
      console.log('Compliance Numbers already exist for tenant');
      return;
    }

    // Create Compliance Numbers category
    const { data: complianceCategory, error: categoryError } = await supabase
      .from('t_category_master')
      .insert({
        category_name: 'Compliance Numbers',
        display_name: 'Compliance Numbers',
        is_active: true,
        description: 'Tax and regulatory compliance identifiers',
        tenant_id: tenantId
      })
      .select()
      .single();

    if (categoryError) {
      console.error('Compliance category creation error:', categoryError.message);
      throw new Error(`Error creating compliance category: ${categoryError.message}`);
    }

    console.log('Compliance category created successfully:', complianceCategory.id);

    // Create default compliance types
    const defaultCompliance = [
      {
        sub_cat_name: 'GST',
        display_name: 'GST',
        category_id: complianceCategory.id,
        hexcolor: '#10B981',
        is_active: true,
        sequence_no: 1,
        tenant_id: tenantId,
        is_deletable: true
      },
      {
        sub_cat_name: 'PAN',
        display_name: 'PAN',
        category_id: complianceCategory.id,
        hexcolor: '#3B82F6',
        is_active: true,
        sequence_no: 2,
        tenant_id: tenantId,
        is_deletable: true
      }
    ];

    const { data: createdCompliance, error: complianceError } = await supabase
      .from('t_category_details')
      .insert(defaultCompliance)
      .select();

    if (complianceError) {
      console.error('Compliance creation error:', complianceError.message);
      throw new Error(`Error creating default compliance numbers: ${complianceError.message}`);
    }

    console.log('Default compliance numbers created successfully:', createdCompliance.map((c: any) => c.sub_cat_name).join(', '));
  } catch (error: any) {
    console.error('Error creating default compliance numbers:', error.message);
    // Non-fatal: don't throw, log and continue
    // Compliance numbers can be created manually later
  }
}
