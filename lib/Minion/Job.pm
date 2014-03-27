package Minion::Job;
use Mojo::Base -base;

has [qw(doc worker)];

sub fail { shift->_update(shift // 'Unknown error.') }

sub finish { shift->_update }

sub perform {
  my $self = shift;
  waitpid $self->_child, 0;
  $self->fail('Non-zero exit status.') if $?;
}

sub _child {
  my $self = shift;

  # Parent
  die "Can't fork: $!" unless defined(my $pid = fork);
  return $pid if $pid;

  # Child
  my $doc    = $self->doc;
  my $minion = $self->worker->minion;
  $minion->app->log->debug(
    qq{Performing job "$doc->{task}" ($doc->{_id}:$$).});
  my $cb = $minion->tasks->{$doc->{task}};
  eval { $self->$cb(@{$doc->{args}}); 1 } ? $self->finish : $self->fail($@);
  exit 0;
}

sub _update {
  my ($self, $err) = @_;
  $self->worker->minion->jobs->save(
    {%{$self->doc}, state => $err ? ('failed', error => $err) : 'finished'});
  return $self;
}

1;

=encoding utf8

=head1 NAME

Minion::Job - Minion job

=head1 SYNOPSIS

  use Minion::Job;

  my $job = Minion::Job->new(doc => $doc, worker => $worker);

=head1 DESCRIPTION

L<Minion::Job> is a container for L<Minion> jobs.

=head1 ATTRIBUTES

L<Minion::Job> implements the following attributes.

=head2 doc

  my $doc = $job->doc;
  $job    = $job->doc({});

BSON document for job.

=head2 worker

  my $worker = $job->worker;
  $job       = $job->worker(Minion::Worker->new);

L<Minion::Worker> object this job belongs to.

=head1 METHODS

L<Minion::Job> inherits all methods from L<Mojo::Base> and implements the
following new ones.

=head2 fail

  $job = $job->fail;
  $job = $job->fail('Something went wrong!');

Update job to C<failed> state.

=head2 finish

  $job = $job->finish;

Update job to C<finished> state.

=head2 perform

  $job->perform;

Perform job in new process and wait for it to finish.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
