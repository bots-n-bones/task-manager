do $$
declare definition text;
begin
 select pg_get_functiondef('public.bot_event_mvp(bigint,bigint,text,text,text)'::regprocedure) into definition;
 definition:=replace(definition,'v ~ ''^[1-9][0-9]{0,17}$''','v ~ ''^[1-9][0-9]{0,17}(:[0-9]{1,18})?$''');
 definition:=replace(definition,'task_no := v::bigint;','task_no := split_part(v,'':'',1)::bigint;');
 definition:=replace(definition,'elsif p_action=''result'' and t.status=''in_progress'' then',
 'elsif split_part(v,'':'',2)<>'''' and split_part(v,'':'',2)::bigint<>t.version then
        notice_text := ''Карточка изменилась. Откройте задачу заново.'';
      elsif p_action=''result'' and t.status=''in_progress'' then');
 definition:=replace(definition,'jsonb_build_object(''number'',task_no)','jsonb_build_object(''number'',task_no,''version'',t.version)');
 definition:=replace(definition,'and status=''in_progress'' returning','and status=''in_progress'' and version=coalesce((d->>''version'')::bigint,version) returning');
 definition:=replace(definition,'notice_text := ''Действие недоступно.''','notice_text := ''Задача или права изменились. Откройте карточку заново.''');
 execute definition;
end $$;
update public.bot_sessions s set draft=s.draft||jsonb_build_object('version',t.version)
from public.tasks t where s.step='result' and (s.draft->>'number')::bigint=t.number and not(s.draft ? 'version');
