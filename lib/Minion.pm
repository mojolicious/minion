package Minion;
use Mojo::Base 'Mojo::EventEmitter';

use Carp qw(croak);
use Config;
use Minion::Iterator;
use Minion::Job;
use Minion::Worker;
use Mojo::Date;
use Mojo::IOLoop;
use Mojo::Loader qw(load_class);
use Mojo::Promise;
use Mojo::Server;
use Mojo::Util qw(scope_guard steady_time);
use YAML::XS   qw(Dump);

has app => sub { $_[0]{app_ref} = Mojo::Server->new->build_app('Mojo::HelloWorld') }, weak => 1;
has 'backend';
has backoff                        => sub { \&_backoff };
has missing_after                  => 1800;
has [qw(remove_after stuck_after)] => 172800;
has tasks                          => sub { {} };

our $VERSION = '10.32';

sub add_task {
  my ($self, $name, $task) = @_;

  unless (ref $task) {
    my $e = load_class $task;
    croak ref $e ? $e : qq{Task "$task" missing} if $e;
    croak qq{Task "$task" is not a Minion::Job subclass} unless $task->isa('Minion::Job');
  }
  $self->tasks->{$name} = $task;

  return $self;
}

sub broadcast { shift->backend->broadcast(@_) }

sub class_for_task {
  my ($self, $task) = @_;
  my $class = $self->tasks->{$task};
  return !$class || ref $class ? 'Minion::Job' : $class;
}

sub enqueue {
  my $self = shift;
  my $id   = $self->backend->enqueue(@_);
  $self->emit(enqueue => $id);
  return $id;
}

sub foreground {
  my ($self, $id) = @_;

  return undef unless my $job = $self->job($id);
  return undef unless $job->retry({attempts => 1, queue => 'minion_foreground'});

  # Reset event loop
  Mojo::IOLoop->reset;
  local $SIG{CHLD} = local $SIG{INT} = local $SIG{TERM} = local $SIG{QUIT} = 'DEFAULT';

  my $worker = $self->worker->register;
  $job = $worker->dequeue(0 => {id => $id, queues => ['minion_foreground']});
  my $err;
  if ($job) { defined($err = $job->execute) ? $job->fail($err) : $job->finish }
  $worker->unregister;

  return defined $err ? die $err : !!$job;
}

sub guard {
  my ($self, $name, $duration, $options) = @_;
  my $time = steady_time + $duration;
  return undef unless $self->lock($name, $duration, $options);
  return scope_guard sub { $self->unlock($name) if steady_time < $time };
}

sub history { shift->backend->history }

sub is_locked { !shift->lock(shift, 0) }

sub job {
  my ($self, $id) = @_;

  return undef unless my $job = $self->_info($id);
  return $self->class_for_task($job->{task})
    ->new(args => $job->{args}, id => $job->{id}, minion => $self, retries => $job->{retries}, task => $job->{task});
}

sub jobs { shift->_iterator(1, @_) }

sub lock { shift->backend->lock(@_) }

sub new {
  my $self = shift->SUPER::new;

  my $class = 'Minion::Backend::' . shift;
  my $e     = load_class $class;
  croak ref $e ? $e : qq{Backend "$class" missing} if $e;

  return $self->backend($class->new(@_)->minion($self));
}

sub perform_jobs               { _perform_jobs(0, @_) }
sub perform_jobs_in_foreground { _perform_jobs(1, @_) }

sub repair { shift->_delegate('repair') }

sub reset { shift->_delegate('reset', @_) }

sub result_p {
  my ($self, $id, $options) = (shift, shift, shift // {});

  my $promise = Mojo::Promise->new;
  my $cb      = sub { $self->_result($promise, $id) };
  my $timer   = Mojo::IOLoop->recurring($options->{interval} // 3 => $cb);
  $promise->finally(sub { Mojo::IOLoop->remove($timer) })->catch(sub { });
  $cb->();

  return $promise;
}

sub stats  { shift->backend->stats }
sub unlock { shift->backend->unlock(@_) }

sub worker {
  my $self = shift;

  # No fork emulation support
  croak 'Minion workers do not support fork emulation' if $Config{d_pseudofork};

  my $worker = Minion::Worker->new(minion => $self);
  $self->emit(worker => $worker);
  return $worker;
}

sub workers { shift->_iterator(0, @_) }

sub _backoff { (shift()**4) + 15 }

# Used by the job command and admin plugin
sub _datetime {
  my $hash = shift;
  $hash->{$_} and $hash->{$_} = Mojo::Date->new($hash->{$_})->to_datetime
    for qw(created delayed expires finished notified retried started time);
  return $hash;
}

sub _delegate {
  my ($self, $method) = (shift, shift);
  $self->backend->$method(@_);
  return $self;
}

sub _dump { local $YAML::XS::Boolean = 'JSON::PP'; Dump(@_) }

sub _iterator {
  my ($self, $jobs, $options) = (shift, shift, shift // {});
  return Minion::Iterator->new(minion => $self, options => $options, jobs => $jobs);
}

sub _info { shift->backend->list_jobs(0, 1, {ids => [shift]})->{jobs}[0] }

sub _perform_jobs {
  my ($foreground, $minion, $options) = @_;

  my $worker = $minion->worker;
  while (my $job = $worker->register->dequeue(0, $options)) {
    if    (!$foreground)                     { $job->perform }
    elsif (defined(my $err = $job->execute)) { $job->fail($err) }
    else                                     { $job->finish }
  }
  $worker->unregister;
}

sub _result {
  my ($self, $promise, $id) = @_;
  return $promise->resolve unless my $job = $self->_info($id);
  if    ($job->{state} eq 'finished') { $promise->resolve($job) }
  elsif ($job->{state} eq 'failed')   { $promise->reject($job) }
}

1;

=encoding utf8

=head1 NAME

Minion - Job queue

=head1 SYNOPSIS

  use Minion;

  # Connect to backend
  my $minion = Minion->new(Pg => 'postgresql://postgres@/test');

  # Add tasks
  $minion->add_task(something_slow => sub ($job, @args) {
    sleep 5;
    say 'This is a background worker process.';
  });

  # Enqueue jobs
  $minion->enqueue(something_slow => ['foo', 'bar']);
  $minion->enqueue(something_slow => [1, 2, 3] => {priority => 5});

  # Perform jobs for testing
  $minion->enqueue(something_slow => ['foo', 'bar']);
  $minion->perform_jobs;

  # Start a worker to perform up to 12 jobs concurrently
  my $worker = $minion->worker;
  $worker->status->{jobs} = 12;
  $worker->run;

=head1 DESCRIPTION

=begin html

<p>
  <img alt="Screenshot" src="https://raw.github.com/mojolicious/minion/main/examples/admin.png?raw=true" width="600px">
</p>

=end html

L<Minion> is a high performance job queue for the Perl programming language, with support for multiple named queues,
priorities, high priority fast lane, delayed jobs, job dependencies, job progress, job results, retries with backoff,
rate limiting, unique jobs, expiring jobs, statistics, distributed workers, parallel processing, autoscaling, remote
control, L<Mojolicious|https://mojolicious.org> admin ui, resource leak protection and multiple backends (such as
L<PostgreSQL|https://www.postgresql.org>).

Job queues allow you to process time and/or computationally intensive tasks in background processes, outside of the
request/response lifecycle of web applications. Among those tasks you'll commonly find image resizing, spam filtering,
HTTP downloads, building tarballs, warming caches and basically everything else you can imagine that's not super fast.

Take a look at our excellent documentation in L<Minion::Guide>!

=head1 EXAMPLES

This distribution also contains a great example application you can use for inspiration. The L<link
checker|https://github.com/mojolicious/minion/tree/main/examples/linkcheck> will show you how to integrate background
jobs into well-structured L<Mojolicious> applications.

=head1 EVENTS

L<Minion> inherits all events from L<Mojo::EventEmitter> and can emit the following new ones.

=head2 enqueue

  $minion->on(enqueue => sub ($minion, $id) {
    ...
  });

Emitted after a job has been enqueued, in the process that enqueued it.

  $minion->on(enqueue => sub ($minion, $id) {
    say "Job $id has been enqueued.";
  });

=head2 worker

  $minion->on(worker => sub ($minion, $worker) {
    ...
  });

Emitted in the worker process after it has been created.

  $minion->on(worker => sub ($minion, $worker) {
    say "Worker $$ started.";
  });

=head1 ATTRIBUTES

L<Minion> implements the following attributes.

=head2 app

  my $app = $minion->app;
  $minion = $minion->app(MyApp->new);

Application for job queue, defaults to a L<Mojo::HelloWorld> object. Note that this attribute is weakened.

=head2 backend

  my $backend = $minion->backend;
  $minion     = $minion->backend(Minion::Backend::Pg->new);

Backend, usually a L<Minion::Backend::Pg> object.

=head2 backoff

  my $cb  = $minion->backoff;
  $minion = $minion->backoff(sub {...});

A callback used to calculate the delay for automatically retried jobs, defaults to C<(retries ** 4) + 15> (15, 16, 31,
96, 271, 640...), which means that roughly C<25> attempts can be made in C<21> days.

  $minion->backoff(sub ($retries) {
    return ($retries ** 4) + 15 + int(rand 30);
  });

=head2 missing_after

  my $after = $minion->missing_after;
  $minion   = $minion->missing_after(172800);

Amount of time in seconds after which workers without a heartbeat will be considered missing and removed from the
registry by L</"repair">, defaults to C<1800> (30 minutes).

=head2 remove_after

  my $after = $minion->remove_after;
  $minion   = $minion->remove_after(86400);

Amount of time in seconds after which jobs that have reached the state C<finished> and have no unresolved dependencies
will be removed automatically by L</"repair">, defaults to C<172800> (2 days). It is not recommended to set this value
below 2 days.

=head2 stuck_after

  my $after = $minion->stuck_after;
  $minion   = $minion->stuck_after(86400);

Amount of time in seconds after which jobs that have not been processed will be considered stuck by L</"repair"> and
transition to the C<failed> state, defaults to C<172800> (2 days).

=head2 tasks

  my $tasks = $minion->tasks;
  $minion   = $minion->tasks({foo => sub {...}});

Registered tasks.

=head1 METHODS

L<Minion> inherits all methods from L<Mojo::EventEmitter> and implements the following new ones.

=head2 add_task

  $minion = $minion->add_task(foo => sub {...});
  $minion = $minion->add_task(foo => 'MyApp::Task::Foo');

Register a task, which can be a closure or a custom L<Minion::Job> subclass. Note that support for custom task classes
is B<EXPERIMENTAL> and might change without warning!

  # Job with result
  $minion->add_task(add => sub ($job, $first, $second) {
    $job->finish($first + $second);
  });
  my $id = $minion->enqueue(add => [1, 1]);
  my $result = $minion->job($id)->info->{result};

=head2 broadcast

  my $bool = $minion->broadcast('some_command');
  my $bool = $minion->broadcast('some_command', [@args]);
  my $bool = $minion->broadcast('some_command', [@args], [$id1, $id2, $id3]);

Broadcast remote control command to one or more workers.

  # Broadcast "stop" command to all workers to kill job 10025
  $minion->broadcast('stop', [10025]);

  # Broadcast "kill" command to all workers to interrupt job 10026
  $minion->broadcast('kill', ['INT', 10026]);

  # Broadcast "jobs" command to pause worker 23
  $minion->broadcast('jobs', [0], [23]);

=head2 class_for_task

  my $class = $minion->class_for_task('foo');

Return job class for task. Note that this method is B<EXPERIMENTAL> and might change without warning!

=head2 enqueue

  my $id = $minion->enqueue('foo');
  my $id = $minion->enqueue(foo => [@args]);
  my $id = $minion->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state. Arguments get serialized by the L</"backend"> (often with L<Mojo::JSON>), so
you shouldn't send objects and be careful with binary data, nested data structures with hash and array references are
fine though.

These options are currently available:

=over 2

=item attempts

  attempts => 25

Number of times performing this job will be attempted, with a delay based on L</"backoff"> after the first attempt,
defaults to C<1>.

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

Hash reference with arbitrary metadata for this job that gets serialized by the L</"backend"> (often with
L<Mojo::JSON>), so you shouldn't send objects and be careful with binary data, nested data structures with hash and
array references are fine though.

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

=head2 foreground

  my $bool = $minion->foreground($id);

Retry job in C<minion_foreground> queue, then perform it right away with a temporary worker in this process, very
useful for debugging.

=head2 guard

  my $guard = $minion->guard('foo', 3600);
  my $guard = $minion->guard('foo', 3600, {limit => 20});

Same as L</"lock">, but returns a scope guard object that automatically releases the lock as soon as the object is
destroyed, or C<undef> if aquiring the lock failed.

  # Only one job should run at a time (unique job)
  $minion->add_task(do_unique_stuff => sub ($job, @args) {
    return $job->finish('Previous job is still active')
      unless my $guard = $minion->guard('fragile_backend_service', 7200);
    ...
  });

  # Only five jobs should run at a time and we try again later if necessary
  $minion->add_task(do_concurrent_stuff => sub ($job, @args) {
    return $job->retry({delay => 30})
      unless my $guard = $minion->guard('some_web_service', 60, {limit => 5});
    ...
  });

=head2 history

  my $history = $minion->history;

Get history information for job queue.

These fields are currently available:

=over 2

=item daily

  daily => [{epoch => 12345, finished_jobs => 95, failed_jobs => 2}, ...]

Hourly counts for processed jobs from the past day.

=back

=head2 is_locked

  my $bool = $minion->is_locked('foo');

Check if a lock with that name is currently active.

=head2 job

  my $job = $minion->job($id);

Get L<Minion::Job> object without making any changes to the actual job or return C<undef> if job does not exist.

  # Check job state
  my $state = $minion->job($id)->info->{state};

  # Get job metadata
  my $progress = $minion->job($id)->info->{notes}{progress};

  # Get job result
  my $result = $minion->job($id)->info->{result};

=head2 jobs

  my $jobs = $minion->jobs;
  my $jobs = $minion->jobs({states => ['inactive']});

Return L<Minion::Iterator> object to safely iterate through job information.

  # Iterate through jobs for two tasks
  my $jobs = $minion->jobs({tasks => ['foo', 'bar']});
  while (my $info = $jobs->next) {
    say "$info->{id}: $info->{state}";
  }

  # Remove all failed jobs from a named queue
  my $jobs = $minion->jobs({states => ['failed'], queues => ['unimportant']});
  while (my $info = $jobs->next) {
    $minion->job($info->{id})->remove;
  }

  # Count failed jobs for a task
  say $minion->jobs({states => ['failed'], tasks => ['foo']})->total;

These options are currently available:

=over 2

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

=head2 lock

  my $bool = $minion->lock('foo', 3600);
  my $bool = $minion->lock('foo', 3600, {limit => 20});

Try to acquire a named lock that will expire automatically after the given amount of time in seconds. You can release
the lock manually with L</"unlock"> to limit concurrency, or let it expire for rate limiting. For convenience you can
also use L</"guard"> to release the lock automatically, even if the job failed.

  # Only one job should run at a time (unique job)
  $minion->add_task(do_unique_stuff => sub ($job, @args) {
    return $job->finish('Previous job is still active')
      unless $minion->lock('fragile_backend_service', 7200);
    ...
    $minion->unlock('fragile_backend_service');
  });

  # Only five jobs should run at a time and we wait for our turn
  $minion->add_task(do_concurrent_stuff => sub ($job, @args) {
    sleep 1 until $minion->lock('some_web_service', 60, {limit => 5});
    ...
    $minion->unlock('some_web_service');
  });

  # Only a hundred jobs should run per hour and we try again later if necessary
  $minion->add_task(do_rate_limited_stuff => sub ($job, @args) {
    return $job->retry({delay => 3600})
      unless $minion->lock('another_web_service', 3600, {limit => 100});
    ...
  });

An expiration time of C<0> can be used to check if a named lock could have been acquired without creating one.

  # Check if the lock "foo" could have been acquired
  say 'Lock could have been acquired' unless $minion->lock('foo', 0);

Or to simply check if a named lock already exists you can also use L</"is_locked">.

These options are currently available:

=over 2

=item limit

  limit => 20

Number of shared locks with the same name that can be active at the same time, defaults to C<1>.

=back

=head2 new

  my $minion = Minion->new(Pg => 'postgresql://postgres@/test');
  my $minion = Minion->new(Pg => Mojo::Pg->new);

Construct a new L<Minion> object.

=head2 perform_jobs

  $minion->perform_jobs;
  $minion->perform_jobs({queues => ['important']});

Perform all jobs with a temporary worker, very useful for testing.

  # Longer version
  my $worker = $minion->worker;
  while (my $job = $worker->register->dequeue(0)) { $job->perform }
  $worker->unregister;

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

=head2 perform_jobs_in_foreground

  $minion->perform_jobs_in_foreground;
  $minion->perform_jobs_in_foreground({queues => ['important']});

Same as L</"perform_jobs">, but all jobs are performed in the current process, without spawning new processes.

=head2 repair

  $minion = $minion->repair;

Repair worker registry and job queue if necessary.

=head2 reset

  $minion = $minion->reset({all => 1});

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

=head2 result_p

  my $promise = $minion->result_p($id);
  my $promise = $minion->result_p($id, {interval => 5});

Return a L<Mojo::Promise> object for the result of a job. The state C<finished> will result in the promise being
C<fullfilled>, and the state C<failed> in the promise being C<rejected>. This operation can be cancelled by resolving
the promise manually at any time.

  # Enqueue job and receive the result at some point in the future
  my $id = $minion->enqueue('foo');
  $minion->result_p($id)->then(sub ($info) {
    my $result = ref $info ? $info->{result} : 'Job already removed';
    say "Finished: $result";
  })->catch(sub ($info) {
    say "Failed: $info->{result}";
  })->wait;

These options are currently available:

=over 2

=item interval

  interval => 5

Polling interval in seconds for checking if the state of the job has changed, defaults to C<3>.

=back

=head2 stats

  my $stats = $minion->stats;

Get statistics for the job queue.

  # Check idle workers
  my $idle = $minion->stats->{inactive_workers};

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

  my $bool = $minion->unlock('foo');

Release a named lock that has been previously acquired with L</"lock">.

=head2 worker

  my $worker = $minion->worker;

Build L<Minion::Worker> object. Note that this method should only be used to implement custom workers.

  # Use the standard worker with all its features
  my $worker = $minion->worker;
  $worker->status->{jobs} = 12;
  $worker->status->{queues} = ['important'];
  $worker->run;

  # Perform one job manually in a separate process
  my $worker = $minion->repair->worker->register;
  my $job    = $worker->dequeue(5);
  $job->perform;
  $worker->unregister;

  # Perform one job manually in this process
  my $worker = $minion->repair->worker->register;
  my $job    = $worker->dequeue(5);
  if (my $err = $job->execute) { $job->fail($err) }
  else                         { $job->finish }
  $worker->unregister;

  # Build a custom worker performing multiple jobs at the same time
  my %jobs;
  my $worker = $minion->repair->worker->register;
  do {
    for my $id (keys %jobs) {
      delete $jobs{$id} if $jobs{$id}->is_finished;
    }
    if (keys %jobs >= 4) { sleep 5 }
    else {
      my $job = $worker->dequeue(5);
      $jobs{$job->id} = $job->start if $job;
    }
  } while keys %jobs;
  $worker->unregister;

=head2 workers

  my $workers = $minion->workers;
  my $workers = $minion->workers({ids => [2, 3]});

Return L<Minion::Iterator> object to safely iterate through worker information.

  # Iterate through workers
  my $workers = $minion->workers;
  while (my $info = $workers->next) {
    say "$info->{id}: $info->{host}";
  }

These options are currently available:

=over 2

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

=head1 API

This is the class hierarchy of the L<Minion> distribution.

=over 2

=item * L<Minion>

=item * L<Minion::Backend>

=over 2

=item * L<Minion::Backend::Pg>

=back

=item * L<Minion::Command::minion>

=item * L<Minion::Command::minion::job>

=item * L<Minion::Command::minion::worker>

=item * L<Minion::Iterator>

=item * L<Minion::Job>

=item * L<Minion::Worker>

=item * L<Mojolicious::Plugin::Minion>

=item * L<Mojolicious::Plugin::Minion::Admin>

=back

=head1 BUNDLED FILES

The L<Minion> distribution includes a few files with different licenses that have been bundled for internal use.

=head2 Minion Artwork

  Copyright (C) 2017, Sebastian Riedel.

Licensed under the CC-SA License, Version 4.0 L<http://creativecommons.org/licenses/by-sa/4.0>.

=head2 Bootstrap

  Copyright (C) 2011-2021 The Bootstrap Authors.

Licensed under the MIT License, L<http://creativecommons.org/licenses/MIT>.

=head2 jQuery

  Copyright (C) jQuery Foundation.

Licensed under the MIT License, L<http://creativecommons.org/licenses/MIT>.

=head2 D3.js

  Copyright (C) 2010-2016, Michael Bostock.

Licensed under the 3-Clause BSD License, L<https://opensource.org/licenses/BSD-3-Clause>.

=head2 epoch.js

  Copyright (C) 2014 Fastly, Inc.

Licensed under the MIT License, L<http://creativecommons.org/licenses/MIT>.

=head2 Font Awesome

  Copyright (C) Dave Gandy.

Licensed under the MIT License, L<http://creativecommons.org/licenses/MIT>, and the SIL OFL 1.1,
L<http://scripts.sil.org/OFL>.

=head2 moment.js

  Copyright (C) JS Foundation and other contributors.

Licensed under the MIT License, L<http://creativecommons.org/licenses/MIT>.

=head1 AUTHORS

=head2 Project Founder

Sebastian Riedel, C<sri@cpan.org>.

=head2 Contributors

In alphabetical order:

=over 2

Andrey Khozov

Andrii Nikitin

Brian Medley

Franz Skale

Henrik Andersen

Hubert "depesz" Lubaczewski

Joel Berger

Paul Williams

Russell Shingleton

Stefan Adams

Stuart Skelton

=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014-2024, Sebastian Riedel and others.

This program is free software, you can redistribute it and/or modify it under the terms of the Artistic License version
2.0.

=head1 SEE ALSO

L<https://github.com/mojolicious/minion>, L<Minion::Guide>, L<https://minion.pm>, L<Mojolicious::Guides>,
L<https://mojolicious.org>.

=cut
