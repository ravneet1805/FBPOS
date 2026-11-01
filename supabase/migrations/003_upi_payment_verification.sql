alter table public.sales
  add column payment_status text,
  add column upi_last_reminded_at timestamptz;

-- Reminder timestamps and verification alone are operational state, not member audit events.
create or replace function public.audit_sale_change() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into sale_audit(sale_id, action, new_data) values (new.id, 'created', to_jsonb(new)); return new;
  elsif tg_op = 'UPDATE' then
    if (to_jsonb(old) - 'payment_status' - 'upi_last_reminded_at')
       is not distinct from (to_jsonb(new) - 'payment_status' - 'upi_last_reminded_at') then
      return new;
    end if;
    insert into sale_audit(sale_id, action, old_data, new_data)
      values (new.id, 'updated', to_jsonb(old), to_jsonb(new)); return new;
  else
    insert into sale_audit(sale_id, action, old_data) values (old.id, 'deleted', to_jsonb(old)); return old;
  end if;
end $$;

-- Existing UPI sales predate verification; preserve them as already settled.
update public.sales
set payment_status = case when payment_method = 'upi' then 'verified' else null end;

alter table public.sales
  add constraint sales_payment_status_check check (
    (payment_method = 'upi' and payment_status in ('pending', 'verified'))
    or (payment_method = 'cash' and payment_status is null)
  );

create index sales_pending_upi_idx on public.sales (created_at desc)
  where payment_method = 'upi' and payment_status = 'pending' and status = 'complete';

create table public.upi_reminder_settings (
  id integer primary key default 1 check (id = 1),
  reminder_interval_minutes smallint not null default 2 check (reminder_interval_minutes between 1 and 60),
  updated_at timestamptz not null default now()
);
insert into public.upi_reminder_settings (id) values (1) on conflict do nothing;
alter table public.upi_reminder_settings enable row level security;
create policy "signed in can read UPI reminder settings" on public.upi_reminder_settings
  for select to authenticated using (true);
create policy "signed in can update UPI reminder settings" on public.upi_reminder_settings
  for update to authenticated using (true) with check (true);
grant select, update on public.upi_reminder_settings to authenticated;

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
  insert into sales(idempotency_key, product_id, product_name, original_unit_price, quantity, gross_amount,
    discount_amount, discount_type, final_amount, payment_method, payment_status, upi_last_reminded_at)
  values (p_idempotency_key, p.id, p.name, p.price_rupees, p_quantity, g, d, p_discount_type, g-d,
    p_payment_method, case when p_payment_method = 'upi' then 'pending' else null end,
    case when p_payment_method = 'upi' then now() else null end)
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
  select * into old_sale from sales where id = p_id for update;
  if not found then raise exception 'Sale not found'; end if;
  select * into p from products where id = p_product_id;
  if not found then raise exception 'Product not found'; end if;
  if p_quantity < 1 or p_quantity > 99 then raise exception 'Invalid quantity'; end if;
  if p_payment_method not in ('cash','upi') then raise exception 'Invalid payment method'; end if;
  if p_discount_type not in ('none','per_unit','transaction','final_total') then raise exception 'Invalid discount type'; end if;
  if p_discount_value < 0 then raise exception 'Discount cannot be negative'; end if;
  unit_price := case when p.id = old_sale.product_id then old_sale.original_unit_price else p.price_rupees end;
  g := unit_price * p_quantity;
  d := case p_discount_type when 'per_unit' then p_discount_value * p_quantity
       when 'transaction' then p_discount_value when 'final_total' then g-p_discount_value else 0 end;
  if d < 0 or d > g then raise exception 'Invalid discount'; end if;
  update sales set product_id=p.id, product_name=p.name, original_unit_price=unit_price, quantity=p_quantity,
    gross_amount=g, discount_amount=d, discount_type=p_discount_type, final_amount=g-d,
    payment_method=p_payment_method,
    payment_status=case when p_payment_method='cash' then null
      when old_sale.payment_method='upi' then old_sale.payment_status else 'pending' end,
    upi_last_reminded_at=case when p_payment_method='cash' then null
      when old_sale.payment_method='upi' then old_sale.upi_last_reminded_at else now() end,
    status='complete', updated_at=now()
  where id=p_id returning * into s;
  return s;
end $$;

create or replace function public.verify_upi_payment(p_id uuid)
returns public.sales language plpgsql security definer set search_path = public as $$
declare s public.sales;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  update sales set payment_status='verified'
  where id=p_id and payment_method='upi' and payment_status='pending' and status='complete'
  returning * into s;
  if not found then raise exception 'UPI payment is no longer pending'; end if;
  return s;
end $$;
grant execute on function public.verify_upi_payment(uuid) to authenticated;

-- Claim due reminders atomically so simultaneous active devices cannot notify twice.
create or replace function public.claim_due_upi_reminders()
returns setof public.sales language plpgsql security definer set search_path = public as $$
declare interval_minutes smallint;
begin
  select reminder_interval_minutes into interval_minutes from upi_reminder_settings where id=1;
  return query
  with due as (
    select id from sales
    where payment_method='upi' and payment_status='pending' and status='complete'
      and (upi_last_reminded_at is null
        or upi_last_reminded_at <= now() - make_interval(mins => interval_minutes))
    order by upi_last_reminded_at nulls first, created_at
    for update skip locked limit 100
  )
  update sales s set upi_last_reminded_at=now()
  from due where s.id=due.id returning s.*;
end $$;
revoke all on function public.claim_due_upi_reminders() from public, anon, authenticated;
grant execute on function public.claim_due_upi_reminders() to service_role;

alter publication supabase_realtime add table public.upi_reminder_settings;
