# Setup

## 1. Create the Supabase project
1. Go to <https://supabase.com> → **New project**.
2. Pick a name, database password, and region. Wait for it to finish provisioning.
3. Open **Project Settings → API** and copy:
   - **Project URL** → this is `SUPABASE_URL`
   - **anon public** key → this is `SUPABASE_ANON_KEY`

## 2. Run the SQL
1. Open **SQL Editor → New query**.
2. Paste the entire contents of [`schema.sql`](schema.sql) and click **Run**.
3. This creates the tables (`branches`, `profiles`, `products`, `stock_moves`), the
   `v_product_stock` view, all RLS policies, and seeds the 2 branches
   (`DIGIART` = DigiArt Invitation, `UVINVITE` = UV Invite).

## 3. Create the 2 login users
Go to **Authentication → Users → Add user** (use "Auto confirm user").

| Branch             | Example email          | Password        |
|--------------------|------------------------|-----------------|
| DigiArt Invitation | `digiart@shop.local`   | *(your choice)* |
| UV Invite          | `uvinvite@shop.local`  | *(your choice)* |

Copy each new user's **UID** (shown in the users list).

## 4. Link each user to its branch in `profiles`
In **SQL Editor**, run this once, replacing the two UIDs:

```sql
insert into profiles (id, branch_id, display_name)
select 'DIGIART_USER_UID', id, 'DigiArt' from branches where code = 'DIGIART';

insert into profiles (id, branch_id, display_name)
select 'UVINVITE_USER_UID', id, 'UV Invite' from branches where code = 'UVINVITE';
```

To verify:

```sql
select p.display_name, b.name
from profiles p join branches b on b.id = p.branch_id;
```

## 5. Configure and open the app
1. Open [`index.html`](index.html) and set the two constants near the top:
   ```js
   const SUPABASE_URL      = "https://YOUR-PROJECT.supabase.co";
   const SUPABASE_ANON_KEY = "YOUR-ANON-KEY";
   ```
2. Open `index.html` in a browser (or host it anywhere static — GitHub Pages,
   Netlify, Supabase Storage, etc.). No build step.
3. Sign in with one of the 2 users. The header shows the branch name.

## Notes
- **Stock IN** is common (no branch). Any user can add it.
- **Stock OUT** is automatically recorded against the logged-in user's branch —
  the branch is not editable. RLS also enforces this on the server.
- Current stock = `opening_stock + total IN − total OUT` (both branches combined).
- An OUT entry that would make stock negative is blocked in the UI with the
  available quantity shown.
- To add more staff logins for a branch, create the auth user and insert a
  matching `profiles` row pointing at that branch.

## 6. Print Order Tracker (Orders tab)
1. **SQL Editor → New query**, paste all of [`print_orders.sql`](print_orders.sql), click **Run**.
   It only adds new tables and a `role` column on `profiles`; existing stock data is not touched.
   Do **not** re-run `schema.sql`.
2. **Authentication → Users → Add user** (Auto confirm) for the two new logins,
   e.g. `printing@...` (production unit) and `packing@...` (courier / packing).
3. Give them their roles (replace the emails):

```sql
insert into profiles (id, role, display_name)
select id, 'printing', 'Printing' from auth.users where email = 'PRINTING_EMAIL'
on conflict (id) do update set role = 'printing', branch_id = null;

insert into profiles (id, role, display_name)
select id, 'packing', 'Packing' from auth.users where email = 'PACKING_EMAIL'
on conflict (id) do update set role = 'packing', branch_id = null;
```

| Role | Login | Can do |
|---|---|---|
| `branch` (default) | DigiArt / UV Invite logins | Add entries for own branch, edit before print, cancel, and courier partner + tracking ID → **Dispatched**. Sees own branch only |
| `printing` | Production unit | Sees both branches, **Print Done**, undo print, and also courier partner + tracking ID → **Dispatched** |
| `packing` | Courier / packing | Sees both branches, enters courier partner + tracking ID → **Dispatched** |

These rules are enforced in the database (trigger `print_orders_guard`), not only in the app.
Every create / status change / edit is recorded in `print_order_log`.
