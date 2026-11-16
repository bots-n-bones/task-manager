begin;
set local role service_role;
do $test$
declare owner uuid; next_owner uuid; member uuid; outsider uuid; project bigint; reply jsonb;
begin
 insert into users(name,role) values('QA project owner','admin') returning id into owner;
 insert into users(name,role) values('QA next project owner','admin') returning id into next_owner;
 insert into users(name,role) values('QA project member','user') returning id into member;
 insert into users(name,role) values('QA outsider','user') returning id into outsider;
 reply:=team_command_user(owner,'project_create',jsonb_build_object('name','Personal membership QA','visibility','personal','members',jsonb_build_array(member)));
 project:=(reply->>'id')::bigint;
 assert (select count(*) from project_admins where project_id=project)=1;
 assert can_view_project(project,member);
 assert not can_view_project(project,outsider);
 assert not exists(select 1 from tasks where project_id=project);
 assert exists(select 1 from jsonb_array_elements(team_command_user(member,'projects')) p where (p->>'id')::bigint=project and p->'members' @> jsonb_build_array(member));
 begin
   perform team_command_user(member,'project_members',jsonb_build_object('id',project,'members',jsonb_build_array(outsider)));
   raise exception 'Member changed access';
 exception when insufficient_privilege then null; end;
 begin
   perform team_command_user(owner,'project_admins',jsonb_build_object('id',project,'admins',jsonb_build_array(owner,next_owner)));
   raise exception 'Multiple project admins accepted';
 exception when check_violation then null; end;
 perform team_command_user(owner,'project_admins',jsonb_build_object('id',project,'admins',jsonb_build_array(next_owner)));
 assert (select user_id from project_admins where project_id=project)=next_owner;
 perform team_command_user(next_owner,'project_members',jsonb_build_object('id',project,'members','[]'::jsonb));
 assert can_view_project(project,member);
 perform team_command_user(next_owner,'project_members',jsonb_build_object('id',project,'members',jsonb_build_array(outsider)));
 assert can_view_project(project,outsider);
 assert can_view_project(project,member);
 perform team_command_user(next_owner,'project_members',jsonb_build_object('id',project,'members',jsonb_build_array(outsider)));
 assert (select count(*) from project_members where project_id=project)=2;
 begin
   perform team_command_user(member,'project_create','{"name":"Forbidden project"}');
   raise exception 'Member created a project';
 exception when insufficient_privilege then null; end;
 perform delete_empty_project(next_owner,project);
 assert not exists(select 1 from project_members where project_id=project);
 set constraints all immediate;
 raise notice 'Personal membership, single project owner, replacement and permissions verified';
end $test$;
rollback;
