package Minion::Job;
use Mojo::Base 'Mojo::EventEmitter';

use Mojo::IOLoop;

has args => sub { [] };
has [qw(id minion task)];

sub app { shift->minion->app }

sub fail {
  my $self = shift;
  my $err  = shift // 'Unknown error';
  my $ok   = $self->minion->backend->fail_job($self->id, $err);
  return $ok ? !!$self->emit(failed => $err) : undef;
}

sub finish {
  my $self = shift;
  my $ok   = $self->minion->backend->finish_job($self->id);
  return $ok ? !!$self->emit('finished') : undef;
}

sub info { $_[0]->minion->backend->job_info($_[0]->id) }

sub perform {
  my $self = shift;
  waitpid $self->_child, 0;
  $? ? $self->fail('Non-zero exit status') : $self->finish;
}

sub remove { $_[0]->minion->backend->remove_job($_[0]->id) }

sub restart { $_[0]->minion->backend->restart_job($_[0]->id) }

sub _child {
  my $self = shift;

  # Parent
  die "Can't fork: $!" unless defined(my $pid = fork);
  $self->emit(spawn => $pid) and return $pid if $pid;

  # Reset event loop
  Mojo::IOLoop->reset;

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

=head2 spawn

  $job->on(spawn => sub {
    my ($job, $pid) = @_;
    ...
  });

Emitted after a process has been spawned to process this job.

  $job->on(spawn => sub {
    my ($job, $pid) = @_;
    my $id = $job->id;
    say "Job $id running in process $pid";
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

=head2 fail

  my $bool = $job->fail;
  my $bool = $job->fail('Something went wrong!');

Transition from C<active> to C<failed> state.

=head2 finish

  my $bool = $job->finish;

Transition from C<active> to C<finished> state.

=head2 info

  my $info = $job->info;

Get job information.

=head2 perform

  $job->perform;

Perform job in new process and wait for it to finish.

=head2 remove

  my $bool = $job->remove;

Remove C<failed>, C<finished> or C<inactive> job from queue.

=head2 restart

  my $bool = $job->restart;

Transition from C<failed> or C<finished> state back to C<inactive>.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
