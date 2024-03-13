package Minion::Backend;
use Mojo::Base -base;

use Carp qw(croak);

has minion => undef, weak => 1;

sub auto_retry_job {
  my ($self, $id, $retries, $attempts) = @_;
  return 1 if $attempts <= 1;
  my $delay = $self->minion->backoff->($retries);
  return $self->retry_job($id, $retries, {attempts => $attempts > 1 ? $attempts - 1 : 1, delay => $delay});
}

sub broadcast         { croak 'Method "broadcast" not implemented by subclass' }
sub dequeue           { croak 'Method "dequeue" not implemented by subclass' }
sub enqueue           { croak 'Method "enqueue" not implemented by subclass' }
sub fail_job          { croak 'Method "fail_job" not implemented by subclass' }
sub finish_job        { croak 'Method "finish_job" not implemented by subclass' }
sub history           { croak 'Method "history" not implemented by subclass' }
sub list_jobs         { croak 'Method "list_jobs" not implemented by subclass' }
sub list_locks        { croak 'Method "list_locks" not implemented by subclass' }
sub list_workers      { croak 'Method "list_workers" not implemented by subclass' }
sub lock              { croak 'Method "lock" not implemented by subclass' }
sub note              { croak 'Method "note" not implemented by subclass' }
sub receive           { croak 'Method "receive" not implemented by subclass' }
sub register_worker   { croak 'Method "register_worker" not implemented by subclass' }
sub remove_job        { croak 'Method "remove_job" not implemented by subclass' }
sub repair            { croak 'Method "repair" not implemented by subclass' }
sub reset             { croak 'Method "reset" not implemented by subclass' }
sub retry_job         { croak 'Method "retry_job" not implemented by subclass' }
sub stats             { croak 'Method "stats" not implemented by subclass' }
sub unlock            { croak 'Method "unlock" not implemented by subclass' }
sub unregister_worker { croak 'Method "unregister_worker" not implemented by subclass' }

1;

=encoding utf8

=head1 NAME

Minion::Backend - Backend base class

=head1 SYNOPSIS

  package Minion::Backend::MyBackend;
  use Mojo::Base 'Minion::Backend';

  sub broadcast         {...}
  sub dequeue           {...}
  sub enqueue           {...}
  sub fail_job          {...}
  sub finish_job        {...}
  sub history           {...}
  sub list_jobs         {...}
  sub list_locks        {...}
  sub list_workers      {...}
  sub lock              {...}
  sub note              {...}
  sub receive           {...}
  sub register_worker   {...}
  sub remove_job        {...}
  sub repair            {...}
  sub reset             {...}
  sub retry_job         {...}
  sub stats             {...}
  sub unlock            {...}
  sub unregister_worker {...}

=head1 DESCRIPTION

L<Minion::Backend> is an abstract base class for L<Minion> backends, like L<Minion::Backend::Pg>.

=head1 ATTRIBUTES

L<Minion::Backend> implements the following attributes.

=head2 minion

  my $minion = $backend->minion;
  $backend   = $backend->minion(Minion->new);

L<Minion> object this backend belongs to. Note that this attribute is weakened.

=head1 METHODS

L<Minion::Backend> inherits all methods from L<Mojo::Base> and implements the following new ones.

=head2 auto_retry_job

  my $bool = $backend->auto_retry_job($job_id, $retries, $attempts);

Automatically L</"retry"> job with L<Minion/"backoff"> if there are attempts left, used to implement backends like
L<Minion::Backend::Pg>.

=head2 broadcast

  my $bool = $backend->broadcast('some_command');
  my $bool = $backend->broadcast('some_command', [@args]);
  my $bool = $backend->broadcast('some_command', [@args], [$id1, $id2, $id3]);

Broadcast remote control command to one or more workers. Meant to be overloaded in a subclass.

=head2 dequeue

  my $job_info = $backend->dequeue($worker_id, 0.5);
  my $job_info = $backend->dequeue($worker_id, 0.5, {queues => ['important']});

Wait a given amount of time in seconds for a job, dequeue it and transition from C<inactive> to C<active> state, or
return C<undef> if queues were empty. Meant to be overloaded in a subclass.

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

Enqueue a new job with C<inactive> state. Meant to be overloaded in a subclass.

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
back to C<inactive> with a delay based on L<Minion/"backoff">. Meant to be overloaded in a subclass.

=head2 finish_job

  my $bool = $backend->finish_job($job_id, $retries);
  my $bool = $backend->finish_job($job_id, $retries, 'All went well!');
  my $bool = $backend->finish_job(
    $job_id, $retries, {whatever => 'All went well!'});

Transition from C<active> to C<finished> state with or without a result. Meant to be overloaded in a subclass.

=head2 history

  my $history = $backend->history;

Get history information for job queue. Meant to be overloaded in a subclass.

These fields are currently available:

=over 2

=item daily

  daily => [{epoch => 12345, finished_jobs => 95, failed_jobs => 2}, ...]

Hourly counts for processed jobs from the past day.

=back

=head2 list_jobs

  my $results = $backend->list_jobs($offset, $limit);
  my $results = $backend->list_jobs($offset, $limit, {states => ['inactive']});

Returns the information about jobs in batches. Meant to be overloaded in a subclass.

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

Returns information about locks in batches. Meant to be overloaded in a subclass.

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

Returns information about workers in batches. Meant to be overloaded in a subclass.

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
time of C<0> can be used to check if a named lock already exists without creating one. Meant to be overloaded in a
subclass.

These options are currently available:

=over 2

=item limit

  limit => 20

Number of shared locks with the same name that can be active at the same time, defaults to C<1>.

=back

=head2 note

  my $bool = $backend->note($job_id, {mojo => 'rocks', minion => 'too'});

Change one or more metadata fields for a job. Setting a value to C<undef> will remove the field. Meant to be overloaded
in a subclass.

=head2 receive

  my $commands = $backend->receive($worker_id);

Receive remote control commands for worker. Meant to be overloaded in a subclass.

=head2 register_worker

  my $worker_id = $backend->register_worker;
  my $worker_id = $backend->register_worker($worker_id);
  my $worker_id = $backend->register_worker(
    $worker_id, {status => {queues => ['default', 'important']}});

Register worker or send heartbeat to show that this worker is still alive. Meant to be overloaded in a subclass.

These options are currently available:

=over 2

=item status

  status => {queues => ['default', 'important']}

Hash reference with whatever status information the worker would like to share.

=back

=head2 remove_job

  my $bool = $backend->remove_job($job_id);

Remove C<failed>, C<finished> or C<inactive> job from queue. Meant to be overloaded in a subclass.

=head2 repair

  $backend->repair;

Repair worker registry and job queue if necessary. Meant to be overloaded in a subclass.

=head2 reset

  $backend->reset({all => 1});

Reset job queue. Meant to be overloaded in a subclass.

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

Transition job back to C<inactive> state, already C<inactive> jobs may also be retried to change options. Meant to be
overloaded in a subclass.

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

Get statistics for the job queue. Meant to be overloaded in a subclass.

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

Number of jobs in C<inactive> state that are scheduled to run at specific time in the future or have unresolved
dependencies.

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

Release a named lock. Meant to be overloaded in a subclass.

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker. Meant to be overloaded in a subclass.

=head1 SEE ALSO

L<Minion>, L<Minion::Guide>, L<https://minion.pm>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
