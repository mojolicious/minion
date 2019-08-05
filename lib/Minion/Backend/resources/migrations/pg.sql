--
-- These are the migrations for the PostgreSQL Minion backend. They are only
-- used for upgrades to the latest version. Downgrades may be used to clean up
-- the database, but they do not have to work with old versions of Minion.
--
-- 1 up
create table if not exists minion_jobs (
  id       bigserial not null primary key,
  args     json not null,
  created  timestamp with time zone not null,
  delayed  timestamp with time zone not null,
  finished timestamp with time zone,
  priority int not null,
  result   json,
  retried  timestamp with time zone,
  retries  int not null,
  started  timestamp with time zone,
  state    text not null,
  task     text not null,
  worker   bigint
);
create table if not exists minion_workers (
  id      bigserial not null primary key,
  host    text not null,
  pid     int not null,
  started timestamp with time zone not null
);

-- 1 down
drop table if exists minion_jobs;
drop table if exists minion_workers;

-- 2 up
alter table minion_jobs alter column created set default now();
alter table minion_jobs alter column state set default 'inactive';
alter table minion_jobs alter column retries set default 0;
alter table minion_workers add column
  notified timestamp with time zone not null default now();
alter table minion_workers alter column started set default now();

-- 4 up
alter table minion_jobs add column queue text not null default 'default';

-- 5 up
alter table minion_jobs add column attempts int not null default 1;

-- 7 up
create type minion_state as enum ('inactive', 'active', 'failed', 'finished');
alter table minion_jobs alter column state set default 'inactive'::minion_state;
alter table minion_jobs
  alter column state type minion_state using state::minion_state;
alter table minion_jobs alter column args type jsonb using args::jsonb;
alter table minion_jobs alter column result type jsonb using result::jsonb;

-- 7 down
alter table minion_jobs alter column state type text using state;
alter table minion_jobs alter column state set default 'inactive';
drop type if exists minion_state;

-- 8 up
alter table minion_jobs add constraint args check(jsonb_typeof(args) = 'array');

-- 9 up
create or replace function minion_jobs_notify_workers() returns trigger as $$
  begin
    if new.delayed <= now() then
      notify "minion.job";
    end if;
    return null;
  end;
$$ language plpgsql;
set client_min_messages to warning;
drop trigger if exists minion_jobs_insert_trigger on minion_jobs;
drop trigger if exists minion_jobs_notify_workers_trigger on minion_jobs;
set client_min_messages to notice;
create trigger minion_jobs_notify_workers_trigger
  after insert or update of retries on minion_jobs
  for each row execute procedure minion_jobs_notify_workers();

-- 9 down
drop trigger if exists minion_jobs_notify_workers_trigger on minion_jobs;
drop function if exists minion_jobs_notify_workers();

-- 10 up
alter table minion_jobs add column parents bigint[] not null default '{}';

-- 11 up
create index on minion_jobs (state, priority desc, id);

-- 12 up
alter table minion_workers add column inbox jsonb
  check(jsonb_typeof(inbox) = 'array') not null default '[]';

-- 15 up
alter table minion_workers add column status jsonb
  check(jsonb_typeof(status) = 'object') not null default '{}';

-- 16 up
create index on minion_jobs using gin (parents);
create table if not exists minion_locks (
  id      bigserial not null primary key,
  name    text not null,
  expires timestamp with time zone not null
);

-- 16 down
drop table if exists minion_locks;

-- 17 up
alter table minion_jobs add column notes jsonb
  check(jsonb_typeof(notes) = 'object') not null default '{}';
alter table minion_locks set unlogged;
create index on minion_locks (name, expires);

-- 18 up
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
drop function if exists minion_lock(text, int, int);

-- 19 up
create index on minion_jobs using gin (notes);
