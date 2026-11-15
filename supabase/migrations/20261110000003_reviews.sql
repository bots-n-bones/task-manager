alter table public.users add column role text not null default 'user' check(role in ('user','admin'));
alter table public.users add column active boolean not null default true;
update public.users set role='admin' where telegram_id=1287414278;
insert into public.users(telegram_id,name,role) values(1287414278,'Илья','admin')
on conflict(telegram_id) do update set role='admin';

alter table public.tasks drop constraint tasks_status_check;
alter table public.tasks add constraint tasks_status_check check(status in ('new','in_progress','review','done','cancelled'));
alter table public.tasks add column completed_at timestamptz;
alter table public.tasks add column reviewed_by uuid references public.users;

create table public.task_reviews (
 id uuid primary key default gen_random_uuid(),
 task_id uuid not null references public.tasks,
 result_version bigint not null,
 reviewer_id uuid not null references public.users,
 decision text not null check(decision in ('approved','returned')),
 comment text,
 created_at timestamptz not null default now(),
 unique(task_id,result_version),
 check(decision <> 'returned' or comment ~ '[^[:space:]]')
);
create table public.task_events (
 id bigint generated always as identity primary key,
 task_id uuid not null references public.tasks,
 actor_id uuid references public.users,
 event text not null,
 changes jsonb not null,
 created_at timestamptz not null default now()
);
alter table public.task_reviews enable row level security;
alter table public.task_events enable row level security;
revoke all on public.task_reviews,public.task_events from public,anon,authenticated;
grant select,insert on public.task_reviews,public.task_events to service_role;
grant usage on sequence public.task_events_id_seq to service_role;

create or replace function public.guard_task_write() returns trigger
language plpgsql set search_path = '' as $$
declare actor uuid;
begin
 actor := nullif(current_setting('app.actor',true),'')::uuid;
 if tg_op='INSERT' then
   if new.status <> 'new' then raise exception 'A task must start in new status' using errcode='23514'; end if;
   new.version:=1;
 else
   if new.status <> old.status and not (
     (old.status='new' and new.status='in_progress') or
     (old.status='in_progress' and new.status='review') or
     (old.status='review' and new.status in ('done','in_progress') and exists(select 1 from public.users where id=actor and role='admin' and active)) or
     (old.status in ('new','in_progress','review') and new.status='cancelled' and exists(select 1 from public.users where id=actor and active and (role='admin' or id=old.author_id)))
   ) then raise exception 'Invalid task status transition' using errcode='23514'; end if;
   if new.creation_update_id <> old.creation_update_id or new.created_at <> old.created_at then
     raise exception 'Immutable task fields' using errcode='23514';
   end if;
   if old.status in ('done','cancelled') then raise exception 'Task is closed' using errcode='23514'; end if;
   new.version:=old.version+1;
   new.updated_at:=clock_timestamp();
 end if;
 return new;
end $$;

create function public.log_task_event() returns trigger language plpgsql set search_path='' as $$
begin
 insert into public.task_events(task_id,actor_id,event,changes)
 values(new.id,nullif(current_setting('app.actor',true),'')::uuid,lower(tg_op),
 jsonb_build_object('before',case when tg_op='UPDATE' then to_jsonb(old) else null end,'after',to_jsonb(new)));
 return new;
end $$;
create trigger log_task_event after insert or update on public.tasks for each row execute function public.log_task_event();

alter function public.bot_event(bigint,bigint,text,text,text) rename to bot_event_mvp;
revoke all on function public.bot_event_mvp(bigint,bigint,text,text,text) from public,anon,authenticated;

create function public.bot_event(p_update bigint,p_actor bigint,p_name text,p_action text,p_value text default '')
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare u users%rowtype; s bot_sessions%rowtype; t tasks%rowtype; answer jsonb; page_no int; n bigint; v bigint; parts text[]; special boolean;
begin
 perform pg_advisory_xact_lock(p_actor);
 select * into u from users where telegram_id=p_actor;
 if found and not u.active then return jsonb_build_object('message','Учётная запись отключена.'); end if;
 perform set_config('app.actor',coalesce(u.id::text,''),true);
 select response into answer from processed_updates where update_id=p_update;
 if found then return answer; end if;
 select * into s from bot_sessions where user_id=u.id;
 special := p_action in ('all','approve','return','cancel_task') or (p_action='open' and u.role='admin')
   or (p_action='text' and s.step='review_reason');
 if not special then
   answer:=bot_event_mvp(p_update,p_actor,p_name,p_action,p_value);
 else
   if s.step is not null and not(p_action='text' and s.step='review_reason') then
     answer:=jsonb_build_object('message','Сначала завершите или отмените форму.','step',s.step,'draft',s.draft);
   elsif u.id is null then
     answer:=jsonb_build_object('message','Отправьте /start.');
   elsif p_action='all' then
     if u.role <> 'admin' then answer:=jsonb_build_object('message','Доступ закрыт.');
     else
       page_no:=case when p_value ~ '^[0-9]{1,8}$' then p_value::int else 0 end;
       select jsonb_build_object('page',page_no,'scope','all','tasks',coalesce(jsonb_agg(to_jsonb(q) order by q.number desc),'[]'))
       into answer from (select number,title,status from tasks order by number desc limit 6 offset page_no*5) q;
     end if;
   else
     parts:=string_to_array(case when s.step='review_reason' then s.draft->>'target' else p_value end,':');
     if parts[1] ~ '^[0-9]{1,18}$' then n:=parts[1]::bigint; end if;
     if parts[2] ~ '^[0-9]{1,18}$' then v:=parts[2]::bigint; end if;
     select * into t from tasks where number=n and (assignee_id=u.id or u.role='admin') for update;
     if not found then answer:=jsonb_build_object('message','Задача недоступна.');
     elsif p_action='open' then answer:=jsonb_build_object('task',to_jsonb(t));
     elsif v is distinct from t.version then answer:=jsonb_build_object('message','Карточка изменилась. Откройте её заново.','task',to_jsonb(t));
     elsif p_action='cancel_task' and (u.role='admin' or t.author_id=u.id) and t.status in ('new','in_progress','review') then
       update tasks set status='cancelled' where id=t.id returning * into t;
       answer:=jsonb_build_object('task',to_jsonb(t));
     elsif u.role <> 'admin' then answer:=jsonb_build_object('message','Действие доступно администратору.');
     elsif t.status <> 'review' then answer:=jsonb_build_object('message','Задача уже обработана.','task',to_jsonb(t));
     elsif p_action='return' then
       insert into bot_sessions(user_id,step,draft) values(u.id,'review_reason',jsonb_build_object('target',p_value,'token',p_update::text));
       answer:=jsonb_build_object('step','review_reason','draft',jsonb_build_object('token',p_update::text));
     elsif p_action='text' and (btrim(p_value) !~ '[^[:space:]]' or char_length(p_value)>1000) then
       answer:=jsonb_build_object('message','Введите причину от 1 до 1000 символов.','step','review_reason','draft',s.draft);
     else
       insert into task_reviews(task_id,result_version,reviewer_id,decision,comment)
       values(t.id,t.version,u.id,case when p_action='approve' then 'approved' else 'returned' end,case when p_action='text' then p_value end);
       update tasks set status=case when p_action='approve' then 'done' else 'in_progress' end,
         completed_at=case when p_action='approve' then now() end,
         reviewed_by=case when p_action='approve' then u.id end where id=t.id returning * into t;
       delete from bot_sessions where user_id=u.id;
       answer:=jsonb_build_object('task',to_jsonb(t));
     end if;
   end if;
   insert into processed_updates(update_id,state,response) values(p_update,'processed',answer);
 end if;
 answer:=answer || jsonb_build_object('admin',u.role='admin','actor_id',u.id);
 update processed_updates set response=answer where update_id=p_update;
 return answer;
end $$;
revoke all on function public.bot_event(bigint,bigint,text,text,text) from public,anon,authenticated;
grant execute on function public.bot_event(bigint,bigint,text,text,text) to service_role;
