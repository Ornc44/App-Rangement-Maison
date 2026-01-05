-- =========================
-- 0) Extensions (UUID)
-- =========================
create extension if not exists pgcrypto;

-- =========================
-- 1) Types
-- =========================
do $$
begin
  if not exists (select 1 from pg_type where typname = 'item_status') then
    create type item_status as enum ('ok','a_reparer','a_donner','prete','a_vendre','sorti');
  end if;
end $$;

-- =========================
-- 2) Tables core (homes, memberships)
-- =========================
create table if not exists homes (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists memberships (
  home_id uuid not null references homes(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('admin','member')),
  created_at timestamptz not null default now(),
  primary key (home_id, user_id)
);

-- =========================
-- 3) Locations (maison -> pièce -> zone)
-- =========================
create table if not exists locations (
  id uuid primary key default gen_random_uuid(),
  home_id uuid not null references homes(id) on delete cascade,
  type text not null check (type in ('house','room','zone')),
  parent_id uuid references locations(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

create index if not exists locations_home_parent_idx on locations(home_id, parent_id);

-- =========================
-- 4) Categories
-- =========================
create table if not exists categories (
  id uuid primary key default gen_random_uuid(),
  home_id uuid not null references homes(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

-- Unicité insensible à la casse (ex: "Câbles" == "câbles")
create unique index if not exists categories_home_name_ci_ux
on categories (home_id, lower(name));

-- =========================
-- 5) Boxes
-- =========================
create table if not exists boxes (
  id uuid primary key default gen_random_uuid(),
  home_id uuid not null references homes(id) on delete cascade,
  location_id uuid references locations(id) on delete set null,
  label text not null,        -- ex: "BOÎTE 014"
  qr_value text not null,     -- ex: "box:<uuid>"
  notes text,
  created_at timestamptz not null default now()
);

create unique index if not exists boxes_qr_value_ux on boxes(qr_value);
create index if not exists boxes_home_location_idx on boxes(home_id, location_id);

-- =========================
-- 6) Items (le "concept" d'objet)
-- =========================
create table if not exists items (
  id uuid primary key default gen_random_uuid(),
  home_id uuid not null references homes(id) on delete cascade,
  name text not null,
  category_id uuid references categories(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index if not exists items_home_name_ci_ux
on items (home_id, lower(name));

-- =========================
-- 7) Item instances (où c'est + quantité + statut)
-- =========================
create table if not exists item_instances (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references items(id) on delete cascade,
  box_id uuid not null references boxes(id) on delete cascade,
  quantity integer not null default 1 check (quantity >= 0),
  status item_status not null default 'ok',
  sale_price_estimated numeric,
  sale_notes text,
  updated_at timestamptz not null default now()
);

create index if not exists item_instances_box_idx on item_instances(box_id);
create index if not exists item_instances_item_idx on item_instances(item_id);
create index if not exists item_instances_status_idx on item_instances(status);

-- =========================
-- 8) Photos
-- =========================
create table if not exists photos (
  id uuid primary key default gen_random_uuid(),
  home_id uuid not null references homes(id) on delete cascade,
  owner_type text not null check (owner_type in ('item','box','invoice')),
  owner_id uuid not null,
  storage_path text not null,
  created_at timestamptz not null default now()
);

create index if not exists photos_owner_idx on photos(home_id, owner_type, owner_id);

-- =========================
-- 9) Audit log
-- =========================
create table if not exists audit_log (
  id uuid primary key default gen_random_uuid(),
  home_id uuid not null references homes(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  before_json jsonb,
  after_json jsonb,
  created_at timestamptz not null default now()
);

create index if not exists audit_home_created_idx on audit_log(home_id, created_at desc);

-- =========================
-- 10) Trigger: auto updated_at
-- =========================
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists trg_item_instances_updated_at on item_instances;
create trigger trg_item_instances_updated_at
before update on item_instances
for each row execute function set_updated_at();

-- =========================
-- 11) Trigger: audit log for boxes & item_instances
-- =========================
create or replace function audit_changes()
returns trigger language plpgsql as $$
declare
  v_home_id uuid;
  v_entity_id uuid;
  v_entity_type text := tg_table_name;
  v_action text := tg_op || '_' || tg_table_name;
begin
  if tg_table_name = 'boxes' then
    v_home_id := coalesce(new.home_id, old.home_id);
    v_entity_id := coalesce(new.id, old.id);
  elsif tg_table_name = 'item_instances' then
    -- home_id vient de boxes -> items -> home_id
    select b.home_id into v_home_id
    from boxes b
    where b.id = coalesce(new.box_id, old.box_id);

    v_entity_id := coalesce(new.id, old.id);
  else
    v_home_id := null;
    v_entity_id := coalesce(new.id, old.id);
  end if;

  insert into audit_log(home_id, user_id, action, entity_type, entity_id, before_json, after_json)
  values (
    v_home_id,
    auth.uid(),
    v_action,
    v_entity_type,
    v_entity_id,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end
  );

  return coalesce(new, old);
end $$;

drop trigger if exists trg_audit_boxes on boxes;
create trigger trg_audit_boxes
after insert or update or delete on boxes
for each row execute function audit_changes();

drop trigger if exists trg_audit_item_instances on item_instances;
create trigger trg_audit_item_instances
after insert or update or delete on item_instances
for each row execute function audit_changes();

-- =========================
-- 12) RLS (Row Level Security)
-- =========================
alter table homes enable row level security;
alter table memberships enable row level security;
alter table locations enable row level security;
alter table categories enable row level security;
alter table boxes enable row level security;
alter table items enable row level security;
alter table item_instances enable row level security;
alter table photos enable row level security;
alter table audit_log enable row level security;

-- Helper: "is member of home"
create or replace function is_home_member(p_home_id uuid)
returns boolean language sql stable as $$
  select exists (
    select 1 from memberships m
    where m.home_id = p_home_id and m.user_id = auth.uid()
  );
$$;

-- Helper: "is admin of home"
create or replace function is_home_admin(p_home_id uuid)
returns boolean language sql stable as $$
  select exists (
    select 1 from memberships m
    where m.home_id = p_home_id and m.user_id = auth.uid() and m.role = 'admin'
  );
$$;

-- =========================
-- 13) Policies
-- =========================

-- homes
drop policy if exists "homes_select_member" on homes;
create policy "homes_select_member"
on homes for select
using (is_home_member(id));

drop policy if exists "homes_insert_auth" on homes;
create policy "homes_insert_auth"
on homes for insert
to authenticated
with check (true);

drop policy if exists "homes_update_admin" on homes;
create policy "homes_update_admin"
on homes for update
using (is_home_admin(id))
with check (is_home_admin(id));

-- memberships
drop policy if exists "memberships_select_member" on memberships;
create policy "memberships_select_member"
on memberships for select
using (is_home_member(home_id));

drop policy if exists "memberships_insert_self" on memberships;
create policy "memberships_insert_self"
on memberships for insert
to authenticated
with check (user_id = auth.uid());

drop policy if exists "memberships_update_admin" on memberships;
create policy "memberships_update_admin"
on memberships for update
using (is_home_admin(home_id))
with check (is_home_admin(home_id));

drop policy if exists "memberships_delete_admin" on memberships;
create policy "memberships_delete_admin"
on memberships for delete
using (is_home_admin(home_id));

-- locations/categories/boxes/items/photos/audit_log: accès si membre
-- (audit_log: lecture seulement; écriture via triggers)
drop policy if exists "locations_member_rw" on locations;
create policy "locations_member_rw" on locations
for all using (is_home_member(home_id)) with check (is_home_member(home_id));

drop policy if exists "categories_member_rw" on categories;
create policy "categories_member_rw" on categories
for all using (is_home_member(home_id)) with check (is_home_member(home_id));

drop policy if exists "boxes_member_rw" on boxes;
create policy "boxes_member_rw" on boxes
for all using (is_home_member(home_id)) with check (is_home_member(home_id));

drop policy if exists "items_member_rw" on items;
create policy "items_member_rw" on items
for all using (is_home_member(home_id)) with check (is_home_member(home_id));

drop policy if exists "photos_member_rw" on photos;
create policy "photos_member_rw" on photos
for all using (is_home_member(home_id)) with check (is_home_member(home_id));

drop policy if exists "audit_log_member_read" on audit_log;
create policy "audit_log_member_read" on audit_log
for select using (is_home_member(home_id));

-- item_instances: on vérifie membership via home_id de la box liée
drop policy if exists "item_instances_member_rw" on item_instances;
create policy "item_instances_member_rw" on item_instances
for all
using (
  exists (
    select 1
    from boxes b
    join memberships m on m.home_id = b.home_id
    where b.id = item_instances.box_id and m.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1
    from boxes b
    join memberships m on m.home_id = b.home_id
    where b.id = item_instances.box_id and m.user_id = auth.uid()
  )
);
