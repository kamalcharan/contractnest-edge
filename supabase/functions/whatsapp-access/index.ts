import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-tenant-id',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...cors, 'Content-Type': 'application/json' },
});
const phoneFormat = /^\+[1-9][0-9]{7,14}$/;
const normalizePhone = (value: unknown) => {
  if (typeof value !== 'string') return null;
  const digits = value.replace(/[\s()+-]/g, '');
  const phone = `+${digits}`;
  return phoneFormat.test(phone) ? phone : null;
};

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return json({ error: 'Channel configuration unavailable' }, 503);
  const jwt = req.headers.get('authorization')?.replace(/^Bearer\s+/i, '');
  if (!jwt) return json({ error: 'Sign in required' }, 401);
  const db = createClient(url, key, { auth: { persistSession: false } });
  const { data: auth, error: authError } = await db.auth.getUser(jwt);
  if (authError || !auth.user) return json({ error: 'Sign in required' }, 401);
  const actor = auth.user.id;
  const tenantId = req.headers.get('x-tenant-id');
  if (!tenantId) return json({ error: 'Workspace required' }, 400);

  const { data: membership } = await db.from('t_user_tenants')
    .select('id, status, is_admin').eq('user_id', actor)
    .eq('tenant_id', tenantId).eq('status', 'active').maybeSingle();
  if (!membership) return json({ error: 'Workspace unavailable' }, 403);
  const { data: tenant } = await db.from('t_tenants')
    .select('id, status, is_test, created_by').eq('id', tenantId).maybeSingle();
  if (!tenant || tenant.status !== 'active' || tenant.is_test) {
    return json({ error: 'Live workspace unavailable' }, 403);
  }

  const audit = async (action: string, result: string, target?: string) => {
    await db.from('t_whatsapp_access_audit').insert({
      tenant_id: tenantId, actor_user_id: actor, target_user_id: target || null, action, result,
    });
  };
  const isManager = async () => {
    if (membership.is_admin || tenant.created_by === actor) return true;
    const { data: category } = await db.from('t_category_master').select('id')
      .eq('tenant_id', tenantId).eq('category_name', 'Roles').maybeSingle();
    if (!category) return false;
    const { data: assignments } = await db.from('t_user_tenant_roles').select('role_id')
      .eq('user_tenant_id', membership.id);
    const ids = (assignments || []).map((row: { role_id: string }) => row.role_id);
    if (!ids.length) return false;
    const { data: roles } = await db.from('t_category_details')
      .select('sub_cat_name, display_name').eq('category_id', category.id).in('id', ids);
    return !!roles?.some((r: { sub_cat_name: string; display_name: string }) =>
      ['admin', 'owner'].includes(String(r.sub_cat_name).toLowerCase()) ||
      ['admin', 'owner'].includes(String(r.display_name).toLowerCase()));
  };

  try {
    const manager = await isManager();
    if (req.method === 'GET') {
      const [{ data: setting }, { data: ownPermission }, { data: binding }, { data: activeMemberships }, { data: exception }, { data: profile }] = await Promise.all([
        db.from('t_whatsapp_tenant_access').select('enabled, updated_at').eq('tenant_id', tenantId).maybeSingle(),
        db.from('t_whatsapp_member_access').select('enabled').eq('tenant_id', tenantId).eq('user_id', actor).maybeSingle(),
        db.from('t_whatsapp_phone_bindings').select('phone_e164, auth_confirmed_at, revoked_at').eq('user_id', actor).maybeSingle(),
        db.from('t_user_tenants').select('id').eq('user_id', actor).eq('status', 'active'),
        db.from('t_workspace_membership_exceptions').select('user_id').eq('user_id', actor).is('revoked_at', null).maybeSingle(),
        db.from('t_user_profiles').select('mobile_number, country_code').eq('user_id', actor).maybeSingle(),
      ]);
      const verified = !!binding && !binding.revoked_at && !!binding.auth_confirmed_at;
      let members: unknown[] | undefined;
      if (manager) {
        const { data: rows } = await db.from('t_user_tenants')
          .select('user_id, status').eq('tenant_id', tenantId).eq('status', 'active');
        const ids = (rows || []).map((row: { user_id: string }) => row.user_id);
        const [{ data: permissions }, { data: bindings }] = await Promise.all([
          ids.length ? db.from('t_whatsapp_member_access').select('user_id, enabled').eq('tenant_id', tenantId).in('user_id', ids) : Promise.resolve({ data: [] }),
          ids.length ? db.from('t_whatsapp_phone_bindings').select('user_id, phone_e164, revoked_at').in('user_id', ids) : Promise.resolve({ data: [] }),
        ]);
        members = ids.map((id: string) => ({ user_id: id,
          enabled: !!permissions?.find((p: { user_id: string; enabled: boolean }) => p.user_id === id)?.enabled,
          linked_phone: bindings?.find((b: { user_id: string; revoked_at: string | null }) => b.user_id === id && !b.revoked_at)?.phone_e164 || null }));
      }
      const workspaceUnique = (activeMemberships?.length || 0) === 1 || !!exception;
      return json({ workspace_enabled: !!setting?.enabled, member_enabled: !!ownPermission?.enabled,
        verified_phone: verified ? binding?.phone_e164 : null, manager, members,
        suggested_phone: normalizePhone(auth.user.phone),
        profile_mobile: profile?.mobile_number || null,
        profile_country_code: profile?.country_code || null,
        eligible: !!setting?.enabled && !!ownPermission?.enabled && verified && workspaceUnique,
        blocked_reason: !workspaceUnique ? 'Multiple workspaces need an approved exception' : null });
    }

    if (req.method !== 'POST') return json({ error: 'Not found' }, 404);
    const body = await req.json();
    if (body.action === 'binding_confirm') {
      const phone = normalizePhone(body.phone);
      const accessToken = body.access_token;
      const authkey = Deno.env.get('MSG91_AUTHKEY');
      if (!phone) return json({ error: 'A valid country code and mobile number are required' }, 400);
      if (typeof accessToken !== 'string' || accessToken.length < 30 || accessToken.length > 8192) {
        return json({ error: 'MSG91 verification token is required' }, 400);
      }
      if (!authkey) return json({ error: 'MSG91 server verification is not configured' }, 503);
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 10000);
      let verification: Record<string, unknown>;
      try {
        const response = await fetch('https://control.msg91.com/api/v5/widget/verifyAccessToken', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ authkey, 'access-token': accessToken }), signal: controller.signal,
        });
        verification = await response.json();
        if (!response.ok || verification.type !== 'success') {
          return json({ error: 'MSG91 could not verify this phone' }, 401);
        }
      } catch (_error) {
        return json({ error: 'MSG91 verification is unavailable; try again' }, 502);
      } finally { clearTimeout(timeout); }
      const details = verification.message && typeof verification.message === 'object'
        ? verification.message as Record<string, unknown> : verification;
      const verifiedPhone = normalizePhone(details.mobile || details.identifier || details.phone || details.mobile_number);
      if (!verifiedPhone || verifiedPhone !== phone) {
        return json({ error: 'The verified number did not match the selected phone' }, 403);
      }
      const { error } = await db.from('t_whatsapp_phone_bindings').upsert({
        user_id: actor, phone_e164: phone, auth_confirmed_at: new Date().toISOString(),
        bound_at: new Date().toISOString(), revoked_at: null,
      }, { onConflict: 'user_id' });
      if (error) return json({ error: error.code === '23505' ? 'Phone is bound to another account' : 'Could not bind phone' }, 409);
      await audit('phone_bind', 'success', actor);
      return json({ verified_phone: phone });
    }
    if (body.action === 'binding_revoke') {
      await db.from('t_whatsapp_phone_bindings').update({ revoked_at: new Date().toISOString() }).eq('user_id', actor);
      await audit('phone_revoke', 'success', actor);
      return json({ verified_phone: null });
    }
    if (!manager) return json({ error: 'Manage-team permission required' }, 403);
    if (body.action === 'workspace') {
      if (typeof body.enabled !== 'boolean') return json({ error: 'enabled must be boolean' }, 400);
      const { error } = await db.from('t_whatsapp_tenant_access').upsert({
        tenant_id: tenantId, enabled: body.enabled, updated_by: actor, updated_at: new Date().toISOString(),
      });
      if (error) return json({ error: 'Could not update workspace access' }, 500);
      await audit('workspace_access', body.enabled ? 'enabled' : 'disabled');
      return json({ workspace_enabled: body.enabled });
    }
    if (body.action === 'member') {
      const target = body.user_id;
      if (typeof target !== 'string') return json({ error: 'Member required' }, 400);
      if (typeof body.enabled !== 'boolean') return json({ error: 'enabled must be boolean' }, 400);
      const { data: targetMembership } = await db.from('t_user_tenants').select('id')
        .eq('tenant_id', tenantId).eq('user_id', target).eq('status', 'active').maybeSingle();
      if (!targetMembership) return json({ error: 'Active member not found' }, 404);
      const { error } = await db.from('t_whatsapp_member_access').upsert({
        tenant_id: tenantId, user_id: target, enabled: body.enabled,
        updated_by: actor, updated_at: new Date().toISOString(),
      });
      if (error) return json({ error: 'Could not update member access' }, 500);
      await audit('member_access', body.enabled ? 'enabled' : 'disabled', target);
      return json({ user_id: target, enabled: body.enabled });
    }
    return json({ error: 'Not found' }, 404);
  } catch (error) {
    console.error('whatsapp-access:', error);
    return json({ error: 'Channel access request failed' }, 500);
  }
});
