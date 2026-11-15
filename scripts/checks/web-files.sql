begin;
set local role service_role;
do $$
declare a bigint:=983000000000; u uuid; n bigint; project bigint; r jsonb; key uuid:=gen_random_uuid(); attachment uuid;
begin
 perform bot_event(a,a,'web file','start');
 select id into u from users where telegram_id=a;
 select min(id) into project from projects;
 r:=task_api(u,'create',jsonb_build_object('title','Web file','project_id',project,'due_date',current_date),gen_random_uuid());
 n:=(r->>'number')::bigint;
 perform task_api(u,'begin',jsonb_build_object('number',n,'version',1),gen_random_uuid());
 r:=web_file_result(u,key,n,2,jsonb_build_object('name','test.txt','size',5,'mime_type','text/plain','path',u||'/'||key||'/digest'));
 assert r->>'status'='review';
 assert web_file_result(u,key,n,2,'{}')=r;
 select a.id into attachment from task_attachments a join tasks t on t.id=a.task_id where t.number=n;
 assert attachment_access(a,attachment)->>'name'='test.txt';
 assert (select count(*) from task_attachments where id=attachment)=1;
end $$;
rollback;
