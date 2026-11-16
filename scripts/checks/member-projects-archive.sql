begin;
do $test$
declare
 member_id uuid; other_id uuid; admin_id uuid; inactive_id uuid; fixture_project bigint;
 result jsonb; task_no bigint; task_version bigint; state text; actor uuid; row jsonb; count_no int;
begin
 insert into public.users(name,role,telegram_id) values('Member project test','user',988131400001) returning id into member_id;
 insert into public.users(name,role,telegram_id) values('Other archive test','user',988131400002) returning id into other_id;
 insert into public.users(name,role,telegram_id) values('Project admin test','admin',988131400003) returning id into admin_id;
 insert into public.users(name,role,active) values('Inactive project test','user',false) returning id into inactive_id;
 result:=public.team_command_user(admin_id,'project_create',jsonb_build_object('name','Member project test','admins',jsonb_build_array(admin_id)));
 fixture_project:=(result->>'id')::bigint;
 assert exists(select 1 from public.project_admins where project_admins.project_id=fixture_project and user_id=admin_id);
 assert not exists(select 1 from public.project_admins where user_id=member_id);
 assert (select role='user' from public.users where id=member_id);
 begin
   perform public.team_command(988131400001,'project_create','{"name":"Telegram member project test"}');
   raise exception 'Member created project';
 exception when insufficient_privilege then null; end;
 begin
   perform public.team_command_user(admin_id,'project_create',jsonb_build_object('name','Invalid owner','admins',jsonb_build_array(member_id)));
   raise exception 'Non-admin owner accepted';
 exception when check_violation then null; end;
 begin
   perform public.team_command_user(inactive_id,'project_create',jsonb_build_object('name','Inactive creator'));
   raise exception 'Inactive creator accepted';
 exception when insufficient_privilege then null; end;
 begin
   perform public.team_command_user(member_id,'project_archive',jsonb_build_object('id',fixture_project,'archived',true));
   raise exception 'Member archived a project';
 exception when insufficient_privilege then null; end;
 begin
   perform public.team_command_user(member_id,'project_admins',jsonb_build_object('id',fixture_project,'admins',jsonb_build_array(member_id)));
   raise exception 'Member changed administrator assignments';
 exception when insufficient_privilege then null; end;
 -- Build real task lifecycles, including another member's closed task.
 for count_no in 1..4 loop
   actor:=case when count_no=4 then other_id else member_id end;
   result:=public.task_api(actor,'create',jsonb_build_object('title','Archive test '||count_no,'project_id',fixture_project,'due_date',current_date),gen_random_uuid());
   task_no:=(result->>'number')::bigint;
   if count_no=2 then
     perform public.task_api(actor,'cancel',jsonb_build_object('number',task_no,'version',result->'version'),gen_random_uuid());
   elsif count_no in (1,4) then
     result:=public.task_api(actor,'begin',jsonb_build_object('number',task_no,'version',result->'version'),gen_random_uuid());
     result:=public.task_api(actor,'result',jsonb_build_object('number',task_no,'version',result->'version','text','Completed'),gen_random_uuid());
     perform public.task_api(admin_id,'approve',jsonb_build_object('number',task_no,'version',result->'version'),gen_random_uuid());
   end if;
 end loop;
 result:=public.task_api(member_id,'list',jsonb_build_object('view','archive','project_id',fixture_project));
 assert jsonb_array_length(result)=2;
 for row in select value from jsonb_array_elements(result) loop
   assert row->>'status' in ('done','cancelled');
   assert public.is_assignee((row->>'id')::uuid,member_id);
 end loop;
 assert jsonb_array_length(public.task_api(member_id,'list',jsonb_build_object('view','archive','project_id',fixture_project,'status','done')))=1;
 assert jsonb_array_length(public.task_api(member_id,'list',jsonb_build_object('view','archive','project_id',fixture_project,'status','new')))=0;
 assert jsonb_array_length(public.task_api(admin_id,'list',jsonb_build_object('view','archive','project_id',fixture_project)))=0;
 assert jsonb_array_length(public.task_api(member_id,'list',jsonb_build_object('view','active','project_id',fixture_project)))=1;
 set constraints all immediate;
 raise notice 'Member project permissions and personal archive isolation verified';
end $test$;
rollback;
