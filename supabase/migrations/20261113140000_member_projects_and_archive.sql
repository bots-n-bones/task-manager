begin;
do $migration$
declare definition text; signature text;
 old_branch text := $old$elsif p_action='project_create' then
   if u.role <> 'admin' then raise exception 'Admin required' using errcode='42501'; end if;
   insert into projects(name,description) values(btrim(p_data->>'name'),p_data->>'description') returning * into p;
   insert into project_admins values(p.id,u.id);
   return to_jsonb(p);$old$;
 new_branch text := $new$elsif p_action='project_create' then
   if p_data ? 'admins' then
     select array_agg(distinct value::uuid) into admins from jsonb_array_elements_text(p_data->'admins');
   elsif u.role='admin' then admins:=array[u.id];
   else select array_agg(id) into admins from users where active and role='admin';
   end if;
   if coalesce(cardinality(admins),0)=0 or exists(
     select 1 from unnest(admins) selected(member_id) where not exists(
       select 1 from users where id=selected.member_id and active and role='admin')) then
     raise exception 'Select an active responsible administrator.' using errcode='23514';
   end if;
   insert into projects(name,description) values(btrim(p_data->>'name'),p_data->>'description') returning * into p;
   insert into project_admins select p.id,id from unnest(admins) id;
   return to_jsonb(p);$new$;
begin
 foreach signature in array array['public.team_command_user(uuid,text,jsonb)','public.team_command(bigint,text,jsonb)'] loop
   definition:=pg_get_functiondef(signature::regprocedure);
   if strpos(definition,old_branch)=0 then raise exception 'Unexpected project creation function: %',signature; end if;
   execute replace(definition,old_branch,new_branch);
 end loop;
 definition:=pg_get_functiondef('public.task_api(uuid,text,jsonb,uuid)'::regprocedure);
 if strpos(definition,$old$when 'cancelled' then listed.status='cancelled'$old$)=0 then raise exception 'Unexpected archive filter'; end if;
 execute replace(definition,$old$when 'cancelled' then listed.status='cancelled'$old$,
 $new$when 'archive' then listed.status in ('done','cancelled') and is_assignee(listed.id,u.id) when 'cancelled' then listed.status='cancelled'$new$);
end $migration$;
notify pgrst,'reload schema';
commit;
