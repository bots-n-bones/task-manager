create table public.projects (
 id bigint generated always as identity primary key,
 name text not null check(name ~ '[^[:space:]]' and char_length(name)<=120),
 description text,
 archived boolean not null default false
);
create table public.project_admins (
 project_id bigint references public.projects,
 user_id uuid references public.users,
 primary key(project_id,user_id)
);
insert into public.projects(name) values('Общие задачи');
insert into public.project_admins select p.id,u.id from public.projects p cross join public.users u where u.role='admin' and u.active;
alter table public.tasks add column project_id bigint references public.projects;
update public.tasks set project_id=(select min(id) from public.projects);
alter table public.tasks alter column project_id set not null;
alter table public.tasks add column important boolean not null default false;
alter table public.tasks add column quick boolean not null default false;
alter table public.tasks drop constraint tasks_check;
create table public.task_assignees (
 task_id uuid references public.tasks,
 user_id uuid references public.users,
 primary key(task_id,user_id)
);
create index task_assignees_user_idx on public.task_assignees(user_id,task_id);
create table public.task_admins (
 task_id uuid references public.tasks,
 user_id uuid references public.users,
 primary key(task_id,user_id)
);
insert into public.task_assignees select id,assignee_id from public.tasks;
insert into public.task_admins select t.id,p.user_id from public.tasks t join public.project_admins p on p.project_id=t.project_id;

-- Keep earlier bot creation compatible during the transition.
create function public.task_team_defaults() returns trigger language plpgsql set search_path='' as $$
begin
 if new.project_id is null then select min(id) into new.project_id from public.projects where not archived; end if;
 return new;
end $$;
create trigger task_team_defaults before insert on public.tasks for each row execute function public.task_team_defaults();
create function public.task_team_insert() returns trigger language plpgsql set search_path='' as $$
begin
 insert into public.task_assignees values(new.id,new.assignee_id) on conflict do nothing;
 insert into public.task_admins select new.id,user_id from public.project_admins where project_id=new.project_id;
 return new;
end $$;
create trigger task_team_insert after insert on public.tasks for each row execute function public.task_team_insert();

create function public.is_assignee(p_task uuid,p_user uuid) returns boolean
language sql stable set search_path='' as $$
 select exists(select 1 from public.task_assignees where task_id=p_task and user_id=p_user)
$$;
do $$
declare definition text;
begin
 select pg_get_functiondef('public.bot_event_mvp(bigint,bigint,text,text,text)'::regprocedure) into definition;
 definition:=replace(definition,'assignee_id=u','public.is_assignee(tasks.id,u)');
 execute definition;
end $$;

do $$
declare table_name text;
begin
 foreach table_name in array array['projects','project_admins','task_assignees','task_admins'] loop
 execute format('alter table public.%I enable row level security',table_name);
 execute format('revoke all on public.%I from public,anon,authenticated',table_name);
 execute format('grant select,insert,update,delete on public.%I to service_role',table_name);
 end loop;
end $$;
grant usage on sequence public.projects_id_seq to service_role;
revoke all on function public.is_assignee(uuid,uuid) from public,anon,authenticated;
grant execute on function public.is_assignee(uuid,uuid) to service_role;

create function public.team_command(p_actor bigint,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql set search_path=public,pg_temp as $$
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
   select coalesce(jsonb_agg(to_jsonb(q) order by q.id),'[]') into items from projects q where not archived or u.role='admin';
   return items;
 elsif p_action='project_create' then
   if u.role <> 'admin' then raise exception 'Admin required' using errcode='42501'; end if;
   insert into projects(name,description) values(btrim(p_data->>'name'),p_data->>'description') returning * into p;
   insert into project_admins values(p.id,u.id);
   return to_jsonb(p);
 elsif p_action in ('project_archive','project_admins') then
   if u.role <> 'admin' then raise exception 'Admin required' using errcode='42501'; end if;
   select * into strict p from projects where id=(p_data->>'id')::bigint for update;
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
 if not found or not(u.role='admin' or is_assignee(t.id,u.id)) then raise exception 'Task unavailable' using errcode='42501'; end if;
 if p_action='task' then
   return to_jsonb(t) || jsonb_build_object(
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
   select * into p from projects where id=(p_data->>'project_id')::bigint and not archived;
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
end $$;
revoke all on function public.team_command(bigint,text,jsonb) from public,anon,authenticated;
grant execute on function public.team_command(bigint,text,jsonb) to service_role;
