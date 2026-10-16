-- ============================================================
-- Print Order Tracker  (Printing -> Courier -> Dispatched)
-- Run this ONCE in the Supabase SQL editor, AFTER schema.sql.
-- Safe to re-run. Does not change any existing stock data.
-- ============================================================

-- ---------- Roles on profiles ----------
-- branch   = Surat / Rajkot branch staff (profiles.branch_id set)
-- printing = production unit, marks Print Done (sees both branches)
-- packing  = enters courier partner + tracking ID (sees both branches)
-- every role can enter courier partner + tracking ID / dispatch (branch: own branch only, via RLS)
alter table profiles add column if not exists role text not null default 'branch'
  check (role in ('branch','printing','packing'));

create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select role from profiles where id = auth.uid()), 'branch')
$$;

create or replace function my_branch() returns uuid
language sql stable security definer set search_path = public as $$
  select branch_id from profiles where id = auth.uid()
$$;

-- ---------- Tables ----------
create table if not exists print_orders (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  branch_id       uuid not null references branches,
  mobile          text not null check (mobile ~ '^[0-9]{10}$'),
  details         text not null check (length(trim(details)) > 0),
  needed_by       date,
  status          text not null default 'pending'
                  check (status in ('pending','courier_pending','dispatched','cancelled')),
  printed_at      timestamptz,
  printed_by      uuid references auth.users,
  courier_partner text check (courier_partner in ('anjani','delhivery','post','other')),
  courier_other   text,
  tracking_id     text,
  dispatched_at   timestamptz,
  dispatched_by   uuid references auth.users,
  created_by      uuid references auth.users,
  updated_by      uuid references auth.users,
  updated_at      timestamptz,
  cancel_reason   text,
  constraint dispatched_needs_tracking check (
    status <> 'dispatched' or (
      coalesce(trim(tracking_id),'') <> '' and courier_partner is not null
      and (courier_partner <> 'other' or coalesce(trim(courier_other),'') <> '')
    )
  ),
  constraint cancel_needs_reason check (status <> 'cancelled' or coalesce(trim(cancel_reason),'') <> '')
);

create index if not exists print_orders_status_idx on print_orders (status, created_at);
create index if not exists print_orders_mobile_idx on print_orders (mobile);
create index if not exists print_orders_branch_idx on print_orders (branch_id);

create table if not exists print_order_log (
  id       uuid primary key default gen_random_uuid(),
  order_id uuid not null references print_orders,
  at       timestamptz not null default now(),
  by_user  uuid references auth.users,
  action   text not null,
  note     text
);
create index if not exists print_order_log_order_idx on print_order_log (order_id, at);

-- ---------- Guard: who may change what ----------
create or replace function print_orders_guard() returns trigger
language plpgsql set search_path = public as $$
declare r text := my_role();
begin
  if tg_op = 'INSERT' then
    new.status := 'pending'; new.created_by := auth.uid(); new.created_at := now();
    new.printed_at := null; new.printed_by := null;
    new.courier_partner := null; new.courier_other := null; new.tracking_id := null;
    new.dispatched_at := null; new.dispatched_by := null; new.cancel_reason := null;
    return new;
  end if;

  -- never editable
  new.id := old.id; new.created_at := old.created_at;
  new.branch_id := old.branch_id; new.created_by := old.created_by;
  -- stamps are set only by the transitions below
  new.printed_at := old.printed_at; new.printed_by := old.printed_by;
  new.dispatched_at := old.dispatched_at; new.dispatched_by := old.dispatched_by;
  new.updated_by := auth.uid(); new.updated_at := now();

  if (new.mobile, new.details, new.needed_by) is distinct from (old.mobile, old.details, old.needed_by)
     and not (r = 'branch' and old.status = 'pending' and new.status = 'pending') then
    raise exception 'Mobile / details can be edited only by the branch, before print is done';
  end if;

  if new.status is distinct from old.status then
    if old.status = 'pending' and new.status = 'courier_pending' and r = 'printing' then
      new.printed_at := now(); new.printed_by := auth.uid();
    elsif old.status = 'courier_pending' and new.status = 'pending' and r = 'printing' then
      new.printed_at := null; new.printed_by := null;                -- undo Print Done
    elsif old.status = 'courier_pending' and new.status = 'dispatched' then
      new.dispatched_at := now(); new.dispatched_by := auth.uid();
    elsif old.status = 'dispatched' and new.status = 'courier_pending' then
      new.dispatched_at := null; new.dispatched_by := null;          -- undo Dispatch
    elsif old.status in ('pending','courier_pending') and new.status = 'cancelled' then
      null;                                                          -- anyone who can see the row
    elsif old.status = 'cancelled' and new.status = 'pending' and r in ('branch','printing') then
      new.printed_at := null; new.printed_by := null;                -- restore
    else
      raise exception 'Status change % -> % is not allowed for %', old.status, new.status, r;
    end if;
  end if;

  if new.status <> 'cancelled' then new.cancel_reason := null;
  elsif old.status = 'cancelled' then new.cancel_reason := old.cancel_reason;
  end if;
  return new;
end $$;

drop trigger if exists print_orders_guard on print_orders;
create trigger print_orders_guard before insert or update on print_orders
  for each row execute function print_orders_guard();

-- ---------- Audit log: one row per create / status change / edit ----------
create or replace function print_orders_log_fn() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into print_order_log (order_id, by_user, action, note)
  values (
    new.id, auth.uid(),
    case when tg_op = 'INSERT' then 'created'
         when new.status is distinct from old.status then old.status || ' -> ' || new.status
         else 'edited' end,
    case when tg_op = 'INSERT' then null
         when new.status = 'cancelled' and old.status <> 'cancelled' then new.cancel_reason
         when new.status = 'dispatched' and old.status <> 'dispatched'
           then new.courier_partner || ' ' || coalesce(new.courier_other || ' ', '') || new.tracking_id
         when new.status = old.status
           then 'before: ' || jsonb_build_object('mobile', old.mobile, 'details', old.details,
                  'needed_by', old.needed_by, 'courier_partner', old.courier_partner,
                  'tracking_id', old.tracking_id)::text
    end
  );
  return null;
end $$;

drop trigger if exists print_orders_log on print_orders;
create trigger print_orders_log after insert or update on print_orders
  for each row execute function print_orders_log_fn();

-- ---------- Row Level Security ----------
alter table print_orders    enable row level security;
alter table print_order_log enable row level security;

-- branch staff see only their own branch; printing / packing see both
drop policy if exists "read print_orders" on print_orders;
create policy "read print_orders" on print_orders for select to authenticated
  using (my_role() in ('printing','packing') or branch_id = my_branch());

-- only branch staff create entries, always for their own branch
drop policy if exists "insert print_orders" on print_orders;
create policy "insert print_orders" on print_orders for insert to authenticated
  with check (my_role() = 'branch' and branch_id = my_branch());

-- updates: same visibility; the guard trigger decides which changes are allowed
drop policy if exists "update print_orders" on print_orders;
create policy "update print_orders" on print_orders for update to authenticated
  using (my_role() in ('printing','packing') or branch_id = my_branch())
  with check (true);

-- no delete policy: orders are never deleted, only cancelled

drop policy if exists "read print_order_log" on print_order_log;
create policy "read print_order_log" on print_order_log for select to authenticated
  using (exists (select 1 from print_orders o where o.id = order_id));

-- ---------- Realtime (new entries appear without refresh) ----------
do $$ begin
  alter publication supabase_realtime add table print_orders;
exception when duplicate_object or undefined_object then null;
end $$;
