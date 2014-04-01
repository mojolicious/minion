package Minion::Worker;
use Mojo::Base -base;

use Mango::BSON 'bson_time';
use Sys::Hostname 'hostname';

# Global counter
my $COUNTER = 0;

has [qw(id minion)];
has number => sub { ++$COUNTER };

sub dequeue {
  my $self = shift;

  # Worker not registered
  return undef unless my $oid = $self->id;

  my $minion = $self->minion;
  my $doc    = {
    query => {
      after => {'$lt' => bson_time},
      state => 'inactive',
      task  => {'$in' => [keys %{$minion->tasks}]}
    },
    fields => {args     => 1, task => 1},
    sort   => {priority => -1},
    update =>
      {'$set' => {started => bson_time, state => 'active', worker => $oid}},
    new => 1
  };
  return undef unless my $job = $minion->jobs->find_and_modify($doc);
  return Minion::Job->new(
    args   => $job->{args},
    id     => $job->{_id},
    minion => $minion,
    task   => $job->{task}
  );
}

sub register {
  my $self = shift;
  my $oid  = $self->minion->workers->insert(
    {host => hostname, num => $self->number, pid => $$, started => bson_time});
  return $self->id($oid);
}

sub unregister {
  my ($self, $id) = @_;
  $self->minion->workers->remove({_id => delete $_[0]->{id}});
  return $self;
}

1;

=encoding utf8

=head1 NAME

Minion::Worker - Minion worker

=head1 SYNOPSIS

  use Minion::Worker;

  my $worker = Minion::Worker->new(minion => $minion);

=head1 DESCRIPTION

L<Minion::Worker> performs jobs for L<Minion>.

=head1 ATTRIBUTES

L<Minion::Worker> implements the following attributes.

=head2 id

  my $oid = $worker->id;
  $worker = $worker->id($oid);

Worker id.

=head2 minion

  my $minion = $worker->minion;
  $worker    = $worker->minion(Minion->new);

L<Minion> object this worker belongs to.

=head2 number

  my $num = $worker->number;
  $worker = $worker->number(5);

Number of this worker, unique per process.

=head1 METHODS

L<Minion::Worker> inherits all methods from L<Mojo::Base> and implements the
following new ones.

=head2 dequeue

  my $job = $worker->dequeue;

Dequeue L<Minion::Job> object and transition from C<inactive> to C<active>
state or return C<undef> if queue was empty.

=head2 register

  $worker = $worker->register;

Register worker.

=head2 unregister

  $worker = $worker->unregister;

Unregister worker.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
