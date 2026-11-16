begin;
set local role service_role;
do $test$
declare owner_id uuid; other_admin uuid; member_id uuid; outsider_id uuid;
 project_id bigint; task jsonb; answer jsonb; links jsonb;
begin
 insert into users(name,role) values('QA owner','admin') returning id into owner_id;
 insert into users(name,role) values('QA other admin','admin') returning id into other_admin;
 insert into users(name,role,telegram_id) values('QA member','user',988161100001) returning id into member_id;
 insert into users(name,role,telegram_id) values('QA outsider','user',988161100002) returning id into outsider_id;
 begin
   perform team_command_user(member_id,'project_create','{"name":"Forbidden"}');
   raise exception 'Member created a project';
 exception when insufficient_privilege then null; end;
 answer:=team_command_user(owner_id,'project_create','{"name":"Private QA","visibility":"personal"}');
 project_id:=(answer->>'id')::bigint;
 assert not can_view_project(project_id,member_id);
 assert not can_view_project(project_id,other_admin);
 begin
   perform task_api(other_admin,'create',jsonb_build_object('project_id',project_id,'title','Hidden','due_date',current_date),gen_random_uuid());
   raise exception 'Other admin created private task';
 exception when check_violation or insufficient_privilege then null; end;
 task:=task_api(owner_id,'create',jsonb_build_object('project_id',project_id,'title','Tender spreadsheet','due_date',current_date,
   'renewable',true,'assignees',jsonb_build_array(member_id)),gen_random_uuid());
 assert task->>'status'='recurring';
 assert can_view_project(project_id,member_id);
 assert can_view_task((task->>'id')::uuid,member_id);
 assert not can_view_task((task->>'id')::uuid,other_admin);
 assert jsonb_array_length(task_api(other_admin,'list',jsonb_build_object('project_id',project_id)))=0;
 begin
   perform task_api(other_admin,'task',jsonb_build_object('number',task->'number'));
   raise exception 'Private task leaked';
 exception when insufficient_privilege then null; end;
 links:='[{"title":"Tender spreadsheet","url":"https://example.com/tenders"}]';
 task:=task_api(member_id,'materials',jsonb_build_object('number',task->'number','version',task->'version','links',links),gen_random_uuid());
 assert task->'working_links'=links;
 assert task->>'status'='recurring';
 begin
   perform task_api(member_id,'materials',jsonb_build_object('number',task->'number','version',task->'version','links','[{"title":"Bad","url":"javascript:alert(1)"}]'::jsonb),gen_random_uuid());
   raise exception 'Unsafe URL accepted';
 exception when check_violation then null; end;
 begin
   perform task_api(member_id,'materials',jsonb_build_object('number',task->'number','version',0,'links',links),gen_random_uuid());
   raise exception 'Stale update accepted';
 exception when serialization_failure then null; end;
 task:=task_api(member_id,'result',jsonb_build_object('number',task->'number','version',task->'version','text','Updated this week'),gen_random_uuid());
 assert task->>'status'='review';
 task:=task_api(owner_id,'return',jsonb_build_object('number',task->'number','version',task->'version','comment','Add this week'),gen_random_uuid());
 assert task->>'status'='recurring';
 answer:=task_api(member_id,'task',jsonb_build_object('number',task->'number'));
 assert answer#>>'{latest_review,needs_changes}'='true';
 assert answer->>'result' is null;
 assert answer->'working_links'=links;
 task:=task_api(member_id,'result',jsonb_build_object('number',task->'number','version',task->'version','text','Updated again'),gen_random_uuid());
 task:=task_api(owner_id,'approve',jsonb_build_object('number',task->'number','version',task->'version'),gen_random_uuid());
 assert task->>'status'='recurring';
 assert task->'working_links'=links;
 begin
   perform task_api(member_id,'complete',jsonb_build_object('number',task->'number','version',task->'version'),gen_random_uuid());
   raise exception 'Member finished recurring task';
 exception when insufficient_privilege then null; end;
 task:=task_api(owner_id,'complete',jsonb_build_object('number',task->'number','version',task->'version'),gen_random_uuid());
 assert task->>'status'='done';
 assert task->'working_links'=links;
 answer:=bot_event(988161100001,988161100002,'QA outsider','open',task->>'number');
 assert answer->>'message'='Project or task unavailable.';
 answer:=bot_event(988161100003,988161100002,'QA outsider','create','');
 assert not exists(select 1 from jsonb_array_elements(answer->'options') option where (option->>'id')::bigint=project_id);
 answer:=bot_event(988161100004,988161100002,'QA outsider','pick',(answer#>>'{draft,token}')||':'||project_id);
 assert answer->>'step'='form_project';
 perform team_command_user(owner_id,'project_visibility',jsonb_build_object('id',project_id,'visibility','shared'));
 assert can_view_project(project_id,outsider_id);
 assert not can_view_task((task->>'id')::uuid,outsider_id);
 set constraints all immediate;
 raise notice 'Project permissions, recurring lifecycle, persistent links and concurrency verified';
end $test$;
rollback;
