package Minion::Job;
use Mojo::Base 'Mojo::EventEmitter';

use Carp qw(croak);
use Mojo::Collection;
use Mojo::IOLoop;
use POSIX qw(WNOHANG);

has [qw(args id minion retries task)];

sub app { shift->minion->app }

sub execute {
  my $self = shift;
  return eval {
    my $task = $self->minion->tasks->{$self->emit('start')->task};
    ref $task ? $self->$task(@{$self->args}) : $self->run(@{$self->args});
    !!$self->emit('finish');
  } ? undef : $@;
}

sub fail {
  my ($self, $err) = (shift, shift // 'Unknown error');
  my $ok = $self->minion->backend->fail_job($self->id, $self->retries, $err);
  return $ok ? !!$self->emit(failed => $err) : undef;
}

sub finish {
  my ($self, $result) = @_;
  my $ok = $self->minion->backend->finish_job($self->id, $self->retries, $result);
  return $ok ? !!$self->emit(finished => $result) : undef;
}

sub info { $_[0]->minion->backend->list_jobs(0, 1, {ids => [$_[0]->id]})->{jobs}[0] }

sub is_finished {
  my $self = shift;
  return undef unless waitpid($self->{pid}, WNOHANG) == $self->{pid};
  $self->_reap($? ? (1, $? >> 8, $? & 127) : ());
  return 1;
}

sub kill { CORE::kill($_[1], $_[0]->{pid}) }

sub note {
  my $self = shift;
  return $self->minion->backend->note($self->id, {@_});
}

sub parents {
  my $self   = shift;
  my $minion = $self->minion;
  return Mojo::Collection->new(map { $minion->job($_) // () } @{($self->info || {})->{parents} || []});
}

sub perform {
  my $self = shift;
  waitpid $self->start->pid, 0;
  $self->_reap($? ? (1, $? >> 8, $? & 127) : ());
}

sub pid { shift->{pid} }

sub remove { $_[0]->minion->backend->remove_job($_[0]->id) }

sub retry {
  my $self = shift;
  return $self->minion->backend->retry_job($self->id, $self->retries, @_);
}

sub run { croak 'Method "run" not implemented by subclass' }

sub start {
  my $self = shift;

  # Parent
  die "Can't fork: $!" unless defined(my $pid = fork);
  return $self->emit(spawn => $pid) if $self->{pid} = $pid;

  # Reset event loop
  Mojo::IOLoop->reset;
  local $SIG{CHLD} = local $SIG{INT}  = local $SIG{TERM} = local $SIG{QUIT} = 'DEFAULT';
  local $SIG{USR1} = local $SIG{USR2} = 'IGNORE';
  srand;

  # Child
  if (defined(my $err = $self->execute)) { $self->fail($err) }
  $self->emit('cleanup');
  POSIX::_exit(0);
}

sub stop { shift->kill('KILL') }

sub _reap {
  my ($self, $term, $exit, $sig) = @_;
  $self->emit(reap => $self->{pid});
  $term ? $self->fail("Job terminated unexpectedly (exit code: $exit, signal: $sig)") : $self->finish;
}

1;

=encoding utf8

=head1 NAME

Minion::Job - Minion job

=head1 SYNOPSIS

  package MyApp::Task::Foo;
  use Mojo::Base 'Minion::Job', -signatures;

  sub run ($self, @args) {

    # Magic here! :)
  }

=head1 DESCRIPTION

L<Minion::Job> is a container for L<Minion> jobs.

=head1 EVENTS

L<Minion::Job> inherits all events from L<Mojo::EventEmitter> and can emit the following new ones.

=head2 cleanup

  $job->on(cleanup => sub ($job) {
    ...
  });

Emitted in the process performing this job right before the process will exit.

  $job->on(cleanup => sub ($job) {
    $job->app->log->debug("Process $$ is about to exit");
  });

=head2 failed

  $job->on(failed => sub ($job, $err) {
    ...
  });

Emitted in the worker process managing this job or the process performing it, after it has transitioned to the
C<failed> state.

  $job->on(failed => sub ($job, $err) {
    say "Something went wrong: $err";
  });

=head2 finish

  $job->on(finish => sub ($job) {
    ...
  });

Emitted in the process performing this job if the task was successful.

  $job->on(finish => sub ($job) {
    my $id   = $job->id;
    my $task = $job->task;
    $job->app->log->debug(qq{Job "$id" was performed with task "$task"});
  });

=head2 finished

  $job->on(finished => sub ($job, $result) {
    ...
  });

Emitted in the worker process managing this job or the process performing it, after it has transitioned to the
C<finished> state.

  $job->on(finished => sub ($job, $result) {
    my $id = $job->id;
    say "Job $id is finished.";
  });

=head2 reap

  $job->on(reap => sub ($job, $pid) {
    ...
  });

Emitted in the worker process managing this job, after the process performing it has exited.

  $job->on(reap => sub ($job, $pid) {
    my $id = $job->id;
    say "Job $id ran in process $pid";
  });

=head2 spawn

  $job->on(spawn => sub ($job, $pid) {
    ...
  });

Emitted in the worker process managing this job, after a new process has been spawned for processing.

  $job->on(spawn => sub ($job, $pid) {
    my $id = $job->id;
    say "Job $id running in process $pid";
  });

=head2 start

  $job->on(start => sub ($job) {
    ...
  });

Emitted in the process performing this job, after it has been spawned.

  $job->on(start => sub ($job) {
    $0 = $job->id;
  });

=head1 ATTRIBUTES

L<Minion::Job> implements the following attributes.

=head2 args

  my $args = $job->args;
  $job     = $job->args([]);

Arguments passed to task.

=head2 id

  my $id = $job->id;
  $job   = $job->id($id);

Job id.

=head2 minion

  my $minion = $job->minion;
  $job       = $job->minion(Minion->new);

L<Minion> object this job belongs to.

=head2 retries

  my $retries = $job->retries;
  $job        = $job->retries(5);

Number of times job has been retried.

=head2 task

  my $task = $job->task;
  $job     = $job->task('foo');

Task name.

=head1 METHODS

L<Minion::Job> inherits all methods from L<Mojo::EventEmitter> and implements the following new ones.

=head2 app

  my $app = $job->app;

Get application from L<Minion/"app">.

  # Longer version
  my $app = $job->minion->app;

=head2 execute

  my $err = $job->execute;

Perform job in this process and return C<undef> if the task was successful or an exception otherwise.  Note that this
method should only be used to implement custom workers.

  # Perform job in foreground
  if (my $err = $job->execute) { $job->fail($err) }
  else                         { $job->finish }

=head2 fail

  my $bool = $job->fail;
  my $bool = $job->fail('Something went wrong!');
  my $bool = $job->fail({whatever => 'Something went wrong!'});

Transition from C<active> to C<failed> state with or without a result, and if there are attempts remaining, transition
back to C<inactive> with a delay based on L<Minion/"backoff">.

=head2 finish

  my $bool = $job->finish;
  my $bool = $job->finish('All went well!');
  my $bool = $job->finish({whatever => 'All went well!'});

Transition from C<active> to C<finished> state with or without a result.

=head2 info

  my $info = $job->info;

Get job information.

  # Check job state
  my $state = $job->info->{state};

  # Get job metadata
  my $progress = $job->info->{notes}{progress};

  # Get job result
  my $result = $job->info->{result};

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

  time => 784111777

Server time.

=item worker

  worker => '154'

Id of worker that is processing the job.

=back

=head2 is_finished

  my $bool = $job->is_finished;

Check if job performed with L</"start"> is finished. Note that this method should only be used to implement custom
workers.

=head2 kill

  $job->kill('INT');

Send a signal to job performed with L</"start">. Note that this method should only be used to implement custom workers.

=head2 note

  my $bool = $job->note(mojo => 'rocks', minion => 'too');

Change one or more metadata fields for this job. Setting a value to C<undef> will remove the field. The new values will
get serialized by L<Minion/"backend"> (often with L<Mojo::JSON>), so you shouldn't send objects and be careful with
binary data, nested data structures with hash and array references are fine though.

  # Share progress information
  $job->note(progress => 95);

  # Share stats
  $job->note(stats => {utime => '0.012628', stime => '0.002429'});

=head2 parents

  my $parents = $job->parents;

Return a L<Mojo::Collection> object containing all jobs this job depends on as L<Minion::Job> objects.

  # Check parent state
  for my $parent ($job->parents->each) {
    my $info = $parent->info;
    say "$info->{id}: $info->{state}";
  }

=head2 perform

  $job->perform;

Perform job in new process and wait for it to finish. Note that this method should only be used to implement custom
workers.

=head2 pid

  my $pid = $job->pid;

Process id of the process spawned by L</"start"> if available. Note that this method should only be used to implement
custom workers.

=head2 remove

  my $bool = $job->remove;

Remove C<failed>, C<finished> or C<inactive> job from queue.

=head2 retry

  my $bool = $job->retry;
  my $bool = $job->retry({delay => 10});

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

=head2 run

  $job->run(@args);

Task to perform by this job. Meant to be overloaded in a subclass to create a custom task class. Note that this method
is B<EXPERIMENTAL> and might change without warning!

=head2 start

  $job = $job->start;

Perform job in new process, but do not wait for it to finish. Note that this method should only be used to implement
custom workers.

  # Perform two jobs concurrently
  $job1->start;
  $job2->start;
  my ($first, $second);
  sleep 1
    until $first ||= $job1->is_finished and $second ||= $job2->is_finished;

=head2 stop

  $job->stop;

Stop job performed with L</"start"> immediately. Note that this method should only be used to implement custom workers.

=head1 SEE ALSO

L<Minion>, L<Minion::Guide>, L<https://minion.pm>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
