alter function public.bot_event(bigint,bigint,text,text,text) rename to bot_event_reviews;
revoke all on function public.bot_event_reviews(bigint,bigint,text,text,text) from public,anon,authenticated;

create function public.bot_event(p_update bigint,p_actor bigint,p_name text,p_action text,p_value text default '')
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare
 u users%rowtype; s bot_sessions%rowtype; t tasks%rowtype;
 answer jsonb; d jsonb; st text; msg text; parts text[]; value text;
 deadline date; member uuid; chosen uuid[]; options jsonb; page_no int;
begin
 perform pg_advisory_xact_lock(p_actor);
 select response into answer from processed_updates where update_id=p_update;
 if found then return answer; end if;
 select * into u from users where telegram_id=p_actor and active;
 if u.id is null then return bot_event_reviews(p_update,p_actor,p_name,p_action,p_value); end if;
 perform set_config('app.actor',u.id::text,true);
 select * into s from bot_sessions where user_id=u.id;
 page_no:=case when p_value ~ '^[0-9]{1,8}$' then p_value::int else 0 end;
 if p_action in ('today','overdue') and s.user_id is null then
   select jsonb_build_object('page',page_no,'scope',p_action,'tasks',coalesce(jsonb_agg(to_jsonb(q) order by q.number desc),'[]'))
   into answer from (select number,title,status from tasks where is_assignee(tasks.id,u.id)
     and status not in ('done','cancelled')
     and case when p_action='today' then due_date=(now() at time zone 'Europe/Moscow')::date
       else due_date<(now() at time zone 'Europe/Moscow')::date end
     order by number desc limit 6 offset page_no*5) q;
 elsif (p_action='create' and s.user_id is null) or s.step like 'form_%' then
   st:=coalesce(s.step,'form_project'); d:=coalesce(s.draft,jsonb_build_object('assignees',jsonb_build_array(u.id),'important',false,'quick',false));
   parts:=string_to_array(p_value,':'); value:=parts[2];
   if p_action in ('cancel','menu') then st:='menu';
   elsif p_action='start' or (p_action='create' and s.user_id is null) then null;
   elsif p_action in ('pick','flag','next','save','back','abort','skip') and parts[1] is distinct from d->>'token' then
     msg:='Эта кнопка устарела.';
   elsif p_action='abort' then st:='menu';
   elsif p_action='back' then
     st:=case st when 'form_title' then 'form_project' when 'form_description' then 'form_title'
       when 'form_flags' then 'form_description' when 'form_date' then 'form_flags'
       when 'form_assignees' then 'form_date' when 'form_preview' then 'form_assignees' else 'menu' end;
   elsif st='form_project' and p_action='pick' and value ~ '^[0-9]{1,18}$' then
     if exists(select 1 from projects p where p.id=value::bigint and not archived and exists(
       select 1 from project_admins pa join users x on x.id=pa.user_id where pa.project_id=p.id and x.active and x.role='admin')) then
       d:=d || jsonb_build_object('project_id',value::bigint); st:='form_title';
     else msg:='Выберите доступный проект с ответственным администратором.'; end if;
   elsif st='form_title' and p_action='text' then
     if btrim(p_value) !~ '[^[:space:]]' or char_length(p_value)>120 then msg:='Введите название от 1 до 120 символов.';
     else d:=d || jsonb_build_object('title',btrim(p_value)); st:='form_description'; end if;
   elsif st='form_description' and p_action in ('text','skip') then
     if p_action='text' and char_length(p_value)>1000 then msg:='Описание должно содержать до 1000 символов.';
     else d:=d || jsonb_build_object('description',case when p_action='text' then btrim(p_value) end); st:='form_flags'; end if;
   elsif st='form_flags' and p_action='flag' and value in ('important','quick') then
     d:=jsonb_set(d,array[value],to_jsonb(not (d->>value)::boolean));
   elsif st='form_flags' and p_action='next' then st:='form_date';
   elsif st='form_date' and p_action='text' then
     if p_value ~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{4}$' then
       begin deadline:=make_date(substr(p_value,7,4)::int,substr(p_value,4,2)::int,left(p_value,2)::int);
       exception when datetime_field_overflow then deadline:=null; end;
     end if;
     if deadline is null then msg:='Введите существующую дату ДД.ММ.ГГГГ.';
     else d:=d || jsonb_build_object('due_date',deadline); st:='form_assignees'; end if;
   elsif st='form_assignees' and p_action='pick' then
     select id into member from users where id::text=value and active;
     if member is not null then
       if d->'assignees' @> jsonb_build_array(member) then
         select coalesce(jsonb_agg(x),'[]') into options from jsonb_array_elements(d->'assignees') x where x<>to_jsonb(member);
         d:=jsonb_set(d,'{assignees}',options);
       else d:=jsonb_set(d,'{assignees}',d->'assignees'||jsonb_build_array(member)); end if;
     end if;
   elsif st='form_assignees' and p_action='next' then
     if jsonb_array_length(d->'assignees')=0 then msg:='Выберите хотя бы одного исполнителя.';
     else st:='form_preview'; end if;
   elsif st='form_preview' and p_action='save' then
     select array_agg(x::uuid) into chosen from jsonb_array_elements_text(d->'assignees') x;
     if exists(select 1 from unnest(chosen) selected(member_id) where not exists(select 1 from users x where x.id=selected.member_id and active))
       or not exists(select 1 from projects p join project_admins pa on pa.project_id=p.id join users x on x.id=pa.user_id
         where p.id=(d->>'project_id')::bigint and not p.archived and x.active and x.role='admin') then
       msg:='Состав команды или проект изменились. Проверьте форму.';
     else
       insert into processed_updates(update_id) values(p_update);
       insert into tasks(author_id,assignee_id,title,description,due_date,creation_update_id,project_id,important,quick)
       values(u.id,chosen[1],d->>'title',d->>'description',(d->>'due_date')::date,p_update,
         (d->>'project_id')::bigint,(d->>'important')::boolean,(d->>'quick')::boolean) returning * into t;
       insert into task_assignees select t.id,x from unnest(chosen) x on conflict do nothing;
       answer:=jsonb_build_object('message','Задача сохранена.','task',to_jsonb(t)); st:='menu';
     end if;
   else msg:='Завершите форму или нажмите «Отмена».';
   end if;
   d:=d || jsonb_build_object('token',p_update::text);
   if st='menu' then delete from bot_sessions where user_id=u.id;
   else
     insert into bot_sessions(user_id,step,draft) values(u.id,st,d)
     on conflict(user_id) do update set step=excluded.step,draft=excluded.draft;
   end if;
   if st='form_project' then
     select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.id),'[]') into options from projects p where not archived and exists(select 1 from project_admins pa join users x on x.id=pa.user_id where pa.project_id=p.id and x.active and x.role='admin');
   elsif st in ('form_assignees','form_preview') then
     select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'selected',d->'assignees' @> jsonb_build_array(id)) order by name),'[]') into options from users where active;
   end if;
   d:=d || jsonb_build_object('project',(select name from projects where id=(d->>'project_id')::bigint));
   answer:=coalesce(answer,jsonb_build_object('step',st,'draft',d,'options',options,'message',msg));
 else
   answer:=bot_event_reviews(p_update,p_actor,p_name,p_action,p_value);
 end if;
 if answer ? 'task' then
   if u.role='admin' or is_assignee((answer#>>'{task,id}')::uuid,u.id) then
     answer:=jsonb_set(answer,'{task}',team_command(p_actor,'task',jsonb_build_object('number',answer#>>'{task,number}')));
   else
     answer:=jsonb_build_object('message','Задача №'||(answer#>>'{task,number}')||' сохранена. Доступна назначенным исполнителям.','step','menu');
   end if;
 end if;
 answer:=answer || jsonb_build_object('admin',u.role='admin','actor_id',u.id);
 insert into processed_updates(update_id,state,response) values(p_update,'processed',answer)
 on conflict(update_id) do update set state='processed',response=excluded.response;
 return answer;
end $$;
revoke all on function public.bot_event(bigint,bigint,text,text,text) from public,anon,authenticated;
grant execute on function public.bot_event(bigint,bigint,text,text,text) to service_role;
