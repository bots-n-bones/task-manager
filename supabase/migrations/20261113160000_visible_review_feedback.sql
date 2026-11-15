begin;
create function public.task_latest_review(p_task uuid) returns jsonb
language sql stable set search_path=public,pg_temp as $fn$
 select jsonb_build_object('id',r.id,'decision',r.decision,'comment',r.comment,
   'reviewer_name',u.name,'created_at',r.created_at,'result_version',r.result_version,
   'needs_changes',r.decision='returned' and t.status='in_progress' and t.result is not null
     and r.result_id=(select id from public.task_results where task_id=t.id order by version desc limit 1))
 from public.task_reviews r join public.users u on u.id=r.reviewer_id join public.tasks t on t.id=r.task_id
 where r.task_id=p_task order by r.result_version desc limit 1;
$fn$;
revoke all on function public.task_latest_review(uuid) from public,anon,authenticated;
grant execute on function public.task_latest_review(uuid) to service_role;
create index if not exists task_reviews_latest_idx on public.task_reviews(task_id,result_version desc);
do $migration$
declare definition text;
begin
 definition:=pg_get_functiondef('public.team_command_user(uuid,text,jsonb)'::regprocedure);
 if strpos(definition,$old$'result',case when t.status<>'in_progress' then t.result end,$old$)=0 then raise exception 'Unexpected task details'; end if;
 execute replace(definition,$old$'result',case when t.status<>'in_progress' then t.result end,$old$,
 $new$'latest_review',public.task_latest_review(t.id),
     'reviews',(select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('reviewer_name',reviewer.name) order by r.result_version desc),'[]')
       from public.task_reviews r join public.users reviewer on reviewer.id=r.reviewer_id where r.task_id=t.id),
     'result',case when t.status<>'in_progress' then t.result end,$new$);
 definition:=pg_get_functiondef('public.task_api(uuid,text,jsonb,uuid)'::regprocedure);
 if strpos(definition,$old$to_jsonb(q) || jsonb_build_object('assignee_names',$old$)=0 then raise exception 'Unexpected task list'; end if;
 execute replace(definition,$old$to_jsonb(q) || jsonb_build_object('assignee_names',$old$,
 $new$to_jsonb(q) || jsonb_build_object('latest_review',public.task_latest_review(q.id)) || jsonb_build_object('assignee_names',$new$);
end $migration$;
notify pgrst,'reload schema';
commit;
