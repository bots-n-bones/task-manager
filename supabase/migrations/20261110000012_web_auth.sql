alter table public.users add column login text unique check(login ~ '^[a-z][a-z0-9_.-]{2,31}$');
alter table public.users add column auth_id uuid unique references auth.users;
create table public.web_sessions (
 token_hash text primary key,
 user_id uuid not null references public.users,
 expires_at timestamptz not null,
 created_at timestamptz not null default now()
);
create table public.login_attempts (
 key text primary key,
 attempts integer not null,
 window_start timestamptz not null default now()
);
alter table public.web_sessions enable row level security;
alter table public.login_attempts enable row level security;
revoke all on public.web_sessions,public.login_attempts from public,anon,authenticated;
grant select,insert,update,delete on public.web_sessions,public.login_attempts to service_role;
create function public.login_limit(p_key text) returns boolean language plpgsql set search_path=public,pg_temp as $$
declare count integer;
begin
 insert into login_attempts(key,attempts) values(p_key,1)
 on conflict(key) do update set attempts=case when login_attempts.window_start<now()-interval '15 minutes' then 1 else login_attempts.attempts+1 end,
 window_start=case when login_attempts.window_start<now()-interval '15 minutes' then now() else login_attempts.window_start end
 returning attempts into count;
 return count<=10;
end $$;
revoke all on function public.login_limit(text) from public,anon,authenticated;
grant execute on function public.login_limit(text) to service_role;
