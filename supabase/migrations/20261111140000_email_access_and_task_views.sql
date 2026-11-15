alter table public.users add column corporate_email text unique
 check (corporate_email = lower(trim(corporate_email)) and corporate_email ~ '^[a-z0-9._%+-]+@bots-n-bones[.]com$'),
 add column email_activated boolean not null default false,
 add column access_mail_status text,
 add column access_token_hash text,
 add column access_token_expiry timestamptz;
update public.users set name=case lower(name) when 'vanya' then 'Vanya' else 'Ilya' end where lower(name) in ('vanya','ilya');

do $$
declare definition text:=pg_get_functiondef('public.task_api(uuid,text,jsonb,uuid)'::regprocedure);
begin
 if strpos(definition,'and (not(p_data ? ''status'')')=0 then raise exception 'Unexpected list query'; end if;
 execute replace(definition,'and (not(p_data ? ''status'')',$filter$
 and (case p_data->>'view' when 'cancelled' then listed.status='cancelled' when 'active' then listed.status not in ('done','cancelled') else true end)
 and (not(p_data ? 'status')$filter$);
end $$;
alter table public.web_sessions add column email_login boolean not null default false;
notify pgrst,'reload schema';
