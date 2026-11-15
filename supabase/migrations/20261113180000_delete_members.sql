begin;
alter table public.users add column deleted_at timestamptz;
alter table public.users add constraint deleted_members_inactive check(deleted_at is null or not active);
-- Keep the historical identity for authorship/review records; delete the login separately.
create table public.member_deletions (
 user_id uuid primary key references public.users,
 auth_id uuid,
 created_at timestamptz not null default now(),
 auth_deleted_at timestamptz
);
alter table public.member_deletions enable row level security;
revoke all on public.member_deletions from public,anon,authenticated;
grant select,insert,update on public.member_deletions to service_role;
create function public.delete_member(p_admin uuid,p_user uuid,p_successor uuid)
returns jsonb language plpgsql set search_path=public,pg_temp as $fn$
declare target users%rowtype; successor users%rowtype; task_row tasks%rowtype; next_assignee uuid;
begin
 perform pg_advisory_xact_lock(78124930815);
 if not exists(select 1 from users where id=p_admin and active and role='admin' and deleted_at is null) then
   raise exception 'Admin required' using errcode='42501';
 end if;
 select * into target from users where id=p_user for update;
 if not found then raise exception 'Member unavailable' using errcode='22023'; end if;
 if target.deleted_at is not null then return jsonb_build_object('deleted',true,'id',target.id); end if;
 select * into successor from users where id=p_successor and id<>target.id and active and role='admin' and deleted_at is null for update;
 if not found then raise exception 'Another active administrator is required' using errcode='23514'; end if;
 perform set_config('app.actor',p_admin::text,true);
 -- Lock affected live tasks before changing their assignments. Closed-task history remains intact.
 for task_row in select t.* from tasks t where t.status not in ('done','cancelled') and
   (t.assignee_id=target.id or exists(select 1 from task_assignees a where a.task_id=t.id and a.user_id=target.id))
   order by t.id for update loop
   select u.id into next_assignee from task_assignees a join users u on u.id=a.user_id
     where a.task_id=task_row.id and u.id<>target.id and u.active and u.deleted_at is null order by u.id limit 1;
   next_assignee:=coalesce(next_assignee,successor.id);
   insert into task_assignees(task_id,user_id) values(task_row.id,next_assignee) on conflict do nothing;
   delete from task_assignees where task_id=task_row.id and user_id=target.id;
   if task_row.assignee_id=target.id then
     update tasks set assignee_id=next_assignee where id=task_row.id;
   else
     -- Bump the version so a stale assignee form cannot overwrite this change.
     update tasks set assignee_id=assignee_id where id=task_row.id;
   end if;
   insert into task_events(task_id,actor_id,event,changes) values(task_row.id,p_admin,'team_edit',
     jsonb_build_object('removed_member',target.name,'replacement',next_assignee,'reason','Member deleted'));
 end loop;
 -- Preserve at least one active responsible administrator on each affected project/task.
 insert into project_admins(project_id,user_id)
 select a.project_id,successor.id from project_admins a where a.user_id=target.id and not exists(
   select 1 from project_admins other join users u on u.id=other.user_id
   where other.project_id=a.project_id and u.id<>target.id and u.active and u.role='admin' and u.deleted_at is null)
 on conflict do nothing;
 delete from project_admins where user_id=target.id;
 insert into task_admins(task_id,user_id)
 select a.task_id,successor.id from task_admins a where a.user_id=target.id and not exists(
   select 1 from task_admins other join users u on u.id=other.user_id
   where other.task_id=a.task_id and u.id<>target.id and u.active and u.role='admin' and u.deleted_at is null)
 on conflict do nothing;
 delete from task_admins where user_id=target.id;
 delete from web_sessions where user_id=target.id;
 delete from telegram_link_codes where user_id=target.id;
 delete from bot_sessions where user_id=target.id;
 update notification_deliveries set state='cancelled',lease_token=null,lease_until=null
   where recipient_id=target.id and state in ('pending','sending','retry');
 insert into member_deletions(user_id,auth_id) values(target.id,target.auth_id);
 update users set active=false,deleted_at=now(),corporate_email=null,login=null,auth_id=null,
   email_activated=false,access_token_hash=null,access_token_expiry=null,access_mail_status=null,telegram_available=false
   where id=target.id;
 return jsonb_build_object('deleted',true,'id',target.id);
end $fn$;
revoke all on function public.delete_member(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.delete_member(uuid,uuid,uuid) to service_role;
do $migration$
declare definition text;
begin
 definition:=pg_get_functiondef('public.manage_member(uuid,uuid,boolean,text)'::regprocedure);
 if strpos(definition,'where id=p_user for update;')=0 then raise exception 'Unexpected member management function'; end if;
 execute replace(definition,'where id=p_user for update;','where id=p_user and deleted_at is null for update;');
 -- A new, authenticated profile may explicitly relink a deleted profile's Telegram account.
 -- Retaining the old link until then prevents legacy bot allowlists from recreating a removed account.
 definition:=pg_get_functiondef('public.consume_link_code(bigint,text)'::regprocedure);
 if strpos(definition,'update users set telegram_id=p_actor,telegram_available=true')=0 then raise exception 'Unexpected linking function'; end if;
 execute replace(definition,'update users set telegram_id=p_actor,telegram_available=true',
   'update users set telegram_id=null where telegram_id=p_actor and deleted_at is not null;
 update users set telegram_id=p_actor,telegram_available=true');
end $migration$;
-- Assignment writes take a user-row lock, so a concurrent request cannot
-- reassign work to a member after deletion has revoked their access.
create function public.guard_member_assignment() returns trigger language plpgsql set search_path=public,pg_temp as $guard$
begin
 perform 1 from users where id=new.user_id and active and deleted_at is null
   and (tg_table_name='task_assignees' or role='admin') for key share;
 if not found then raise exception 'An active member with the required role is needed' using errcode='23514'; end if;
 return new;
end $guard$;
create trigger guard_assignee_identity before insert or update of user_id on public.task_assignees for each row execute function public.guard_member_assignment();
create trigger guard_project_owner_identity before insert or update of user_id on public.project_admins for each row execute function public.guard_member_assignment();
create trigger guard_task_owner_identity before insert or update of user_id on public.task_admins for each row execute function public.guard_member_assignment();
notify pgrst,'reload schema';
commit;
