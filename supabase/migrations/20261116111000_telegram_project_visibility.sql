begin;
do $patch$
declare definition text;
begin
 definition:=pg_get_functiondef('public.bot_event_unfiltered(bigint,bigint,text,text,text)'::regprocedure);
 definition:=replace(definition,'from projects where not archived','from projects where not archived and can_view_project(id,u.id)');
 definition:=replace(definition,'from projects p where not archived','from projects p where not archived and can_view_project(p.id,u.id)');
 definition:=replace(definition,'p.id::text=p_value and not p.archived','p.id::text=p_value and not p.archived and can_view_project(p.id,u.id)');
 definition:=replace(definition,'p.id=value::bigint and not archived','p.id=value::bigint and not archived and can_view_project(p.id,u.id)');
 execute definition;
end $patch$;
notify pgrst,'reload schema';
commit;
