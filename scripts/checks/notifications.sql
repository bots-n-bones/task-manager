begin;
set local role service_role;
do $$
declare a bigint:=980000000000; u uuid; t uuid; n jsonb; day date:=(now() at time zone 'Europe/Moscow')::date;
 tm timestamptz:=((now() at time zone 'Europe/Moscow')::date+time '10:00') at time zone 'Europe/Moscow';
begin
 tm:=greatest(tm,now()+interval '1 minute');
 perform bot_event(a,a,'notification test','start');
 select id into u from users where telegram_id=a;
 insert into processed_updates(update_id) values(a+1);
 insert into tasks(author_id,assignee_id,title,due_date,creation_update_id)
 values(u,u,'Deadline test',day,a+1) returning id into t;
 perform notification_queue(array[a],(day+time '08:00') at time zone 'Europe/Moscow');
 assert not exists(select 1 from notification_deliveries where recipient_id=u);
 perform notification_queue(array[a],tm);
 perform notification_queue(array[a],tm);
 assert (select count(*) from notification_deliveries where recipient_id=u)=1;
 update tasks set due_date=day+1 where id=t;
 n:=notification_claim(array[a],tm); assert n is null;
 update tasks set due_date=day-1 where id=t;
 perform notification_queue(array[a],tm);
 n:=notification_claim(array[a],tm);
 assert n->>'kind'='overdue';
 assert not notification_finish((n->>'id')::bigint,gen_random_uuid(),'sent');
 assert notification_finish((n->>'id')::bigint,(n->>'lease_token')::uuid,'retry','test',1);
 update notification_deliveries set next_attempt_at=tm where id=(n->>'id')::bigint;
 n:=notification_claim(array[a],tm+interval '1 hour');
 assert n->>'attempts'='2';
 assert notification_finish((n->>'id')::bigint,(n->>'lease_token')::uuid,'unavailable');
 assert not(select telegram_available from users where id=u);
 perform bot_event(a+2,a,'notification test','start');
 assert (select telegram_available from users where id=u);
end $$;
rollback;
