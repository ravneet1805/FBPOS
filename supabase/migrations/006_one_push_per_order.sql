-- Make the one-time order notification idempotent across request retries/devices.
alter table public.sales add column sale_notification_sent_at timestamptz;

create or replace function public.audit_sale_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into sale_audit(sale_id, action, new_data) values (new.id, 'created', to_jsonb(new)); return new;
  elsif tg_op = 'UPDATE' then
    if (to_jsonb(old) - 'payment_status' - 'sale_notification_sent_at')
       is not distinct from (to_jsonb(new) - 'payment_status' - 'sale_notification_sent_at') then
      return new;
    end if;
    insert into sale_audit(sale_id, action, old_data, new_data)
      values (new.id, 'updated', to_jsonb(old), to_jsonb(new)); return new;
  else
    insert into sale_audit(sale_id, action, old_data) values (old.id, 'deleted', to_jsonb(old)); return old;
  end if;
end $$;

create or replace function public.claim_sale_notification(p_sale_id uuid)
returns setof public.sales language plpgsql security definer set search_path = public as $$
begin
  return query
  update public.sales as sale
  set sale_notification_sent_at = now()
  where sale.id = p_sale_id and sale.sale_notification_sent_at is null
  returning sale.*;
end $$;
revoke all on function public.claim_sale_notification(uuid) from public, anon, authenticated;
grant execute on function public.claim_sale_notification(uuid) to service_role;
