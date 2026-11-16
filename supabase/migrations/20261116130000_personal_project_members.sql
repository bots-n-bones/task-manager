begin;
create table public.project_members (
 project_id bigint not null references public.projects on delete cascade,
 user_id uuid not null references public.users on delete cascade,
 primary key(project_id,user_id)
);
alter table public.project_members enable row level security;
revoke all on public.project_members from public,anon,authenticated;
grant select,insert,update,delete on public.project_members to service_role;
-- Preserve access if an older project had several administrators.
insert into public.project_members select a.project_id,a.user_id from public.project_admins a
 where exists(select 1 from public.project_admins b where b.project_id=a.project_id and b.user_id<a.user_id);
delete from public.project_admins a using public.project_admins b
 where a.project_id=b.project_id and a.user_id>b.user_id;
alter table public.project_admins add constraint project_single_admin unique(project_id) deferrable initially deferred;

create function public.guard_project_member() returns trigger
language plpgsql set search_path='' as $$
begin
 perform 1 from public.users where id=new.user_id and active and deleted_at is null for key share;
 if not found then raise exception 'Active member required' using errcode='23514'; end if;
 return new;
end $$;
create trigger guard_project_member before insert or update on public.project_members
 for each row execute function public.guard_project_member();

create function public.check_project_owner() returns trigger
language plpgsql set search_path='' as $$
declare project_no bigint;
begin
 if tg_table_name='projects' then project_no:=coalesce(new.id,old.id);
 else project_no:=coalesce(new.project_id,old.project_id); end if;
 if exists(select 1 from public.projects where id=project_no)
 and (select count(*) from public.project_admins where project_id=project_no)<>1 then
   raise exception 'Project requires exactly one administrator' using errcode='23514';
 end if;
 return null;
end $$;
create constraint trigger project_owner_required after insert or update on public.projects
 deferrable initially deferred for each row execute function public.check_project_owner();
create constraint trigger project_owner_required after insert or update or delete on public.project_admins
 deferrable initially deferred for each row execute function public.check_project_owner();

do $patch$
declare definition text; signature text;
begin
 definition:=pg_get_functiondef('public.can_view_project(bigint,uuid)'::regprocedure);
 definition:=replace(definition,'p.visibility=''shared''','exists(select 1 from public.project_members m where m.project_id=p.id and m.user_id=p_user) or p.visibility=''shared''');
 execute definition;
 foreach signature in array array['public.team_command_user(uuid,text,jsonb)','public.team_command(bigint,text,jsonb)'] loop
   definition:=pg_get_functiondef(signature::regprocedure);
   definition:=replace(definition,'to_jsonb(q) || jsonb_build_object(''admins''',
     'to_jsonb(q) || jsonb_build_object(''members'',(select coalesce(jsonb_agg(m.user_id),''[]'') from public.project_members m join public.users member on member.id=m.user_id where m.project_id=q.id and member.active and member.deleted_at is null)) || jsonb_build_object(''admins''');
   definition:=replace(split_part(definition,' select * into t from tasks',1),'coalesce(cardinality(admins),0)=0','coalesce(cardinality(admins),0)<>1')
     || ' select * into t from tasks' || split_part(definition,' select * into t from tasks',2);
   definition:=replace(definition,'else select array_agg(id) into admins from users where active and role=''admin'';',
     'else admins:=array[u.id];');
   definition:=replace(definition,'insert into project_admins select p.id,id from unnest(admins) id;',
     'insert into project_admins select p.id,id from unnest(admins) id;
      if p_action=''project_create'' and p_data ? ''members'' then
        perform team_command_user(u.id,''project_members'',jsonb_build_object(''id'',p.id,''members'',p_data->''members''));
      end if;');
   definition:=replace(definition,'elsif p_action=''project_visibility'' then',
     'elsif p_action=''project_members'' then
       if u.role<>''admin'' then raise exception ''Administrator required'' using errcode=''42501''; end if;
       select * into strict p from projects where id=(p_data->>''id'')::bigint and can_view_project(id,u.id) for update;
       if jsonb_typeof(p_data->''members'') is distinct from ''array'' then
         raise exception ''Member list required'' using errcode=''23514'';
       end if;
       select array_agg(distinct value::uuid) into ids from jsonb_array_elements_text(p_data->''members'');
       if exists(select 1 from unnest(ids) member_id where not exists(select 1 from users x where x.id=member_id and active and deleted_at is null)) then
         raise exception ''Active members required'' using errcode=''23514'';
       end if;
       delete from project_members where project_id=p.id;
       insert into project_members select p.id,member_id from unnest(ids) member_id;
       return to_jsonb(p);
     elsif p_action=''project_visibility'' then');
   execute definition;
 end loop;
 definition:=pg_get_functiondef('public.delete_member(uuid,uuid,uuid)'::regprocedure);
 definition:=replace(definition,
   'delete from project_admins where user_id=target.id;',
   'delete from project_admins where user_id=target.id; delete from project_members where user_id=target.id;');
 definition:=replace(definition,
   'on conflict do nothing;
 delete from project_admins',
   'on conflict on constraint project_admins_pkey do nothing;
 delete from project_admins');
 execute definition;
end $patch$;
notify pgrst,'reload schema';
commit;
