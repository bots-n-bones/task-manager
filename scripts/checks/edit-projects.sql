-- Regression checks run against local Supabase inside a rolled-back transaction.
begin;
set local role service_role;
do $$
declare a bigint:=960000000000; u uuid; peer uuid; task_no bigint; project bigint; r jsonb;
begin
 perform bot_event(a,a,'owner','start');
 perform bot_event(a+1,a+1,'peer','start');
 select id into u from users where telegram_id=a;
 select id into peer from users where telegram_id=a+1;
 r:=bot_event(a+2,1287414278,'Илья','project_new');
 assert r->>'step'='project_name';
 r:=bot_event(a+3,1287414278,'Илья','text','Test project');
 select id into project from projects where name='Test project';
 assert project is not null;
 insert into processed_updates(update_id) values(a+4);
 insert into tasks(author_id,assignee_id,title,due_date,creation_update_id)
 values(u,u,'Before',current_date,a+4) returning number into task_no;
 r:=bot_event(a+5,a+1,'peer','edit',task_no||':1');
 assert r->>'message'='Редактирование недоступно.';
 perform bot_event(a+6,a,'owner','edit',task_no||':1');
 perform bot_event(a+7,a,'owner','pick',(a+6)||':'||project);
 perform bot_event(a+8,a,'owner','text','After');
 perform bot_event(a+9,a,'owner','skip',(a+8)::text);
 perform bot_event(a+10,a,'owner','flag',(a+9)||':quick');
 perform bot_event(a+11,a,'owner','next',(a+10)::text);
 perform bot_event(a+12,a,'owner','text','12.11.2026');
 perform bot_event(a+13,a,'owner','pick',(a+12)||':'||peer);
 perform bot_event(a+14,a,'owner','next',(a+13)::text);
 r:=bot_event(a+15,a,'owner','save',(a+14)::text);
 assert r#>>'{task,title}'='After';
 assert r#>>'{task,project_id}'=project::text;
 assert r#>>'{task,quick}'='true';
 assert jsonb_array_length(r#>'{task,assignees}')=2;
 assert bot_event(a+15,a,'owner','save',(a+14)::text)=r;
 r:=bot_event(a+16,1287414278,'Илья','archive',project::text);
 assert (select archived from projects where id=project);
 assert exists(select 1 from tasks where number=task_no);
 perform bot_event(a+17,1287414278,'Илья','restore',project::text);
 assert not(select archived from projects where id=project);
 -- Parallel edit invalidates a pending form without losing the committed write.
 perform bot_event(a+18,a,'owner','edit',task_no||':2');
 perform bot_event(a+19,a,'owner','pick',(a+18)||':'||project);
 perform bot_event(a+20,a,'owner','text','Stale');
 perform bot_event(a+21,a,'owner','skip',(a+20)::text);
 perform bot_event(a+22,a,'owner','next',(a+21)::text);
 perform bot_event(a+23,a,'owner','text','12.11.2026');
 perform bot_event(a+24,a,'owner','next',(a+23)::text);
 perform team_command(1287414278,'edit',jsonb_build_object('number',task_no,'version',2,'title','Concurrent'));
 r:=bot_event(a+25,a,'owner','save',(a+24)::text);
 assert r->>'message' like 'Задача или права изменились%';
 assert (select title from tasks where number=task_no)='Concurrent';
end $$;
rollback;
