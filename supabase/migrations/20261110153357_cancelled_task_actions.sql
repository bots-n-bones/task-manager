grant delete on public.task_attachments, public.notification_deliveries, public.task_reviews,
  public.task_events, public.task_results to service_role;

do $$
declare
  definition text;
  signature regprocedure;
begin
  definition := pg_get_functiondef('public.guard_task_write()'::regprocedure);
  definition := replace(definition, 'if new.status <> old.status and not (', $sql$if new.status <> old.status and not (
     (old.status='cancelled' and new.status='new' and exists(
       select 1 from public.users where id=actor and active and (role='admin' or id=old.author_id))) or$sql$);
  definition := replace(definition, $sql$if old.status in ('done','cancelled') then$sql$,
    $sql$if old.status='done' or (old.status='cancelled' and new.status<>'new') then$sql$);
  if definition not like '%old.status=''cancelled'' and new.status=''new''%'
     or definition not like '%old.status=''cancelled'' and new.status<>''new''%' then
    raise exception 'Unexpected task guard definition';
  end if;
  execute definition;

  definition := pg_get_functiondef('public.task_api(uuid,text,jsonb,uuid)'::regprocedure);
  definition := replace(definition, $sql$'approve','return','cancel') then$sql$,
    $sql$'approve','return','cancel','restore','delete') then$sql$);
  definition := replace(definition, 'jsonb_agg(to_jsonb(q) order by', $sql$jsonb_agg(
     to_jsonb(q) || jsonb_build_object('assignee_names', (
       select coalesce(jsonb_agg(member.name order by member.name, member.id), '[]')
       from public.task_assignees assigned join public.users member on member.id=assigned.user_id
       where assigned.task_id=q.id
     )) order by$sql$);
  definition := replace(definition, $sql$   when 'cancel' then$sql$, $sql$
   when 'restore' then
     if t.status<>'cancelled' or not(u.role='admin' or t.author_id=u.id) then
       raise exception 'Restore denied' using errcode='42501';
     end if;
     update tasks set status='new',result=null where id=t.id returning * into t;
   when 'delete' then
     if t.status<>'cancelled' or u.role<>'admin' then
       raise exception 'Delete denied' using errcode='42501';
     end if;
     -- Hand off physical objects to the existing asynchronous storage cleanup.
     update storage_uploads set state='staging',expires_at=now()
       where state='committed' and path in (select storage_path from task_attachments where task_id=t.id);
     delete from task_attachments where task_id=t.id;
     delete from notification_deliveries where task_id=t.id;
     delete from task_reviews where task_id=t.id;
     delete from task_events where task_id=t.id;
     delete from task_results where task_id=t.id;
     delete from task_assignees where task_id=t.id;
     delete from task_admins where task_id=t.id;
     delete from tasks where id=t.id;
   when 'cancel' then$sql$);
  definition := replace(definition, $sql$   end case;
   result:=to_jsonb(t);$sql$, $sql$   end case;
   result:=case when p_action='delete' then jsonb_build_object('deleted',true) else to_jsonb(t) end;$sql$);
  if definition not like '%''cancel'',''restore'',''delete''%'
     or definition not like '%''assignee_names''%'
     or definition not like '%when ''restore'' then%'
     or definition not like '%when ''delete'' then%'
     or definition not like '%jsonb_build_object(''deleted'',true)%' then
    raise exception 'Unexpected task API definition';
  end if;
  execute definition;

  foreach signature in array array[
    'public.team_command(bigint,text,jsonb)'::regprocedure,
    'public.team_command_user(uuid,text,jsonb)'::regprocedure
  ] loop
    definition := pg_get_functiondef(signature);
    definition := replace(definition, $sql$where t.status<>'in_progress' and a.result_id=$sql$,
      $sql$where t.status<>'in_progress' and t.result is not null and a.result_id=$sql$);
    if definition not like '%t.result is not null and a.result_id=%' then
      raise exception 'Unexpected attachment list definition for %', signature;
    end if;
    execute definition;
  end loop;
end $$;
