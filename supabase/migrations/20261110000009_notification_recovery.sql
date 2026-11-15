-- A final attempt interrupted by process termination must reach a terminal state.
create function public.notification_expire() returns trigger language plpgsql set search_path='' as $$
begin
 update public.notification_deliveries set state='failed',error='Delivery lease expired',lease_token=null,lease_until=null
 where state='sending' and attempts>=5 and lease_until<now();
 return null;
end $$;
create trigger notification_expire after insert on public.notification_deliveries
for each statement execute function public.notification_expire();
-- Restore delivery availability when a user contacts the bot again.
create function public.restore_telegram_delivery() returns trigger language plpgsql set search_path='' as $$
begin
 new.telegram_available:=true;
 return new;
end $$;
create trigger restore_telegram_delivery before update of name on public.users
for each row execute function public.restore_telegram_delivery();
