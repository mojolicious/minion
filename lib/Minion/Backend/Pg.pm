package Minion::Backend::Pg;
use Mojo::Base 'Minion::Backend';

use Carp 'croak';
use Mojo::IOLoop;
use Mojo::Pg 2.18;
use Sys::Hostname 'hostname';

has 'pg';

sub broadcast {
  my ($self, $command, $args, $ids) = (shift, shift, shift || [], shift || []);
  return !!$self->pg->db->query(
    q{update minion_workers set inbox = inbox || $1::jsonb
      where (id = any ($2) or $2 = '{}')}, {json => [[$command, @$args]]}, $ids
  )->rows;
}

sub dequeue {
  my ($self, $id, $wait, $options) = @_;

  if ((my $job = $self->_try($id, $options))) { return $job }
  return undef if Mojo::IOLoop->is_running;

  my $db = $self->pg->db;
  $db->listen('minion.job')->on(notification => sub { Mojo::IOLoop->stop });
  my $timer = Mojo::IOLoop->timer($wait => sub { Mojo::IOLoop->stop });
  Mojo::IOLoop->start;
  $db->unlisten('*') and Mojo::IOLoop->remove($timer);
  undef $db;

  return $self->_try($id, $options);
}

sub enqueue {
  my ($self, $task, $args, $options) = (shift, shift, shift || [], shift || {});

  my $db = $self->pg->db;
  return $db->query(
    "insert into minion_jobs
       (args, attempts, delayed, parents, priority, queue, task)
     values (?, ?, (now() + (interval '1 second' * ?)), ?, ?, ?, ?)
     returning id", {json => $args}, $options->{attempts} // 1,
    $options->{delay} // 0, $options->{parents} || [],
    $options->{priority} // 0, $options->{queue} // 'default', $task
  )->hash->{id};
}

sub fail_job   { shift->_update(1, @_) }
sub finish_job { shift->_update(0, @_) }

sub job_info {
  shift->pg->db->query(
    'select id, args, attempts,
       array(select id from minion_jobs where parents @> ARRAY[j.id])
         as children,
       extract(epoch from created) as created,
       extract(epoch from delayed) as delayed,
       extract(epoch from finished) as finished, parents, priority, queue,
       result, extract(epoch from retried) as retried, retries,
       extract(epoch from started) as started, state, task, worker
     from minion_jobs as j where id = ?', shift
  )->expand->hash;
}

sub list_jobs {
  my ($self, $offset, $limit, $options) = @_;

  return $self->pg->db->query(
    'select id from minion_jobs
     where (queue = $1 or $1 is null) and (state = $2 or $2 is null)
       and (task = $3 or $3 is null)
     order by id desc
     limit $4 offset $5', @$options{qw(queue state task)}, $limit, $offset
  )->arrays->map(sub { $self->job_info($_->[0]) })->to_array;
}

sub list_workers {
  my ($self, $offset, $limit) = @_;

  my $sql = 'select id from minion_workers order by id desc limit ? offset ?';
  return $self->pg->db->query($sql, $limit, $offset)
    ->arrays->map(sub { $self->worker_info($_->[0]) })->to_array;
}

sub lock {
  my ($self, $name, $duration, $options) = (shift, shift, shift, shift // {});
  return !!$self->pg->db->query('select * from minion_lock(?, ?, ?)',
    $name, $duration, $options->{limit} || 1)->array->[0];
}

sub new {
  my $self = shift->SUPER::new(pg => Mojo::Pg->new(@_));

  croak 'PostgreSQL 9.5 or later is required'
    if Mojo::Pg->new(@_)->db->dbh->{pg_server_version} < 90500;
  my $pg = $self->pg->auto_migrate(1)->max_connections(1);
  $pg->migrations->name('minion')->from_data;

  return $self;
}

sub receive {
  my $array = shift->pg->db->query(
    "update minion_workers as new set inbox = '[]'
     from (select id, inbox from minion_workers where id = ? for update) as old
     where new.id = old.id and old.inbox != '[]'
     returning old.inbox", shift
  )->expand->array;
  return $array ? $array->[0] : [];
}

sub register_worker {
  my ($self, $id, $options) = (shift, shift, shift || {});

  return $self->pg->db->query(
    q{insert into minion_workers (id, host, pid, status)
      values (coalesce($1, nextval('minion_workers_id_seq')), $2, $3, $4)
      on conflict(id) do update set notified = now(), status = $4
      returning id}, $id, $self->{host} //= hostname, $$,
    {json => $options->{status} // {}}
  )->hash->{id};
}

sub remove_job {
  !!shift->pg->db->query(
    "delete from minion_jobs
     where id = ? and state in ('inactive', 'failed', 'finished')
     returning 1", shift
  )->rows;
}

sub repair {
  my $self = shift;

  # Workers without heartbeat
  my $db     = $self->pg->db;
  my $minion = $self->minion;
  $db->query(
    "delete from minion_workers
     where notified < now() - interval '1 second' * ?", $minion->missing_after
  );

  # Jobs with missing worker (can be retried)
  my $fail = $db->query(
    "select id, retries from minion_jobs as j
     where state = 'active'
       and not exists (select 1 from minion_workers where id = j.worker)"
  )->hashes;
  $fail->each(sub { $self->fail_job(@$_{qw(id retries)}, 'Worker went away') });

  # Old jobs with no unresolved dependencies
  $db->query(
    "delete from minion_jobs as j
     where finished <= now() - interval '1 second' * ? and not exists (
       select 1 from minion_jobs
       where parents @> ARRAY[j.id] and state != 'finished'
     ) and state = 'finished'", $minion->remove_after
  );
}

sub reset {
  shift->pg->db->query(
    'truncate minion_jobs, minion_locks, minion_workers restart identity');
}

sub retry_job {
  my ($self, $id, $retries, $options) = (shift, shift, shift, shift || {});

  return !!$self->pg->db->query(
    "update minion_jobs
     set delayed = (now() + (interval '1 second' * ?)),
       priority = coalesce(?, priority), queue = coalesce(?, queue),
       retried = now(), retries = retries + 1, state = 'inactive'
     where id = ? and retries = ?
     returning 1", $options->{delay} // 0, @$options{qw(priority queue)}, $id,
    $retries
  )->rows;
}

sub stats {
  my $self = shift;

  my $stats = $self->pg->db->query(
    "select count(*) filter (where state = 'inactive') as inactive_jobs,
       count(*) filter (where state = 'active') as active_jobs,
       count(*) filter (where state = 'failed') as failed_jobs,
       count(*) filter (where state = 'finished') as finished_jobs,
       count(*) filter (where state = 'inactive'
         and (delayed > now() or parents != '{}')) as delayed_jobs,
       count(distinct worker) filter (where state = 'active') as active_workers,
       (select case when is_called then last_value else 0 end
         from minion_jobs_id_seq) as enqueued_jobs,
       (select count(*) from minion_workers) as inactive_workers
     from minion_jobs"
  )->hash;
  $stats->{inactive_workers} -= $stats->{active_workers};

  return $stats;
}

sub unlock {
  !!shift->pg->db->query(
    'delete from minion_locks where id = (
       select id from minion_locks
       where expires > now() and name = ? order by expires limit 1
     ) returning 1', shift
  )->rows;
}

sub unregister_worker {
  shift->pg->db->query('delete from minion_workers where id = ?', shift);
}

sub worker_info {
  shift->pg->db->query(
    "select id, extract(epoch from notified) as notified, array(
       select id from minion_jobs
       where state = 'active' and worker = minion_workers.id
     ) as jobs, host, pid, status, extract(epoch from started) as started
     from minion_workers
     where id = ?", shift
  )->expand->hash;
}

sub _try {
  my ($self, $id, $options) = @_;

  return $self->pg->db->query(
    "update minion_jobs
     set started = now(), state = 'active', worker = ?
     where id = (
       select id from minion_jobs as j
       where delayed <= now() and (parents = '{}' or not exists (
         select 1 from minion_jobs
         where id = any (j.parents)
           and state in ('inactive', 'active', 'failed')
       )) and queue = any (?) and state = 'inactive' and task = any (?)
       order by priority desc, id
       limit 1
       for update skip locked
     )
     returning id, args, retries, task", $id,
    $options->{queues} || ['default'], [keys %{$self->minion->tasks}]
  )->expand->hash;
}

sub _update {
  my ($self, $fail, $id, $retries, $result) = @_;

  return undef unless my $row = $self->pg->db->query(
    "update minion_jobs
     set finished = now(), result = ?, state = ?
     where id = ? and retries = ? and state = 'active'
     returning attempts", {json => $result}, $fail ? 'failed' : 'finished',
    $id, $retries
  )->array;

  return 1 if !$fail || (my $attempts = $row->[0]) == 1;
  return 1 if $retries >= ($attempts - 1);
  my $delay = $self->minion->backoff->($retries);
  return $self->retry_job($id, $retries, {delay => $delay});
}

1;

=encoding utf8

=head1 NAME

Minion::Backend::Pg - PostgreSQL backend

=head1 SYNOPSIS

  use Minion::Backend::Pg;

  my $backend = Minion::Backend::Pg->new('postgresql://postgres@/test');

=head1 DESCRIPTION

L<Minion::Backend::Pg> is a backend for L<Minion> based on L<Mojo::Pg>. All
necessary tables will be created automatically with a set of migrations named
C<minion>. Note that this backend uses many bleeding edge features, so only the
latest, stable version of PostgreSQL is fully supported.

=head1 ATTRIBUTES

L<Minion::Backend::Pg> inherits all attributes from L<Minion::Backend> and
implements the following new ones.

=head2 pg

  my $pg   = $backend->pg;
  $backend = $backend->pg(Mojo::Pg->new);

L<Mojo::Pg> object used to store all data.

=head1 METHODS

L<Minion::Backend::Pg> inherits all methods from L<Minion::Backend> and
implements the following new ones.

=head2 broadcast

  my $bool = $backend->broadcast('some_command');
  my $bool = $backend->broadcast('some_command', [@args]);
  my $bool = $backend->broadcast('some_command', [@args], [$id1, $id2, $id3]);

Broadcast remote control command to one or more workers.

=head2 dequeue

  my $job_info = $backend->dequeue($worker_id, 0.5);
  my $job_info = $backend->dequeue($worker_id, 0.5, {queues => ['important']});

Wait a given amount of time in seconds for a job, dequeue it and transition from
C<inactive> to C<active> state, or return C<undef> if queues were empty.

These options are currently available:

=over 2

=item queues

  queues => ['important']

One or more queues to dequeue jobs from, defaults to C<default>.

=back

These fields are currently available:

=over 2

=item args

  args => ['foo', 'bar']

Job arguments.

=item id

  id => '10023'

Job ID.

=item retries

  retries => 3

Number of times job has been retried.

=item task

  task => 'foo'

Task name.

=back

=head2 enqueue

  my $job_id = $backend->enqueue('foo');
  my $job_id = $backend->enqueue(foo => [@args]);
  my $job_id = $backend->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state.

These options are currently available:

=over 2

=item attempts

  attempts => 25

Number of times performing this job will be attempted, with a delay based on
L<Minion/"backoff"> after the first attempt, defaults to C<1>.

=item delay

  delay => 10

Delay job for this many seconds (from now), defaults to C<0>.

=item parents

  parents => [$id1, $id2, $id3]

One or more existing jobs this job depends on, and that need to have
transitioned to the state C<finished> before it can be processed.

=item priority

  priority => 5

Job priority, defaults to C<0>. Jobs with a higher priority get performed first.

=item queue

  queue => 'important'

Queue to put job in, defaults to C<default>.

=back

=head2 fail_job

  my $bool = $backend->fail_job($job_id, $retries);
  my $bool = $backend->fail_job($job_id, $retries, 'Something went wrong!');
  my $bool = $backend->fail_job(
    $job_id, $retries, {whatever => 'Something went wrong!'});

Transition from C<active> to C<failed> state, and if there are attempts
remaining, transition back to C<inactive> with a delay based on
L<Minion/"backoff">.

=head2 finish_job

  my $bool = $backend->finish_job($job_id, $retries);
  my $bool = $backend->finish_job($job_id, $retries, 'All went well!');
  my $bool = $backend->finish_job(
    $job_id, $retries, {whatever => 'All went well!'});

Transition from C<active> to C<finished> state.

=head2 job_info

  my $job_info = $backend->job_info($job_id);

Get information about a job, or return C<undef> if job does not exist.

  # Check job state
  my $state = $backend->job_info($job_id)->{state};

  # Get job result
  my $result = $backend->job_info($job_id)->{result};

These fields are currently available:

=over 2

=item args

  args => ['foo', 'bar']

Job arguments.

=item attempts

  attempts => 25

Number of times performing this job will be attempted.

=item children

  children => ['10026', '10027', '10028']

Jobs depending on this job.

=item created

  created => 784111777

Epoch time job was created.

=item delayed

  delayed => 784111777

Epoch time job was delayed to.

=item finished

  finished => 784111777

Epoch time job was finished.

=item parents

  parents => ['10023', '10024', '10025']

Jobs this job depends on.

=item priority

  priority => 3

Job priority.

=item queue

  queue => 'important'

Queue name.

=item result

  result => 'All went well!'

Job result.

=item retried

  retried => 784111777

Epoch time job has been retried.

=item retries

  retries => 3

Number of times job has been retried.

=item started

  started => 784111777

Epoch time job was started.

=item state

  state => 'inactive'

Current job state, usually C<active>, C<failed>, C<finished> or C<inactive>.

=item task

  task => 'foo'

Task name.

=item worker

  worker => '154'

Id of worker that is processing the job.

=back

=head2 list_jobs

  my $batch = $backend->list_jobs($offset, $limit);
  my $batch = $backend->list_jobs($offset, $limit, {state => 'inactive'});

Returns the same information as L</"job_info"> but in batches.

These options are currently available:

=over 2

=item queue

  queue => 'important'

List only jobs in this queue.

=item state

  state => 'inactive'

List only jobs in this state.

=item task

  task => 'test'

List only jobs for this task.

=back

=head2 list_workers

  my $batch = $backend->list_workers($offset, $limit);

Returns the same information as L</"worker_info"> but in batches.

=head2 lock

  my $bool = $backend->lock('foo', 3600);
  my $bool = $backend->lock('foo', 3600, {limit => 20});

Try to acquire a named lock that will expire automatically after the given
amount of time in seconds.

These options are currently available:

=over 2

=item limit

  limit => 20

Number of shared locks with the same name that can be active at the same time,
defaults to C<1>.

=back

=head2 new

  my $backend = Minion::Backend::Pg->new('postgresql://postgres@/test');

Construct a new L<Minion::Backend::Pg> object.

=head2 receive

  my $commands = $backend->receive($worker_id);

Receive remote control commands for worker.

=head2 register_worker

  my $worker_id = $backend->register_worker;
  my $worker_id = $backend->register_worker($worker_id);
  my $worker_id = $backend->register_worker(
    $worker_id, {status => {queues => ['default', 'important']}});

Register worker or send heartbeat to show that this worker is still alive.

These options are currently available:

=over 2

=item status

  status => {queues => ['default', 'important']}

Hash reference with whatever status information the worker would like to share.

=back

=head2 remove_job

  my $bool = $backend->remove_job($job_id);

Remove C<failed>, C<finished> or C<inactive> job from queue.

=head2 repair

  $backend->repair;

Repair worker registry and job queue if necessary.

=head2 reset

  $backend->reset;

Reset job queue.

=head2 retry_job

  my $bool = $backend->retry_job($job_id, $retries);
  my $bool = $backend->retry_job($job_id, $retries, {delay => 10});

Transition job back to C<inactive> state, already C<inactive> jobs may also be
retried to change options.

These options are currently available:

=over 2

=item delay

  delay => 10

Delay job for this many seconds (from now), defaults to C<0>.

=item priority

  priority => 5

Job priority.

=item queue

  queue => 'important'

Queue to put job in.

=back

=head2 stats

  my $stats = $backend->stats;

Get statistics for jobs and workers.

These fields are currently available:

=over 2

=item active_jobs

  active_jobs => 100

Number of jobs in C<active> state.

=item active_workers

  active_workers => 100

Number of workers that are currently processing a job.

=item delayed_jobs

  delayed_jobs => 100

Number of jobs in C<inactive> state that are scheduled to run at specific time
in the future or have unresolved dependencies. Note that this field is
EXPERIMENTAL and might change without warning!

=item enqueued_jobs

  enqueued_jobs => 100000

Rough estimate of how many jobs have ever been enqueued. Note that this field is
EXPERIMENTAL and might change without warning!

=item failed_jobs

  failed_jobs => 100

Number of jobs in C<failed> state.

=item finished_jobs

  finished_jobs => 100

Number of jobs in C<finished> state.

=item inactive_jobs

  inactive_jobs => 100

Number of jobs in C<inactive> state.

=item inactive_workers

  inactive_workers => 100

Number of workers that are currently not processing a job.

=back

=head2 unlock

  my $bool = $backend->unlock('foo');

Release a named lock.

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker.

=head2 worker_info

  my $worker_info = $backend->worker_info($worker_id);

Get information about a worker, or return C<undef> if worker does not exist.

  # Check worker host
  my $host = $backend->worker_info($worker_id)->{host};

These fields are currently available:

=over 2

=item host

  host => 'localhost'

Worker host.

=item jobs

  jobs => ['10023', '10024', '10025', '10029']

Ids of jobs the worker is currently processing.

=item notified

  notified => 784111777

Epoch time worker sent the last heartbeat.

=item pid

  pid => 12345

Process id of worker.

=item started

  started => 784111777

Epoch time worker was started.

=item status

  status => {queues => ['default', 'important']}

Hash reference with whatever status information the worker would like to share.

=back

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut

__DATA__

@@ minion
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
alter table minion_jobs add column parents bigint[] default '{}';

-- 11 up
create index on minion_jobs (state, priority desc, id);

-- 12 up
alter table minion_workers add column inbox jsonb
  check(jsonb_typeof(inbox) = 'array') default '[]';

-- 15 up
alter table minion_workers add column status jsonb
  check(jsonb_typeof(status) = 'object') default '{}';

-- 16 up
create index on minion_jobs using gin (parents);
create table if not exists minion_locks (
  id      bigserial not null primary key,
  name    text not null,
  expires timestamp with time zone not null
);
create function minion_lock(text, int, int) returns bool as $$
declare
  new_expires timestamp with time zone = now() + (interval '1 second' * $2);
begin
  delete from minion_locks where expires < now();
  lock table minion_locks in exclusive mode;
  if (select count(*) >= $3 from minion_locks where name = $1) then
    return false;
  end if;
  insert into minion_locks (name, expires) values ($1, new_expires);
  return true;
end;
$$ language plpgsql;

-- 16 down
drop function if exists minion_lock(text, int, int);
drop table if exists minion_locks;

-- 17 up
alter table minion_locks set unlogged;
create index on minion_locks (name, expires);
