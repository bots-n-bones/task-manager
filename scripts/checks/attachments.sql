begin;
set local role service_role;
do $$
declare a bigint:=990000000000; u uuid; n bigint; task_uuid uuid; r jsonb; attachment uuid;
begin
 perform bot_event(a,a,'file test','start');
 perform bot_event(a+1,a+1,'outsider','start');
 select id into u from users where telegram_id=a;
 insert into processed_updates(update_id) values(a+2);
 insert into tasks(author_id,assignee_id,title,due_date,creation_update_id)
 values(u,u,'File task',current_date,a+2) returning number,id into n,task_uuid;
 perform bot_event(a+3,a,'file test','begin',n::text);
 perform bot_event(a+4,a,'file test','result',n::text);
 r:=attachment_result(a,a+5,'file test',jsonb_build_object('name','test.txt','size',5,'mime_type','text/plain','path',a||'/'||(a+5),'file_id','test'));
 assert r#>>'{task,status}'='review';
 select id into attachment from task_attachments where task_id=task_uuid;
 assert attachment is not null;
 assert attachment_access(a,attachment)->>'name'='test.txt';
 begin
 perform attachment_access(a+1,attachment);
 raise exception 'Outsider accessed file';
 exception when insufficient_privilege then null; end;
 assert attachment_access(1287414278,attachment)->>'name'='test.txt';
 perform attachment_result(a,a+5,'file test',jsonb_build_object('name','test.txt','size',5,'mime_type','text/plain','path',a||'/'||(a+5),'file_id','test'));
 assert (select count(*) from task_attachments where task_id=task_uuid)=1;
 r:=bot_event(a+6,a,'file test','open',n::text);
 assert jsonb_array_length(r#>'{task,attachments}')=1;
end $$;
rollback;
