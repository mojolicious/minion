package Minion::Job;
use Mojo::Base 'Mojo::EventEmitter';

has args => sub { [] };
has [qw(id minion task)];

sub app { shift->minion->app }

sub created { $_[0]->minion->backend->job_info($_[0]->id)->{created} }

sub delayed { $_[0]->minion->backend->job_info($_[0]->id)->{delayed} }

sub error { $_[0]->minion->backend->job_info($_[0]->id)->{error} }

sub fail {
  my $self = shift;
  my $err = shift // 'Unknown error.';
  return $self->minion->backend->fail_job($self->id, $err)
    ? !!$self->emit(failed => $err)
    : undef;
}

sub finish {
  my $self = shift;
  return $self->minion->backend->finish_job($self->id)
    ? !!$self->emit('finished')
    : undef;
}

sub finished { $_[0]->minion->backend->job_info($_[0]->id)->{finished} }

sub perform {
  my $self = shift;
  waitpid $self->_child, 0;
  $? ? $self->fail('Non-zero exit status.') : $self->finish;
}

sub priority { $_[0]->minion->backend->job_info($_[0]->id)->{priority} }

sub remove { $_[0]->minion->backend->remove_job($_[0]->id) }

sub restart { $_[0]->minion->backend->restart_job($_[0]->id) }

sub restarted { $_[0]->minion->backend->job_info($_[0]->id)->{restarted} }

sub restarts { $_[0]->minion->backend->job_info($_[0]->id)->{restarts} }

sub started { $_[0]->minion->backend->job_info($_[0]->id)->{started} }

sub state { $_[0]->minion->backend->job_info($_[0]->id)->{state} }

sub _child {
  my $self = shift;

  # Parent
  die "Can't fork: $!" unless defined(my $pid = fork);
  return $pid if $pid;

  # Child
  my $task = $self->task;
  $self->app->log->debug(qq{Performing job "$task" (@{[$self->id]}:$$).});
  my $cb = $self->minion->tasks->{$task};
  $self->fail($@) unless eval { $self->$cb(@{$self->args}); 1 };
  exit 0;
}

1;

=encoding utf8

=head1 NAME

Minion::Job - Minion job

=head1 SYNOPSIS

  use Minion::Job;

  my $job = Minion::Job->new(id => $id, minion => $minion, task => 'foo');

=head1 DESCRIPTION

L<Minion::Job> is a container for L<Minion> jobs.

=head1 EVENTS

L<Minion::Job> inherits all events from L<Mojo::EventEmitter> and can emit the
following new ones.

=head2 failed

  $job->on(failed => sub {
    my ($job, $err) = @_;
    ...
  });

Emitted after this job transitioned to the C<failed> state.

  $job->on(failed => sub {
    my ($job, $err) = @_;
    say "Something went wrong: $err";
  });

=head2 finished

  $job->on(finished => sub {
    my $job = shift;
    ...
  });

Emitted after this job transitioned to the C<finished> state.

  $job->on(finished => sub {
    my $job = shift;
    my $id = $job->id;
    say "Job $id is finished.";
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

=head2 task

  my $task = $job->task;
  $job     = $job->task('foo');

Task name.

=head1 METHODS

L<Minion::Job> inherits all methods from L<Mojo::EventEmitter> and implements
the following new ones.

=head2 app

  my $app = $job->app;

Get application from L<Minion/"app">.

  # Longer version
  my $app = $job->minion->app;

=head2 created

  my $epoch = $job->created;

Time this job was created in floating seconds since the epoch.

=head2 delayed

  my $epoch = $job->delayed;

Time this job was delayed to in floating seconds since the epoch.

=head2 error

  my $err = $job->error;

Get error for C<failed> job.

=head2 fail

  my $bool = $job->fail;
  my $bool = $job->fail('Something went wrong!');

Transition from C<active> to C<failed> state.

=head2 finish

  my $bool = $job->finish;

Transition from C<active> to C<finished> state.

=head2 finished

  my $epoch = $job->finished;

Time this job transitioned from C<active> to C<failed> or C<finished> in
floating seconds since the epoch.

=head2 perform

  $job->perform;

Perform job in new process and wait for it to finish.

=head2 priority

  my $priority = $job->priority;

Get job priority.

=head2 remove

  my $bool = $job->remove;

Remove C<failed>, C<finished> or C<inactive> job from queue.

=head2 restart

  my $bool = $job->restart;

Transition from C<failed> or C<finished> state back to C<inactive>.

=head2 restarted

  my $epoch = $job->restarted;

Time this job last transitioned from C<failed> or C<finished> back to
C<inactive> in floating seconds since the epoch.

=head2 restarts

  my $num = $job->restarts;

Get number of times this job has been restarted.

=head2 started

  my $epoch = $job->started;

Time this job transitioned from C<inactive> to C<active> in floating seconds
since the epoch.

=head2 state

  my $state = $job->state;

Get current state of job, usually C<active>, C<failed>, C<finished> or
C<inactive>.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
