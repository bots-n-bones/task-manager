-- Apply the same order before pagination and when serializing each page.
-- Renewable tasks use the non-quick bucket. Task number breaks priority ties.
do $$
declare
  definition text;
  bot_function regprocedure;
  expected_lists int;
begin
  definition := pg_get_functiondef('public.task_api(uuid,text,jsonb,uuid)'::regprocedure);
  if regexp_count(definition, 'order by listed\.number desc limit 21') <> 1
     or regexp_count(definition, 'order by q\.number desc') <> 1 then
    raise exception 'Unexpected task API list definition';
  end if;
  definition := replace(definition, 'order by listed.number desc limit 21',
    'order by (listed.status = ''done''), listed.important desc, listed.quick desc, listed.number desc limit 21');
  definition := replace(definition, 'order by q.number desc',
    'order by (q.status = ''done''), q.important desc, q.quick desc, q.number desc');
  execute definition;

  foreach bot_function in array array[
    'public.bot_event_unfiltered(bigint,bigint,text,text,text)'::regprocedure,
    'public.bot_event_lists(bigint,bigint,text,text,text)'::regprocedure,
    'public.bot_event_reviews(bigint,bigint,text,text,text)'::regprocedure,
    'public.bot_event_mvp(bigint,bigint,text,text,text)'::regprocedure
  ] loop
    expected_lists := case when bot_function = 'public.bot_event_unfiltered(bigint,bigint,text,text,text)'::regprocedure
                           then 2 else 1 end;
    definition := pg_get_functiondef(bot_function);
    if regexp_count(definition, 'select number,title,status from tasks') <> expected_lists
       or regexp_count(definition, 'order by number desc limit 6') <> expected_lists
       or regexp_count(definition, 'jsonb_agg\(to_jsonb\(q\) order by q\.number desc\)') <> expected_lists then
      raise exception 'Unexpected Telegram list definition for %', bot_function;
    end if;
    definition := replace(definition, 'select number,title,status from tasks',
      'select number,title,status,important,quick from tasks');
    definition := replace(definition, 'order by number desc limit 6',
      'order by (status = ''done''), important desc, quick desc, number desc limit 6');
    definition := replace(definition, 'jsonb_agg(to_jsonb(q) order by q.number desc)',
      'jsonb_agg((to_jsonb(q) - ''important'' - ''quick'') order by (q.status = ''done''), q.important desc, q.quick desc, q.number desc)');
    execute definition;
  end loop;
end $$;
