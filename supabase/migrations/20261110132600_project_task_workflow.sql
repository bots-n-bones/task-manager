alter table public.tasks add column renewable boolean not null default false;
alter table public.tasks add constraint tasks_duration_exclusive check (not (quick and renewable));

-- Preserve the existing permissions, response caching and version checks.
do $$
declare
 signature text;
 definition text;
begin
 foreach signature in array array['public.team_command(bigint,text,jsonb)', 'public.team_command_user(uuid,text,jsonb)'] loop
   select pg_get_functiondef(signature::regprocedure) into definition;
   definition:=replace(definition,
     'quick=coalesce((p_data->>''quick'')::boolean,quick),',
     'quick=coalesce((p_data->>''quick'')::boolean,quick),
      renewable=coalesce((p_data->>''renewable'')::boolean,
        case when (p_data->>''quick'')::boolean then false else renewable end),');
   definition:=replace(definition,
     'from public.task_attachments a where a.task_id=t.id)',
     'from public.task_attachments a where t.status<>''in_progress'' and a.result_id=(
       select r.id from public.task_results r where r.task_id=t.id order by r.version desc limit 1))');
   definition:=replace(definition,
     'return to_jsonb(t) || jsonb_build_object(',
     'return to_jsonb(t) || jsonb_build_object(''result'',case when t.status<>''in_progress'' then t.result end,');
   if definition not like '%renewable=coalesce%' or definition not like '%a.result_id=%'
      or definition not like '%then t.result end%' then
     raise exception 'Unexpected task card or edit definition: %',signature;
   end if;
   execute definition;
 end loop;

 select pg_get_functiondef('public.task_api(uuid,text,jsonb,uuid)'::regprocedure) into definition;
 definition:=replace(definition,
   'and (not(p_data ? ''quick'') or listed.quick=(p_data->>''quick'')::boolean)',
   'and (not(p_data ? ''quick'') or listed.quick=(p_data->>''quick'')::boolean)
    and (not(p_data ? ''renewable'') or listed.renewable=(p_data->>''renewable'')::boolean)');
 definition:=replace(definition,'project_id,important,quick)','project_id,important,quick,renewable)');
 definition:=replace(definition,'coalesce((p_data->>''quick'')::boolean,false)) returning',
   'coalesce((p_data->>''quick'')::boolean,false),coalesce((p_data->>''renewable'')::boolean,false)) returning');
 if definition not like '%listed.renewable=%' or definition not like '%project_id,important,quick,renewable)%'
    or definition not like '%coalesce((p_data->>''renewable'')::boolean,false)) returning%' then
   raise exception 'Unexpected task API definition';
 end if;
 execute definition;

 select pg_get_functiondef('public.bot_event_unfiltered(bigint,bigint,text,text,text)'::regprocedure) into definition;
 definition:=replace(definition,'options jsonb; page_no int;', 'options jsonb; page_no int; selected_project projects%rowtype;');
 definition:=replace(definition,'''quick'',t.quick,''due_date''','''quick'',t.quick,''renewable'',t.renewable,''due_date''');
 definition:=replace(definition,$old$ elsif p_action='projects' and s.user_id is null then$old$,$new$
 elsif p_action='project_open' and s.user_id is null then
   select * into selected_project from projects where id::text=split_part(p_value,':',1);
   page_no:=case when split_part(p_value,':',2) ~ '^[0-9]{1,8}$'
     then split_part(p_value,':',2)::int else 0 end;
   if selected_project.id is null then
     answer:=jsonb_build_object('message','Проект недоступен.','projects',team_command(p_actor,'projects'));
   else
     select jsonb_build_object('page',page_no,'scope','project_open:'||selected_project.id,
       'selected_project',to_jsonb(selected_project),'tasks',coalesce(jsonb_agg(to_jsonb(q) order by q.number desc),'[]'))
       into answer from (
         select number,title,status from tasks where project_id=selected_project.id
           and (u.role='admin' or is_assignee(tasks.id,u.id))
         order by number desc limit 6 offset page_no*5
       ) q;
   end if;
 elsif p_action='projects' and s.user_id is null then$new$);
 definition:=replace(definition,$old$   parts:=string_to_array(p_value,':'); value:=parts[2];$old$,$new$
   if p_action='create' and s.user_id is null and p_value<>'' then
     select p.* into selected_project from projects p where p.id::text=p_value and not p.archived and exists(
       select 1 from project_admins pa join users x on x.id=pa.user_id
       where pa.project_id=p.id and x.active and x.role='admin');
     if selected_project.id is null then
       msg:='Проект недоступен. Выберите другой проект.';
     else
       d:=d||jsonb_build_object('project_id',selected_project.id); st:='form_title';
     end if;
   end if;
   parts:=string_to_array(p_value,':'); value:=parts[2];$new$);
 definition:=replace(definition,$old$   elsif st='form_flags' and p_action='flag' and value in ('important','quick') then
     d:=jsonb_set(d,array[value],to_jsonb(not (d->>value)::boolean));$old$,$new$
   elsif st='form_flags' and p_action='flag' and value in ('important','neutral','quick','renewable','ordinary') then
     if value in ('important','neutral') then
       d:=d||jsonb_build_object('important',value='important');
     else
       d:=d||jsonb_build_object('quick',value='quick','renewable',value='renewable');
     end if;$new$);
 definition:=replace(definition,'project_id,important,quick)','project_id,important,quick,renewable)');
 definition:=replace(definition,'(d->>''quick'')::boolean) returning',
   '(d->>''quick'')::boolean,coalesce((d->>''renewable'')::boolean,false)) returning');
 if definition not like '%selected_project projects%rowtype%' or definition not like '%''selected_project'',to_jsonb%'
    or definition not like '%''renewable'',t.renewable%' or definition not like '%''renewable'',value=''renewable''%'
    or definition not like '%coalesce((d->>''renewable'')::boolean,false)) returning%' then
   raise exception 'Unexpected Telegram workflow definition';
 end if;
 execute definition;
end $$;
