package Minion::Backend::Pg;
use Mojo::Base 'Minion::Backend';

use Carp       qw(croak);
use Mojo::File qw(path);
use Mojo::IOLoop;
use Mojo::Pg 4.0;
use Sys::Hostname qw(hostname);

has 'pg';

sub broadcast {
  my ($self, $command, $args, $ids) = (shift, shift, shift || [], shift || []);
  return !!$self->pg->db->query(
    q{UPDATE minion_workers SET inbox = inbox || $1::JSONB WHERE (id = ANY ($2) OR $2 = '{}')},
    {json => [[$command, @$args]]}, $ids)->rows;
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

  return $self->pg->db->query(
    q{INSERT INTO minion_jobs (args, attempts, delayed, expires, lax, notes, parents, priority, queue, task)
      VALUES ($1, $2, (NOW() + (INTERVAL '1 second' * $3)),
      CASE WHEN $4::BIGINT IS NOT NULL THEN NOW() + (INTERVAL '1 second' * $4::BIGINT) END, $5, $6, $7, $8, $9, $10)
      RETURNING id}, {json => $args}, $options->{attempts} // 1, $options->{delay} // 0, $options->{expire},
    $options->{lax} ? 1 : 0, {json => $options->{notes} || {}}, $options->{parents} || [], $options->{priority} // 0,
    $options->{queue} // 'default', $task
  )->hash->{id};
}

sub fail_job   { shift->_update(1, @_) }
sub finish_job { shift->_update(0, @_) }

sub history {
  my $self = shift;

  my $daily = $self->pg->db->query(
    "SELECT EXTRACT(EPOCH FROM ts) AS epoch, COALESCE(failed_jobs, 0) AS failed_jobs,
       COALESCE(finished_jobs, 0) AS finished_jobs
     FROM (
       SELECT EXTRACT (DAY FROM finished) AS day, EXTRACT(HOUR FROM finished) AS hour,
         COUNT(*) FILTER (WHERE state = 'failed') AS failed_jobs,
         COUNT(*) FILTER (WHERE state = 'finished') AS finished_jobs
       FROM minion_jobs
       WHERE finished > NOW() - INTERVAL '23 hours'
       GROUP BY day, hour
     ) AS j RIGHT OUTER JOIN (
       SELECT *
       FROM GENERATE_SERIES(NOW() - INTERVAL '23 hour', NOW(), '1 hour') AS ts
     ) AS s ON EXTRACT(HOUR FROM ts) = j.hour AND EXTRACT(DAY FROM ts) = j.day
     ORDER BY epoch ASC"
  )->hashes->to_array;

  return {daily => $daily};
}

sub list_jobs {
  my ($self, $offset, $limit, $options) = @_;

  my $jobs = $self->pg->db->query(
    q{SELECT id, args, attempts,
        ARRAY(SELECT id FROM minion_jobs WHERE parents @> ARRAY[j.id]) AS children,
        EXTRACT(epoch FROM created) AS created, EXTRACT(EPOCH FROM delayed) AS delayed,
        EXTRACT(EPOCH FROM expires) AS expires, EXTRACT(EPOCH FROM finished) AS finished, lax, notes, parents, priority,
        queue, result, EXTRACT(EPOCH FROM retried) AS retried, retries, EXTRACT(EPOCH FROM started) AS started, state,
        task, EXTRACT(EPOCH FROM now()) AS time, COUNT(*) OVER() AS total, worker
      FROM minion_jobs AS j
      WHERE (id < $1 OR $1 IS NULL) AND (id = ANY ($2) OR $2 IS NULL) AND (notes \? ANY ($3) OR $3 IS NULL)
        AND (queue = ANY ($4) OR $4 IS null) AND (state = ANY ($5) OR $5 IS NULL) AND (task = ANY ($6) OR $6 IS NULL)
        AND (state != 'inactive' OR expires IS null OR expires > NOW())
      ORDER BY id DESC
      LIMIT $7 OFFSET $8}, @$options{qw(before ids notes queues states tasks)}, $limit, $offset
  )->expand->hashes->to_array;

  return _total('jobs', $jobs);
}

sub list_locks {
  my ($self, $offset, $limit, $options) = @_;

  my $locks = $self->pg->db->query(
    'SELECT id, name, EXTRACT(EPOCH FROM expires) AS expires, COUNT(*) OVER() AS total FROM minion_locks
     WHERE expires > NOW() AND (name = ANY ($1) OR $1 IS NULL)
     ORDER BY id DESC LIMIT $2 OFFSET $3', $options->{names}, $limit, $offset
  )->hashes->to_array;
  return _total('locks', $locks);
}

sub list_workers {
  my ($self, $offset, $limit, $options) = @_;

  my $workers = $self->pg->db->query(
    "SELECT id, EXTRACT(EPOCH FROM notified) AS notified, ARRAY(
        SELECT id FROM minion_jobs WHERE state = 'active' AND worker = minion_workers.id
      ) AS jobs, host, pid, status, EXTRACT(EPOCH FROM started) AS started,
      COUNT(*) OVER() AS total
     FROM minion_workers
     WHERE (id < \$1 OR \$1 IS NULL)  AND (id = ANY (\$2) OR \$2 IS NULL)
     ORDER BY id DESC LIMIT \$3 OFFSET \$4", @$options{qw(before ids)}, $limit, $offset
  )->expand->hashes->to_array;
  return _total('workers', $workers);
}

sub lock {
  my ($self, $name, $duration, $options) = (shift, shift, shift, shift // {});
  return !!$self->pg->db->query('SELECT * FROM minion_lock(?, ?, ?)', $name, $duration, $options->{limit} || 1)
    ->array->[0];
}

sub new {
  my $self = shift->SUPER::new(pg => Mojo::Pg->new(@_));

  my $db = Mojo::Pg->new(@_)->db;
  croak 'PostgreSQL 9.5 or later is required' if $db->dbh->{pg_server_version} < 90500;
  $db->disconnect;

  my $schema = path(__FILE__)->dirname->child('resources', 'migrations', 'pg.sql');
  $self->pg->auto_migrate(1)->migrations->name('minion')->from_file($schema);

  return $self;
}

sub note {
  my ($self, $id, $merge) = @_;
  return !!$self->pg->db->query('UPDATE minion_jobs SET notes = JSONB_STRIP_NULLS(notes || ?) WHERE id = ?',
    {json => $merge}, $id)->rows;
}

sub receive {
  my $array = shift->pg->db->query(
    "UPDATE minion_workers AS new SET inbox = '[]'
     FROM (SELECT id, inbox FROM minion_workers WHERE id = ? FOR UPDATE) AS old
     WHERE new.id = old.id AND old.inbox != '[]'
     RETURNING old.inbox", shift
  )->expand->array;
  return $array ? $array->[0] : [];
}

sub register_worker {
  my ($self, $id, $options) = (shift, shift, shift || {});

  return $self->pg->db->query(
    q{INSERT INTO minion_workers (id, host, pid, status)
      VALUES (COALESCE($1, NEXTVAL('minion_workers_id_seq')), $2, $3, $4)
      ON CONFLICT(id) DO UPDATE SET notified = now(), status = $4
      RETURNING id}, $id, $self->{host} //= hostname, $$, {json => $options->{status} // {}}
  )->hash->{id};
}

sub remove_job {
  my ($self, $id) = @_;
  return !!$self->pg->db->query(
    "DELETE FROM minion_jobs WHERE id = ? AND state IN ('inactive', 'failed', 'finished') RETURNING 1", $id)->rows;
}

sub repair {
  my $self = shift;

  # Workers without heartbeat
  my $db     = $self->pg->db;
  my $minion = $self->minion;
  $db->query("DELETE FROM minion_workers WHERE notified < NOW() - INTERVAL '1 second' * ?", $minion->missing_after);

  # Old jobs with no unresolved dependencies
  $db->query(
    "DELETE FROM minion_jobs
     WHERE id IN (
      SELECT id FROM minion_jobs WHERE state = 'finished' AND finished <= NOW() - INTERVAL '1 second' * ?
      EXCEPT SELECT unnest(parents) AS id FROM minion_jobs WHERE state != 'finished'
    )", $minion->remove_after
  );

  # Expired jobs
  $db->query("DELETE FROM minion_jobs WHERE state = 'inactive' AND expires <= NOW()");

  # Jobs with missing worker (can be retried)
  $db->query(
    "SELECT id, retries FROM minion_jobs AS j
     WHERE state = 'active' AND queue != 'minion_foreground'
       AND NOT EXISTS (SELECT 1 FROM minion_workers WHERE id = j.worker)"
  )->hashes->each(sub { $self->fail_job(@$_{qw(id retries)}, 'Worker went away') });

  # Jobs in queue without workers or not enough workers (cannot be retried and requires admin attention)
  $db->query(
    q{UPDATE minion_jobs SET state = 'failed', result = '"Job appears stuck in queue"'
      WHERE state = 'inactive' AND delayed + ? * INTERVAL '1 second' < NOW()}, $minion->stuck_after
  );
}

sub reset {
  my ($self, $options) = (shift, shift // {});

  if ($options->{all}) { $self->pg->db->query('TRUNCATE minion_jobs, minion_locks, minion_workers RESTART IDENTITY') }
  elsif ($options->{locks}) { $self->pg->db->query('TRUNCATE minion_locks') }
}

sub retry_job {
  my ($self, $id, $retries, $options) = (shift, shift, shift, shift || {});

  return !!$self->pg->db->query(
    q{UPDATE minion_jobs SET attempts = COALESCE($1, attempts), delayed = (NOW() + (INTERVAL '1 second' * $2)),
        expires = CASE WHEN $3::BIGINT IS NOT NULL THEN NOW() + (INTERVAL '1 second' * $3::BIGINT) ELSE expires END,
        lax = COALESCE($4, lax), parents = COALESCE($5, parents), priority = COALESCE($6, priority),
        queue = COALESCE($7, queue), retried = NOW(), retries = retries + 1, state = 'inactive'
      WHERE id = $8 AND retries = $9
      RETURNING 1}, $options->{attempts}, $options->{delay} // 0, $options->{expire},
    exists $options->{lax} ? $options->{lax} ? 1 : 0 : undef, @$options{qw(parents priority queue)}, $id, $retries
  )->rows;
}

sub stats {
  my $self = shift;

  my $stats = $self->pg->db->query(
    "SELECT
       (SELECT COUNT(*) FROM minion_jobs WHERE state = 'inactive' AND (expires IS NULL OR expires > NOW())) AS inactive_jobs,
       (SELECT COUNT(*) FROM minion_jobs WHERE state = 'active') AS active_jobs,
       (SELECT COUNT(*) FROM minion_jobs WHERE state = 'failed') AS failed_jobs,
       (SELECT COUNT(*) FROM minion_jobs WHERE state = 'finished') AS finished_jobs,
       (SELECT COUNT(*) FROM minion_jobs WHERE state = 'inactive' AND delayed > NOW()) AS delayed_jobs,
       (SELECT COUNT(*) FROM minion_locks WHERE expires > NOW()) AS active_locks,
       (SELECT COUNT(DISTINCT worker) FROM minion_jobs mj WHERE state = 'active') AS active_workers,
       (SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM minion_jobs_id_seq) AS enqueued_jobs,
       (SELECT COUNT(*) FROM minion_workers) AS workers,
       EXTRACT(EPOCH FROM NOW() - PG_POSTMASTER_START_TIME()) AS uptime"
  )->hash;
  $stats->{inactive_workers} = $stats->{workers} - $stats->{active_workers};

  return $stats;
}

sub unlock {
  !!shift->pg->db->query(
    'DELETE FROM minion_locks WHERE id = (
       SELECT id FROM minion_locks WHERE expires > NOW() AND name = ? ORDER BY expires LIMIT 1 FOR UPDATE
     ) RETURNING 1', shift
  )->rows;
}

sub unregister_worker { shift->pg->db->query('DELETE FROM minion_workers WHERE id = ?', shift) }

sub _total {
  my ($name, $results) = @_;
  my $total = @$results ? $results->[0]{total} : 0;
  delete $_->{total} for @$results;
  return {total => $total, $name => $results};
}

sub _try {
  my ($self, $id, $options) = @_;

  return $self->pg->db->query(
    q{UPDATE minion_jobs SET started = NOW(), state = 'active', worker = ?
      WHERE id = (
        SELECT id FROM minion_jobs AS j
        WHERE delayed <= NOW() AND id = COALESCE(?, id) AND (parents = '{}' OR NOT EXISTS (
          SELECT 1 FROM minion_jobs WHERE id = ANY (j.parents) AND (
            state = 'active' OR (state = 'failed' AND NOT j.lax)
            OR (state = 'inactive' AND (expires IS NULL OR expires > NOW())))
        )) AND priority >= COALESCE(?, priority) AND queue = ANY (?) AND state = 'inactive' AND task = ANY (?)
          AND (EXPIRES IS NULL OR expires > NOW())
        ORDER BY priority DESC, id
        LIMIT 1
        FOR UPDATE SKIP LOCKED
      )
      RETURNING id, args, retries, task}, $id, $options->{id}, $options->{min_priority},
    $options->{queues} || ['default'], [keys %{$self->minion->tasks}]
  )->expand->hash;
}

sub _update {
  my ($self, $fail, $id, $retries, $result) = @_;

  return undef unless my $row = $self->pg->db->query(
    "UPDATE minion_jobs SET finished = NOW(), result = ?, state = ?
     WHERE id = ? AND retries = ? AND state = 'active'
     RETURNING attempts", {json => $result}, $fail ? 'failed' : 'finished', $id, $retries
  )->array;

  return $fail ? $self->auto_retry_job($id, $retries, $row->[0]) : 1;
}

1;

=encoding utf8

=head1 NAME

Minion::Backend::Pg - PostgreSQL backend

=head1 SYNOPSIS

  use Minion::Backend::Pg;

  my $backend = Minion::Backend::Pg->new('postgresql://postgres@/test');

=head1 DESCRIPTION

L<Minion::Backend::Pg> is a backend for L<Minion> based on L<Mojo::Pg>. All necessary tables will be created
automatically with a set of migrations named C<minion>. Note that this backend uses many bleeding edge features, so
only the latest, stable version of PostgreSQL is fully supported.

=head1 ATTRIBUTES

L<Minion::Backend::Pg> inherits all attributes from L<Minion::Backend> and implements the following new ones.

=head2 pg

  my $pg   = $backend->pg;
  $backend = $backend->pg(Mojo::Pg->new);

L<Mojo::Pg> object used to store all data.

=head1 METHODS

L<Minion::Backend::Pg> inherits all methods from L<Minion::Backend> and implements the following new ones.

=head2 broadcast

  my $bool = $backend->broadcast('some_command');
  my $bool = $backend->broadcast('some_command', [@args]);
  my $bool = $backend->broadcast('some_command', [@args], [$id1, $id2, $id3]);

Broadcast remote control command to one or more workers.

=head2 dequeue

  my $job_info = $backend->dequeue($worker_id, 0.5);
  my $job_info = $backend->dequeue($worker_id, 0.5, {queues => ['important']});

Wait a given amount of time in seconds for a job, dequeue it and transition from C<inactive> to C<active> state, or
return C<undef> if queues were empty.

These options are currently available:

=over 2

=item id

  id => '10023'

Dequeue a specific job.

=item min_priority

  min_priority => 3

Do not dequeue jobs with a lower priority.

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

Number of times performing this job will be attempted, with a delay based on L<Minion/"backoff"> after the first
attempt, defaults to C<1>.

=item delay

  delay => 10

Delay job for this many seconds (from now), defaults to C<0>.

=item expire

  expire => 300

Job is valid for this many seconds (from now) before it expires.

=item lax

  lax => 1

Existing jobs this job depends on may also have transitioned to the C<failed> state to allow for it to be processed,
defaults to C<false>. Note that this option is B<EXPERIMENTAL> and might change without warning!

=item notes

  notes => {foo => 'bar', baz => [1, 2, 3]}

Hash reference with arbitrary metadata for this job.

=item parents

  parents => [$id1, $id2, $id3]

One or more existing jobs this job depends on, and that need to have transitioned to the state C<finished> before it
can be processed.

=item priority

  priority => 5

Job priority, defaults to C<0>. Jobs with a higher priority get performed first. Priorities can be positive or negative,
but should be in the range between C<100> and C<-100>.

=item queue

  queue => 'important'

Queue to put job in, defaults to C<default>.

=back

=head2 fail_job

  my $bool = $backend->fail_job($job_id, $retries);
  my $bool = $backend->fail_job($job_id, $retries, 'Something went wrong!');
  my $bool = $backend->fail_job(
    $job_id, $retries, {whatever => 'Something went wrong!'});

Transition from C<active> to C<failed> state with or without a result, and if there are attempts remaining, transition
back to C<inactive> with a delay based on L<Minion/"backoff">.

=head2 finish_job

  my $bool = $backend->finish_job($job_id, $retries);
  my $bool = $backend->finish_job($job_id, $retries, 'All went well!');
  my $bool = $backend->finish_job(
    $job_id, $retries, {whatever => 'All went well!'});

Transition from C<active> to C<finished> state with or without a result.

=head2 history

  my $history = $backend->history;

Get history information for job queue.

These fields are currently available:

=over 2

=item daily

  daily => [{epoch => 12345, finished_jobs => 95, failed_jobs => 2}, ...]

Hourly counts for processed jobs from the past day.

=back

=head2 list_jobs

  my $results = $backend->list_jobs($offset, $limit);
  my $results = $backend->list_jobs($offset, $limit, {states => ['inactive']});

Returns the information about jobs in batches.

  # Get the total number of results (without limit)
  my $num = $backend->list_jobs(0, 100, {queues => ['important']})->{total};

  # Check job state
  my $results = $backend->list_jobs(0, 1, {ids => [$job_id]});
  my $state = $results->{jobs}[0]{state};

  # Get job result
  my $results = $backend->list_jobs(0, 1, {ids => [$job_id]});
  my $result  = $results->{jobs}[0]{result};

These options are currently available:

=over 2

=item before

  before => 23

List only jobs before this id.

=item ids

  ids => ['23', '24']

List only jobs with these ids.

=item notes

  notes => ['foo', 'bar']

List only jobs with one of these notes.

=item queues

  queues => ['important', 'unimportant']

List only jobs in these queues.

=item states

  states => ['inactive', 'active']

List only jobs in these states.

=item tasks

  tasks => ['foo', 'bar']

List only jobs for these tasks.

=back

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

=item expires

  expires => 784111777

Epoch time job is valid until before it expires.

=item finished

  finished => 784111777

Epoch time job was finished.

=item id

  id => 10025

Job id.

=item lax

  lax => 0

Existing jobs this job depends on may also have failed to allow for it to be processed.

=item notes

  notes => {foo => 'bar', baz => [1, 2, 3]}

Hash reference with arbitrary metadata for this job.

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

=item time

  time => 78411177

Server time.

=item worker

  worker => '154'

Id of worker that is processing the job.

=back

=head2 list_locks

  my $results = $backend->list_locks($offset, $limit);
  my $results = $backend->list_locks($offset, $limit, {names => ['foo']});

Returns information about locks in batches.

  # Get the total number of results (without limit)
  my $num = $backend->list_locks(0, 100, {names => ['bar']})->{total};

  # Check expiration time
  my $results = $backend->list_locks(0, 1, {names => ['foo']});
  my $expires = $results->{locks}[0]{expires};

These options are currently available:

=over 2

=item names

  names => ['foo', 'bar']

List only locks with these names.

=back

These fields are currently available:

=over 2

=item expires

  expires => 784111777

Epoch time this lock will expire.

=item id

  id => 1

Lock id.

=item name

  name => 'foo'

Lock name.

=back

=head2 list_workers

  my $results = $backend->list_workers($offset, $limit);
  my $results = $backend->list_workers($offset, $limit, {ids => [23]});

Returns information about workers in batches.

  # Get the total number of results (without limit)
  my $num = $backend->list_workers(0, 100)->{total};

  # Check worker host
  my $results = $backend->list_workers(0, 1, {ids => [$worker_id]});
  my $host    = $results->{workers}[0]{host};

These options are currently available:

=over 2

=item before

  before => 23

List only workers before this id.

=item ids

  ids => ['23', '24']

List only workers with these ids.

=back

These fields are currently available:

=over 2

=item id

  id => 22

Worker id.

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

=head2 lock

  my $bool = $backend->lock('foo', 3600);
  my $bool = $backend->lock('foo', 3600, {limit => 20});

Try to acquire a named lock that will expire automatically after the given amount of time in seconds. An expiration
time of C<0> can be used to check if a named lock already exists without creating one.

These options are currently available:

=over 2

=item limit

  limit => 20

Number of shared locks with the same name that can be active at the same time, defaults to C<1>.

=back

=head2 new

  my $backend = Minion::Backend::Pg->new('postgresql://postgres@/test');
  my $backend = Minion::Backend::Pg->new(Mojo::Pg->new);

Construct a new L<Minion::Backend::Pg> object.

=head2 note

  my $bool = $backend->note($job_id, {mojo => 'rocks', minion => 'too'});

Change one or more metadata fields for a job. Setting a value to C<undef> will remove the field.

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

  $backend->reset({all => 1});

Reset job queue.

These options are currently available:

=over 2

=item all

  all => 1

Reset everything.

=item locks

  locks => 1

Reset only locks.

=back

=head2 retry_job

  my $bool = $backend->retry_job($job_id, $retries);
  my $bool = $backend->retry_job($job_id, $retries, {delay => 10});

Transition job back to C<inactive> state, already C<inactive> jobs may also be retried to change options.

These options are currently available:

=over 2

=item attempts

  attempts => 25

Number of times performing this job will be attempted.

=item delay

  delay => 10

Delay job for this many seconds (from now), defaults to C<0>.

=item expire

  expire => 300

Job is valid for this many seconds (from now) before it expires.

=item lax

  lax => 1

Existing jobs this job depends on may also have transitioned to the C<failed> state to allow for it to be processed,
defaults to C<false>. Note that this option is B<EXPERIMENTAL> and might change without warning!

=item parents

  parents => [$id1, $id2, $id3]

Jobs this job depends on.

=item priority

  priority => 5

Job priority.

=item queue

  queue => 'important'

Queue to put job in.

=back

=head2 stats

  my $stats = $backend->stats;

Get statistics for the job queue.

These fields are currently available:

=over 2

=item active_jobs

  active_jobs => 100

Number of jobs in C<active> state.

=item active_locks

  active_locks => 100

Number of active named locks.

=item active_workers

  active_workers => 100

Number of workers that are currently processing a job.

=item delayed_jobs

  delayed_jobs => 100

Number of jobs in C<inactive> state that are scheduled to run at specific time in the future.

=item enqueued_jobs

  enqueued_jobs => 100000

Rough estimate of how many jobs have ever been enqueued.

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

=item uptime

  uptime => 1000

Uptime in seconds.

=item workers

  workers => 200;

Number of registered workers.

=back

=head2 unlock

  my $bool = $backend->unlock('foo');

Release a named lock.

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker.

=head1 SEE ALSO

L<Minion>, L<Minion::Guide>, L<https://minion.pm>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
