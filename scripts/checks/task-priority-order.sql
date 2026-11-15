begin;
set local role service_role;
do $$
declare
  actor bigint := 981050153000;
  admin_id uuid;
  project_id bigint;
  expected text[];
  actual text[];
  task jsonb;
  args jsonb;
  list jsonb;
begin
  insert into users (telegram_id,name,role) values (actor,'Priority check','admin') returning id into admin_id;
  project_id := (team_command_user(admin_id,'project_create','{"name":"Priority check"}')->>'id')::bigint;

  -- Interleave priority groups so that descending task number alone cannot pass.
  for i in 0..24 loop
    task := task_api(admin_id,'create',jsonb_build_object(
      'title','Priority '||i,'project_id',project_id,'due_date',current_date,
      'important',i%4 in (0,1),'quick',i%4 in (0,2),'renewable',i%4=1
    ),gen_random_uuid());
  end loop;
  args := jsonb_build_object('number',task->'number','version',task->'version');
  task := task_api(admin_id,'begin',args,gen_random_uuid());
  args := args || jsonb_build_object('version',task->'version','text','Done');
  task := task_api(admin_id,'result',args,gen_random_uuid());
  args := args || jsonb_build_object('version',task->'version');
  perform task_api(admin_id,'approve',args,gen_random_uuid());

  expected := array(
    select 'Priority '||i from generate_series(0,24) i
    order by (i=24), i%4, i desc
  );
  for page in 0..1 loop
    list := task_api(admin_id,'list',jsonb_build_object('project_id',project_id,'page',page));
    select array_agg(value->>'title' order by n) into actual from jsonb_array_elements(list) with ordinality j(value,n);
    assert actual=expected[page*20+1:page*20+21], 'Mini App task order';
  end loop;

  for page in 0..4 loop
    foreach args in array array[
      jsonb_build_array('list',page::text),
      jsonb_build_array('project_open',project_id||':'||page),
      jsonb_build_array('all_project',project_id||':'||page)
    ] loop
      list := bot_event(actor+100+page*3+case args->>0 when 'list' then 0 when 'project_open' then 1 else 2 end,
                        actor,'Priority check',args->>0,args->>1)->'tasks';
      select array_agg(value->>'title' order by n) into actual from jsonb_array_elements(list) with ordinality j(value,n);
      assert actual=expected[page*5+1:page*5+6], 'Telegram task order: '||(args->>0);
    end loop;
  end loop;
end $$;
rollback;
