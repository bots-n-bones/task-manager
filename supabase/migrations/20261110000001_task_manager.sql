create table public.users (
  id uuid primary key default gen_random_uuid(),
  telegram_id bigint not null unique check (telegram_id > 0),
  name text not null check (name ~ '[^[:space:]]'),
  created_at timestamptz not null default now()
);

create table public.processed_updates (
  update_id bigint primary key check (update_id >= 0),
  state text not null default 'processing' check (state in ('processing', 'processed')),
  created_at timestamptz not null default now()
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  number bigint generated always as identity unique,
  author_id uuid not null references public.users,
  assignee_id uuid not null references public.users,
  title text not null check (title ~ '[^[:space:]]'),
  description text,
  due_date date not null,
  status text not null default 'new' check (status in ('new', 'in_progress', 'review')),
  result text,
  creation_update_id bigint not null unique references public.processed_updates(update_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1,
  check (author_id = assignee_id),
  check (status <> 'review' or coalesce(result, '') ~ '[^[:space:]]')
);

create index tasks_assignee_number_idx on public.tasks (assignee_id, number desc);

create function public.guard_task_write() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'new' then
      raise exception 'A task must start in new status' using errcode = '23514';
    end if;
    new.version := 1;
  else
    if new.status <> old.status and not (
      (old.status = 'new' and new.status = 'in_progress') or
      (old.status = 'in_progress' and new.status = 'review')
    ) then
      raise exception 'Invalid task status transition' using errcode = '23514';
    end if;
    if new.creation_update_id <> old.creation_update_id then
      raise exception 'Creation update is immutable' using errcode = '23514';
    end if;
    new.version := old.version + 1;
    new.updated_at := clock_timestamp();
  end if;
  return new;
end;
$$;

create trigger guard_task_write before insert or update on public.tasks
for each row execute function public.guard_task_write();

create table public.bot_sessions (
  user_id uuid primary key references public.users on delete cascade,
  step text not null check (step ~ '[^[:space:]]'),
  draft jsonb not null default '{}' check (jsonb_typeof(draft) = 'object')
);

alter table public.users enable row level security;
alter table public.tasks enable row level security;
alter table public.bot_sessions enable row level security;
alter table public.processed_updates enable row level security;

revoke all on public.users, public.tasks, public.bot_sessions, public.processed_updates
from public, anon, authenticated;
revoke all on sequence public.tasks_number_seq from public, anon, authenticated;
grant select, insert, update, delete on public.users, public.tasks, public.bot_sessions, public.processed_updates to service_role;
grant usage on sequence public.tasks_number_seq to service_role;
