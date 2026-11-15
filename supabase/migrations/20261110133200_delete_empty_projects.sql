create function public.delete_empty_project(p_user uuid,p_project bigint)
returns text language plpgsql set search_path='' as $$
begin
  if not exists (select 1 from public.users where id=p_user and active and role='admin') then
    raise exception 'Admin required' using errcode='42501';
  end if;

  -- Serialize deletion with the foreign keys used by tasks and project admins.
  perform 1 from public.projects where id=p_project for update;
  if not found then return 'missing'; end if;
  if exists (select 1 from public.tasks where project_id=p_project) then
    return 'has_tasks';
  end if;

  delete from public.project_admins where project_id=p_project;
  delete from public.projects where id=p_project;
  return 'deleted';
end $$;
revoke all on function public.delete_empty_project(uuid,bigint) from public,anon,authenticated;
grant execute on function public.delete_empty_project(uuid,bigint) to service_role;

do $$
declare definition text;
begin
  select pg_get_functiondef('public.bot_event(bigint,bigint,text,text,text)'::regprocedure) into definition;
  definition:=replace(definition,'chosen jsonb;','chosen jsonb; target_project projects%rowtype; outcome text;');
  definition:=replace(definition,$old$ select * into s from bot_sessions where user_id=u.id;$old$,$new$
 select * into s from bot_sessions where user_id=u.id;
 if p_action in ('project_delete','project_delete_confirm') then
   if u.role is distinct from 'admin' then
     answer:=jsonb_build_object('message','Требуются права администратора.');
   elsif s.user_id is not null then
     answer:=jsonb_build_object('message','Завершите текущую форму или отправьте /cancel.');
   else
     select * into target_project from projects where id::text=p_value;
     if target_project.id is null then
       msg:='Проект уже удалён или недоступен.';
     elsif p_action='project_delete' then
       if exists (select 1 from tasks where project_id=target_project.id) then
         msg:='В проекте есть задачи. Его можно архивировать.';
       else
         answer:=jsonb_build_object('delete_project',jsonb_build_object('id',target_project.id,'name',target_project.name));
       end if;
     else
       outcome:=delete_empty_project(u.id,target_project.id);
       msg:=case outcome when 'deleted' then 'Проект удалён.'
         when 'has_tasks' then 'В проекте есть задачи. Его можно архивировать.'
         else 'Проект уже удалён или недоступен.' end;
     end if;
     answer:=coalesce(answer,jsonb_build_object('message',msg,'projects',team_command_user(u.id,'projects')));
   end if;
   answer:=answer||jsonb_build_object('admin',u.role='admin','actor_id',u.id);
   insert into processed_updates(update_id,state,response) values(p_update,'processed',answer);
   return answer;
 end if;$new$);
  if definition not like '%outcome:=delete_empty_project%' or definition not like '%target_project projects%rowtype%' then
    raise exception 'Unexpected Telegram project command definition';
  end if;
  execute definition;
end $$;

-- Old Telegram messages can still contain archive buttons for a deleted project.
do $$
declare definition text;
begin
  select pg_get_functiondef('public.bot_event_unfiltered(bigint,bigint,text,text,text)'::regprocedure) into definition;
  definition:=replace(definition,$old$   perform team_command(p_actor,'project_archive',jsonb_build_object('id',p_value::bigint,'archived',p_action='archive'));
   answer:=jsonb_build_object('projects',team_command(p_actor,'projects'));$old$,$new$
   perform 1 from projects where id::text=p_value for update;
   if found then
     perform team_command(p_actor,'project_archive',jsonb_build_object('id',p_value::bigint,'archived',p_action='archive'));
   else
     msg:='Проект уже удалён или недоступен.';
   end if;
   answer:=jsonb_build_object('message',msg,'projects',team_command(p_actor,'projects'));$new$);
  if definition not like '%where id::text=p_value for update%' then
    raise exception 'Unexpected Telegram archive command definition';
  end if;
  execute definition;
end $$;
