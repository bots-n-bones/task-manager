alter table public.task_attachments alter column telegram_file_id drop not null;
alter table public.task_attachments alter column update_id drop not null;
create function public.web_file_result(p_user uuid,p_request uuid,p_number bigint,p_version bigint,p_file jsonb,p_text text default '')
returns jsonb language plpgsql set search_path=public,pg_temp as $$
declare answer jsonb; t uuid; r uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_user::text,0));
 select response into answer from web_requests where user_id=p_user and request_id=p_request;
 if found then return answer; end if;
 if char_length(p_file->>'name') not between 1 and 255 or (p_file->>'size')::bigint not between 1 and 10485760
 or not starts_with(p_file->>'path',p_user||'/'||p_request||'/') then raise exception 'Invalid file metadata' using errcode='23514'; end if;
 answer:=task_api(p_user,'result',jsonb_build_object('number',p_number,'version',p_version,
 'text',case when btrim(p_text) ~ '[^[:space:]]' then p_text else 'Файл: '||(p_file->>'name') end),p_request);
 t:=(answer->>'id')::uuid;
 select id into r from task_results where task_id=t order by version desc limit 1;
 insert into task_attachments(task_id,result_id,name,mime_type,size,storage_path)
 values(t,r,p_file->>'name',p_file->>'mime_type',(p_file->>'size')::bigint,p_file->>'path');
 insert into task_events(task_id,actor_id,event,changes) values(t,p_user,'attachment',jsonb_build_object('name',p_file->>'name','result_id',r));
 return answer;
end $$;
revoke all on function public.web_file_result(uuid,uuid,bigint,bigint,jsonb,text) from public,anon,authenticated;
grant execute on function public.web_file_result(uuid,uuid,bigint,bigint,jsonb,text) to service_role;
