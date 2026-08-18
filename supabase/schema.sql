-- โครงสร้างฐานข้อมูลของแอป "เงินของฉัน" (ใช้แล้วกับโปรเจกต์ nvagsyvueppkjrcyinqu)
-- เก็บไว้เป็นเอกสารอ้างอิง / ใช้ตั้งโปรเจกต์ใหม่ได้ทั้งไฟล์
--
-- แนวคิด: 1 "household" = 1 กระเป๋าที่ใช้ร่วมกัน (คู่รัก/ครอบครัว)
--   - สมัครสมาชิก -> ได้ profile + household ของตัวเองอัตโนมัติ (มีรหัสเชิญ 6 หลัก)
--   - อีกฝ่ายกรอกรหัสเชิญ -> ย้ายมาอยู่ household เดียวกัน
--   - RLS: เห็นข้อมูลของคนใน household เดียวกัน แต่แก้/ลบได้เฉพาะแถวของตัวเอง

create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'บ้านของเรา',
  invite_code text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  color text not null default 'blue',
  household_id uuid references public.households(id) on delete set null,
  default_salary numeric(14,2) not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists profiles_household_idx on public.profiles(household_id);

create table if not exists public.salary_overrides (
  user_id uuid not null references public.profiles(id) on delete cascade,
  ym text not null check (ym ~ '^[0-9]{4}-[0-9]{2}$'),
  amount numeric(14,2) not null default 0,
  primary key (user_id, ym)
);

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null check (type in ('income','expense')),
  name text not null,
  icon text not null default '📦',
  sort int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists categories_user_idx on public.categories(user_id);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null check (type in ('income','expense')),
  amount numeric(14,2) not null check (amount > 0),
  cat_id uuid references public.categories(id) on delete set null,
  cat_name text not null default '',   -- สำเนาชื่อหมวด เพื่อให้อีกฝ่ายเห็นได้โดยไม่ต้องแชร์หมวด
  cat_icon text not null default '📦',
  date date not null,
  note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists transactions_user_date_idx on public.transactions(user_id, date desc);

-- ---------- helpers (security definer เพื่อไม่ให้ RLS วนกลับมาหาตัวเอง) ----------
create or replace function public.my_household()
returns uuid language sql stable security definer set search_path = public as $$
  select household_id from public.profiles where id = auth.uid();
$$;

create or replace function public.is_partner(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles me
    join public.profiles other on other.household_id = me.household_id
    where me.id = auth.uid() and other.id = uid and me.household_id is not null
  );
$$;

create or replace function public.gen_invite_code()
returns text language plpgsql security definer set search_path = public as $$
declare c text; i int := 0;
begin
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from public.households where invite_code = c) or i > 30;
    i := i + 1;
  end loop;
  return c;
end $$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare h_id uuid;
begin
  insert into public.households(invite_code) values (public.gen_invite_code()) returning id into h_id;
  insert into public.profiles(id, display_name, household_id)
  values (new.id,
          coalesce(nullif(new.raw_user_meta_data->>'display_name',''), split_part(new.email,'@',1)),
          h_id);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists transactions_touch on public.transactions;
create trigger transactions_touch before update on public.transactions
  for each row execute function public.touch_updated_at();

create or replace function public.join_household(p_code text)
returns public.households language plpgsql security definer set search_path = public as $$
declare h public.households; old_h uuid;
begin
  if auth.uid() is null then raise exception 'ต้องเข้าสู่ระบบก่อน'; end if;
  select * into h from public.households where invite_code = upper(btrim(p_code));
  if h.id is null then raise exception 'ไม่พบรหัสเชิญนี้'; end if;
  select household_id into old_h from public.profiles where id = auth.uid();
  update public.profiles set household_id = h.id where id = auth.uid();
  if old_h is not null and old_h <> h.id then
    delete from public.households hh where hh.id = old_h
      and not exists (select 1 from public.profiles p where p.household_id = old_h);
  end if;
  return h;
end $$;

create or replace function public.leave_household()
returns public.households language plpgsql security definer set search_path = public as $$
declare h_id uuid; old_h uuid; h public.households;
begin
  if auth.uid() is null then raise exception 'ต้องเข้าสู่ระบบก่อน'; end if;
  select household_id into old_h from public.profiles where id = auth.uid();
  insert into public.households(invite_code) values (public.gen_invite_code()) returning id into h_id;
  update public.profiles set household_id = h_id where id = auth.uid();
  if old_h is not null then
    delete from public.households hh where hh.id = old_h
      and not exists (select 1 from public.profiles p where p.household_id = old_h);
  end if;
  select * into h from public.households where id = h_id;
  return h;
end $$;

-- ---------- RLS ----------
alter table public.households       enable row level security;
alter table public.profiles         enable row level security;
alter table public.salary_overrides enable row level security;
alter table public.categories       enable row level security;
alter table public.transactions     enable row level security;

create policy households_select on public.households
  for select to authenticated using (id = public.my_household());
create policy households_update on public.households
  for update to authenticated using (id = public.my_household()) with check (id = public.my_household());

create policy profiles_select on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_partner(id));
create policy profiles_update on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_insert on public.profiles
  for insert to authenticated with check (id = auth.uid());

create policy salary_select on public.salary_overrides
  for select to authenticated using (user_id = auth.uid() or public.is_partner(user_id));
create policy salary_write on public.salary_overrides
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy categories_select on public.categories
  for select to authenticated using (user_id = auth.uid() or public.is_partner(user_id));
create policy categories_write on public.categories
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy transactions_select on public.transactions
  for select to authenticated using (user_id = auth.uid() or public.is_partner(user_id));
create policy transactions_write on public.transactions
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- grants ----------
revoke all on public.households, public.profiles, public.salary_overrides,
              public.categories, public.transactions from anon;
grant select, insert, update, delete on public.profiles, public.salary_overrides,
      public.categories, public.transactions to authenticated;
grant select, update on public.households to authenticated;

revoke execute on function public.handle_new_user()   from public, anon, authenticated;
revoke execute on function public.touch_updated_at()  from public, anon, authenticated;
revoke execute on function public.gen_invite_code()   from public, anon, authenticated;
revoke execute on function public.my_household()      from public, anon;
revoke execute on function public.is_partner(uuid)    from public, anon;
revoke execute on function public.join_household(text) from public, anon;
revoke execute on function public.leave_household()   from public, anon;
grant execute on function public.my_household(), public.is_partner(uuid),
                          public.join_household(text), public.leave_household() to authenticated;
