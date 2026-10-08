-- Phase-one WhatsApp identity and entitlement. All switches default OFF.
create table if not exists public.t_whatsapp_tenant_access (
  tenant_id uuid primary key references public.t_tenants(id) on delete cascade,
  enabled boolean not null default false,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create table if not exists public.t_whatsapp_member_access (
  tenant_id uuid not null references public.t_tenants(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  enabled boolean not null default false,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  primary key (tenant_id, user_id)
);

-- Only a confirmed Auth phone can create a binding. A profile mobile is not proof.
create table if not exists public.t_whatsapp_phone_bindings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  phone_e164 text not null check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  auth_confirmed_at timestamptz not null,
  bound_at timestamptz not null default now(),
  revoked_at timestamptz
);
create unique index if not exists t_whatsapp_phone_bindings_active_phone
  on public.t_whatsapp_phone_bindings(phone_e164) where revoked_at is null;

create table if not exists public.t_workspace_membership_exceptions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reason text not null check (length(trim(reason)) >= 12),
  approved_by uuid references auth.users(id),
  approved_at timestamptz not null default now(),
  revoked_at timestamptz
);

create table if not exists public.t_whatsapp_access_audit (
  id bigint generated always as identity primary key,
  tenant_id uuid,
  actor_user_id uuid,
  target_user_id uuid,
  action text not null,
  result text not null,
  created_at timestamptz not null default now()
);

alter table public.t_whatsapp_tenant_access enable row level security;
alter table public.t_whatsapp_member_access enable row level security;
alter table public.t_whatsapp_phone_bindings enable row level security;
alter table public.t_workspace_membership_exceptions enable row level security;
alter table public.t_whatsapp_access_audit enable row level security;

-- No anon/authenticated grants or policies: only trusted service-role code can access these records.
revoke all on public.t_whatsapp_tenant_access, public.t_whatsapp_member_access,
  public.t_whatsapp_phone_bindings, public.t_workspace_membership_exceptions,
  public.t_whatsapp_access_audit from anon, authenticated;

-- Protect *every* membership creation path, including invitations and admin tooling.
-- Existing memberships are retained. A deliberate exception record is required for
-- future multi-workspace activation; the exception is never inferred from a UI flag.
create or replace function public.enforce_one_active_workspace()
returns trigger language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  if new.status <> 'active' then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.status = 'active' and
     old.user_id = new.user_id and old.tenant_id = new.tenant_id then
    return new;
  end if;
  -- Serialize concurrent activations of the same account.
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));
  if new.status = 'active' then
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
  end if;
  return new;
end;
$$;
revoke execute on function public.enforce_one_active_workspace() from public, anon, authenticated;

drop trigger if exists t_user_tenants_one_active_workspace on public.t_user_tenants;
create trigger t_user_tenants_one_active_workspace
before insert or update of status, user_id, tenant_id on public.t_user_tenants
for each row execute function public.enforce_one_active_workspace();

