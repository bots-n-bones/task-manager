alter table public.users alter column telegram_id drop not null;
-- Use the internal profile UUID across web operations, including profiles awaiting Telegram linking.
do $$
declare definition text;
begin
 select pg_get_functiondef('public.team_command(bigint,text,jsonb)'::regprocedure) into definition;
 definition:=replace(definition,'public.team_command(p_actor bigint','public.team_command_user(p_user uuid');
 definition:=replace(definition,'telegram_id=p_actor','id=p_user');
 execute definition;
 select pg_get_functiondef('public.task_api(uuid,text,jsonb,uuid)'::regprocedure) into definition;
 definition:=replace(definition,'team_command(u.telegram_id,','team_command_user(u.id,');
 execute definition;
end $$;
revoke all on function public.team_command_user(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.team_command_user(uuid,text,jsonb) to service_role;

create table public.telegram_link_codes (
 token_hash text primary key,
 user_id uuid not null references public.users,
 expires_at timestamptz not null,
 created_at timestamptz not null default now()
);
alter table public.telegram_link_codes enable row level security;
revoke all on public.telegram_link_codes from public,anon,authenticated;
grant select,insert,delete on public.telegram_link_codes to service_role;
create function public.create_member(p_admin uuid,p_name text) returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare u users%rowtype;
begin
 if not exists(select 1 from users where id=p_admin and active and role='admin') then raise exception 'Admin required' using errcode='42501'; end if;
 if char_length(btrim(p_name)) not between 1 and 120 then raise exception 'Name required' using errcode='23514'; end if;
 insert into users(name) values(btrim(p_name)) returning * into u;
 return jsonb_build_object('id',u.id,'name',u.name);
end $$;
create function public.issue_link_code(p_user uuid,p_hash text) returns void language plpgsql set search_path=public,pg_temp as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(p_user::text,0));
 if not exists(select 1 from users where id=p_user and active) then raise exception 'User unavailable' using errcode='42501'; end if;
 delete from telegram_link_codes where user_id=p_user or expires_at<now();
 insert into telegram_link_codes(token_hash,user_id,expires_at) values(p_hash,p_user,now()+interval '15 minutes');
end $$;
create function public.consume_link_code(p_actor bigint,p_hash text) returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare code telegram_link_codes%rowtype; u users%rowtype;
begin
 perform pg_advisory_xact_lock(p_actor);
 select * into code from telegram_link_codes where token_hash=p_hash and expires_at>now() for update;
 if not found then raise exception 'Invalid link code' using errcode='42501'; end if;
 select * into u from users where id=code.user_id and active for update;
 if not found or (u.telegram_id is not null and u.telegram_id<>p_actor) then raise exception 'Profile already linked' using errcode='42501'; end if;
 update users set telegram_id=p_actor,telegram_available=true where id=u.id;
 delete from telegram_link_codes where token_hash=p_hash;
 return jsonb_build_object('id',u.id,'name',u.name);
end $$;
revoke all on function public.create_member(uuid,text),public.issue_link_code(uuid,text),public.consume_link_code(bigint,text) from public,anon,authenticated;
grant execute on function public.create_member(uuid,text),public.issue_link_code(uuid,text),public.consume_link_code(bigint,text) to service_role;
