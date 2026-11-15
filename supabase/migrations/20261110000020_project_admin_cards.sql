do $$
declare definition text; signature text;
begin
 foreach signature in array array['public.team_command_user(uuid,text,jsonb)','public.team_command(bigint,text,jsonb)'] loop
 select pg_get_functiondef(signature::regprocedure) into definition;
 definition:=replace(definition,'jsonb_agg(to_jsonb(q) order by q.id)',
 'jsonb_agg(to_jsonb(q) || jsonb_build_object(''admins'',(select coalesce(jsonb_agg(pa.user_id),''[]'') from public.project_admins pa where pa.project_id=q.id)) order by q.id)');
 execute definition;
 end loop;
end $$;
