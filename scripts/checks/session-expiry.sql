begin;
set local role service_role;
do $$
declare a bigint:=988000000000; u uuid; r jsonb;
begin
 perform bot_event(a,a,'Expiry test','start');
 select id into u from users where telegram_id=a;
 perform bot_event(a+1,a,'Expiry test','create');
 -- The normal update trigger extends expiry, so set an expired value on initial insertion.
 delete from bot_sessions where user_id=u;
 insert into bot_sessions(user_id,step,draft,expires_at) values(u,'result','{"number":999}',now()-interval '1 second');
 assert attachment_access(a) is null;
 r:=bot_event(a+2,a,'Expiry test','start');
 assert r->>'step'='menu';
 assert not exists(select 1 from bot_sessions where user_id=u);
end $$;
rollback;
