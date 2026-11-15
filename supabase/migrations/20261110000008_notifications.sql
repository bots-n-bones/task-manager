alter table public.users add column telegram_available boolean not null default true;
create table public.notification_deliveries (
 id bigint generated always as identity primary key,
 recipient_id uuid not null references public.users,
 kind text not null check(kind in ('deadline','overdue')),
 task_id uuid references public.tasks,
 delivery_date date not null,
 dedupe_key text not null unique,
 state text not null default 'pending' check(state in ('pending','sending','sent','failed','unavailable','cancelled')),
 attempts integer not null default 0,
 next_attempt_at timestamptz not null default now(),
 lease_until timestamptz,
 lease_token uuid,
 sent_at timestamptz,
 error text
);
create index notification_queue_idx on public.notification_deliveries(state,next_attempt_at);
alter table public.notification_deliveries enable row level security;
revoke all on public.notification_deliveries from public,anon,authenticated;
grant select,insert,update on public.notification_deliveries to service_role;
grant usage on sequence public.notification_deliveries_id_seq to service_role;

create function public.notification_queue(p_allowed bigint[],p_now timestamptz default now())
returns void language plpgsql set search_path=public,pg_temp as $$
declare day date:=(p_now at time zone 'Europe/Moscow')::date;
begin
 if (p_now at time zone 'Europe/Moscow')::time < time '09:00' then return; end if;
 insert into notification_deliveries(recipient_id,kind,task_id,delivery_date,dedupe_key)
 select distinct u.id,'deadline',t.id,day,'deadline:'||u.id||':'||t.id||':'||day
 from users u join task_assignees a on a.user_id=u.id join tasks t on t.id=a.task_id
 where u.active and u.telegram_available and u.telegram_id=any(p_allowed) and t.due_date=day and t.status not in ('done','cancelled')
 on conflict(dedupe_key) do nothing;
 insert into notification_deliveries(recipient_id,kind,delivery_date,dedupe_key)
 select u.id,'overdue',day,'overdue:'||u.id||':'||day from users u
 where u.active and u.telegram_available and u.telegram_id=any(p_allowed) and exists(
 select 1 from task_assignees a join tasks t on t.id=a.task_id where a.user_id=u.id and t.due_date<day and t.status not in ('done','cancelled'))
 on conflict(dedupe_key) do nothing;
 update notification_deliveries set state='cancelled',lease_token=null,lease_until=null
 where delivery_date<day and state in ('pending','sending');
end $$;

create function public.notification_claim(p_allowed bigint[],p_now timestamptz default now())
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare n notification_deliveries%rowtype; u users%rowtype; items jsonb;
begin
 loop
   select * into n from notification_deliveries where delivery_date=(p_now at time zone 'Europe/Moscow')::date
     and attempts<5 and ((state='pending' and next_attempt_at<=p_now) or (state='sending' and lease_until<p_now))
     order by id for update skip locked limit 1;
   if not found then return null; end if;
   select * into u from users where id=n.recipient_id;
   select coalesce(jsonb_agg(jsonb_build_object('number',t.number,'title',t.title,'due_date',t.due_date) order by t.due_date,t.number),'[]')
   into items from tasks t join task_assignees a on a.task_id=t.id
   where a.user_id=u.id and t.status not in ('done','cancelled') and
     ((n.kind='deadline' and t.id=n.task_id and t.due_date=n.delivery_date) or (n.kind='overdue' and t.due_date<n.delivery_date));
   if not u.active or not u.telegram_available or not(u.telegram_id=any(p_allowed)) or jsonb_array_length(items)=0 then
     update notification_deliveries set state='cancelled' where id=n.id;
     continue;
   end if;
   update notification_deliveries set state='sending',attempts=attempts+1,
     lease_token=gen_random_uuid(),lease_until=p_now+interval '10 minutes'
   where id=n.id returning * into n;
   return to_jsonb(n)||jsonb_build_object('telegram_id',u.telegram_id,'tasks',items);
 end loop;
end $$;

create function public.notification_finish(p_id bigint,p_token uuid,p_status text,p_error text default null,p_delay integer default 60)
returns boolean language plpgsql set search_path=public,pg_temp as $$
declare n notification_deliveries%rowtype;
begin
 select * into n from notification_deliveries where id=p_id and state='sending' and lease_token=p_token for update;
 if not found then return false; end if;
 if p_status not in ('sent','retry','unavailable') then raise exception 'Invalid delivery status'; end if;
 update notification_deliveries set state=case when p_status='retry' then case when attempts>=5 then 'failed' else 'pending' end else p_status end,
   sent_at=case when p_status='sent' then now() end,error=left(p_error,200),
   next_attempt_at=now()+make_interval(secs=>greatest(1,p_delay)),lease_token=null,lease_until=null where id=n.id;
 if p_status='unavailable' then update users set telegram_available=false where id=n.recipient_id; end if;
 return true;
end $$;
revoke all on function public.notification_queue(bigint[],timestamptz),public.notification_claim(bigint[],timestamptz),public.notification_finish(bigint,uuid,text,text,integer) from public,anon,authenticated;
grant execute on function public.notification_queue(bigint[],timestamptz),public.notification_claim(bigint[],timestamptz),public.notification_finish(bigint,uuid,text,text,integer) to service_role;
