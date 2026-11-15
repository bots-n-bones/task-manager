alter table public.bot_sessions add column expires_at timestamptz not null default now()+interval '7 days';
create function public.refresh_bot_session() returns trigger language plpgsql set search_path='' as $$
begin new.expires_at:=now()+interval '7 days'; return new; end $$;
create trigger refresh_bot_session before update on public.bot_sessions for each row execute function public.refresh_bot_session();
create function public.check_task_team() returns trigger language plpgsql set search_path='' as $$
declare target uuid;
begin
 if tg_table_name='tasks' then target:=coalesce(new.id,old.id);
 else target:=coalesce(new.task_id,old.task_id); end if;
 if exists(select 1 from public.tasks where id=target) then
   if not exists(select 1 from public.task_assignees where task_id=target) then
     raise exception 'Task requires an assignee' using errcode='23514'; end if;
   if not exists(select 1 from public.task_admins a join public.users u on u.id=a.user_id where a.task_id=target and u.role='admin') then
     raise exception 'Task requires an administrator' using errcode='23514'; end if;
 end if;
 return null;
end $$;
create constraint trigger check_task_assignees after insert or update or delete on public.task_assignees
deferrable initially deferred for each row execute function public.check_task_team();
create constraint trigger check_task_admins after insert or update or delete on public.task_admins
deferrable initially deferred for each row execute function public.check_task_team();
create constraint trigger check_new_task_team after insert or update on public.tasks
deferrable initially deferred for each row execute function public.check_task_team();

do $$
declare definition text; signature text;
begin
 select pg_get_functiondef('public.bot_event(bigint,bigint,text,text,text)'::regprocedure) into definition;
 definition:=replace(definition,'begin
 if p_action', 'begin
 delete from public.bot_sessions where user_id in(select id from public.users where telegram_id=p_actor) and expires_at<=now();
 if p_action');
 execute definition;
 foreach signature in array array['public.attachment_access(bigint,uuid)','public.attachment_access_user(uuid,uuid)'] loop
 select pg_get_functiondef(signature::regprocedure) into definition;
 definition:=replace(definition,'and step=''result''','and step=''result'' and expires_at>now()');
 execute definition;
 end loop;
end $$;
