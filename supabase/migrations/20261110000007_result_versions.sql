create table public.task_results (
 id uuid primary key default gen_random_uuid(),
 task_id uuid not null references public.tasks,
 author_id uuid not null references public.users,
 text text,
 version bigint not null,
 created_at timestamptz not null default now(),
 unique(task_id,version),
 check(text ~ '[^[:space:]]')
);
insert into public.task_results(task_id,author_id,text,version)
select id,assignee_id,result,version from public.tasks where result ~ '[^[:space:]]';
alter table public.task_reviews add column result_id uuid references public.task_results;
update public.task_reviews r set result_id=(select id from public.task_results x where x.task_id=r.task_id order by version desc limit 1);
alter table public.task_results enable row level security;
revoke all on public.task_results from public,anon,authenticated;
grant select,insert on public.task_results to service_role;

create function public.record_task_result() returns trigger language plpgsql set search_path='' as $$
begin
 if new.result is distinct from old.result and new.result ~ '[^[:space:]]' then
   insert into public.task_results(task_id,author_id,text,version)
   values(new.id,coalesce(nullif(current_setting('app.actor',true),'')::uuid,new.assignee_id),new.result,new.version);
 end if;
 return new;
end $$;
create trigger record_task_result after update on public.tasks for each row execute function public.record_task_result();
create function public.bind_review_result() returns trigger language plpgsql set search_path='' as $$
begin
 select id into new.result_id from public.task_results where task_id=new.task_id order by version desc limit 1;
 if new.result_id is null then raise exception 'Result required' using errcode='23514'; end if;
 return new;
end $$;
create trigger bind_review_result before insert on public.task_reviews for each row execute function public.bind_review_result();
