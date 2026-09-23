create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text,
  role text not null default 'user' check (role in ('admin','user')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.clients (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  instagram text,
  niche text,
  color text not null default '#00d4ff',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  updated_by uuid references public.profiles(id)
);

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  client_id uuid not null references public.clients(id) on delete cascade,
  status text not null check (status in ('A fazer','Conferir','Refinar','Programado','Publicado')),
  type text,
  post_date date,
  post_time time,
  canva text,
  legenda text,
  notes text,
  automatic_status_update boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  updated_by uuid references public.profiles(id)
);

create table if not exists public.activity_log (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id),
  action text not null,
  entity_type text not null check (entity_type in ('client','post')),
  entity_id uuid not null,
  client_id uuid,
  post_id uuid,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.activity_reads (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  last_read_at timestamptz not null default now()
);

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  if auth.uid() is not null then new.updated_by = auth.uid(); end if;
  return new;
end;
$$;

drop trigger if exists clients_updated_at on public.clients;
create trigger clients_updated_at before update on public.clients
for each row execute procedure public.set_updated_at();

drop trigger if exists posts_updated_at on public.posts;
create trigger posts_updated_at before update on public.posts
for each row execute procedure public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  is_first_user boolean;
begin
  select not exists (select 1 from public.profiles) into is_first_user;
  insert into public.profiles (id, email, display_name, role, active)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'display_name', split_part(coalesce(new.email, ''), '@', 1)),
    case when is_first_user then 'admin' else 'user' end,
    true
  );
  insert into public.activity_reads (user_id) values (new.id);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.log_client_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  event_action text;
  actor uuid := auth.uid();
begin
  event_action := lower(tg_op);
  if tg_op = 'INSERT' then
    insert into public.activity_log(actor_id, action, entity_type, entity_id, client_id, after_data)
    values (actor, event_action, 'client', new.id, new.id, to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    insert into public.activity_log(actor_id, action, entity_type, entity_id, client_id, before_data, after_data)
    values (actor, event_action, 'client', new.id, new.id, to_jsonb(old), to_jsonb(new));
    return new;
  else
    insert into public.activity_log(actor_id, action, entity_type, entity_id, client_id, before_data)
    values (actor, event_action, 'client', old.id, old.id, to_jsonb(old));
    return old;
  end if;
end;
$$;

create or replace function public.log_post_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  event_action text;
  actor uuid := auth.uid();
begin
  event_action := lower(tg_op);
  if tg_op = 'INSERT' then
    insert into public.activity_log(actor_id, action, entity_type, entity_id, client_id, post_id, after_data)
    values (actor, event_action, 'post', new.id, new.client_id, new.id, to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    if new.automatic_status_update then return new; end if;
    insert into public.activity_log(actor_id, action, entity_type, entity_id, client_id, post_id, before_data, after_data)
    values (actor, event_action, 'post', new.id, new.client_id, new.id, to_jsonb(old), to_jsonb(new));
    return new;
  else
    insert into public.activity_log(actor_id, action, entity_type, entity_id, client_id, post_id, before_data)
    values (actor, event_action, 'post', old.id, old.client_id, old.id, to_jsonb(old));
    return old;
  end if;
end;
$$;

drop trigger if exists clients_activity_log on public.clients;
create trigger clients_activity_log after insert or update or delete on public.clients
for each row execute procedure public.log_client_change();

drop trigger if exists posts_activity_log on public.posts;
create trigger posts_activity_log after insert or update or delete on public.posts
for each row execute procedure public.log_post_change();

alter table public.profiles enable row level security;
alter table public.clients enable row level security;
alter table public.posts enable row level security;
alter table public.activity_log enable row level security;
alter table public.activity_reads enable row level security;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin' and active);
$$;

create or replace function public.is_active_user()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active);
$$;

drop policy if exists "authenticated can view profiles" on public.profiles;
create policy "authenticated can view profiles" on public.profiles for select to authenticated using (active = true or id = auth.uid() or public.is_admin());
drop policy if exists "admins can update profiles" on public.profiles;
create policy "admins can update profiles" on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "authenticated full access clients" on public.clients;
create policy "active users full access clients" on public.clients for all to authenticated using (public.is_active_user()) with check (public.is_active_user());
drop policy if exists "authenticated full access posts" on public.posts;
create policy "active users full access posts" on public.posts for all to authenticated using (public.is_active_user()) with check (public.is_active_user());
drop policy if exists "authenticated can view activity" on public.activity_log;
create policy "active users can view activity" on public.activity_log for select to authenticated using (public.is_active_user());
drop policy if exists "users manage own activity read" on public.activity_reads;
create policy "active users manage own activity read" on public.activity_reads for all to authenticated using (user_id = auth.uid() and public.is_active_user()) with check (user_id = auth.uid() and public.is_active_user());

alter table public.clients replica identity full;
alter table public.posts replica identity full;
alter table public.activity_log replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.clients;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.posts;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.activity_log;
exception when duplicate_object then null;
end $$;
