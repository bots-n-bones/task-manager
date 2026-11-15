create function public.reserve_login(p_admin uuid,p_user uuid,p_login text)
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare u users%rowtype;
begin
 if not exists(select 1 from users where id=p_admin and active and role='admin') then raise exception 'Admin required' using errcode='42501'; end if;
 select * into u from users where id=p_user and active for update;
 if not found then raise exception 'User unavailable' using errcode='42501'; end if;
 if u.login is not null and u.login<>p_login then raise exception 'Login already assigned' using errcode='23514'; end if;
 update users set login=p_login where id=u.id returning * into u;
 return to_jsonb(u);
end $$;
revoke all on function public.reserve_login(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.reserve_login(uuid,uuid,text) to service_role;
