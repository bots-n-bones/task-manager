create function public.check_responsible_role() returns trigger language plpgsql set search_path='' as $$
begin
 if new.role<>'admin' and (
 exists(select 1 from public.project_admins where user_id=new.id) or
 exists(select 1 from public.task_admins where user_id=new.id)) then
   raise exception 'Reassign administrator responsibilities before changing role' using errcode='23514';
 end if;
 return new;
end $$;
create trigger check_responsible_role before update of role on public.users for each row execute function public.check_responsible_role();
