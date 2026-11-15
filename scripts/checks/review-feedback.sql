begin;
do $test$
declare
 member_id uuid; outsider_id uuid; admin_id uuid; project_id bigint; task_no bigint;
 result jsonb; details jsonb; listed jsonb; first_review uuid; request_id uuid; before_version bigint;
begin
 insert into users(name,role) values('Feedback member','user') returning id into member_id;
 insert into users(name,role) values('Feedback outsider','user') returning id into outsider_id;
 insert into users(name,role) values('Feedback admin','admin') returning id into admin_id;
 result:=team_command_user(admin_id,'project_create','{"name":"Review feedback test"}');
 project_id:=(result->>'id')::bigint;
 result:=task_api(member_id,'create',jsonb_build_object('title','Review feedback test','project_id',project_id,'due_date',current_date),gen_random_uuid());
 task_no:=(result->>'number')::bigint;
 result:=task_api(member_id,'begin',jsonb_build_object('number',task_no,'version',result->'version'),gen_random_uuid());
 result:=task_api(member_id,'result',jsonb_build_object('number',task_no,'version',result->'version','text','First submission'),gen_random_uuid());
 begin
   perform task_api(admin_id,'return',jsonb_build_object('number',task_no,'version',result->'version','comment','   '),gen_random_uuid());
   raise exception 'Empty feedback accepted';
 exception when check_violation then null; end;
 begin
   perform task_api(member_id,'return',jsonb_build_object('number',task_no,'version',result->'version','comment','Self review'),gen_random_uuid());
   raise exception 'Member review accepted';
 exception when insufficient_privilege then null; end;
 request_id:=gen_random_uuid();before_version:=(result->>'version')::bigint;
 result:=task_api(admin_id,'return',jsonb_build_object('number',task_no,'version',before_version,'comment',E'Add the source link.\nInclude the mobile screenshot.'),request_id);
 assert result->>'status'='in_progress';
 assert task_api(admin_id,'return',jsonb_build_object('number',task_no,'version',before_version,'comment','Retry'),request_id)=result;
 details:=task_api(member_id,'task',jsonb_build_object('number',task_no));
 assert details#>>'{latest_review,reviewer_name}'='Feedback admin';
 assert details#>>'{latest_review,comment}'=E'Add the source link.\nInclude the mobile screenshot.';
 assert (details#>>'{latest_review,needs_changes}')::boolean;
 assert jsonb_array_length(details->'reviews')=1;
 first_review:=(details#>>'{latest_review,id}')::uuid;
 listed:=task_api(member_id,'list',jsonb_build_object('project_id',project_id,'mine',true));
 assert (listed#>>'{0,latest_review,needs_changes}')::boolean;
 begin
   perform task_api(outsider_id,'task',jsonb_build_object('number',task_no));
   raise exception 'Feedback leaked to unrelated member';
 exception when insufficient_privilege then null; end;
 assert jsonb_array_length(task_api(outsider_id,'list',jsonb_build_object('project_id',project_id)))=0;
 -- Editing a deadline must not clear the feedback while work is still pending.
 result:=task_api(member_id,'edit',jsonb_build_object('number',task_no,'version',result->'version','due_date',current_date+1),gen_random_uuid());
 assert (task_api(member_id,'task',jsonb_build_object('number',task_no))#>>'{latest_review,needs_changes}')::boolean;
 -- An unchanged result text is still a fresh submission with its own review cycle.
 result:=task_api(member_id,'result',jsonb_build_object('number',task_no,'version',result->'version','text','First submission'),gen_random_uuid());
 details:=task_api(member_id,'task',jsonb_build_object('number',task_no));
 assert details->>'status'='review';
 assert not (details#>>'{latest_review,needs_changes}')::boolean;
 assert details#>>'{latest_review,comment}'=E'Add the source link.\nInclude the mobile screenshot.';
 result:=task_api(admin_id,'return',jsonb_build_object('number',task_no,'version',result->'version','comment','Use a full-page screenshot.'),gen_random_uuid());
 details:=task_api(member_id,'task',jsonb_build_object('number',task_no));
 assert details#>>'{latest_review,comment}'='Use a full-page screenshot.';
 assert jsonb_array_length(details->'reviews')=2;
 assert (details#>>'{reviews,1,id}')::uuid=first_review;
 result:=task_api(member_id,'result',jsonb_build_object('number',task_no,'version',result->'version','text','Updated submission with sources and screenshots'),gen_random_uuid());
 result:=task_api(admin_id,'approve',jsonb_build_object('number',task_no,'version',result->'version'),gen_random_uuid());
 details:=task_api(member_id,'task',jsonb_build_object('number',task_no));
 assert details->>'status'='done';
 assert details#>>'{latest_review,decision}'='approved';
 assert not (details#>>'{latest_review,needs_changes}')::boolean;
 assert jsonb_array_length(details->'reviews')=3;
 assert details#>>'{reviews,1,comment}'='Use a full-page screenshot.';
 assert not has_function_privilege('anon','public.task_latest_review(uuid)','EXECUTE');
 assert not has_function_privilege('authenticated','public.task_latest_review(uuid)','EXECUTE');
 set constraints all immediate;
 raise notice 'Feedback visibility, privacy, idempotency, resubmission and approval verified';
end $test$;
rollback;
