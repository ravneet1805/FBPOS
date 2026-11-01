-- Ensure human-readable order references exist even on projects that applied
-- later migrations out of sequence or had an earlier migration partially applied.
create sequence if not exists public.sale_order_number_seq start with 1;
alter table public.sales add column if not exists order_number text;

with existing as (
  select coalesce(max(substring(order_number from '-([0-9]+)$')::bigint), 0) as max_no
  from public.sales where order_number is not null
), missing as (
  select s.id, s.product_id, s.product_name,
    row_number() over (order by s.created_at, s.id) as row_no,
    existing.max_no
  from public.sales s cross join existing
  where s.order_number is null
)
update public.sales s
set order_number =
  (case missing.product_id when 'blazer' then 'BLA' when 'waistcoat' then 'WAI' when 'perfume' then 'PER'
    else upper(left(coalesce(nullif(missing.product_name, ''), 'SAL'), 3)) end)
  || '-' || lpad((missing.max_no + missing.row_no)::text, 4, '0')
from missing
where s.id = missing.id;

alter table public.sales alter column order_number set not null;
create unique index if not exists sales_order_number_key on public.sales(order_number);

-- Continue after both existing references and any sequence values already allocated.
do $$
declare max_number bigint; current_value bigint; was_called boolean; next_value bigint;
begin
  select coalesce(max(substring(order_number from '-([0-9]+)$')::bigint), 0)
    into max_number from public.sales;
  select last_value, is_called into current_value, was_called from public.sale_order_number_seq;
  next_value := greatest(max_number + 1, case when was_called then current_value + 1 else current_value end);
  perform setval('public.sale_order_number_seq', next_value, false);
end $$;

create or replace function public.assign_sale_order_number()
returns trigger language plpgsql security definer set search_path = public as $$
declare prefix text;
begin
  prefix := case new.product_id when 'blazer' then 'BLA' when 'waistcoat' then 'WAI' when 'perfume' then 'PER'
    else upper(left(coalesce(nullif(new.product_name, ''), 'SAL'), 3)) end;
  new.order_number := prefix || '-' || lpad(nextval('public.sale_order_number_seq')::text, 4, '0');
  return new;
end $$;
drop trigger if exists sales_assign_order_number on public.sales;
create trigger sales_assign_order_number
before insert on public.sales
for each row execute function public.assign_sale_order_number();

notify pgrst, 'reload schema';
