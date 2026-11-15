begin;
set local role service_role;
do $$
declare a bigint:=985000000000; u uuid; n bigint; t uuid; r jsonb;
begin
 perform bot_event(a,a,'version test','start');
 select id into u from users where telegram_id=a;
 insert into processed_updates(update_id) values(a+1);
 insert into tasks(author_id,assignee_id,title,due_date,creation_update_id)
 values(u,u,'Version test',current_date,a+1) returning number,id into n,t;
 update tasks set title='Changed' where id=t;
 r:=bot_event(a+2,a,'version test','begin',n||':1');
 assert r->>'message'='Карточка изменилась. Откройте задачу заново.';
 assert (select status from tasks where id=t)='new';
 perform bot_event(a+3,a,'version test','begin',n||':2');
 perform bot_event(a+4,a,'version test','result',n||':3');
 update tasks set description='Concurrent edit' where id=t;
 r:=bot_event(a+5,a,'version test','text','Stale result');
 assert r->>'message'='Задача или права изменились. Откройте карточку заново.';
 assert (select status from tasks where id=t)='in_progress';
 assert (select result from tasks where id=t) is null;
end $$;
rollback;
