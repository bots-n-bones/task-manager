create table public.storage_uploads (
 path text primary key,
 state text not null default 'staging' check(state in ('staging','committed','collecting','deleted')),
 expires_at timestamptz not null default now()+interval '24 hours',
 claimed_at timestamptz,
 error text
);
alter table public.storage_uploads enable row level security;
revoke all on public.storage_uploads from public,anon,authenticated;
grant select,insert,update on public.storage_uploads to service_role;

create function public.file_stage(p_path text) returns void language plpgsql set search_path=public,pg_temp as $$
declare entry storage_uploads%rowtype;
begin
 insert into storage_uploads(path) values(p_path) on conflict do nothing;
 select * into entry from storage_uploads where path=p_path for update;
 if entry.state in ('collecting','deleted') then raise exception 'Upload expired; submit a new request' using errcode='40001'; end if;
 if entry.state='staging' then update storage_uploads set expires_at=now()+interval '24 hours' where path=p_path; end if;
end $$;

create function public.commit_staged_file() returns trigger language plpgsql set search_path=public,pg_temp as $$
declare entry storage_uploads%rowtype;
begin
 select * into entry from storage_uploads where path=new.storage_path for update;
 if found and entry.state in ('collecting','deleted') then raise exception 'Upload expired; submit a new request' using errcode='40001'; end if;
 -- Older uploads created before staging was introduced remain valid.
 insert into storage_uploads(path,state) values(new.storage_path,'committed')
 on conflict(path) do update set state='committed';
 return new;
end $$;
create trigger commit_staged_file before insert on public.task_attachments for each row execute function public.commit_staged_file();

create function public.file_cleanup_claim() returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare paths jsonb;
begin
 -- Include historical orphans whose upload failed before the staging registry existed.
 insert into storage_uploads(path,expires_at)
 select name,created_at from storage.objects o where bucket_id='task-results' and created_at<now()-interval '24 hours'
 and not exists(select 1 from task_attachments a where a.storage_path=o.name)
 on conflict(path) do nothing;
 with candidates as (
   select path from storage_uploads s where state='staging' and expires_at<now()
   and not exists(select 1 from task_attachments a where a.storage_path=s.path)
   for update skip locked limit 100
 )
 update storage_uploads set state='collecting',claimed_at=now() where path in(select path from candidates);
 -- Delay physical deletion beyond the maximum in-flight HTTP upload timeout.
 select coalesce(jsonb_agg(path),'[]') into paths from (
 select path from storage_uploads s where state='collecting' and claimed_at<now()-interval '5 minutes'
 and not exists(select 1 from task_attachments a where a.storage_path=s.path) order by claimed_at limit 100) q;
 return paths;
end $$;
create function public.file_cleanup_done(p_paths text[]) returns void language sql set search_path='' as $$
 update public.storage_uploads set state='deleted',error=null
 where state='collecting' and path=any(p_paths);
$$;
revoke all on function public.file_stage(text),public.file_cleanup_claim(),public.file_cleanup_done(text[]) from public,anon,authenticated;
grant execute on function public.file_stage(text),public.file_cleanup_claim(),public.file_cleanup_done(text[]) to service_role;

notify pgrst, 'reload schema';
