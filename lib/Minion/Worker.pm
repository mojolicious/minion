package Minion::Worker;
use Mojo::Base -base;

use Mango::BSON 'bson_time';
use Sys::Hostname 'hostname';

# Global counter
my $COUNTER = 0;

has 'minion';
has number => sub { ++$COUNTER };

sub all_jobs { shift->_jobs }

sub dequeue {
  my $self = shift;

  # Worker not registered
  return undef unless $self->{id};

  my $minion = $self->minion;
  my $doc    = {
    query => {
      after => {'$lt' => bson_time},
      state => 'inactive',
      task  => {'$in' => [keys %{$minion->tasks}]}
    },
    sort   => {priority => -1},
    update => {
      '$set' =>
        {started => bson_time, state => 'active', worker => $self->{id}}
    },
    new => 1
  };
  return undef unless my $job = $minion->jobs->find_and_modify($doc);
  return Minion::Job->new(doc => $job, minion => $minion);
}

sub one_job { !!shift->_jobs(1) }

sub register {
  my $self = shift;
  $self->{id} = $self->minion->workers->insert(
    {host => hostname, num => $self->number, pid => $$, started => bson_time});
  return $self;
}

sub repair {
  my $self = shift;

  # Check workers on this host (all should be owned by the same user)
  my $workers = $self->minion->workers;
  my $cursor = $workers->find({host => hostname});
  while (my $worker = $cursor->next) {
    $workers->remove({_id => $worker->{_id}}) unless kill 0, $worker->{pid};
  }

  # Abandoned jobs
  my $jobs = $self->minion->jobs;
  $cursor = $jobs->find({state => 'active'});
  while (my $job = $cursor->next) {
    $jobs->save({%$job, state => 'failed', error => 'Worker went away.'})
      unless $workers->find_one($job->{worker});
  }

  return $self;
}

sub unregister {
  my ($self, $id) = @_;
  $self->minion->workers->remove({_id => delete $_[0]->{id}});
  return $self;
}

sub _jobs {
  my ($self, $one) = @_;

  $self->register;
  my $i = 0;
  while (my $job = $self->dequeue) {
    ++$i and $job->perform;
    last if $one;
  }
  $self->unregister;

  return $i;
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

=head2 all_jobs

  my $num = $worker->all_jobs;

Perform jobs until queue is empty and return the number of jobs performed.

=head2 dequeue

  my $job = $worker->dequeue;

Dequeue L<Minion::Job> object or return C<undef> if queue was empty.

=head2 one_job

  my $bool = $worker->one_job;

Perform one job and return a false value if queue was empty.

=head2 register

  $worker = $worker->register;

Register worker.

=head2 repair

  $worker = $worker->repair;

Repair worker registry and job queue.

=head2 unregister

  $worker = $worker->unregister;

Unregister worker.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
