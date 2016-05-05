package Minion::Backend::Pg;
use Mojo::Base 'Minion::Backend';

use Carp 'croak';
use Mojo::IOLoop;
use Mojo::Pg 2.18;
use Sys::Hostname 'hostname';

has 'pg';

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
    "insert into minion_jobs (args, attempts, delayed, priority, queue, task)
     values (?, ?, (now() + (interval '1 second' * ?)), ?, ?, ?)
     returning id", {json => $args}, $options->{attempts} // 1,
    $options->{delay} // 0, $options->{priority} // 0,
    $options->{queue} // 'default', $task
  )->hash->{id};
}

sub fail_job   { shift->_update(1, @_) }
sub finish_job { shift->_update(0, @_) }

sub job_info {
  shift->pg->db->query(
    'select id, args, attempts, extract(epoch from created) as created,
       extract(epoch from delayed) as delayed,
       extract(epoch from finished) as finished, priority, queue, result,
       extract(epoch from retried) as retried, retries,
       extract(epoch from started) as started, state, task, worker
     from minion_jobs where id = ?', shift
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

sub new {
  my $self = shift->SUPER::new(pg => Mojo::Pg->new(@_));

  croak 'PostgreSQL 9.5 or later is required'
    if Mojo::Pg->new(@_)->db->dbh->{pg_server_version} < 90500;
  my $pg = $self->pg->auto_migrate(1)->max_connections(1);
  $pg->migrations->name('minion')->from_data;

  return $self;
}

sub register_worker {
  my ($self, $id) = @_;

  return shift->pg->db->query(
    "insert into minion_workers (id, host, pid)
     values (coalesce(?, nextval('minion_workers_id_seq')), ?, ?)
     on conflict(id) do update set notified = now()
     returning id", $id, $self->{host} //= hostname, $$
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

  # Check worker registry
  my $db     = $self->pg->db;
  my $minion = $self->minion;
  $db->query(
    "delete from minion_workers
     where notified < now() - interval '1 second' * ?", $minion->missing_after
  );

  # Abandoned jobs
  my $fail = $db->query(
    "select id, retries from minion_jobs as j
     where state = 'active'
       and not exists(select 1 from minion_workers where id = j.worker)"
  )->hashes;
  $fail->each(sub { $self->fail_job(@$_{qw(id retries)}, 'Worker went away') });

  # Old jobs
  $db->query(
    "delete from minion_jobs
     where state = 'finished' and finished < now() - interval '1 second' * ?",
    $minion->remove_after
  );
}

sub reset { shift->pg->db->query('truncate minion_jobs, minion_workers') }

sub retry_job {
  my ($self, $id, $retries, $options) = (shift, shift, shift, shift || {});

  return !!$self->pg->db->query(
    "update minion_jobs
     set priority = coalesce(?, priority), queue = coalesce(?, queue),
       retried = now(), retries = retries + 1, state = 'inactive',
       delayed = (now() + (interval '1 second' * ?))
     where id = ? and retries = ?
       and state in ('inactive', 'failed', 'finished')
     returning 1", @$options{qw(priority queue)}, $options->{delay} // 0, $id,
    $retries
  )->rows;
}

sub stats {
  my $self = shift;

  my $stats = $self->pg->db->query(
    "select state::text || '_jobs', count(*) from minion_jobs group by state
     union all
     select 'delayed_jobs', count(*) from minion_jobs
     where state = 'inactive' and delayed > now()
     union all
     select 'inactive_workers', count(*) from minion_workers
     union all
     select 'active_workers', count(distinct worker) from minion_jobs
     where state = 'active'"
  )->arrays->reduce(sub { $a->{$b->[0]} = $b->[1]; $a }, {});
  $stats->{inactive_workers} -= $stats->{active_workers};
  $stats->{"${_}_jobs"} ||= 0 for qw(inactive active failed finished);

  return $stats;
}

sub unregister_worker {
  shift->pg->db->query('delete from minion_workers where id = ?', shift);
}

sub worker_info {
  shift->pg->db->query(
    "select id, extract(epoch from notified) as notified, array(
       select id from minion_jobs
       where state = 'active' and worker = minion_workers.id
     ) as jobs, host, pid, extract(epoch from started) as started
     from minion_workers
     where id = ?", shift
  )->hash;
}

sub _try {
  my ($self, $id, $options) = @_;

  return $self->pg->db->query(
    "update minion_jobs
     set started = now(), state = 'active', worker = ?
     where id = (
       select id from minion_jobs
       where delayed <= now() and queue = any (?) and state = 'inactive'
         and task = any (?)
       order by priority desc, created
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

Delay job for this many seconds (from now).

=item priority

  priority => 5

Job priority, defaults to C<0>.

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

=item created

  created => 784111777

Epoch time job was created.

=item delayed

  delayed => 784111777

Epoch time job was delayed to.

=item finished

  finished => 784111777

Epoch time job was finished.

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

=head2 new

  my $backend = Minion::Backend::Pg->new('postgresql://postgres@/test');

Construct a new L<Minion::Backend::Pg> object.

=head2 register_worker

  my $worker_id = $backend->register_worker;
  my $worker_id = $backend->register_worker($worker_id);

Register worker or send heartbeat to show that this worker is still alive.

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

Transition from C<failed> or C<finished> state back to C<inactive>, already
C<inactive> jobs may also be retried to change options.

These options are currently available:

=over 2

=item delay

  delay => 10

Delay job for this many seconds (from now).

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
in the future. Note that this field is EXPERIMENTAL and might change without
warning!

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
create index on minion_jobs (state, priority desc, created);

-- 9 up
create or replace function minion_jobs_notify_workers() returns trigger as $$
  begin
    if new.delayed <= now() then
      notify "minion.job", '';
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
