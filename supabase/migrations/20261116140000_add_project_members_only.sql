begin;
do $patch$
declare definition text; signature text;
begin
 foreach signature in array array['public.team_command_user(uuid,text,jsonb)','public.team_command(bigint,text,jsonb)'] loop
   definition:=pg_get_functiondef(signature::regprocedure);
   if strpos(definition,'delete from project_members where project_id=p.id;')=0 then raise exception 'Unexpected project membership implementation'; end if;
   definition:=replace(definition,'delete from project_members where project_id=p.id;','');
   definition:=replace(definition,
     'insert into project_members select p.id,member_id from unnest(ids) member_id;',
     'insert into project_members select p.id,member_id from unnest(ids) member_id on conflict do nothing;');
   execute definition;
 end loop;
end $patch$;
notify pgrst,'reload schema';
commit;
