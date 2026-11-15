alter table public.task_attachments add column telegram_kind text not null default 'document' check(telegram_kind in ('document','photo'));
do $$
declare definition text;
begin
 select pg_get_functiondef('public.attachment_result(bigint,bigint,text,jsonb,text)'::regprocedure) into definition;
 definition:=replace(definition,'telegram_file_id,update_id)','telegram_file_id,update_id,telegram_kind)');
 definition:=replace(definition,'p_file->>''file_id'',p_update);','p_file->>''file_id'',p_update,coalesce(p_file->>''kind'',''document''));');
 definition:=replace(definition,' return answer;
end', ' answer:=jsonb_set(answer,''{task}'',public.team_command(p_actor,''task'',jsonb_build_object(''number'',answer#>>''{task,number}'')));
 update public.processed_updates set response=answer where update_id=p_update;
 return answer;
end');
 execute definition;
end $$;
