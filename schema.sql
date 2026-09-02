-- ============================================================
-- Stock Management Tool - Supabase schema
-- Run this in the Supabase SQL editor (one shot).
-- ============================================================

-- ---------- Extensions ----------
create extension if not exists "pgcrypto";

-- ---------- Tables ----------
create table if not exists branches (
  id   uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null
);

create table if not exists profiles (
  id           uuid primary key references auth.users on delete cascade,
  branch_id    uuid references branches,
  display_name text
);

create table if not exists products (
  id            uuid primary key default gen_random_uuid(),
  product_no    text unique not null,
  name          text not null,
  category      text,
  unit          text default 'pcs',
  opening_stock numeric default 0,
  min_stock     numeric default 0,
  is_active     boolean default true,
  created_at    timestamptz default now()
);

create table if not exists stock_moves (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid references products on delete cascade,
  move_type  text check (move_type in ('IN','OUT')),
  qty        numeric not null check (qty > 0),
  branch_id  uuid references branches,          -- NULL for IN (common), required for OUT
  party      text,                              -- customer / supplier / order no
  note       text,
  created_by uuid references auth.users,
  move_date  date default current_date,
  created_at timestamptz default now(),
  constraint out_needs_branch check (
    (move_type = 'OUT' and branch_id is not null) or
    (move_type = 'IN'  and branch_id is null)
  )
);

create index if not exists idx_stock_moves_product on stock_moves(product_id);
create index if not exists idx_stock_moves_date    on stock_moves(move_date);
create index if not exists idx_stock_moves_type    on stock_moves(move_type);

-- ---------- Seed branches ----------
insert into branches (code, name) values
  ('DIGIART',  'DigiArt Invitation'),
  ('UVINVITE', 'UV Invite')
on conflict (code) do nothing;

-- ---------- Stock view ----------
create or replace view v_product_stock as
select
  p.id                                            as product_id,
  p.product_no,
  p.name,
  p.unit,
  p.min_stock,
  coalesce(sum(m.qty) filter (where m.move_type = 'IN'), 0)                                     as total_in,
  coalesce(sum(m.qty) filter (where m.move_type = 'OUT'), 0)                                    as total_out,
  coalesce(sum(m.qty) filter (where m.move_type = 'OUT' and b.code = 'DIGIART'), 0)             as out_digiart,
  coalesce(sum(m.qty) filter (where m.move_type = 'OUT' and b.code = 'UVINVITE'), 0)            as out_uvinvite,
  p.opening_stock
    + coalesce(sum(m.qty) filter (where m.move_type = 'IN'), 0)
    - coalesce(sum(m.qty) filter (where m.move_type = 'OUT'), 0)                                as current_stock,
  (
    p.opening_stock
    + coalesce(sum(m.qty) filter (where m.move_type = 'IN'), 0)
    - coalesce(sum(m.qty) filter (where m.move_type = 'OUT'), 0)
  ) <= p.min_stock                                                                             as low_stock
from products p
left join stock_moves m on m.product_id = p.id
left join branches    b on b.id = m.branch_id
group by p.id;

-- ---------- Row Level Security ----------
alter table branches    enable row level security;
alter table profiles    enable row level security;
alter table products    enable row level security;
alter table stock_moves enable row level security;

-- Everyone logged in can read
create policy "read branches"    on branches    for select to authenticated using (true);
create policy "read profiles"    on profiles    for select to authenticated using (true);
create policy "read products"    on products    for select to authenticated using (true);
create policy "read stock_moves" on stock_moves for select to authenticated using (true);

-- Products: any logged-in user can add / edit
create policy "write products"  on products for insert to authenticated with check (true);
create policy "update products" on products for update to authenticated using (true) with check (true);

-- stock_moves insert rules:
--   IN  -> branch_id must be null
--   OUT -> branch_id must equal the user's own branch from profiles
create policy "insert stock_moves" on stock_moves for insert to authenticated
with check (
  created_by = auth.uid()
  and (
    (move_type = 'IN' and branch_id is null)
    or
    (move_type = 'OUT' and branch_id = (select branch_id from profiles where id = auth.uid()))
  )
);
