create sequence public.web_update_ids start 4000000000000000 maxvalue 8000000000000000;
grant usage on sequence public.web_update_ids to service_role;
create table public.web_requests (
 user_id uuid references public.users,
 request_id uuid,
 response jsonb not null,
 created_at timestamptz not null default now(),
 primary key(user_id,request_id)
);
alter table public.web_requests enable row level security;
revoke all on public.web_requests from public,anon,authenticated;
grant select,insert on public.web_requests to service_role;

create function public.task_api(p_user uuid,p_action text,p_data jsonb default '{}',p_request uuid default null)
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare u users%rowtype; t tasks%rowtype; result jsonb; ids uuid[]; admins uuid[]; update_no bigint; offset_no integer;
begin
 select * into u from users where id=p_user and active;
 if not found then raise exception 'Access denied' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(u.id::text,0));
 perform set_config('app.actor',u.id::text,true);
 if p_action in ('create','edit','begin','result','approve','return','cancel') then
   if p_request is null then raise exception 'Request ID required' using errcode='22023'; end if;
   select response into result from web_requests where user_id=u.id and request_id=p_request;
   if found then return result; end if;
 end if;
 if p_action='list' then
   offset_no:=greatest(0,least(coalesce((p_data->>'page')::integer,0),100000))*20;
   select coalesce(jsonb_agg(to_jsonb(q) order by q.number desc),'[]') into result from (
   select listed.*,(select name from projects where id=listed.project_id) as project from tasks listed
   where (u.role='admin' or is_assignee(listed.id,u.id))
   and (not coalesce((p_data->>'mine')::boolean,false) or is_assignee(listed.id,u.id))
   and (not(p_data ? 'project_id') or listed.project_id=(p_data->>'project_id')::bigint)
   and (not(p_data ? 'status') or listed.status=p_data->>'status')
   and (not(p_data ? 'important') or listed.important=(p_data->>'important')::boolean)
   and (not(p_data ? 'quick') or listed.quick=(p_data->>'quick')::boolean)
   and (not(p_data ? 'member') or is_assignee(listed.id,(p_data->>'member')::uuid))
   and (not(p_data ? 'deadline') or case p_data->>'deadline'
      when 'today' then listed.due_date=(now() at time zone 'Europe/Moscow')::date and listed.status not in ('done','cancelled')
      when 'overdue' then listed.due_date<(now() at time zone 'Europe/Moscow')::date and listed.status not in ('done','cancelled')
      else listed.due_date=(p_data->>'deadline')::date end)
   order by listed.number desc limit 21 offset offset_no) q;
   return result;
 elsif p_action in ('task','history') then return team_command(u.telegram_id,p_action,p_data);
 elsif p_action='create' then
   select array_agg(x::uuid) into ids from jsonb_array_elements_text(coalesce(p_data->'assignees',jsonb_build_array(u.id))) x;
   if coalesce(cardinality(ids),0)=0 or exists(select 1 from unnest(ids) a(id) where not exists(select 1 from users x where x.id=a.id and active)) then
     raise exception 'Active assignees required' using errcode='23514'; end if;
   select array_agg(pa.user_id) into admins from project_admins pa join projects p on p.id=pa.project_id join users x on x.id=pa.user_id
   where p.id=(p_data->>'project_id')::bigint and not archived and x.active and x.role='admin';
   if coalesce(cardinality(admins),0)=0 then raise exception 'Project administrators required' using errcode='23514'; end if;
   update_no:=nextval('public.web_update_ids');
   insert into processed_updates(update_id,state) values(update_no,'processed');
   insert into tasks(author_id,assignee_id,title,description,due_date,creation_update_id,project_id,important,quick)
   values(u.id,ids[1],p_data->>'title',p_data->>'description',(p_data->>'due_date')::date,update_no,(p_data->>'project_id')::bigint,
     coalesce((p_data->>'important')::boolean,false),coalesce((p_data->>'quick')::boolean,false)) returning * into t;
   insert into task_assignees select t.id,id from unnest(ids) id on conflict do nothing;
   result:=to_jsonb(t);
 elsif p_action='edit' then result:=team_command(u.telegram_id,'edit',p_data);
 else
   select * into t from tasks where number=(p_data->>'number')::bigint and (u.role='admin' or is_assignee(tasks.id,u.id)) for update;
   if not found then raise exception 'Task unavailable' using errcode='42501'; end if;
   if t.version is distinct from (p_data->>'version')::bigint then raise exception 'Version conflict' using errcode='40001'; end if;
   case p_action
   when 'begin' then
     if not is_assignee(t.id,u.id) or t.status<>'new' then raise exception 'Invalid transition' using errcode='42501'; end if;
     update tasks set status='in_progress' where id=t.id returning * into t;
   when 'result' then
     if not is_assignee(t.id,u.id) or t.status<>'in_progress' then raise exception 'Result denied' using errcode='42501'; end if;
     if coalesce(p_data->>'text','') !~ '[^[:space:]]' or char_length(p_data->>'text')>1000 then raise exception 'Result required' using errcode='23514'; end if;
     update tasks set result=p_data->>'text',status='review' where id=t.id returning * into t;
   when 'approve','return' then
     if u.role<>'admin' or t.status<>'review' then raise exception 'Review denied' using errcode='42501'; end if;
     if p_action='return' and (coalesce(p_data->>'comment','') !~ '[^[:space:]]' or char_length(p_data->>'comment')>1000) then
       raise exception 'Reason required' using errcode='23514'; end if;
     insert into task_reviews(task_id,result_version,reviewer_id,decision,comment)
     values(t.id,t.version,u.id,case when p_action='approve' then 'approved' else 'returned' end,p_data->>'comment');
     update tasks set status=case when p_action='approve' then 'done' else 'in_progress' end,
       completed_at=case when p_action='approve' then now() end,reviewed_by=case when p_action='approve' then u.id end
     where id=t.id returning * into t;
   when 'cancel' then
     if not(u.role='admin' or t.author_id=u.id) then raise exception 'Cancel denied' using errcode='42501'; end if;
     update tasks set status='cancelled' where id=t.id returning * into t;
   else raise exception 'Unknown action' using errcode='22023';
   end case;
   result:=to_jsonb(t);
 end if;
 insert into web_requests(user_id,request_id,response) values(u.id,p_request,result);
 return result;
end $$;
revoke all on function public.task_api(uuid,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.task_api(uuid,text,jsonb,uuid) to service_role;
