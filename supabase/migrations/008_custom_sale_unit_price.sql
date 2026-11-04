-- Add price-override RPC overloads while keeping the existing default-price signatures
-- available to older clients during deployment.
create or replace function public.create_sale(
  p_idempotency_key uuid,
  p_product_id text,
  p_quantity integer,
  p_payment_method text,
  p_discount_type text,
  p_discount_value integer,
  p_unit_price integer
) returns public.sales language plpgsql security definer set search_path = public as $$
declare p public.products; g integer; d integer; s public.sales;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into p from products where id=p_product_id and active;
  if not found then raise exception 'Product unavailable'; end if;
  if p_quantity < 1 or p_quantity > 99 then raise exception 'Quantity must be between 1 and 99'; end if;
  if p_payment_method not in ('cash','upi') then raise exception 'Invalid payment method'; end if;
  if p_discount_type not in ('none','per_unit','transaction','final_total') then raise exception 'Invalid discount type'; end if;
  if p_unit_price is null or p_unit_price < 0 then raise exception 'Unit price cannot be negative'; end if;
  if p_discount_value < 0 then raise exception 'Discount cannot be negative'; end if;
  g := p_unit_price * p_quantity;
  d := case p_discount_type when 'per_unit' then p_discount_value*p_quantity
       when 'transaction' then p_discount_value when 'final_total' then g-p_discount_value else 0 end;
  if d < 0 or d > g then raise exception 'Discount cannot exceed gross amount'; end if;
  insert into sales(idempotency_key, product_id, product_name, original_unit_price, quantity, gross_amount,
    discount_amount, discount_type, final_amount, payment_method, payment_status)
  values (p_idempotency_key, p.id, p.name, p_unit_price, p_quantity, g, d, p_discount_type, g-d,
    p_payment_method, case when p_payment_method='upi' then 'pending' else null end)
  on conflict (idempotency_key) do nothing;
  select * into s from sales where idempotency_key=p_idempotency_key;
  return s;
end $$;
revoke all on function public.create_sale(uuid,text,integer,text,text,integer,integer) from public, anon;
grant execute on function public.create_sale(uuid,text,integer,text,text,integer,integer) to authenticated;

create or replace function public.update_sale(
  p_id uuid,
  p_product_id text,
  p_quantity integer,
  p_payment_method text,
  p_discount_type text,
  p_discount_value integer,
  p_unit_price integer
) returns public.sales language plpgsql security definer set search_path = public as $$
declare p public.products; old_sale public.sales; g integer; d integer; s public.sales;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into old_sale from sales where id=p_id for update;
  if not found then raise exception 'Sale not found'; end if;
  select * into p from products where id=p_product_id;
  if not found then raise exception 'Product not found'; end if;
  if p_quantity < 1 or p_quantity > 99 then raise exception 'Quantity must be between 1 and 99'; end if;
  if p_payment_method not in ('cash','upi') then raise exception 'Invalid payment method'; end if;
  if p_discount_type not in ('none','per_unit','transaction','final_total') then raise exception 'Invalid discount type'; end if;
  if p_unit_price is null or p_unit_price < 0 then raise exception 'Unit price cannot be negative'; end if;
  if p_discount_value < 0 then raise exception 'Discount cannot be negative'; end if;
  g := p_unit_price*p_quantity;
  d := case p_discount_type when 'per_unit' then p_discount_value*p_quantity
       when 'transaction' then p_discount_value when 'final_total' then g-p_discount_value else 0 end;
  if d < 0 or d > g then raise exception 'Invalid discount'; end if;
  update sales set product_id=p.id, product_name=p.name, original_unit_price=p_unit_price, quantity=p_quantity,
    gross_amount=g, discount_amount=d, discount_type=p_discount_type, final_amount=g-d,
    payment_method=p_payment_method,
    payment_status=case when p_payment_method='cash' then null
      when old_sale.payment_method='upi' then old_sale.payment_status else 'pending' end,
    status='complete', updated_at=now()
  where id=p_id returning * into s;
  return s;
end $$;
revoke all on function public.update_sale(uuid,text,integer,text,text,integer,integer) from public, anon;
grant execute on function public.update_sale(uuid,text,integer,text,text,integer,integer) to authenticated;

notify pgrst, 'reload schema';
