begin;
set local role service_role;
do $$
declare a bigint:=991000000000; u uuid; peer uuid; t uuid; n jsonb; admin_id uuid; number bigint; ver bigint;
day date:=(now() at time zone 'Europe/Moscow')::date; tm timestamptz;
begin
 tm:=greatest((day+time '10:00') at time zone 'Europe/Moscow',now()+interval '1 minute');
 perform bot_event(a,a,'Reminder owner','start');
 perform bot_event(a+1,a+1,'Reminder peer','start');
 select id into u from users where telegram_id=a;
 select id into peer from users where telegram_id=a+1;
 insert into processed_updates(update_id) values(a+2);
 insert into tasks(author_id,assignee_id,title,due_date,creation_update_id)
 values(u,u,'Queue lifecycle',day,a+2) returning id into t;
 perform notification_queue(array[a,a+1],tm);
 -- Reassignment after enqueue cancels the old recipient and queues the new one.
 delete from task_assignees where task_id=t;
 insert into task_assignees values(t,peer);
 perform notification_queue(array[a,a+1],tm);
 n:=notification_claim(array[a,a+1],tm);
 assert n->>'recipient_id'=peer::text;
 assert (select state from notification_deliveries where recipient_id=u and task_id=t)='cancelled';
 -- A terminated worker releases its leased item for a retry.
 update notification_deliveries set lease_until=tm-interval '1 minute' where id=(n->>'id')::bigint;
 n:=notification_claim(array[a,a+1],tm);
 assert n->>'attempts'='2';
 perform notification_finish((n->>'id')::bigint,(n->>'lease_token')::uuid,'retry','test',1);
 update notification_deliveries set next_attempt_at=tm where id=(n->>'id')::bigint;
 -- Cancellation before retry suppresses delivery.
 perform set_config('app.actor',u::text,true);
 update tasks set status='cancelled' where id=t;
 assert notification_claim(array[a,a+1],tm) is null;
 assert (select state from notification_deliveries where recipient_id=peer and task_id=t)='cancelled';
 -- Completion between enqueue and delivery suppresses the message too.
 insert into processed_updates(update_id) values(a+3);
 insert into tasks(author_id,assignee_id,title,due_date,creation_update_id)
 values(u,u,'Completed before send',day,a+3) returning id,tasks.number into t,number;
 perform notification_queue(array[a,a+1],tm);
 update tasks set status='in_progress' where id=t;
 update tasks set result='Done',status='review' where id=t returning version into ver;
 select id into admin_id from users where telegram_id=1287414278;
 perform task_api(admin_id,'approve',jsonb_build_object('number',number,'version',ver),gen_random_uuid());
 assert notification_claim(array[a,a+1],tm) is null;
 assert (select state from notification_deliveries where task_id=t)='cancelled';
 set constraints all immediate;
end $$;
rollback;
