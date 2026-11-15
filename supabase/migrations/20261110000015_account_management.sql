create function public.manage_member(p_admin uuid,p_user uuid,p_active boolean default null,p_role text default null)
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare target users%rowtype;
begin
 perform pg_advisory_xact_lock(78124930815);
 if not exists(select 1 from users where id=p_admin and active and role='admin') then raise exception 'Admin required' using errcode='42501'; end if;
 select * into target from users where id=p_user for update;
 if not found then raise exception 'User unavailable' using errcode='42501'; end if;
 if target.active and target.role='admin' and (p_active=false or p_role='user') and
   not exists(select 1 from users where id<>target.id and active and role='admin') then
   raise exception 'Last active administrator required' using errcode='23514';
 end if;
 update users set active=coalesce(p_active,active),role=coalesce(p_role,role) where id=target.id returning * into target;
 if not target.active then delete from web_sessions where user_id=target.id; end if;
 return jsonb_build_object('id',target.id,'name',target.name,'login',target.login,'active',target.active,'role',target.role,'telegram_id',target.telegram_id);
end $$;
revoke all on function public.manage_member(uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.manage_member(uuid,uuid,boolean,text) to service_role;
