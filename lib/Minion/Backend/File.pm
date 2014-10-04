package Minion::Backend::File;
use Mojo::Base 'Minion::Backend';

use DBM::Deep;
use List::Util 'first';
use Mojo::Util 'md5_sum';
use Sys::Hostname 'hostname';
use Time::HiRes qw(time usleep);

has 'db';

sub dequeue {
  my ($self, $id, $timeout) = @_;
  usleep $timeout * 1000000 unless my $job = $self->_try($id);
  return $job || $self->_try($id);
}

sub enqueue {
  my ($self, $task) = (shift, shift);
  my $args    = shift // [];
  my $options = shift // {};

  my $db = $self->db;
  $db->lock_exclusive;
  my $job = {
    args    => $args,
    created => time,
    delayed => $options->{delay} ? (time + $options->{delay}) : 1,
    id      => $self->_id,
    priority => $options->{priority} // 0,
    retries  => 0,
    state    => 'inactive',
    task     => $task
  };
  $self->_jobs->{$job->{id}} = $job;
  $db->unlock;

  return $job->{id};
}

sub fail_job { shift->_update(1, @_) }

sub finish_job { shift->_update(0, @_) }

sub job_info {
  return undef unless my $job = shift->_jobs->{shift()};
  return $job->export;
}

sub list_jobs {
  my ($self, $offset, $limit, $options) = @_;

  my @jobs = sort { $b->{created} <=> $a->{created} } values %{$self->_jobs};
  @jobs = grep { $_->{state} eq $options->{state} } @jobs if $options->{state};
  @jobs = grep { $_->{task} eq $options->{task} } @jobs   if $options->{task};
  @jobs = grep {defined} @jobs[$offset .. ($offset + $limit - 1)];

  return [map { $_->export } @jobs];
}

sub list_workers {
  my ($self, $offset, $limit) = @_;

  my @workers
    = sort { $b->{started} <=> $a->{started} } values %{$self->_workers};
  @workers = grep {defined} @workers[$offset .. ($offset + $limit - 1)];

  return [map { $self->_worker_info($_->{id}) } @workers];
}

sub new { shift->SUPER::new(db => DBM::Deep->new(@_)) }

sub register_worker {
  my $self = shift;

  my $db = $self->db;
  $db->lock_exclusive;
  my $worker
    = {host => hostname, id => $self->_id, pid => $$, started => time};
  $self->_workers->{$worker->{id}} = $worker;
  $db->unlock;

  return $worker->{id};
}

sub remove_job {
  my ($self, $id) = @_;

  my $db = $self->db;
  $db->lock_exclusive;
  delete $self->_jobs->{$id}
    if my $removed = !!$self->_job($id, 'failed', 'finished', 'inactive');
  $db->unlock;

  return $removed;
}

sub repair {
  my $self = shift;

  # Check workers on this host (all should be owned by the same user)
  my $db = $self->db;
  $db->lock_exclusive;
  my $workers = $self->_workers;
  my $host    = hostname;
  delete $workers->{$_->{id}}
    for grep { $_->{host} eq $host && !kill 0, $_->{pid} } values %$workers;

  # Abandoned jobs
  my $jobs = $self->_jobs;
  for my $job (values %$jobs) {
    next if $job->{state} ne 'active' || $workers->{$job->{worker}};
    @$job{qw(error state)} = ('Worker went away', 'failed');
  }

  # Old jobs
  my $after = time - $self->minion->remove_after;
  delete $jobs->{$_->{id}}
    for grep { $_->{state} eq 'finished' && $_->{finished} < $after }
    values %$jobs;
  $db->unlock;
}

sub reset { shift->db->clear }

sub retry_job {
  my ($self, $id) = @_;

  my $db = $self->db;
  $db->lock_exclusive;
  my $job = $self->_job($id, 'failed', 'finished');
  if ($job) {
    $job->{retries} += 1;
    @$job{qw(retried state)} = (time, 'inactive');
    delete $job->{$_} for qw(error finished result started worker);
  }
  $db->unlock;

  return !!$job;
}

sub stats {
  my $self = shift;

  my (%seen, %states);
  my $active = grep {
         ++$states{$_->{state}}
      && $_->{state} eq 'active'
      && !$seen{$_->{worker}}++
  } values %{$self->_jobs};

  return {
    active_workers   => $active,
    inactive_workers => keys(%{$self->_workers}) - $active,
    active_jobs      => $states{active} || 0,
    inactive_jobs    => $states{inactive} || 0,
    failed_jobs      => $states{failed} || 0,
    finished_jobs    => $states{finished} || 0,
  };
}

sub unregister_worker { delete shift->_workers->{shift()} }

sub worker_info { shift->_worker_info(@_) }

sub _id {
  my $self = shift;
  my $id;
  do { $id = md5_sum(time . rand 999) }
    while $self->_workers->{$id} || $self->_jobs->{$id};
  return $id;
}

sub _job {
  my ($self, $id) = (shift, shift);
  return undef unless my $job = $self->_jobs->{$id};
  return grep({ $job->{state} eq $_ } @_) ? $job : undef;
}

sub _jobs { shift->db->{jobs} //= {} }

sub _try {
  my ($self, $id) = @_;

  my $db = $self->db;
  $db->lock_exclusive;
  my @ready = grep { $_->{state} eq 'inactive' } values %{$self->_jobs};
  my $now = time;
  @ready = grep { $_->{delayed} < $now } @ready;
  @ready = sort { $a->{created} <=> $b->{created} } @ready;
  @ready = sort { $b->{priority} <=> $a->{priority} } @ready;
  my $job = first { $self->minion->tasks->{$_->{task}} } @ready;
  @$job{qw(started state worker)} = (time, 'active', $id) if $job;
  $db->unlock;

  return $job ? $job->export : undef;
}

sub _update {
  my ($self, $fail, $id, $err) = @_;

  my $db = $self->db;
  $db->lock_exclusive;
  my $job = $self->_job($id, 'active');
  if ($job) {
    $job->{finished} = time;
    $job->{state}    = $fail ? 'failed' : 'finished';
    $job->{error}    = $err if $err;
  }
  $db->unlock;

  return !!$job;
}

sub _worker_info {
  my ($self, $id) = @_;

  return undef unless $id && (my $worker = $self->_workers->{$id});
  my @jobs
    = map { $_->{id} } grep { $_->{worker} eq $id } values %{$self->_jobs};
  return {%{$worker->export}, jobs => \@jobs};
}

sub _workers { shift->db->{workers} //= {} }

1;

=encoding utf8

=head1 NAME

Minion::Backend::File - File backend

=head1 SYNOPSIS

  use Minion::Backend::File;

  my $backend = Minion::Backend::File->new('/Users/sri/minion.db');

=head1 DESCRIPTION

L<Minion::Backend::File> is a highly portable backend for L<Minion> based on
L<DBM::Deep>.

=head1 ATTRIBUTES

L<Minion::Backend::File> inherits all attributes from L<Minion::Backend> and
implements the following new ones.

=head2 db

  my $db   = $backend->db;
  $backend = $backend->db(DBM::Deep->new);

L<DBM::Deep> object used to store all data.

=head1 METHODS

L<Minion::Backend::File> inherits all methods from L<Minion::Backend> and
implements the following new ones.

=head2 dequeue

  my $job_info = $backend->dequeue($worker_id, 0.5);

Wait for job, dequeue it and transition from C<inactive> to C<active> state or
return C<undef> if queue was empty.

=head2 enqueue

  my $job_id = $backend->enqueue('foo');
  my $job_id = $backend->enqueue(foo => [@args]);
  my $job_id = $backend->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state.

These options are currently available:

=over 2

=item delay

  delay => 10

Delay job for this many seconds from now.

=item priority

  priority => 5

Job priority, defaults to C<0>.

=back

=head2 fail_job

  my $bool = $backend->fail_job($job_id);
  my $bool = $backend->fail_job($job_id, 'Something went wrong!');

Transition from C<active> to C<failed> state.

=head2 finish_job

  my $bool = $backend->finish_job($job_id);

Transition from C<active> to C<finished> state.

=head2 job_info

  my $job_info = $backend->job_info($job_id);

Get information about a job or return C<undef> if job does not exist.

=head2 list_jobs

  my $batch = $backend->list_jobs($offset, $limit);
  my $batch = $backend->list_jobs($offset, $limit, {state => 'inactive'});

Returns the same information as L</"job_info"> but in batches.

These options are currently available:

=over 2

=item state

  state => 'inactive'

List only jobs in this state.

=item task

  task => 'test'

List only jobs for this task.

=back

=head2 list_workers

  my $batch = $backend->list_workers($offset, $limit);

Returns the same information as L</"worker_info"> but in batches.

=head2 new

  my $backend = Minion::Backend::File->new('/Users/sri/minion.db');

Construct a new L<Minion::Backend::File> object.

=head2 register_worker

  my $worker_id = $backend->register_worker;

Register worker.

=head2 remove_job

  my $bool = $backend->remove_job($job_id);

Remove C<failed>, C<finished> or C<inactive> job from queue.

=head2 repair

  $backend->repair;

Repair worker registry and job queue if necessary.

=head2 reset

  $backend->reset;

Reset job queue.

=head2 retry_job

  my $bool = $backend->retry_job($job_id);

Transition from C<failed> or C<finished> state back to C<inactive>.

=head2 stats

  my $stats = $backend->stats;

Get statistics for jobs and workers.

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker.

=head2 worker_info

  my $worker_info = $backend->worker_info($worker_id);

Get information about a worker or return C<undef> if worker does not exist.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
