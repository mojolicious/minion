package Minion::Job;
use Mojo::Base -base;

use Mango::BSON 'bson_time';

has args => sub { [] };
has [qw(id minion task)];

sub app { shift->minion->app }

sub created { shift->_time('created') }

sub delayed { shift->_time('delayed') }

sub error { shift->_get('error') }

sub fail { shift->_update(shift // 'Unknown error.') }

sub finish { shift->_update }

sub finished { shift->_time('finished') }

sub perform {
  my $self = shift;
  waitpid $self->_child, 0;
  $? ? $self->fail('Non-zero exit status.') : $self->finish;
}

sub priority { shift->_get('priority') }

sub remove {
  my $self   = shift;
  my $states = [qw(failed finished inactive)];
  return !!$self->minion->jobs->remove(
    {_id => $self->id, state => {'$in' => $states}})->{n};
}

sub restart {
  my $self = shift;

  return !!$self->minion->jobs->update(
    {_id => $self->id, state => {'$in' => [qw(failed finished)]}},
    {
      '$inc' => {restarts  => 1},
      '$set' => {restarted => bson_time, state => 'inactive'},
      '$unset' => {error => '', finished => '', started => '', worker => ''}
    }
  )->{n};
}

sub restarted { shift->_time('restarted') }

sub restarts { shift->_get('restarts') // 0 }

sub started { shift->_time('started') }

sub state { shift->_get('state') }

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

sub _get {
  my ($self, $key) = @_;
  return undef
    unless my $job = $self->minion->jobs->find_one($self->id, {$key => 1});
  return $job->{$key};
}

sub _time {
  my $self = shift;
  return undef unless my $time = $self->_get(@_);
  return $time->to_epoch;
}

sub _update {
  my ($self, $err) = @_;

  my $doc
    = {finished => bson_time, state => defined $err ? 'failed' : 'finished'};
  $doc->{error} = $err if defined $err;
  return !!$self->minion->jobs->update({_id => $self->id, state => 'active'},
    {'$set' => $doc})->{n};
}

1;

=encoding utf8

=head1 NAME

Minion::Job - Minion job

=head1 SYNOPSIS

  use Minion::Job;

  my $job = Minion::Job->new(id => $oid, minion => $minion, task => 'foo');

=head1 DESCRIPTION

L<Minion::Job> is a container for L<Minion> jobs.

=head1 ATTRIBUTES

L<Minion::Job> implements the following attributes.

=head2 args

  my $args = $job->args;
  $job     = $job->args([]);

Arguments passed to task.

=head2 id

  my $oid = $job->id;
  $job    = $job->id($oid);

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

L<Minion::Job> inherits all methods from L<Mojo::Base> and implements the
following new ones.

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
