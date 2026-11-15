begin;
set local role service_role;
do $$
declare a bigint:=981000000000; owner_id uuid; other_id uuid; admin_id uuid; project bigint; r jsonb; n bigint; key uuid:=gen_random_uuid(); ver bigint;
begin
 perform bot_event(a,a,'API owner','start');
 perform bot_event(a+1,a+1,'API other','start');
 select id into owner_id from users where telegram_id=a;
 select id into other_id from users where telegram_id=a+1;
 select id into admin_id from users where telegram_id=1287414278;
 select min(id) into project from projects where not archived;
 r:=task_api(owner_id,'create',jsonb_build_object('title','API task','project_id',project,'due_date',current_date),key);
 n:=(r->>'number')::bigint;
 assert task_api(owner_id,'create','{}',key)=r;
 assert (select count(*) from tasks where number=n)=1;
 assert jsonb_array_length(task_api(other_id,'list'))=0;
 begin
 perform task_api(other_id,'task',jsonb_build_object('number',n));
 raise exception 'Unauthorized read';
 exception when insufficient_privilege then null; end;
 r:=task_api(owner_id,'begin',jsonb_build_object('number',n,'version',1),gen_random_uuid());
 begin
 perform task_api(owner_id,'result',jsonb_build_object('number',n,'version',1,'text','Done'),gen_random_uuid());
 raise exception 'Stale write';
 exception when serialization_failure then null; end;
 r:=task_api(owner_id,'result',jsonb_build_object('number',n,'version',2,'text','Done'),gen_random_uuid());
 begin
 perform task_api(owner_id,'approve',jsonb_build_object('number',n,'version',3),gen_random_uuid());
 raise exception 'Unauthorized review';
 exception when insufficient_privilege then null; end;
 r:=task_api(admin_id,'approve',jsonb_build_object('number',n,'version',3),gen_random_uuid());
 assert r->>'status'='done';
 assert r->>'completed_at' is not null;
end $$;
rollback;
