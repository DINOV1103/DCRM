-- =====================================================================
--  DCRM — Supabase sozlamasi (rollar, ruxsatlar, bosqichlar)
--  Qayerda: Supabase → SQL Editor → New query → shu faylni to‘liq qo‘yib "Run".
--  Qayta ishga tushirsa ham xavfsiz: mavjud bitimlar o‘chmaydi.
--
--  Natija:
--   • Menejer faqat o‘z bitimlarini ko‘radi va o‘zgartiradi, ularni boshqaga o‘tkaza olmaydi.
--   • Admin hamma bitimni ko‘radi, foydalanuvchi va bosqichlarni boshqaradi.
--   • Admin menejerga alohida ruxsat bera oladi: view_all (hamma bitim va umumiy statistika),
--     transfer (bitimni o‘tkazish, hamma bitimni ko‘rishni ham beradi), delete, export.
--
--  DIQQAT: deals, profiles, stages jadvallaridagi ESKI RLS qoidalari o‘chiriladi
--  va o‘rniga quyidagilar qo‘yiladi (eski "hammaga ruxsat" qoidasi qolsa, cheklovlar ishlamaydi).
--  sdelkalar jadvaliga tegilmaydi.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. Foydalanuvchilar profili: rol, ruxsatlar, faol/faol emas
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade
);
alter table public.profiles add column if not exists full_name  text;
alter table public.profiles add column if not exists email      text;
alter table public.profiles add column if not exists role       text;
alter table public.profiles add column if not exists perms      jsonb;
alter table public.profiles add column if not exists active     boolean;
alter table public.profiles add column if not exists created_at timestamptz default now();

update public.profiles set role = 'manager' where role is null or role not in ('admin', 'manager');
update public.profiles set perms = '{}'::jsonb where perms is null;
update public.profiles set active = true where active is null;
alter table public.profiles alter column role   set default 'manager';
alter table public.profiles alter column role   set not null;
alter table public.profiles alter column perms  set default '{}'::jsonb;
alter table public.profiles alter column perms  set not null;
alter table public.profiles alter column active set default true;
alter table public.profiles alter column active set not null;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_role_check' and conrelid = 'public.profiles'::regclass) then
    alter table public.profiles add constraint profiles_role_check check (role in ('admin', 'manager'));
  end if;
end $$;

-- Mavjud foydalanuvchilar uchun profil (yo‘q bo‘lsa) va bo‘sh emaillarni to‘ldirish
insert into public.profiles (id, email, full_name)
select u.id, u.email, coalesce(u.raw_user_meta_data->>'full_name', split_part(u.email, '@', 1))
from auth.users u
on conflict (id) do nothing;
update public.profiles p set email = u.email from auth.users u where p.id = u.id and p.email is null;

-- Yangi foydalanuvchi yaratilganda profil avtomatik ochiladi (rol: menejer)
create or replace function public.dcrm_handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists dcrm_on_auth_user_created on auth.users;
create trigger dcrm_on_auth_user_created after insert on auth.users
  for each row execute function public.dcrm_handle_new_user();

-- ---------------------------------------------------------------------
-- 2. Ruxsat tekshiruvchi funksiyalar
-- ---------------------------------------------------------------------
create or replace function public.dcrm_me_active() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select active from public.profiles where id = auth.uid()), false)
$$;

create or replace function public.dcrm_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin' and active)
$$;

-- p: 'view_all' | 'transfer' | 'delete' | 'export'. Admin uchun hammasi ruxsat.
create or replace function public.dcrm_can(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and active and (role = 'admin' or (perms ->> p) = 'true')
  )
$$;

-- ---------------------------------------------------------------------
-- 3. Bosqichlar (admin qo‘shadi va tahrirlaydi)
--    key — bitimda saqlanadigan kod, name — ko‘rinadigan nom,
--    kind — open (jarayonda) | won (yutilgan) | lost (yo‘qotilgan)
-- ---------------------------------------------------------------------
create table if not exists public.stages (
  key        text primary key,
  name       text not null,
  color      text not null default '#7C8794',
  position   integer not null default 0,
  kind       text not null default 'open' check (kind in ('open', 'won', 'lost')),
  created_at timestamptz not null default now()
);
insert into public.stages (key, name, color, position, kind) values
  ('ПЕРВИЧНЫЙ',         'Первичный',         '#3B82C4',  1, 'open'),
  ('КОНСУЛЬТАЦИЯ',      'Консультация',      '#1AA3B8',  2, 'open'),
  ('ПРИНИМАЕТ РЕШЕНИЯ', 'Принимает решения', '#D99A1C',  3, 'open'),
  ('ЗАКАЗ',             'Заказ',             '#8B5CD6',  4, 'open'),
  ('КАЙТА ХАРИД',       'Кайта харид',       '#6FA82B',  5, 'open'),
  ('НЕКОРРЕКТНЫЙ',      'Некорректный',      '#7C8794',  6, 'lost'),
  ('НЕДОЗВОН',          'Недозвон',          '#D4619E',  7, 'lost'),
  ('ОТКАЗ',             'Отказ',             '#D5433B',  8, 'lost'),
  ('УСПЕШНО',           'Успешно',           '#1F9D61',  9, 'won'),
  ('ДОСТАВКА',          'Доставка',          '#4F6FD8', 10, 'open'),
  ('ФИНИШ',             'Финиш',             '#A8813A', 11, 'open'),
  ('ТАРГЕТ ЛИТ',        'Таргет лит',        '#E0703A', 12, 'open')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 4. Bitimlar jadvali (bor bo‘lsa, faqat yetishmagan ustunlar qo‘shiladi)
-- ---------------------------------------------------------------------
create table if not exists public.deals (
  id bigint generated by default as identity primary key
);
alter table public.deals add column if not exists name       text;
alter table public.deals add column if not exists owner      text;
alter table public.deals add column if not exists owner_id   uuid;
alter table public.deals add column if not exists created_ts bigint;
alter table public.deals add column if not exists funnel     text;
alter table public.deals add column if not exists stage      text;
alter table public.deals add column if not exists order_date date;
alter table public.deals add column if not exists budget     numeric default 0;
alter table public.deals add column if not exists product    text;
alter table public.deals add column if not exists qty        integer default 1;
alter table public.deals add column if not exists client     jsonb default '{}'::jsonb;
alter table public.deals add column if not exists tasks      jsonb default '[]'::jsonb;
alter table public.deals add column if not exists events     jsonb default '[]'::jsonb;
alter table public.deals add column if not exists updated_at timestamptz default now();
alter table public.deals add column if not exists created_at timestamptz default now();

create index if not exists deals_owner_id_idx   on public.deals (owner_id);
create index if not exists deals_stage_idx      on public.deals (stage);
create index if not exists deals_created_ts_idx on public.deals (created_ts desc);

-- Menejer bitimni boshqaga o‘tkaza olmaydi; yangi bitim avtomatik o‘ziga yoziladi.
create or replace function public.dcrm_deals_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  my_name text;
begin
  if me is null or public.dcrm_can('transfer') then
    return new;                       -- server (service role) yoki o‘tkazish ruxsati bor
  end if;
  if tg_op = 'INSERT' then
    select full_name into my_name from public.profiles where id = me;
    new.owner_id := me;
    new.owner := coalesce(my_name, new.owner);
  elsif new.owner_id::text is distinct from old.owner_id::text then
    raise exception 'Bitimni boshqa menejerga o‘tkazishga ruxsatingiz yo‘q' using errcode = '42501';
  else
    new.owner := old.owner;
  end if;
  return new;
end $$;
drop trigger if exists dcrm_deals_guard on public.deals;
create trigger dcrm_deals_guard before insert or update on public.deals
  for each row execute function public.dcrm_deals_guard();

-- Bitimi bor bosqichni o‘chirib bo‘lmaydi
create or replace function public.dcrm_stages_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.deals where stage = old.key) then
    raise exception 'Bu bosqichda bitimlar bor — avval ularni boshqa bosqichga o‘tkazing' using errcode = '23503';
  end if;
  return old;
end $$;
drop trigger if exists dcrm_stages_guard on public.stages;
create trigger dcrm_stages_guard before delete on public.stages
  for each row execute function public.dcrm_stages_guard();

-- Kamida bitta faol admin qolishi shart
create or replace function public.dcrm_profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.role = 'admin' and old.active
     and (tg_op = 'DELETE' or new.role <> 'admin' or not new.active)
     and not exists (select 1 from public.profiles where role = 'admin' and active and id <> old.id) then
    raise exception 'Kamida bitta faol admin qolishi kerak' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists dcrm_profiles_guard on public.profiles;
create trigger dcrm_profiles_guard before update or delete on public.profiles
  for each row execute function public.dcrm_profiles_guard();

-- ---------------------------------------------------------------------
-- 5. RLS qoidalari
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('deals', 'profiles', 'stages') loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.deals    enable row level security;
alter table public.profiles enable row level security;
alter table public.stages   enable row level security;

-- Bitimlar: o‘ziniki; "view_all" yoki "transfer" ruxsati bo‘lsa — hammasi
-- (o‘tkazgan bitimini ko‘rib turishi uchun "transfer" ham hammasini ko‘rishni beradi)
create policy dcrm_deals_select on public.deals for select to authenticated
  using (public.dcrm_me_active() and (owner_id::text = auth.uid()::text or public.dcrm_can('view_all') or public.dcrm_can('transfer')));
create policy dcrm_deals_insert on public.deals for insert to authenticated
  with check (public.dcrm_me_active() and (owner_id::text = auth.uid()::text or public.dcrm_can('transfer')));
create policy dcrm_deals_update on public.deals for update to authenticated
  using (public.dcrm_me_active() and (owner_id::text = auth.uid()::text or public.dcrm_can('view_all') or public.dcrm_can('transfer')))
  with check (public.dcrm_me_active());
create policy dcrm_deals_delete on public.deals for delete to authenticated
  using (public.dcrm_can('delete') and (owner_id::text = auth.uid()::text or public.dcrm_can('view_all')));

-- Profillar: har kim o‘zinikini ko‘radi; ro‘yxatni admin va view_all/transfer ruxsatlilar ko‘radi; o‘zgartirish — faqat admin
create policy dcrm_profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.dcrm_can('view_all') or public.dcrm_can('transfer'));
create policy dcrm_profiles_insert on public.profiles for insert to authenticated
  with check (public.dcrm_is_admin());
create policy dcrm_profiles_update on public.profiles for update to authenticated
  using (public.dcrm_is_admin()) with check (public.dcrm_is_admin());
create policy dcrm_profiles_delete on public.profiles for delete to authenticated
  using (public.dcrm_is_admin() and id <> auth.uid());

-- Bosqichlar: hamma ko‘radi, faqat admin o‘zgartiradi
create policy dcrm_stages_select on public.stages for select to authenticated using (true);
create policy dcrm_stages_insert on public.stages for insert to authenticated with check (public.dcrm_is_admin());
create policy dcrm_stages_update on public.stages for update to authenticated using (public.dcrm_is_admin()) with check (public.dcrm_is_admin());
create policy dcrm_stages_delete on public.stages for delete to authenticated using (public.dcrm_is_admin());

grant select, insert, update, delete on public.deals, public.profiles, public.stages to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- Real vaqt yangilanishi (boshqa menejer o‘zgartirsa, ekran yangilanadi)
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'deals') then
    alter publication supabase_realtime add table public.deals;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. Birinchi adminni belgilash (bir marta)
--    Avval Supabase → Authentication → Users → "Add user" orqali o‘zingizga
--    email va parol yarating, keyin quyidagi qatordagi emailni o‘zingiznikiga
--    almashtirib, "--" belgisini olib tashlang va faqat shu qatorni ishga tushiring:
--
-- update public.profiles set role = 'admin', full_name = 'Muhiddin Sabriddinovich' where email = 'SIZNING@EMAIL';
-- ---------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from public.profiles where role = 'admin' and active) then
    raise notice 'Hali admin yo‘q: 6-bo‘limdagi qatorni o‘z emailingiz bilan ishga tushiring.';
  end if;
end $$;
