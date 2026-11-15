create or replace function public.delete_empty_project(p_user uuid,p_project bigint)
returns text language plpgsql set search_path='' as $$
begin
  if not exists (select 1 from public.users where id=p_user and active and role='admin') then
    raise exception 'Admin required' using errcode='42501';
  end if;
  perform 1 from public.projects where id=p_project for update;
  if not found then return 'missing'; end if;

  -- Project deletion is intentionally cascade-like, while keeping the FKs strict.
  delete from public.task_attachments where task_id in (select id from public.tasks where project_id=p_project);
  delete from public.notification_deliveries where task_id in (select id from public.tasks where project_id=p_project);
  delete from public.task_reviews where task_id in (select id from public.tasks where project_id=p_project);
  delete from public.task_events where task_id in (select id from public.tasks where project_id=p_project);
  delete from public.task_results where task_id in (select id from public.tasks where project_id=p_project);
  delete from public.task_assignees where task_id in (select id from public.tasks where project_id=p_project);
  delete from public.task_admins where task_id in (select id from public.tasks where project_id=p_project);
  delete from public.tasks where project_id=p_project;
  delete from public.project_admins where project_id=p_project;
  delete from public.projects where id=p_project;
  return 'deleted';
end $$;

do $$
declare definition text;
begin
  select pg_get_functiondef('public.bot_event(bigint,bigint,text,text,text)'::regprocedure) into definition;
  definition:=replace(definition,
    $old$if exists (select 1 from tasks where project_id=target_project.id) then
         msg:='В проекте есть задачи. Его можно архивировать.';$old$,
    $new$if false then
         msg:='В проекте есть задачи. Его можно архивировать.';$new$);
  definition:=replace(definition,
    $old$outcome:=delete_empty_project(u.id,target_project.id);
       msg:=case outcome when 'deleted' then 'Проект удалён.'
         when 'has_tasks' then 'В проекте есть задачи. Его можно архивировать.'$old$,
    $new$outcome:=delete_empty_project(u.id,target_project.id);
       msg:=case outcome when 'deleted' then 'Проект удалён.'
         when 'has_tasks' then 'Проект не удалось удалить.'$new$);
  execute definition;
end $$;
