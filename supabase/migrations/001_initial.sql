create extension if not exists pgcrypto;

create table public.products (
  id text primary key,
  name text not null unique,
  price_rupees integer not null check (price_rupees >= 0),
  active boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into public.products (id, name, price_rupees) values
  ('blazer','Blazer',1000), ('waistcoat','Waistcoat',500), ('perfume','Perfume',500)
on conflict (id) do nothing;

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  idempotency_key uuid not null unique,
  product_id text not null references public.products(id),
  product_name text not null,
  original_unit_price integer not null check (original_unit_price >= 0),
  quantity integer not null check (quantity between 1 and 99),
  gross_amount integer not null check (gross_amount >= 0),
  discount_amount integer not null default 0 check (discount_amount >= 0),
  discount_type text not null default 'none' check (discount_type in ('none','per_unit','transaction','final_total')),
  final_amount integer not null check (final_amount >= 0),
  payment_method text not null check (payment_method in ('cash','upi')),
  status text not null default 'complete' check (status in ('complete','void')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (gross_amount = original_unit_price * quantity),
  check (final_amount = gross_amount - discount_amount)
);
create index sales_created_at_idx on public.sales (created_at desc);
create index sales_product_idx on public.sales (product_id, created_at desc);

create table public.sale_audit (
  id bigint generated always as identity primary key,
  sale_id uuid not null,
  action text not null check (action in ('created','updated','deleted')),
  old_data jsonb,
  new_data jsonb,
  changed_at timestamptz not null default now()
);
create index sale_audit_sale_time_idx on public.sale_audit (sale_id, changed_at desc);

create or replace function public.audit_sale_change() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into sale_audit(sale_id, action, new_data) values (new.id, 'created', to_jsonb(new)); return new;
  elsif tg_op = 'UPDATE' then
    insert into sale_audit(sale_id, action, old_data, new_data) values (new.id, 'updated', to_jsonb(old), to_jsonb(new)); return new;
  else
    insert into sale_audit(sale_id, action, old_data) values (old.id, 'deleted', to_jsonb(old)); return old;
  end if;
end $$;
create trigger sales_audit_trigger after insert or update or delete on public.sales for each row execute function public.audit_sale_change();

create or replace function public.create_sale(
  p_idempotency_key uuid, p_product_id text, p_quantity integer, p_payment_method text,
  p_discount_type text default 'none', p_discount_value integer default 0
) returns public.sales language plpgsql security definer set search_path = public as $$
declare p public.products; g integer; d integer; s public.sales;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into p from products where id = p_product_id and active;
  if not found then raise exception 'Product unavailable'; end if;
  if p_quantity < 1 or p_quantity > 99 then raise exception 'Quantity must be between 1 and 99'; end if;
  if p_payment_method not in ('cash','upi') then raise exception 'Invalid payment method'; end if;
  if p_discount_type not in ('none','per_unit','transaction','final_total') then raise exception 'Invalid discount type'; end if;
  if p_discount_value < 0 then raise exception 'Discount cannot be negative'; end if;
  g := p.price_rupees * p_quantity;
  d := case p_discount_type when 'per_unit' then p_discount_value * p_quantity
       when 'transaction' then p_discount_value when 'final_total' then g - p_discount_value else 0 end;
  if d > g then raise exception 'Discount cannot exceed gross amount'; end if;
  insert into sales(idempotency_key, product_id, product_name, original_unit_price, quantity, gross_amount, discount_amount, discount_type, final_amount, payment_method)
  values (p_idempotency_key, p.id, p.name, p.price_rupees, p_quantity, g, d, p_discount_type, g-d, p_payment_method)
  on conflict (idempotency_key) do nothing;
  select * into s from sales where idempotency_key = p_idempotency_key;
  return s;
end $$;

create or replace function public.update_sale(
  p_id uuid, p_product_id text, p_quantity integer, p_payment_method text,
  p_discount_type text, p_discount_value integer
) returns public.sales language plpgsql security definer set search_path = public as $$
declare p public.products; old_sale public.sales; unit_price integer; g integer; d integer; s public.sales;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into old_sale from sales where id=p_id for update;
  if not found then raise exception 'Sale not found'; end if;
  select * into p from products where id = p_product_id;
  if not found then raise exception 'Product not found'; end if;
  if p_quantity < 1 or p_quantity > 99 then raise exception 'Invalid quantity'; end if;
  if p_payment_method not in ('cash','upi') then raise exception 'Invalid payment method'; end if;
  if p_discount_type not in ('none','per_unit','transaction','final_total') then raise exception 'Invalid discount type'; end if;
  if p_discount_value < 0 then raise exception 'Discount cannot be negative'; end if;
  unit_price := case when p.id = old_sale.product_id then old_sale.original_unit_price else p.price_rupees end;
  g := unit_price * p_quantity;
  d := case p_discount_type when 'per_unit' then p_discount_value * p_quantity when 'transaction' then p_discount_value when 'final_total' then g-p_discount_value else 0 end;
  if d < 0 or d > g then raise exception 'Invalid discount'; end if;
  update sales set product_id=p.id, product_name=p.name, original_unit_price=unit_price, quantity=p_quantity, gross_amount=g, discount_amount=d,
    discount_type=p_discount_type, final_amount=g-d, payment_method=p_payment_method, status='complete', updated_at=now()
  where id=p_id returning * into s;
  if not found then raise exception 'Sale not found'; end if;
  return s;
end $$;

create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  endpoint text not null unique,
  subscription jsonb not null,
  created_at timestamptz not null default now()
);
create table public.daily_summary_settings (
  id integer primary key default 1 check (id = 1),
  summary_time time not null default '21:00',
  last_sent_date date
);
insert into public.daily_summary_settings(id) values(1) on conflict do nothing;

alter table public.products enable row level security;
alter table public.sales enable row level security;
alter table public.sale_audit enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.daily_summary_settings enable row level security;
create policy "signed in can read products" on products for select to authenticated using (true);
create policy "signed in can read sales" on sales for select to authenticated using (true);
create policy "signed in can delete sales" on sales for delete to authenticated using (true);
create policy "signed in can read audit" on sale_audit for select to authenticated using (true);
create policy "signed in can manage subscriptions" on push_subscriptions for all to authenticated using (true) with check (true);
create policy "signed in can manage summary setting" on daily_summary_settings for all to authenticated using (true) with check (true);
grant select on public.products to authenticated;
grant select, delete on public.sales to authenticated;
grant select on public.sale_audit to authenticated;
grant select, insert, update, delete on public.push_subscriptions to authenticated;
grant select, insert, update on public.daily_summary_settings to authenticated;
grant usage, select on sequence public.sale_audit_id_seq to authenticated;
grant execute on function public.create_sale(uuid,text,integer,text,text,integer) to authenticated;
grant execute on function public.update_sale(uuid,text,integer,text,text,integer) to authenticated;
alter publication supabase_realtime add table public.sales;
alter publication supabase_realtime add table public.products;
