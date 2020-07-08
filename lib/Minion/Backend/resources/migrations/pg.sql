--
-- These are the migrations for the PostgreSQL Minion backend. They are only used for upgrades to the latest version.
-- Downgrades may be used to clean up the database, but they do not have to work with old versions of Minion.
--
-- 18 up
create type minion_state as enum ('inactive', 'active', 'failed', 'finished');
create table if not exists minion_jobs (
  id       bigserial not null primary key,
  args     jsonb not null check(jsonb_typeof(args) = 'array'),
  attempts int not null default 1,
  created  timestamp with time zone not null default now(),
  delayed  timestamp with time zone not null,
  finished timestamp with time zone,
  notes    jsonb check(jsonb_typeof(notes) = 'object') not null default '{}',
  parents  bigint[] not null default '{}',
  priority int not null,
  queue    text not null default 'default',
  result   jsonb,
  retried  timestamp with time zone,
  retries  int not null default 0,
  started  timestamp with time zone,
  state    minion_state not null default 'inactive'::minion_state,
  task     text not null,
  worker   bigint
);
create index on minion_jobs (state, priority desc, id);
create index on minion_jobs using gin (parents);
create table if not exists minion_workers (
  id       bigserial not null primary key,
  host     text not null,
  inbox    jsonb check(jsonb_typeof(inbox) = 'array') not null default '[]',
  notified timestamp with time zone not null default now(),
  pid      int not null,
  started  timestamp with time zone not null default now(),
  status   jsonb check(jsonb_typeof(status) = 'object') not null default '{}'
);
create unlogged table if not exists minion_locks (
  id      bigserial not null primary key,
  name    text not null,
  expires timestamp with time zone not null
);
create index on minion_locks (name, expires);

create or replace function minion_jobs_notify_workers() returns trigger as $$
  begin
    if new.delayed <= now() then
      notify "minion.job";
    end if;
    return null;
  end;
$$ language plpgsql;
create trigger minion_jobs_notify_workers_trigger
  after insert or update of retries on minion_jobs
  for each row execute procedure minion_jobs_notify_workers();

create or replace function minion_lock(text, int, int) returns bool as $$
declare
  new_expires timestamp with time zone = now() + (interval '1 second' * $2);
begin
  lock table minion_locks in exclusive mode;
  delete from minion_locks where expires < now();
  if (select count(*) >= $3 from minion_locks where name = $1) then
    return false;
  end if;
  if new_expires > now() then
    insert into minion_locks (name, expires) values ($1, new_expires);
  end if;
  return true;
end;
$$ language plpgsql;

-- 18 down
drop table if exists minion_jobs;
drop table if exists minion_workers;
drop table if exists minion_locks;
drop type if exists minion_state;
drop trigger if exists minion_jobs_notify_workers_trigger on minion_jobs;
drop function if exists minion_jobs_notify_workers();
drop function if exists minion_lock(text, int, int);

-- 19 up
create index on minion_jobs using gin (notes);

-- 20 up
alter table minion_workers set unlogged;

-- 21 up
alter table minion_jobs add column sequence text;
alter table minion_jobs add column next bigint;
create index on minion_jobs (sequence, next);
