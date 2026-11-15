alter function public.bot_event(bigint,bigint,text,text,text) rename to bot_event_lists;
revoke all on function public.bot_event_lists(bigint,bigint,text,text,text) from public,anon,authenticated;
create function public.bot_event(p_update bigint,p_actor bigint,p_name text,p_action text,p_value text default '')
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare u users%rowtype; s bot_sessions%rowtype; t tasks%rowtype; answer jsonb; d jsonb; st text; msg text; options jsonb; member uuid; chosen jsonb;
begin
 perform pg_advisory_xact_lock(p_actor);
 select response into answer from processed_updates where update_id=p_update;
 if found then return answer; end if;
 select * into u from users where telegram_id=p_actor and active;
 delete from bot_sessions where user_id=u.id and expires_at<=now();
 select * into s from bot_sessions where user_id=u.id;
 if p_action not in ('project_team','task_team','admin_pick','admin_save') and coalesce(s.step,'') not in ('admin_project','admin_task') then
   return bot_event_lists(p_update,p_actor,p_name,p_action,p_value);
 end if;
 if u.role is distinct from 'admin' then
   answer:=jsonb_build_object('message','Требуются права администратора.');
 elsif s.user_id is not null and s.step not in ('admin_project','admin_task') then
   answer:=jsonb_build_object('message','Завершите форму или отправьте /cancel.');
 else
   d:=coalesce(s.draft,'{}'); st:=s.step;
   if p_action='project_team' and s.user_id is null then
     if exists(select 1 from projects where id::text=p_value) then
       select coalesce(jsonb_agg(user_id),'[]') into chosen from project_admins where project_id=p_value::bigint;
       st:='admin_project'; d:=jsonb_build_object('id',p_value::bigint,'admins',chosen);
     else msg:='Проект недоступен.'; end if;
   elsif p_action='task_team' and s.user_id is null then
     select * into t from tasks where number=split_part(p_value,':',1)::bigint;
     if t.id is null or t.status in ('done','cancelled') then msg:='Редактирование недоступно.';
     elsif t.version is distinct from split_part(p_value,':',2)::bigint then msg:='Карточка изменилась. Откройте её заново.';
     else
       select coalesce(jsonb_agg(user_id),'[]') into chosen from task_admins where task_id=t.id;
       st:='admin_task'; d:=jsonb_build_object('number',t.number,'version',t.version,'admins',chosen);
     end if;
   elsif p_action in ('cancel','menu') or (p_action in ('abort','back') and p_value=d->>'token') then
     st:='menu';
   elsif p_action='start' then null;
   elsif split_part(p_value,':',1) is distinct from d->>'token' then msg:='Эта кнопка устарела.';
   elsif p_action='admin_pick' then
     select id into member from users where id::text=split_part(p_value,':',2) and active and role='admin';
     if member is not null then
       if d->'admins' @> jsonb_build_array(member) then
         select coalesce(jsonb_agg(x),'[]') into chosen from jsonb_array_elements(d->'admins') x where x<>to_jsonb(member);
       else chosen:=d->'admins'||jsonb_build_array(member); end if;
       d:=jsonb_set(d,'{admins}',chosen);
     end if;
   elsif p_action='admin_save' then
     if jsonb_array_length(d->'admins')=0 then msg:='Выберите хотя бы одного администратора.';
     else
       begin
         if st='admin_project' then perform team_command_user(u.id,'project_admins',d);
         else perform team_command_user(u.id,'edit',d); end if;
         st:='menu'; msg:='Ответственные сохранены.';
       exception when serialization_failure or check_violation or insufficient_privilege then
         msg:='Задача или состав команды изменились. Отмените форму и откройте её заново.';
       end;
     end if;
   else msg:='Выберите ответственных или отмените форму.';
   end if;
   st:=coalesce(st,'menu');
   d:=d||jsonb_build_object('token',p_update::text);
   if st='menu' then delete from bot_sessions where user_id=u.id;
   else
     insert into bot_sessions(user_id,step,draft) values(u.id,st,d)
       on conflict(user_id) do update set step=excluded.step,draft=excluded.draft;
     select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'selected',d->'admins' @> jsonb_build_array(id)) order by name),'[]')
       into options from users where active and role='admin';
   end if;
   answer:=jsonb_build_object('step',st,'draft',d,'admin_options',options,'message',msg);
 end if;
 answer:=answer||jsonb_build_object('admin',u.role='admin','actor_id',u.id);
 insert into processed_updates(update_id,state,response) values(p_update,'processed',answer);
 return answer;
end $$;
revoke all on function public.bot_event(bigint,bigint,text,text,text) from public,anon,authenticated;
grant execute on function public.bot_event(bigint,bigint,text,text,text) to service_role;
