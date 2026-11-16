begin;
alter table public.projects add column visibility text not null default 'shared' check (visibility in ('shared','personal'));
alter table public.projects add column created_by uuid references public.users on delete set null;
alter table public.tasks add column working_links jsonb not null default '[]';
alter table public.tasks drop constraint tasks_status_check;
alter table public.tasks add constraint tasks_status_check check(status in ('new','in_progress','recurring','review','done','cancelled'));

create function public.can_view_project(p_project bigint,p_user uuid) returns boolean
language sql stable set search_path='' as $$
 select exists(select 1 from public.projects p join public.users u on u.id=p_user and u.active
 where p.id=p_project and (p.visibility='shared' or p.created_by=p_user
 or exists(select 1 from public.project_admins a where a.project_id=p.id and a.user_id=p_user)
 or exists(select 1 from public.tasks t join public.task_assignees a on a.task_id=t.id where t.project_id=p.id and a.user_id=p_user)
 or exists(select 1 from public.tasks t join public.task_admins a on a.task_id=t.id where t.project_id=p.id and a.user_id=p_user)));
$$;
create function public.can_view_task(p_task uuid,p_user uuid) returns boolean
language sql stable set search_path='' as $$
 select exists(select 1 from public.tasks t join public.users u on u.id=p_user and u.active
 where t.id=p_task and public.can_view_project(t.project_id,p_user) and
 (u.role='admin' or public.is_assignee(t.id,p_user)));
$$;
create function public.valid_working_links(links jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare item jsonb;
begin
 if jsonb_typeof(links) is distinct from 'array' then return false; end if;
 if jsonb_array_length(links)>20 then return false; end if;
 for item in select value from jsonb_array_elements(links) loop
   if jsonb_typeof(item) is distinct from 'object'
      or jsonb_typeof(item->'title') is distinct from 'string'
      or length(btrim(item->>'title')) not between 1 and 120
      or jsonb_typeof(item->'url') is distinct from 'string'
      or length(item->>'url') not between 8 and 2048
      or item->>'url' !~ '^https?://[^/[:space:]]+'
      or item->>'url' ~ '[[:space:]]' then return false; end if;
 end loop;
 return true;
end $$;
alter table public.tasks add constraint tasks_working_links_check check(public.valid_working_links(working_links));
revoke all on function public.can_view_project(bigint,uuid) from public,anon,authenticated;
grant execute on function public.can_view_project(bigint,uuid) to service_role;
revoke all on function public.can_view_task(uuid,uuid) from public,anon,authenticated;
grant execute on function public.can_view_task(uuid,uuid) to service_role;
revoke all on function public.valid_working_links(jsonb) from public,anon,authenticated;
grant execute on function public.valid_working_links(jsonb) to service_role;
CREATE OR REPLACE FUNCTION public.guard_task_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare actor uuid;
begin
 actor := nullif(current_setting('app.actor',true),'')::uuid;
 if actor is not null and new.project_id is not null and not public.can_view_project(new.project_id,actor) then
   raise exception 'Project unavailable' using errcode='42501';
 end if;
 if tg_op='INSERT' then
   if new.status <> 'new' then raise exception 'A task must start in new status' using errcode='23514'; end if;
   if new.renewable then new.status:='recurring'; end if;
   new.version:=1;
 else
   if new.status=old.status and old.status in ('new','in_progress','recurring') and new.renewable is distinct from old.renewable then
     new.status:=case when new.renewable then 'recurring' else 'in_progress' end;
   end if;
   if new.status='new' and new.renewable then new.status:='recurring'; end if;
   if new.status <> old.status and not (
     (old.status in ('new','in_progress') and new.status='recurring' and new.renewable) or
     (old.status='recurring' and new.status='in_progress' and not new.renewable) or
     (old.status='recurring' and new.status='review') or
     (old.status='recurring' and new.status='done' and exists(select 1 from public.users where id=actor and role='admin' and active)) or
     (old.status='cancelled' and new.status in ('new','recurring') and exists(
       select 1 from public.users where id=actor and active and (role='admin' or id=old.author_id))) or
     (old.status='new' and new.status='in_progress') or
     (old.status='in_progress' and new.status='review') or
     (old.status='review' and new.status in ('done','in_progress','recurring') and exists(select 1 from public.users where id=actor and role='admin' and active)) or
     (old.status in ('new','in_progress','recurring','review') and new.status='cancelled' and exists(select 1 from public.users where id=actor and active and (role='admin' or id=old.author_id)))
   ) then raise exception 'Invalid task status transition' using errcode='23514'; end if;
   if new.creation_update_id <> old.creation_update_id or new.created_at <> old.created_at then
     raise exception 'Immutable task fields' using errcode='23514';
   end if;
   if old.status='done' or (old.status='cancelled' and new.status not in ('new','recurring')) then raise exception 'Task is closed' using errcode='23514'; end if;
   new.version:=old.version+1;
   new.updated_at:=clock_timestamp();
 end if;
 return new;
end $function$;
CREATE OR REPLACE FUNCTION public.team_command_user(p_user uuid, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 u users%rowtype;
 t tasks%rowtype;
 p projects%rowtype;
 items jsonb;
 ids uuid[];
 admins uuid[];
begin
 select * into u from users where id=p_user and active;
 if not found then raise exception 'Access denied' using errcode='42501'; end if;
 perform set_config('app.actor',u.id::text,true);
 if p_action='members' then
   select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'role',role) order by name),'[]') into items from users where active;
   return items;
 elsif p_action='projects' then
   select coalesce(jsonb_agg(to_jsonb(q) || jsonb_build_object('admins',(select coalesce(jsonb_agg(pa.user_id),'[]') from public.project_admins pa where pa.project_id=q.id)) order by q.id),'[]') into items from projects q where (not archived or u.role='admin') and can_view_project(q.id,u.id);
   return items;
 elsif p_action='project_visibility' then
   if u.role<>'admin' or not can_view_project((p_data->>'id')::bigint,u.id) then raise exception 'Admin required' using errcode='42501'; end if;
   update projects set visibility=p_data->>'visibility' where id=(p_data->>'id')::bigint returning * into p;
   return to_jsonb(p);
 elsif p_action='project_create' then
   if u.role<>'admin' then raise exception 'Admin required' using errcode='42501'; end if;
   if p_data ? 'admins' then
     select array_agg(distinct value::uuid) into admins from jsonb_array_elements_text(p_data->'admins');
   elsif u.role='admin' then admins:=array[u.id];
   else select array_agg(id) into admins from users where active and role='admin';
   end if;
   if coalesce(cardinality(admins),0)=0 or exists(
     select 1 from unnest(admins) selected(member_id) where not exists(
       select 1 from users where id=selected.member_id and active and role='admin')) then
     raise exception 'Select an active responsible administrator.' using errcode='23514';
   end if;
   insert into projects(name,description,visibility,created_by) values(btrim(p_data->>'name'),p_data->>'description',coalesce(p_data->>'visibility','shared'),u.id) returning * into p;
   insert into project_admins select p.id,id from unnest(admins) id;
   return to_jsonb(p);
 elsif p_action in ('project_archive','project_admins') then
   if u.role <> 'admin' then raise exception 'Admin required' using errcode='42501'; end if;
   select * into strict p from projects where id=(p_data->>'id')::bigint and can_view_project(id,u.id) for update;
   if p_action='project_archive' then
     update projects set archived=(p_data->>'archived')::boolean where id=p.id returning * into p;
   else
     select array_agg(value::uuid) into admins from jsonb_array_elements_text(p_data->'admins');
     if coalesce(cardinality(admins),0)=0 or exists(select 1 from unnest(admins) selected(member_id) where not exists(select 1 from users where users.id=selected.member_id and role='admin' and active)) then
       raise exception 'Active administrators required' using errcode='23514';
     end if;
     delete from project_admins where project_id=p.id;
     insert into project_admins select p.id,id from unnest(admins) id;
   end if;
   return to_jsonb(p);
 end if;
 select * into t from tasks where number=(p_data->>'number')::bigint for update;
 if not found or not can_view_task(t.id,u.id) then raise exception 'Task unavailable' using errcode='42501'; end if;
 if p_action='task' then
   return to_jsonb(t) || jsonb_build_object('latest_review',public.task_latest_review(t.id),
     'reviews',(select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('reviewer_name',reviewer.name) order by r.result_version desc),'[]')
       from public.task_reviews r join public.users reviewer on reviewer.id=r.reviewer_id where r.task_id=t.id),
     'result',case when t.status<>'in_progress' then t.result end,
     'attachments',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'name',a.name)),'[]') from public.task_attachments a where t.status<>'in_progress' and t.result is not null and a.result_id=(
       select r.id from public.task_results r where r.task_id=t.id order by r.version desc limit 1)),
     'project',(select name from projects where id=t.project_id),
     'assignees',(select jsonb_agg(jsonb_build_object('id',x.id,'name',x.name)) from users x join task_assignees a on a.user_id=x.id where a.task_id=t.id),
     'admins',(select jsonb_agg(jsonb_build_object('id',x.id,'name',x.name)) from users x join task_admins a on a.user_id=x.id where a.task_id=t.id));
 elsif p_action='history' then
   select coalesce(jsonb_agg(to_jsonb(e) order by e.id),'[]') into items from task_events e where task_id=t.id;
   return items;
 elsif p_action <> 'edit' then raise exception 'Unknown action'; end if;
 if not(u.role='admin' or t.author_id=u.id) then raise exception 'Editing denied' using errcode='42501'; end if;
 if t.version is distinct from (p_data->>'version')::bigint then raise exception 'Version conflict' using errcode='40001'; end if;
 if p_data ? 'assignees' then
   select array_agg(value::uuid) into ids from jsonb_array_elements_text(p_data->'assignees');
   if coalesce(cardinality(ids),0)=0 or exists(select 1 from unnest(ids) selected(member_id) where not exists(select 1 from users where users.id=selected.member_id and active)) then
     raise exception 'Active assignees required' using errcode='23514';
   end if;
 end if;
 if p_data ? 'project_id' then
   select * into p from projects where id=(p_data->>'project_id')::bigint and not archived and can_view_project(id,u.id);
   if not found or not exists(select 1 from project_admins pa join users x on x.id=pa.user_id where pa.project_id=p.id and x.active and x.role='admin') then
     raise exception 'Project with active administrators required' using errcode='23514';
   end if;
 end if;
 if p_data ? 'admins' then
   if u.role <> 'admin' then raise exception 'Admin required' using errcode='42501'; end if;
   select array_agg(value::uuid) into admins from jsonb_array_elements_text(p_data->'admins');
   if coalesce(cardinality(admins),0)=0 or exists(select 1 from unnest(admins) selected(member_id) where not exists(select 1 from users where users.id=selected.member_id and role='admin' and active)) then
     raise exception 'Active administrators required' using errcode='23514';
   end if;
 end if;
 update tasks set title=case when p_data ? 'title' then p_data->>'title' else title end,
 description=case when p_data ? 'description' then p_data->>'description' else description end,
 due_date=case when p_data ? 'due_date' then (p_data->>'due_date')::date else due_date end,
 important=coalesce((p_data->>'important')::boolean,important),
 quick=coalesce((p_data->>'quick')::boolean,quick),
      renewable=coalesce((p_data->>'renewable')::boolean,
        case when (p_data->>'quick')::boolean then false else renewable end),
 project_id=coalesce(p.id,project_id),
 assignee_id=coalesce(ids[1],assignee_id) where id=t.id returning * into t;
 if ids is not null then
   delete from task_assignees where task_id=t.id;
   insert into task_assignees select t.id,id from unnest(ids) id;
 end if;
 if admins is not null or p.id is not null then
   delete from task_admins where task_id=t.id;
   if admins is not null then insert into task_admins select t.id,id from unnest(admins) id;
   else insert into task_admins select t.id,user_id from project_admins where project_id=p.id; end if;
 end if;
 insert into task_events(task_id,actor_id,event,changes) values(t.id,u.id,'team_edit',p_data);
 return to_jsonb(t);
end $function$;
CREATE OR REPLACE FUNCTION public.team_command(p_actor bigint, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 u users%rowtype;
 t tasks%rowtype;
 p projects%rowtype;
 items jsonb;
 ids uuid[];
 admins uuid[];
begin
 select * into u from users where telegram_id=p_actor and active;
 if not found then raise exception 'Access denied' using errcode='42501'; end if;
 perform set_config('app.actor',u.id::text,true);
 if p_action='members' then
   select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'role',role) order by name),'[]') into items from users where active;
   return items;
 elsif p_action='projects' then
   select coalesce(jsonb_agg(to_jsonb(q) || jsonb_build_object('admins',(select coalesce(jsonb_agg(pa.user_id),'[]') from public.project_admins pa where pa.project_id=q.id)) order by q.id),'[]') into items from projects q where (not archived or u.role='admin') and can_view_project(q.id,u.id);
   return items;
 elsif p_action='project_visibility' then
   if u.role<>'admin' or not can_view_project((p_data->>'id')::bigint,u.id) then raise exception 'Admin required' using errcode='42501'; end if;
   update projects set visibility=p_data->>'visibility' where id=(p_data->>'id')::bigint returning * into p;
   return to_jsonb(p);
 elsif p_action='project_create' then
   if u.role<>'admin' then raise exception 'Admin required' using errcode='42501'; end if;
   if p_data ? 'admins' then
     select array_agg(distinct value::uuid) into admins from jsonb_array_elements_text(p_data->'admins');
   elsif u.role='admin' then admins:=array[u.id];
   else select array_agg(id) into admins from users where active and role='admin';
   end if;
   if coalesce(cardinality(admins),0)=0 or exists(
     select 1 from unnest(admins) selected(member_id) where not exists(
       select 1 from users where id=selected.member_id and active and role='admin')) then
     raise exception 'Select an active responsible administrator.' using errcode='23514';
   end if;
   insert into projects(name,description,visibility,created_by) values(btrim(p_data->>'name'),p_data->>'description',coalesce(p_data->>'visibility','shared'),u.id) returning * into p;
   insert into project_admins select p.id,id from unnest(admins) id;
   return to_jsonb(p);
 elsif p_action in ('project_archive','project_admins') then
   if u.role <> 'admin' then raise exception 'Admin required' using errcode='42501'; end if;
   select * into strict p from projects where id=(p_data->>'id')::bigint and can_view_project(id,u.id) for update;
   if p_action='project_archive' then
     update projects set archived=(p_data->>'archived')::boolean where id=p.id returning * into p;
   else
     select array_agg(value::uuid) into admins from jsonb_array_elements_text(p_data->'admins');
     if coalesce(cardinality(admins),0)=0 or exists(select 1 from unnest(admins) selected(member_id) where not exists(select 1 from users where users.id=selected.member_id and role='admin' and active)) then
       raise exception 'Active administrators required' using errcode='23514';
     end if;
     delete from project_admins where project_id=p.id;
     insert into project_admins select p.id,id from unnest(admins) id;
   end if;
   return to_jsonb(p);
 end if;
 select * into t from tasks where number=(p_data->>'number')::bigint for update;
 if not found or not can_view_task(t.id,u.id) then raise exception 'Task unavailable' using errcode='42501'; end if;
 if p_action='task' then
   return to_jsonb(t) || jsonb_build_object('result',case when t.status<>'in_progress' then t.result end,
     'attachments',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'name',a.name)),'[]') from public.task_attachments a where t.status<>'in_progress' and t.result is not null and a.result_id=(
       select r.id from public.task_results r where r.task_id=t.id order by r.version desc limit 1)),
     'project',(select name from projects where id=t.project_id),
     'assignees',(select jsonb_agg(jsonb_build_object('id',x.id,'name',x.name)) from users x join task_assignees a on a.user_id=x.id where a.task_id=t.id),
     'admins',(select jsonb_agg(jsonb_build_object('id',x.id,'name',x.name)) from users x join task_admins a on a.user_id=x.id where a.task_id=t.id));
 elsif p_action='history' then
   select coalesce(jsonb_agg(to_jsonb(e) order by e.id),'[]') into items from task_events e where task_id=t.id;
   return items;
 elsif p_action <> 'edit' then raise exception 'Unknown action'; end if;
 if not(u.role='admin' or t.author_id=u.id) then raise exception 'Editing denied' using errcode='42501'; end if;
 if t.version is distinct from (p_data->>'version')::bigint then raise exception 'Version conflict' using errcode='40001'; end if;
 if p_data ? 'assignees' then
   select array_agg(value::uuid) into ids from jsonb_array_elements_text(p_data->'assignees');
   if coalesce(cardinality(ids),0)=0 or exists(select 1 from unnest(ids) selected(member_id) where not exists(select 1 from users where users.id=selected.member_id and active)) then
     raise exception 'Active assignees required' using errcode='23514';
   end if;
 end if;
 if p_data ? 'project_id' then
   select * into p from projects where id=(p_data->>'project_id')::bigint and not archived and can_view_project(id,u.id);
   if not found or not exists(select 1 from project_admins pa join users x on x.id=pa.user_id where pa.project_id=p.id and x.active and x.role='admin') then
     raise exception 'Project with active administrators required' using errcode='23514';
   end if;
 end if;
 if p_data ? 'admins' then
   if u.role <> 'admin' then raise exception 'Admin required' using errcode='42501'; end if;
   select array_agg(value::uuid) into admins from jsonb_array_elements_text(p_data->'admins');
   if coalesce(cardinality(admins),0)=0 or exists(select 1 from unnest(admins) selected(member_id) where not exists(select 1 from users where users.id=selected.member_id and role='admin' and active)) then
     raise exception 'Active administrators required' using errcode='23514';
   end if;
 end if;
 update tasks set title=case when p_data ? 'title' then p_data->>'title' else title end,
 description=case when p_data ? 'description' then p_data->>'description' else description end,
 due_date=case when p_data ? 'due_date' then (p_data->>'due_date')::date else due_date end,
 important=coalesce((p_data->>'important')::boolean,important),
 quick=coalesce((p_data->>'quick')::boolean,quick),
      renewable=coalesce((p_data->>'renewable')::boolean,
        case when (p_data->>'quick')::boolean then false else renewable end),
 project_id=coalesce(p.id,project_id),
 assignee_id=coalesce(ids[1],assignee_id) where id=t.id returning * into t;
 if ids is not null then
   delete from task_assignees where task_id=t.id;
   insert into task_assignees select t.id,id from unnest(ids) id;
 end if;
 if admins is not null or p.id is not null then
   delete from task_admins where task_id=t.id;
   if admins is not null then insert into task_admins select t.id,id from unnest(admins) id;
   else insert into task_admins select t.id,user_id from project_admins where project_id=p.id; end if;
 end if;
 insert into task_events(task_id,actor_id,event,changes) values(t.id,u.id,'team_edit',p_data);
 return to_jsonb(t);
end $function$;
CREATE OR REPLACE FUNCTION public.task_api(p_user uuid, p_action text, p_data jsonb DEFAULT '{}'::jsonb, p_request uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare u users%rowtype; t tasks%rowtype; result jsonb; ids uuid[]; admins uuid[]; update_no bigint; offset_no integer;
begin
 select * into u from users where id=p_user and active;
 if not found then raise exception 'Access denied' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(u.id::text,0));
 perform set_config('app.actor',u.id::text,true);
 if p_action in ('create','edit','begin','result','approve','return','cancel','restore','delete','materials','complete') then
   if p_request is null then raise exception 'Request ID required' using errcode='22023'; end if;
   select response into result from web_requests where user_id=u.id and request_id=p_request;
   if found then return result; end if;
 end if;
 if p_action='list' then
   offset_no:=greatest(0,least(coalesce((p_data->>'page')::integer,0),100000))*20;
   select coalesce(jsonb_agg(
     to_jsonb(q) || jsonb_build_object('latest_review',public.task_latest_review(q.id)) || jsonb_build_object('assignee_names', (
       select coalesce(jsonb_agg(member.name order by member.name, member.id), '[]')
       from public.task_assignees assigned join public.users member on member.id=assigned.user_id
       where assigned.task_id=q.id
     )) order by (q.status = 'done'), q.important desc, q.quick desc, q.number desc),'[]') into result from (
   select listed.*,(select name from projects where id=listed.project_id) as project from tasks listed
   where can_view_task(listed.id,u.id)
   and (not coalesce((p_data->>'mine')::boolean,false) or is_assignee(listed.id,u.id))
   and (not(p_data ? 'project_id') or listed.project_id=(p_data->>'project_id')::bigint)
   
 and (case p_data->>'view' when 'archive' then listed.status in ('done','cancelled') and is_assignee(listed.id,u.id) when 'cancelled' then listed.status='cancelled' when 'active' then listed.status not in ('done','cancelled') else true end)
 and (not(p_data ? 'status') or listed.status=p_data->>'status')
   and (not(p_data ? 'important') or listed.important=(p_data->>'important')::boolean)
   and (not(p_data ? 'quick') or listed.quick=(p_data->>'quick')::boolean)
    and (not(p_data ? 'renewable') or listed.renewable=(p_data->>'renewable')::boolean)
   and (not(p_data ? 'member') or is_assignee(listed.id,(p_data->>'member')::uuid))
   and (not(p_data ? 'deadline') or case p_data->>'deadline'
      when 'today' then listed.due_date=(now() at time zone 'Europe/Moscow')::date and listed.status not in ('done','cancelled')
      when 'overdue' then listed.due_date<(now() at time zone 'Europe/Moscow')::date and listed.status not in ('done','cancelled')
      else listed.due_date=(p_data->>'deadline')::date end)
   order by (listed.status = 'done'), listed.important desc, listed.quick desc, listed.number desc limit 21 offset offset_no) q;
   return result;
 elsif p_action in ('task','history') then return team_command_user(u.id,p_action,p_data);
 elsif p_action='create' then
   select array_agg(x::uuid) into ids from jsonb_array_elements_text(coalesce(p_data->'assignees',jsonb_build_array(u.id))) x;
   if coalesce(cardinality(ids),0)=0 or exists(select 1 from unnest(ids) a(id) where not exists(select 1 from users x where x.id=a.id and active)) then
     raise exception 'Active assignees required' using errcode='23514'; end if;
   select array_agg(pa.user_id) into admins from project_admins pa join projects p on p.id=pa.project_id join users x on x.id=pa.user_id
   where p.id=(p_data->>'project_id')::bigint and not archived and can_view_project(p.id,u.id) and x.active and x.role='admin';
   if coalesce(cardinality(admins),0)=0 then raise exception 'Project administrators required' using errcode='23514'; end if;
   update_no:=nextval('public.web_update_ids');
   insert into processed_updates(update_id,state) values(update_no,'processed');
   insert into tasks(author_id,assignee_id,title,description,due_date,creation_update_id,project_id,important,quick,renewable)
   values(u.id,ids[1],p_data->>'title',p_data->>'description',(p_data->>'due_date')::date,update_no,(p_data->>'project_id')::bigint,
     coalesce((p_data->>'important')::boolean,false),coalesce((p_data->>'quick')::boolean,false),coalesce((p_data->>'renewable')::boolean,false)) returning * into t;
   insert into task_assignees select t.id,id from unnest(ids) id on conflict do nothing;
   result:=to_jsonb(t);
 elsif p_action='edit' then result:=team_command_user(u.id,'edit',p_data);
 else
   select * into t from tasks where number=(p_data->>'number')::bigint and can_view_task(tasks.id,u.id) for update;
   if not found then raise exception 'Task unavailable' using errcode='42501'; end if;
   if t.version is distinct from (p_data->>'version')::bigint then raise exception 'Version conflict' using errcode='40001'; end if;
   case p_action
   when 'begin' then
     if not is_assignee(t.id,u.id) or t.status<>'new' then raise exception 'Invalid transition' using errcode='42501'; end if;
     update tasks set status='in_progress' where id=t.id returning * into t;
   when 'result' then
     if not is_assignee(t.id,u.id) or t.status not in ('in_progress','recurring') then raise exception 'Result denied' using errcode='42501'; end if;
     if coalesce(p_data->>'text','') !~ '[^[:space:]]' or char_length(p_data->>'text')>1000 then raise exception 'Result required' using errcode='23514'; end if;
     update tasks set result=p_data->>'text',status='review' where id=t.id returning * into t;
   when 'approve','return' then
     if u.role<>'admin' or t.status<>'review' then raise exception 'Review denied' using errcode='42501'; end if;
     if p_action='return' and (coalesce(p_data->>'comment','') !~ '[^[:space:]]' or char_length(p_data->>'comment')>1000) then
       raise exception 'Reason required' using errcode='23514'; end if;
     insert into task_reviews(task_id,result_version,reviewer_id,decision,comment)
     values(t.id,t.version,u.id,case when p_action='approve' then 'approved' else 'returned' end,p_data->>'comment');
     update tasks set status=case when t.renewable then 'recurring' when p_action='approve' then 'done' else 'in_progress' end,
       completed_at=case when p_action='approve' and not t.renewable then now() end,reviewed_by=case when p_action='approve' and not t.renewable then u.id end
     where id=t.id returning * into t;

   when 'materials' then
     if t.status in ('done','cancelled') or not (u.role='admin' or is_assignee(t.id,u.id)) then
       raise exception 'Editing materials denied' using errcode='42501';
     end if;
     update tasks set working_links=p_data->'links' where id=t.id returning * into t;
   when 'complete' then
     if u.role<>'admin' or t.status<>'recurring' then raise exception 'Completion denied' using errcode='42501'; end if;
     update tasks set status='done',completed_at=now(),reviewed_by=u.id where id=t.id returning * into t;
   when 'restore' then
     if t.status<>'cancelled' or not(u.role='admin' or t.author_id=u.id) then
       raise exception 'Restore denied' using errcode='42501';
     end if;
     update tasks set status='new',result=null where id=t.id returning * into t;
   when 'delete' then
     if t.status<>'cancelled' or u.role<>'admin' then
       raise exception 'Delete denied' using errcode='42501';
     end if;
     -- Hand off physical objects to the existing asynchronous storage cleanup.
     update storage_uploads set state='staging',expires_at=now()
       where state='committed' and path in (select storage_path from task_attachments where task_id=t.id);
     delete from task_attachments where task_id=t.id;
     delete from notification_deliveries where task_id=t.id;
     delete from task_reviews where task_id=t.id;
     delete from task_events where task_id=t.id;
     delete from task_results where task_id=t.id;
     delete from task_assignees where task_id=t.id;
     delete from task_admins where task_id=t.id;
     delete from tasks where id=t.id;
   when 'cancel' then
     if not(u.role='admin' or t.author_id=u.id) then raise exception 'Cancel denied' using errcode='42501'; end if;
     update tasks set status='cancelled' where id=t.id returning * into t;
   else raise exception 'Unknown action' using errcode='22023';
   end case;
   result:=case when p_action='delete' then jsonb_build_object('deleted',true) else to_jsonb(t) end;
 end if;
 insert into web_requests(user_id,request_id,response) values(u.id,p_request,result);
 return result;
end $function$;
CREATE OR REPLACE FUNCTION public.attachment_access_user(p_user uuid, p_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare u users%rowtype; n bigint; a task_attachments%rowtype;
begin
 select * into u from users where id=p_user and active;
 if not found then raise exception 'Access denied' using errcode='42501'; end if;
 if p_id is null then
   select (draft->>'number')::bigint into n from bot_sessions where user_id=u.id and step='result' and expires_at>now();
   if n is null or not exists(select 1 from tasks t where number=n and status='in_progress' and is_assignee(t.id,u.id)) then
     return null;
   end if;
   return jsonb_build_object('number',n);
 end if;
 select * into a from task_attachments where id=p_id;
 if a.id is null or not can_view_task(a.task_id,u.id) then raise exception 'Access denied' using errcode='42501'; end if;
 return to_jsonb(a);
end $function$;
CREATE OR REPLACE FUNCTION public.attachment_access(p_actor bigint, p_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare u users%rowtype; n bigint; a task_attachments%rowtype;
begin
 select * into u from users where telegram_id=p_actor and active;
 if not found then raise exception 'Access denied' using errcode='42501'; end if;
 if p_id is null then
   select (draft->>'number')::bigint into n from bot_sessions where user_id=u.id and step='result' and expires_at>now();
   if n is null or not exists(select 1 from tasks t where number=n and status='in_progress' and is_assignee(t.id,u.id)) then
     return null;
   end if;
   return jsonb_build_object('number',n);
 end if;
 select * into a from task_attachments where id=p_id;
 if a.id is null or not can_view_task(a.task_id,u.id) then raise exception 'Access denied' using errcode='42501'; end if;
 return to_jsonb(a);
end $function$;
CREATE OR REPLACE FUNCTION public.delete_empty_project(p_user uuid, p_project bigint)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if not exists (select 1 from public.users where id=p_user and active and role='admin') then
    raise exception 'Admin required' using errcode='42501';
  end if;
  if not public.can_view_project(p_project,p_user) then raise exception 'Project unavailable' using errcode='42501'; end if;
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
end $function$;
-- Existing renewable work becomes ongoing without altering closed tasks or pending reviews.
update public.tasks set status='recurring' where renewable and status in ('new','in_progress');
-- Keep legacy Telegram menus subject to the same project visibility.
alter function public.bot_event(bigint,bigint,text,text,text) rename to bot_event_before_workspaces;
create function public.bot_event(p_update bigint,p_actor bigint,p_name text,p_action text,p_value text default '')
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare u users%rowtype; answer jsonb; draft jsonb; project_no bigint; task_no bigint; key text; filtered jsonb;
begin
 select * into u from users where telegram_id=p_actor and active;
 if u.id is null then return bot_event_before_workspaces(p_update,p_actor,p_name,p_action,p_value); end if;
 select s.draft into draft from bot_sessions s where s.user_id=u.id;
 project_no:=nullif(draft->>'project_id','')::bigint;
 task_no:=nullif(draft->>'number','')::bigint;
 if p_action in ('project_open','project_delete','project_delete_confirm','project_team','archive','restore','all_project') and split_part(p_value,':',1) ~ '^[0-9]+$' then
   project_no:=split_part(p_value,':',1)::bigint;
 end if;
 if p_action in ('open','begin','result','approve','return','cancel_task','edit','task_team') and split_part(p_value,':',1) ~ '^[0-9]+$' then
   task_no:=split_part(p_value,':',1)::bigint;
 end if;
 if (project_no is not null and not can_view_project(project_no,u.id)) or
    (task_no is not null and not exists(select 1 from tasks where number=task_no and can_view_task(id,u.id))) then
   delete from bot_sessions where user_id=u.id;
   return jsonb_build_object('message','Project or task unavailable.');
 end if;
 if p_action='project_new' and u.role<>'admin' then return jsonb_build_object('message','Administrator access required.'); end if;
 answer:=bot_event_before_workspaces(p_update,p_actor,p_name,p_action,p_value);
 if answer ? 'task' and jsonb_typeof(answer->'task')='object' then
   if not exists(select 1 from tasks where number=(answer#>>'{task,number}')::bigint and can_view_task(id,u.id)) then
     return jsonb_build_object('message','Task unavailable.');
   end if;
 end if;
 foreach key in array array['tasks','projects','project_options'] loop
   if jsonb_typeof(answer->key)='array' then
     select coalesce(jsonb_agg(value),'[]') into filtered from jsonb_array_elements(answer->key)
     where case when key='tasks' then exists(select 1 from tasks where number=(value->>'number')::bigint and can_view_task(id,u.id))
       else can_view_project((value->>'id')::bigint,u.id) end;
     answer:=jsonb_set(answer,array[key],filtered);
   end if;
 end loop;
 if jsonb_typeof(answer->'filter_options')='array' then
   select coalesce(jsonb_agg(value),'[]') into filtered from jsonb_array_elements(answer->'filter_options')
   where case when value->>'action' like 'all_project:%' then can_view_project(split_part(value->>'action',':',2)::bigint,u.id) else true end;
   answer:=jsonb_set(answer,'{filter_options}',filtered);
 end if;
 return answer;
end $$;
revoke all on function public.bot_event(bigint,bigint,text,text,text) from public,anon,authenticated;
grant execute on function public.bot_event(bigint,bigint,text,text,text) to service_role;

do $patch$
declare definition text; signature text;
begin
 foreach signature in array array[
 'public.bot_event_mvp(bigint,bigint,text,text,text)',
 'public.bot_event_reviews(bigint,bigint,text,text,text)',
 'public.attachment_access(bigint,uuid)',
 'public.attachment_access_user(uuid,uuid)',
 'public.task_latest_review(uuid)'] loop
   definition:=pg_get_functiondef(signature::regprocedure);
   definition:=replace(definition,'t.status=''in_progress''','t.status in (''in_progress'',''recurring'')');
   definition:=replace(definition,'and status=''in_progress'' and version','and status in (''in_progress'',''recurring'') and version');
   definition:=replace(definition,'t.status in (''new'',''in_progress'',''review'')','t.status in (''new'',''in_progress'',''recurring'',''review'')');
   definition:=replace(definition,'case when p_action=''approve'' then ''done'' else ''in_progress'' end','case when t.renewable then ''recurring'' when p_action=''approve'' then ''done'' else ''in_progress'' end');
   definition:=replace(definition,'case when p_action=''approve'' then now() end','case when p_action=''approve'' and not t.renewable then now() end');
   definition:=replace(definition,'case when p_action=''approve'' then u.id end','case when p_action=''approve'' and not t.renewable then u.id end');
   execute definition;
 end loop;
 foreach signature in array array['public.team_command_user(uuid,text,jsonb)','public.team_command(bigint,text,jsonb)'] loop
   definition:=pg_get_functiondef(signature::regprocedure);
   definition:=replace(definition,'t.status<>''in_progress''','t.status<>''in_progress'' and not coalesce((t.status=''recurring'' and (public.task_latest_review(t.id)->>''needs_changes'')::boolean),false)');
   execute definition;
 end loop;
end $patch$;

notify pgrst,'reload schema';
commit;
