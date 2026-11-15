alter table public.processed_updates add column response jsonb;

-- One Telegram update and its reply commit together. Serialize each user's form.
create function public.bot_event(p_update bigint, p_actor bigint, p_name text, p_action text, p_value text default '')
returns jsonb language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  u uuid;
  s bot_sessions%rowtype;
  t tasks%rowtype;
  d jsonb;
  step_name text;
  v text := btrim(p_value);
  page_no integer;
  rows_json jsonb;
  answer jsonb;
  notice_text text;
  task_no bigint;
  deadline date;
begin
  perform pg_advisory_xact_lock(p_actor);
  insert into processed_updates(update_id) values(p_update) on conflict do nothing;
  if not found then
    select response into answer from processed_updates where update_id=p_update;
    return answer;
  end if;
  if p_action='start' then
    insert into users(telegram_id,name) values(p_actor,p_name)
    on conflict(telegram_id) do update set name=excluded.name;
  end if;
  select id into u from users where telegram_id=p_actor;
  select * into s from bot_sessions where user_id=u;
  d := coalesce(s.draft,'{}');
  step_name := coalesce(s.step,'menu');

  if u is null then
    answer := jsonb_build_object('message','Для начала отправьте /start.');
  elsif p_action='start' then
    null; -- Resume a saved form.
  elsif p_action in ('cancel','menu') then
    step_name := 'menu'; d := '{}';
  elsif p_action='create' and step_name='menu' then
    step_name := 'title'; d := '{}';
  elsif p_action in ('list','open','begin','result') then
    if step_name <> 'menu' then
      notice_text := 'Сначала завершите или отмените текущую форму.';
    elsif p_action='list' and v ~ '^[0-9]{1,8}$' then
      page_no := v::integer;
      select coalesce(jsonb_agg(to_jsonb(q) order by q.number desc),'[]') into rows_json from
        (select number,title,status from tasks where assignee_id=u order by number desc limit 6 offset page_no*5) q;
      answer := jsonb_build_object('page',page_no,'tasks',rows_json);
    elsif p_action <> 'list' and v ~ '^[1-9][0-9]{0,17}$' then
      task_no := v::bigint;
      select * into t from tasks where number=task_no and assignee_id=u for update;
      if not found then
        notice_text := 'Задача недоступна.';
      elsif p_action='result' and t.status='in_progress' then
        step_name := 'result'; d := jsonb_build_object('number',task_no);
      else
        if p_action='begin' and t.status='new' then
          update tasks set status='in_progress' where id=t.id returning * into t;
        end if;
        answer := jsonb_build_object('task',to_jsonb(t));
      end if;
    end if;
  elsif p_action in ('save','skip','back','abort') and v <> coalesce(d->>'token','') then
    notice_text := 'Эта кнопка устарела.';
  elsif p_action='abort' then
    step_name := 'menu'; d := '{}';
  elsif p_action='back' then
    step_name := case step_name when 'preview' then 'date' when 'date' then 'description'
      when 'description' then 'title' else 'menu' end;
  elsif p_action='skip' and step_name='description' then
    d := d - 'description'; step_name := 'date';
  elsif p_action='save' and step_name='preview' then
    insert into tasks(author_id,assignee_id,title,description,due_date,creation_update_id)
    values(u,u,d->>'title',d->>'description',(d->>'due_date')::date,p_update) returning * into t;
    answer := jsonb_build_object('message','Задача сохранена.','task',to_jsonb(t));
    step_name := 'menu';
  elsif p_action='text' then
    case step_name
    when 'title','description','result' then
      if v !~ '[^[:space:]]' or char_length(v) > (case step_name when 'title' then 120 else 1000 end) then
        notice_text := case step_name when 'title' then 'Введите название от 1 до 120 символов.'
          else 'Введите текст от 1 до 1000 символов.' end;
      elsif step_name='result' then
        update tasks set result=v,status='review' where number=(d->>'number')::bigint
          and assignee_id=u and status='in_progress' returning * into t;
        if found then answer := jsonb_build_object('task',to_jsonb(t));
        else notice_text := 'Действие недоступно.'; end if;
        step_name := 'menu';
      else
        d := d || jsonb_build_object(step_name,v);
        step_name := case step_name when 'title' then 'description' else 'date' end;
      end if;
    when 'date' then
      if v ~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{4}$' then
        begin
          deadline := make_date(substr(v,7,4)::int,substr(v,4,2)::int,left(v,2)::int);
        exception when datetime_field_overflow then deadline := null;
        end;
      end if;
      if deadline is null then notice_text := 'Введите существующую дату в формате ДД.ММ.ГГГГ.';
      else d := d || jsonb_build_object('due_date',deadline); step_name := 'preview'; end if;
    else null;
    end case;
  end if;

  if u is not null then
    if step_name='menu' then delete from bot_sessions where user_id=u;
    else
      if s.step is distinct from step_name then d := d || jsonb_build_object('token',p_update::text); end if;
      insert into bot_sessions(user_id,step,draft) values(u,step_name,d)
      on conflict(user_id) do update set step=excluded.step,draft=excluded.draft;
    end if;
  end if;
  answer := coalesce(answer,jsonb_build_object('step',step_name,'draft',d,'message',notice_text));
  update processed_updates set state='processed',response=answer where update_id=p_update;
  return answer;
end $$;
revoke all on function public.bot_event(bigint,bigint,text,text,text) from public, anon, authenticated;
grant execute on function public.bot_event(bigint,bigint,text,text,text) to service_role;
