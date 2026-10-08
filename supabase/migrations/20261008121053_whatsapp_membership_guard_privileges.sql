-- The membership writers include user-JWT PostgREST requests. The guard must
-- see all of a user's memberships and the private exception table even when
-- caller RLS cannot. Keep it in a non-exposed schema, callable only by trigger.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create or replace function private.enforce_one_active_workspace()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, private, pg_temp as $$
begin
  if new.status <> 'active' then return new; end if;
  if tg_op = 'UPDATE' and old.status = 'active' and
     old.user_id = new.user_id and old.tenant_id = new.tenant_id then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));
  if not exists (
    select 1 from public.t_workspace_membership_exceptions e
    where e.user_id = new.user_id and e.revoked_at is null
  ) and exists (
    select 1 from public.t_user_tenants ut
    where ut.user_id = new.user_id and ut.status = 'active'
      and ut.tenant_id is distinct from new.tenant_id
  ) then
    raise exception 'Account already belongs to another active workspace'
      using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke execute on function private.enforce_one_active_workspace() from public, anon, authenticated;

drop trigger if exists t_user_tenants_one_active_workspace on public.t_user_tenants;
create trigger t_user_tenants_one_active_workspace
before insert or update of status, user_id, tenant_id on public.t_user_tenants
for each row execute function private.enforce_one_active_workspace();
drop function if exists public.enforce_one_active_workspace();

