alter function public.bot_event(bigint,bigint,text,text,text) rename to bot_event_unfiltered;
revoke all on function public.bot_event_unfiltered(bigint,bigint,text,text,text) from public,anon,authenticated;
create function public.bot_event(p_update bigint,p_actor bigint,p_name text,p_action text,p_value text default '')
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare u users%rowtype; answer jsonb; choices jsonb; page_no int; selected text;
begin
 if p_action not in ('filters','all_status','all_member','all_project') then
   return bot_event_unfiltered(p_update,p_actor,p_name,p_action,p_value);
 end if;
 perform pg_advisory_xact_lock(p_actor);
 select response into answer from processed_updates where update_id=p_update;
 if found then return answer; end if;
 select * into u from users where telegram_id=p_actor and active and role='admin';
 if not found then answer:=jsonb_build_object('message','Доступ закрыт.');
 elsif exists(select 1 from bot_sessions where user_id=u.id) then
   answer:=jsonb_build_object('message','Завершите текущую форму или отправьте /cancel.');
 elsif p_action='filters' then
   select coalesce(jsonb_agg(q),'[]') into choices from (
     select 'Статус · '||label as name,'all_status:'||value||':0' as action from
       (values('new','Новая'),('in_progress','В работе'),('review','На проверке'),('done','Готово'),('cancelled','Отменена')) s(value,label)
     union all select 'Проект · '||name,'all_project:'||id||':0' from projects
     union all select 'Участник · '||name,'all_member:'||id||':0' from users where active
   ) q;
   answer:=jsonb_build_object('filter_options',choices);
 else
   selected:=split_part(p_value,':',1);
   page_no:=case when split_part(p_value,':',2) ~ '^[0-9]{1,8}$' then split_part(p_value,':',2)::int else 0 end;
   select jsonb_build_object('tasks',coalesce(jsonb_agg(to_jsonb(q) order by q.number desc),'[]'),'page',page_no,'scope',p_action||':'||selected)
   into answer from (
     select number,title,status from tasks t where
       (p_action='all_status' and status=selected) or
       (p_action='all_project' and project_id::text=selected) or
       (p_action='all_member' and exists(select 1 from task_assignees a where a.task_id=t.id and a.user_id::text=selected))
     order by number desc limit 6 offset page_no*5
   ) q;
 end if;
 answer:=answer||jsonb_build_object('admin',u.role='admin','actor_id',u.id);
 insert into processed_updates(update_id,state,response) values(p_update,'processed',answer);
 return answer;
end $$;
revoke all on function public.bot_event(bigint,bigint,text,text,text) from public,anon,authenticated;
grant execute on function public.bot_event(bigint,bigint,text,text,text) to service_role;
