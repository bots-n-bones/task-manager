insert into storage.buckets(id,name,public,file_size_limit) values('task-results','task-results',false,10485760)
on conflict(id) do update set public=false,file_size_limit=10485760;
create table public.task_attachments (
 id uuid primary key default gen_random_uuid(),
 task_id uuid not null references public.tasks,
 result_id uuid not null references public.task_results,
 name text not null,
 mime_type text not null,
 size bigint not null check(size between 1 and 10485760),
 storage_path text not null unique,
 telegram_file_id text not null,
 update_id bigint not null unique references public.processed_updates,
 created_at timestamptz not null default now()
);
alter table public.task_attachments enable row level security;
revoke all on public.task_attachments from public,anon,authenticated;
grant select,insert on public.task_attachments to service_role;

create function public.attachment_access(p_actor bigint,p_id uuid default null)
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare u users%rowtype; n bigint; a task_attachments%rowtype;
begin
 select * into u from users where telegram_id=p_actor and active;
 if not found then raise exception 'Access denied' using errcode='42501'; end if;
 if p_id is null then
   select (draft->>'number')::bigint into n from bot_sessions where user_id=u.id and step='result';
   if n is null or not exists(select 1 from tasks t where number=n and status='in_progress' and is_assignee(t.id,u.id)) then
     return null;
   end if;
   return jsonb_build_object('number',n);
 end if;
 select * into a from task_attachments where id=p_id;
 if a.id is null or not(u.role='admin' or is_assignee(a.task_id,u.id)) then raise exception 'Access denied' using errcode='42501'; end if;
 return to_jsonb(a);
end $$;

create function public.attachment_result(p_actor bigint,p_update bigint,p_name text,p_file jsonb,p_caption text default '')
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare answer jsonb; u uuid; result_uuid uuid; task_uuid uuid; body text;
begin
 perform pg_advisory_xact_lock(p_actor);
 select response into answer from processed_updates where update_id=p_update;
 if found then return answer; end if;
 if attachment_access(p_actor) is null then return jsonb_build_object('message','Сначала откройте задачу и нажмите «Добавить результат».'); end if;
 select id into u from users where telegram_id=p_actor;
 if char_length(p_caption)>1000 or char_length(p_file->>'name')>255 or (p_file->>'size')::bigint not between 1 and 10485760
   or p_file->>'path' <> p_actor||'/'||p_update then raise exception 'Invalid file metadata' using errcode='23514'; end if;
 body:=case when btrim(p_caption) ~ '[^[:space:]]' then p_caption else 'Файл: '||left(p_file->>'name',255) end;
 answer:=bot_event(p_update,p_actor,p_name,'text',body);
 task_uuid:=(answer#>>'{task,id}')::uuid;
 if task_uuid is null or answer#>>'{task,status}' <> 'review' then raise exception 'Result unavailable' using errcode='40001'; end if;
 select id into result_uuid from task_results where task_id=task_uuid order by version desc limit 1;
 insert into task_attachments(task_id,result_id,name,mime_type,size,storage_path,telegram_file_id,update_id)
 values(task_uuid,result_uuid,p_file->>'name',p_file->>'mime_type',(p_file->>'size')::bigint,p_file->>'path',p_file->>'file_id',p_update);
 insert into task_events(task_id,actor_id,event,changes) values(task_uuid,u,'attachment',jsonb_build_object('name',p_file->>'name','result_id',result_uuid));
 return answer;
end $$;
revoke all on function public.attachment_access(bigint,uuid),public.attachment_result(bigint,bigint,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.attachment_access(bigint,uuid),public.attachment_result(bigint,bigint,text,jsonb,text) to service_role;

-- The returned card includes attachment buttons only for callers who can read the task.
do $$
declare definition text;
begin
 select pg_get_functiondef('public.team_command(bigint,text,jsonb)'::regprocedure) into definition;
 definition:=replace(definition,'''project'',(select name', '''attachments'',(select coalesce(jsonb_agg(jsonb_build_object(''id'',a.id,''name'',a.name)),''[]'') from public.task_attachments a where a.task_id=t.id),
     ''project'',(select name');
 execute definition;
end $$;
-- A repeated result text still constitutes a new submission after a return.
create or replace function public.record_task_result() returns trigger language plpgsql set search_path='' as $$
begin
 if (new.result is distinct from old.result or (new.status='review' and old.status<>'review')) and new.result ~ '[^[:space:]]' then
   insert into public.task_results(task_id,author_id,text,version)
   values(new.id,coalesce(nullif(current_setting('app.actor',true),'')::uuid,new.assignee_id),new.result,new.version);
 end if;
 return new;
end $$;
