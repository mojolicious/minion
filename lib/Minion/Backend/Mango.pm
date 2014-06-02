package Minion::Backend::Mango;
use Mojo::Base 'Minion::Backend';

use Mango;
use Mango::BSON qw(bson_oid bson_time);
use Scalar::Util 'weaken';
use Sys::Hostname 'hostname';

has jobs => sub { $_[0]->mango->db->collection($_[0]->prefix . '.jobs') };
has 'mango';
has prefix => 'minion';
has workers =>
  sub { $_[0]->mango->db->collection($_[0]->prefix . '.workers') };

sub dequeue {
  my ($self, $id) = @_;

  my $doc = {
    query => {
      delayed => {'$lt' => bson_time},
      state   => 'inactive',
      task    => {'$in' => [keys %{$self->minion->tasks}]}
    },
    fields => {args     => 1, task => 1},
    sort   => {priority => -1},
    update =>
      {'$set' => {started => bson_time, state => 'active', worker => $id}},
    new => 1
  };

  return undef unless my $job = $self->jobs->find_and_modify($doc);
  return {args => $job->{args}, id => $job->{_id}, task => $job->{task}};
}

sub enqueue {
  my ($self, $task) = (shift, shift);
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $args    = shift // [];
  my $options = shift // {};

  my $doc = {
    args    => $args,
    created => bson_time,
    delayed => bson_time($options->{delayed} ? $options->{delayed} : 1),
    priority => $options->{priority} // 0,
    state    => 'inactive',
    task     => $task
  };

  # Blocking
  return $self->jobs->insert($doc) unless $cb;

  # Non-blocking
  weaken $self;
  $self->jobs->insert($doc => sub { shift; $self->$cb(@_) });
}

sub fail_job { shift->_update(@_) }

sub finish_job { shift->_update(@_) }

sub job_info {
  my ($self, $id) = @_;
  return {} unless my $job = $self->jobs->find_one(bson_oid($id));
  return {
    args      => $job->{args},
    created   => $job->{created}->to_epoch,
    delayed   => $job->{delayed}->to_epoch,
    error     => $job->{error},
    finished  => $job->{finished} ? $job->{finished}->to_epoch : undef,
    priority  => $job->{priority},
    restarted => $job->{restarted} ? $job->{restarted}->to_epoch : undef,
    restarts => $job->{restarts} // 0,
    started => $job->{started} ? $job->{started}->to_epoch : undef,
    state   => $job->{state},
    task    => $job->{task}
  };
}

sub new { shift->SUPER::new(mango => Mango->new(@_)) }

sub register_worker {
  my $self = shift;
  return $self->workers->insert(
    {host => hostname, pid => $$, started => bson_time});
}

sub remove_job {
  my ($self, $id) = @_;
  return !!$self->jobs->remove(
    {_id => $id, state => {'$in' => [qw(failed finished inactive)]}})->{n};
}

sub repair {
  my $self = shift;

  # Check workers on this host (all should be owned by the same user)
  my $workers = $self->workers;
  my $cursor = $workers->find({host => hostname});
  while (my $worker = $cursor->next) {
    $workers->remove({_id => $worker->{_id}}) unless kill 0, $worker->{pid};
  }

  # Abandoned jobs
  my $jobs = $self->jobs;
  $cursor = $jobs->find({state => 'active'});
  while (my $job = $cursor->next) {
    $jobs->save({%$job, state => 'failed', error => 'Worker went away.'})
      unless $workers->find_one($job->{worker});
  }
}

sub reset {
  my $self = shift;
  $_->options && $_->drop for $self->workers, $self->jobs;
}

sub restart_job {
  my ($self, $id) = @_;
  return !!$self->jobs->update(
    {_id => $id, state => {'$in' => [qw(failed finished)]}},
    {
      '$inc' => {restarts  => 1},
      '$set' => {restarted => bson_time, state => 'inactive'},
      '$unset' => {error => '', finished => '', started => '', worker => ''}
    }
  )->{n};
}

sub stats {
  my $self = shift;

  my $jobs    = $self->jobs;
  my $active  = @{$jobs->find({state => 'active'})->distinct('worker')};
  my $workers = $self->workers;
  my $all     = $workers->find->count;
  my $stats = {active_workers => $active, inactive_workers => $all - $active};
  $stats->{"${_}_jobs"} = $jobs->find({state => $_})->count
    for qw(active failed finished inactive);
  return $stats;
}

sub unregister_worker { shift->workers->remove({_id => shift}) }

sub worker_info {
  my ($self, $id) = @_;
  return {} unless my $worker = $self->workers->find_one($id);
  return {started => $worker->{started}->to_epoch};
}

sub _update {
  my ($self, $id, $err) = @_;

  my $doc
    = {finished => bson_time, state => defined $err ? 'failed' : 'finished'};
  $doc->{error} = $err if $err;
  return !!$self->jobs->update({_id => $id, state => 'active'},
    {'$set' => $doc})->{n};
}

1;

=encoding utf8

=head1 NAME

Minion::Backend::Mango - MongoDB backend

=head1 SYNOPSIS

  use Minion::Backend::Mango;

  my $backend = Minion::Backend::Mango->new('mongodb://127.0.0.1:27017');

=head1 DESCRIPTION

L<Minion::Backend::Mango> is a L<Mango> backend for L<Minion>.

=head1 ATTRIBUTES

L<Minion::Backend::Mango> inherits all attributes from L<Minion::Backend> and
implements the following new ones.

=head2 jobs

  my $jobs = $backend->jobs;
  $backend = $backend->jobs(Mango::Collection->new);

L<Mango::Collection> object for C<jobs> collection, defaults to one based on
L</"prefix">.

=head2 mango

  my $mango = $backend->mango;
  $backend  = $backend->mango(Mango->new);

L<Mango> object used to store collections.

=head2 prefix

  my $prefix = $backend->prefix;
  $backend   = $backend->prefix('foo');

Prefix for collections, defaults to C<minion>.

=head2 workers

  my $workers = $backend->workers;
  $backend    = $backend->workers(Mango::Collection->new);

L<Mango::Collection> object for C<workers> collection, defaults to one based
on L</"prefix">.

=head1 METHODS

L<Minion::Backend::Mango> inherits all methods from L<Minion::Backend> and
implements the following new ones.

=head2 dequeue

  my $info = $backend->dequeue($worker_id);

Dequeue job and transition from C<inactive> to C<active> state or return
C<undef> if queue was empty.

=head2 enqueue

  my $job_id = $backend->enqueue('foo');
  my $job_id = $backend->enqueue(foo => [@args]);
  my $job_id = $backend->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state. You can also append a callback to
perform operation non-blocking.

  $backend->enqueue(foo => sub {
    my ($backend, $err, $job_id) = @_;
    ...
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 fail_job

  my $bool = $backend->fail_job;
  my $bool = $backend->fail_job($job_id, 'Something went wrong!');

Transition from C<active> to C<failed> state.

=head2 finish_job

  my $bool = $backend->finish_job($job_id);

Transition from C<active> to C<finished> state.

=head2 job_info

  my $info = $backend->job_info($job_id);

Get information about a job.

=head2 new

  my $backend = Minion::Backend::Mango->new('mongodb://127.0.0.1:27017');

Construct a new L<Minion::Backend::Mango> object.

=head2 register_worker

  my $worker_id = $backend->register_worker;

Register worker.

=head2 remove_job

  my $bool = $backend->remove_job($job_id);

Remove C<failed>, C<finished> or C<inactive> job from queue.

=head2 repair

  $backend->repair;

Repair worker registry and job queue.

=head2 reset

  $backend->reset;

Reset job queue.

=head2 restart_job

  my $bool = $backend->restart_job;

Transition from C<failed> or C<finished> state back to C<inactive>.

=head2 stats

  my $stats = $backend->stats;

Get statistics for jobs and workers.

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker.

=head2 worker_info

  my $info = $backend->worker_info($worker_id);

Get information about a worker.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
