begin;
set local role service_role;
do $$
declare a bigint:=987000000000; u uuid; t uuid;
begin
 perform bot_event(a,a,'Integrity test','start');
 select id into u from users where telegram_id=a;
 insert into processed_updates(update_id) values(a+1);
 insert into tasks(author_id,assignee_id,title,due_date,creation_update_id)
 values(u,u,'Integrity test',current_date,a+1) returning id into t;
 set constraints all immediate;
 set constraints all deferred;
 begin
   delete from task_assignees where task_id=t;
   set constraints all immediate;
   raise exception 'Missing assignee accepted';
 exception when check_violation then null;
 end;
 set constraints all deferred;
 begin
   delete from task_admins where task_id=t;
   set constraints all immediate;
   raise exception 'Missing administrator accepted';
 exception when check_violation then null;
 end;
end $$;
rollback;
