do $$
declare definition text;
begin
 select pg_get_functiondef('public.attachment_access(bigint,uuid)'::regprocedure) into definition;
 definition:=replace(definition,'public.attachment_access(p_actor bigint','public.attachment_access_user(p_user uuid');
 definition:=replace(definition,'telegram_id=p_actor','id=p_user');
 execute definition;
end $$;
revoke all on function public.attachment_access_user(uuid,uuid) from public,anon,authenticated;
grant execute on function public.attachment_access_user(uuid,uuid) to service_role;
