begin;
do $test$
declare
 admin_a uuid; admin_b uuid; member_c uuid; member_d uuid; inactive_member uuid;
 fixture_project bigint; open_task bigint; shared_task bigint; closed_task bigint; admin_task bigint;
 r jsonb; v jsonb; t_id uuid; old_auth uuid:=gen_random_uuid(); token text:=repeat('b',64);
begin
 insert into users(name,role) values('Delete test admin A','admin') returning id into admin_a;
 insert into users(name,role) values('Delete test admin B','admin') returning id into admin_b;
 insert into auth.users(id,email,aud,role) values(old_auth,'member-delete-test@example.invalid','authenticated','authenticated');
 insert into users(name,role,telegram_id,auth_id,corporate_email,email_activated)
 values('Delete test member C','user',988131800001,old_auth,'delete-test@bots-n-bones.com',true) returning id into member_c;
 insert into users(name,role) values('Delete test member D','user') returning id into member_d;
 insert into users(name,role,active) values('Delete inactive test','user',false) returning id into inactive_member;
 r:=team_command_user(admin_a,'project_create','{"name":"Member deletion test"}');fixture_project:=(r->>'id')::bigint;
 r:=task_api(member_c,'create',jsonb_build_object('title','Sole assignee','project_id',fixture_project,'due_date',current_date),gen_random_uuid());open_task:=(r->>'number')::bigint;
 r:=task_api(member_c,'create',jsonb_build_object('title','Shared task','project_id',fixture_project,'due_date',current_date,'assignees',jsonb_build_array(member_c,member_d)),gen_random_uuid());shared_task:=(r->>'number')::bigint;
 r:=task_api(member_c,'create',jsonb_build_object('title','Closed task','project_id',fixture_project,'due_date',current_date),gen_random_uuid());closed_task:=(r->>'number')::bigint;
 r:=task_api(member_c,'begin',jsonb_build_object('number',closed_task,'version',r->'version'),gen_random_uuid());
 r:=task_api(member_c,'result',jsonb_build_object('number',closed_task,'version',r->'version','text','Keep the historical submission'),gen_random_uuid());
 perform task_api(admin_a,'approve',jsonb_build_object('number',closed_task,'version',r->'version'),gen_random_uuid());
 r:=task_api(admin_a,'create',jsonb_build_object('title','Admin assigned task','project_id',fixture_project,'due_date',current_date),gen_random_uuid());admin_task:=(r->>'number')::bigint;
 insert into web_sessions(token_hash,user_id,expires_at) values(repeat('a',64),member_c,now()+interval '1 day');
 perform issue_link_code(member_c,repeat('c',64));
 perform set_config('role','service_role',true);
 begin
   perform delete_member(member_d,member_c,admin_a);raise exception 'Member deleted another user';
 exception when insufficient_privilege then null;end;
 begin
   perform delete_member(admin_a,member_c,member_d);raise exception 'Invalid replacement accepted';
 exception when check_violation then null;end;
 r:=delete_member(admin_a,member_c,admin_a);
 assert r->>'deleted'='true';assert not(r ? 'auth_id');
 assert exists(select 1 from users where id=member_c and not active and deleted_at is not null and auth_id is null and corporate_email is null and access_token_hash is null);
 assert not exists(select 1 from web_sessions where user_id=member_c);
 assert not exists(select 1 from telegram_link_codes where user_id=member_c);
 assert exists(select 1 from member_deletions where user_id=member_c and auth_id=old_auth and auth_deleted_at is null);
 assert exists(select 1 from tasks where number=open_task and assignee_id=admin_a and author_id=member_c and status='new');
 select id into t_id from tasks where number=open_task;
 assert is_assignee(t_id,admin_a);assert not is_assignee(t_id,member_c);
 assert exists(select 1 from tasks where number=shared_task and assignee_id=member_d);
 select id into t_id from tasks where number=shared_task;
 assert is_assignee(t_id,member_d);assert not is_assignee(t_id,member_c);
 assert exists(select 1 from tasks where number=closed_task and status='done' and assignee_id=member_c and author_id=member_c and result='Keep the historical submission');
 begin
   perform task_api(member_c,'list');raise exception 'Deleted member still has access';
 exception when insufficient_privilege then null;end;
 begin
   perform manage_member(admin_a,member_c,true);raise exception 'Deleted member was reactivated';
 exception when insufficient_privilege then null;end;
 begin
   insert into task_assignees values(t_id,member_c);raise exception 'Work reassigned to deleted member';
 exception when check_violation then null;end;
 assert delete_member(admin_a,member_c,admin_a)=r;
 assert (select count(*) from member_deletions where user_id=member_c)=1;
 -- A new authenticated profile can explicitly link the old Telegram identity.
 perform issue_link_code(member_d,token);
 v:=consume_link_code(988131800001,token);
 assert (v->>'id')::uuid=member_d;
 assert (select telegram_id is null from users where id=member_c);
 -- Administrators, including the acting administrator, can be removed with a successor.
 insert into web_sessions(token_hash,user_id,expires_at) values(repeat('d',64),admin_a,now()+interval '1 day');
 perform delete_member(admin_a,admin_a,admin_b);
 assert exists(select 1 from project_admins where project_admins.project_id=fixture_project and user_id=admin_b);
 assert not exists(select 1 from project_admins where user_id=admin_a);
 assert not exists(select 1 from task_admins where user_id=admin_a);
 assert exists(select 1 from tasks where number=admin_task and assignee_id=admin_b);
 assert not exists(select 1 from web_sessions where user_id=admin_a);
 assert exists(select 1 from task_reviews where reviewer_id=admin_a);
 assert exists(select 1 from task_results where author_id=member_c and text='Keep the historical submission');
 begin
   perform delete_member(admin_b,admin_b,admin_b);raise exception 'Administrator deleted without another active administrator';
 exception when check_violation then null;end;
 perform delete_member(admin_b,inactive_member,admin_b);
 assert exists(select 1 from users where id=inactive_member and deleted_at is not null);
 assert not has_function_privilege('authenticated','public.delete_member(uuid,uuid,uuid)','EXECUTE');
 set constraints all immediate;
 raise notice 'Member/admin/self deletion, reassignment, history, login revocation, retry and relinking verified';
end $test$;
rollback;
