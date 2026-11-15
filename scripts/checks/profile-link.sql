begin;
set local role service_role;
do $$
declare admin_id uuid; u uuid; r jsonb; n bigint; project bigint;
begin
 select id into admin_id from users where telegram_id=1287414278;
 r:=create_member(admin_id,'Unlinked profile');
 u:=(r->>'id')::uuid;
 assert (select telegram_id is null from users where id=u);
 assert jsonb_typeof(team_command_user(u,'projects'))='array';
 select min(id) into project from projects where not archived;
 r:=task_api(u,'create',jsonb_build_object('title','No Telegram yet','project_id',project,'due_date',current_date),gen_random_uuid());
 n:=(r->>'number')::bigint;
 assert task_api(u,'task',jsonb_build_object('number',n))->>'title'='No Telegram yet';
 perform issue_link_code(u,'test-hash');
 r:=consume_link_code(984000000000,'test-hash');
 assert r->>'id'=u::text;
 begin
 perform consume_link_code(984000000000,'test-hash');
 raise exception 'Code reused';
 exception when insufficient_privilege then null; end;
 r:=bot_event(984000000000,984000000000,'Linked profile','open',n::text);
 assert r#>>'{task,title}'='No Telegram yet';
 perform issue_link_code(u,'expired');
 update telegram_link_codes set expires_at=now()-interval '1 second' where user_id=u;
 begin
 perform consume_link_code(984000000000,'expired');
 raise exception 'Expired code accepted';
 exception when insufficient_privilege then null; end;
end $$;
rollback;
