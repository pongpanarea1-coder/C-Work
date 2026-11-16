-- Supabase SQL: เปิด SQL Editor แล้วรันสคริปต์นี้
create extension if not exists pgcrypto;
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text
);
create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text unique not null default upper(substr(encode(gen_random_bytes(6),'hex'),1,8)),
  created_by uuid not null references auth.users(id),
  created_at timestamptz default now()
);
create table if not exists public.team_members (
  team_id uuid references public.teams(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  joined_at timestamptz default now(),
  primary key(team_id,user_id)
);
create table if not exists public.shifts (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  work_date date not null,
  shift_type text not null check (shift_type in ('morning','afternoon','off','special','custom')),
  note text default '',
  created_at timestamptz default now()
);
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into public.profiles(id,email) values(new.id,new.email) on conflict(id) do update set email=excluded.email; return new; end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert or update of email on auth.users for each row execute procedure public.handle_new_user();
create or replace function public.is_team_member(tid uuid) returns boolean language sql security definer set search_path=public stable as $$
 select exists(select 1 from public.team_members where team_id=tid and user_id=auth.uid()); $$;
create or replace function public.create_team(team_name text) returns json language plpgsql security definer set search_path=public as $$
declare tid uuid; code text; n int;
begin
 if auth.uid() is null then raise exception 'กรุณาเข้าสู่ระบบ'; end if;
 select count(*) into n from public.team_members where user_id=auth.uid();
 if n>0 then raise exception 'บัญชีนี้อยู่ในทีมแล้ว'; end if;
 insert into public.teams(name,created_by) values(coalesce(nullif(trim(team_name),''),'ทีมของฉัน'),auth.uid()) returning id,invite_code into tid,code;
 insert into public.team_members(team_id,user_id) values(tid,auth.uid());
 return json_build_object('id',tid,'invite_code',code);
end; $$;
create or replace function public.join_team(invite_code_input text) returns boolean language plpgsql security definer set search_path=public as $$
declare tid uuid; n int;
begin
 if auth.uid() is null then raise exception 'กรุณาเข้าสู่ระบบ'; end if;
 select count(*) into n from public.team_members where user_id=auth.uid();
 if n>0 then raise exception 'บัญชีนี้อยู่ในทีมแล้ว'; end if;
 select id into tid from public.teams where invite_code=upper(trim(invite_code_input));
 if tid is null then raise exception 'ไม่พบรหัสเชิญทีม'; end if;
 select count(*) into n from public.team_members where team_id=tid;
 if n>=10 then raise exception 'ทีมนี้มีสมาชิกครบ 10 คนแล้ว'; end if;
 insert into public.team_members(team_id,user_id) values(tid,auth.uid());
 return true;
end; $$;
alter table public.profiles enable row level security;
alter table public.teams enable row level security;
alter table public.team_members enable row level security;
alter table public.shifts enable row level security;
create policy "profiles visible to teammates" on public.profiles for select to authenticated using (exists(select 1 from public.team_members a join public.team_members b on a.team_id=b.team_id where a.user_id=auth.uid() and b.user_id=profiles.id));
create policy "users update own profile" on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
create policy "team members can view teams" on public.teams for select to authenticated using(public.is_team_member(id));
create policy "members view roster" on public.team_members for select to authenticated using(public.is_team_member(team_id));
create policy "members view shifts" on public.shifts for select to authenticated using(public.is_team_member(team_id));
create policy "members add own shifts" on public.shifts for insert to authenticated with check(public.is_team_member(team_id) and user_id=auth.uid());
create policy "members update own shifts" on public.shifts for update to authenticated using(public.is_team_member(team_id) and user_id=auth.uid()) with check(public.is_team_member(team_id) and user_id=auth.uid());
create policy "members delete own shifts" on public.shifts for delete to authenticated using(public.is_team_member(team_id) and user_id=auth.uid());
grant execute on function public.create_team(text) to authenticated;
grant execute on function public.join_team(text) to authenticated;
