package Minion::Job;
use Mojo::Base -base;

use Mango::BSON 'bson_time';

has args => sub { [] };
has [qw(id minion task)];

sub app { shift->minion->app }

sub error { shift->_get('error') }

sub fail { shift->_update(shift // 'Unknown error.') }

sub finish { shift->_update }

sub perform {
  my $self = shift;
  waitpid $self->_child, 0;
  $self->fail('Non-zero exit status.') if $?;
}

sub state { shift->_get('state') }

sub _child {
  my $self = shift;

  # Parent
  die "Can't fork: $!" unless defined(my $pid = fork);
  return $pid if $pid;

  # Child
  my $task   = $self->task;
  my $minion = $self->minion;
  $minion->app->log->debug(qq{Performing job "$task" (@{[$self->id]}:$$).});
  my $cb = $minion->tasks->{$task};
  eval { $self->$cb(@{$self->args}); 1 } ? $self->finish : $self->fail($@);
  exit 0;
}

sub _get {
  my ($self, $key) = @_;
  return undef
    unless my $job = $self->minion->jobs->find_one($self->id, {$key => 1});
  return $job->{$key};
}

sub _update {
  my ($self, $err) = @_;

  $self->minion->jobs->update(
    {_id => $self->id, state => 'active'},
    {
      '$set' => {
        finished => bson_time,
        state => $err ? ('failed', error => $err) : 'finished'
      }
    }
  );

  return $self;
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

=head2 error

  my $err = $job->error;

Get error for C<failed> job.

=head2 fail

  $job = $job->fail;
  $job = $job->fail('Something went wrong!');

Transition from C<active> to C<failed> state.

=head2 finish

  $job = $job->finish;

Transition from C<active> to C<finished> state.

=head2 perform

  $job->perform;

Perform job in new process and wait for it to finish.

=head2 state

  my $state = $job->state;

Get current state of job, usually C<active>, C<failed>, C<finished> or
C<inactive>.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
