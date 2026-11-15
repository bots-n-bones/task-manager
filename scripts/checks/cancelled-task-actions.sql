begin;
set local role service_role;
do $$
declare
  admin_id uuid;
  member_id uuid;
  project_id bigint;
  task_id uuid;
  result_id uuid;
  task jsonb;
  args jsonb;
  deletion_request uuid := gen_random_uuid();
  attachment_path text := 'checks/'||gen_random_uuid();
begin
  insert into users(telegram_id,name,role) values(981053357000,'Actions admin','admin') returning id into admin_id;
  insert into users(telegram_id,name) values(981053357001,'Actions member') returning id into member_id;
  project_id := (team_command_user(admin_id,'project_create','{"name":"Actions check"}')->>'id')::bigint;
  task := task_api(admin_id,'create',jsonb_build_object('title','Actions check','project_id',project_id,
    'due_date',current_date,'assignees',jsonb_build_array(admin_id,member_id)),gen_random_uuid());
  task_id := (task->>'id')::uuid;
  args := jsonb_build_object('number',task->'number','version',task->'version');
  assert task_api(admin_id,'list',jsonb_build_object('project_id',project_id))->0->'assignee_names'
    = '["Actions admin","Actions member"]'::jsonb;
  task := task_api(admin_id,'edit',args||jsonb_build_object('due_date',current_date+1),gen_random_uuid());
  assert (task->>'due_date')::date=current_date+1;
  assert task_api(admin_id,'list',jsonb_build_object('project_id',project_id,'deadline',current_date))='[]'::jsonb;
  assert jsonb_array_length(task_api(admin_id,'list',jsonb_build_object('project_id',project_id,'deadline',current_date+1)))=1;
  args := args||jsonb_build_object('version',task->'version');
  task := task_api(admin_id,'begin',args,gen_random_uuid());
  args := args||jsonb_build_object('version',task->'version','text','Old result');
  task := task_api(admin_id,'result',args,gen_random_uuid());
  select id into result_id from task_results where task_results.task_id=(task->>'id')::uuid;
  insert into task_attachments(task_id,result_id,name,mime_type,size,storage_path)
    values(task_id,result_id,'result.txt','text/plain',10,attachment_path);
  args := args||jsonb_build_object('version',task->'version');
  task := task_api(admin_id,'cancel',args,gen_random_uuid());
  args := args||jsonb_build_object('version',task->'version');
  assert jsonb_array_length(task_api(admin_id,'list',jsonb_build_object('project_id',project_id,'status','cancelled')))=1;
  begin
    perform task_api(member_id,'restore',args,gen_random_uuid());
    raise exception 'Non-author restore was allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform task_api(member_id,'delete',args,gen_random_uuid());
    raise exception 'Non-admin deletion was allowed';
  exception when insufficient_privilege then null; end;

  task := task_api(admin_id,'restore',args,gen_random_uuid());
  assert task->>'status'='new' and task->>'result' is null;
  assert task_api(admin_id,'task',args)->'attachments'='[]'::jsonb;
  args := args||jsonb_build_object('version',task->'version');
  begin
    perform task_api(admin_id,'delete',args,gen_random_uuid());
    raise exception 'Active task deletion was allowed';
  exception when insufficient_privilege then null; end;
  task := task_api(admin_id,'cancel',args,gen_random_uuid());
  begin
    perform task_api(admin_id,'delete',args,gen_random_uuid());
    raise exception 'Stale deletion was allowed';
  exception when serialization_failure then null; end;
  args := args||jsonb_build_object('version',task->'version');
  assert task_api(admin_id,'delete',args,deletion_request)='{"deleted":true}'::jsonb;
  assert task_api(admin_id,'delete',args,deletion_request)='{"deleted":true}'::jsonb;
  assert not exists(select 1 from tasks where id=task_id);
  assert exists(select 1 from storage_uploads where path=attachment_path and state='staging');
end $$;
rollback;
