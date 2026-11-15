begin;
set local role service_role;
do $$
declare a bigint:=989000000000; admin_id uuid; peer uuid; project bigint; r jsonb; number bigint; task_uuid uuid;
begin
 select id into admin_id from users where telegram_id=1287414278;
 insert into users(telegram_id,name,role) values(a,'Second admin','admin') returning id into peer;
 r:=team_command_user(admin_id,'project_create',jsonb_build_object('name','Responsible check'));
 project:=(r->>'id')::bigint;
 r:=bot_event(a,1287414278,'Илья','project_team',project::text);
 assert r->>'step'='admin_project';
 r:=bot_event(a+1,1287414278,'Илья','admin_pick',a||':'||peer);
 r:=bot_event(a+2,1287414278,'Илья','admin_save',(a+1)::text);
 assert r->>'message'='Ответственные сохранены.';
 assert (select count(*) from project_admins where project_id=project)=2;
 r:=bot_event(a+3,1287414278,'Илья','project_team',project::text);
 perform bot_event(a+4,1287414278,'Илья','admin_pick',(a+3)||':'||admin_id);
 perform bot_event(a+5,1287414278,'Илья','admin_pick',(a+4)||':'||peer);
 r:=bot_event(a+6,1287414278,'Илья','admin_save',(a+5)::text);
 assert r->>'message'='Выберите хотя бы одного администратора.';
 assert (select count(*) from project_admins where project_id=project)=2;
 perform bot_event(a+7,1287414278,'Илья','cancel');
 insert into processed_updates(update_id) values(a+8);
 insert into tasks(author_id,assignee_id,title,due_date,creation_update_id,project_id)
 values(admin_id,admin_id,'Responsible task',current_date,a+8,project) returning tasks.number,id into number,task_uuid;
 r:=bot_event(a+9,1287414278,'Илья','task_team',number||':1');
 assert r->>'step'='admin_task';
 perform bot_event(a+10,1287414278,'Илья','admin_pick',(a+9)||':'||peer);
 r:=bot_event(a+11,1287414278,'Илья','admin_save',(a+10)::text);
 assert r->>'message'='Ответственные сохранены.';
 assert (select count(*) from task_admins where task_id=task_uuid)=1;
 assert exists(select 1 from task_admins where task_id=task_uuid and user_id=admin_id);
 r:=bot_event(a+12,1287414278,'Илья','task_team',number||':1');
 assert r->>'message'='Карточка изменилась. Откройте её заново.';
 set constraints all immediate;
end $$;
rollback;
