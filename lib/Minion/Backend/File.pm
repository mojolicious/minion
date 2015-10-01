package Minion::Backend::File;
use Mojo::Base 'Minion::Backend';

use DBM::Deep;
use List::Util 'first';
use Mojo::Util 'md5_sum';
use Sys::Hostname 'hostname';
use Time::HiRes qw(time usleep);

sub db {
  my $self = shift;
  @$self{qw(db pid)} = (undef, $$) if ($self->{pid} //= $$) ne $$;
  return $self->{db} ||= DBM::Deep->new(@{$self->{args}});
}

sub dequeue {
  my ($self, $id, $wait, $options) = @_;
  usleep($wait * 1000000) unless my $job = $self->_try($id, $options);
  return $job || $self->_try($id, $options);
}

sub enqueue {
  my ($self, $task) = (shift, shift);
  my $args    = shift // [];
  my $options = shift // {};

  my $guard = $self->_exclusive;
  my $job   = {
    args    => $args,
    created => time,
    delayed => $options->{delay} ? (time + $options->{delay}) : 1,
    id      => $self->_id,
    priority => $options->{priority} // 0,
    queue    => $options->{queue}    // 'default',
    retries  => 0,
    state    => 'inactive',
    task     => $task
  };
  $self->_jobs->{$job->{id}} = $job;

  return $job->{id};
}

sub fail_job   { shift->_update(1, @_) }
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

sub new { shift->SUPER::new(args => [@_]) }

sub register_worker {
  my ($self, $id) = @_;

  my $guard = $self->_exclusive;
  my $worker = $id ? $self->_workers->{$id} : undef;
  unless ($worker) {
    $worker = {host => hostname, id => $self->_id, pid => $$, started => time};
    $self->_workers->{$worker->{id}} = $worker;
  }
  $worker->{notified} = time;

  return $worker->{id};
}

sub remove_job {
  my ($self, $id) = @_;
  my $guard = $self->_exclusive;
  delete $self->_jobs->{$id}
    if my $removed = !!$self->_job($id, 'failed', 'finished', 'inactive');
  return $removed;
}

sub repair {
  my $self = shift;

  # Check worker registry
  my $guard   = $self->_exclusive;
  my $workers = $self->_workers;
  my $minion  = $self->minion;
  my $after   = time - $minion->missing_after;
  $_->{notified} < $after and delete $workers->{$_->{id}} for values %$workers;

  # Abandoned jobs
  my $jobs = $self->_jobs;
  for my $job (values %$jobs) {
    next if $job->{state} ne 'active' || $workers->{$job->{worker}};
    @$job{qw(finished result state)} = (time, 'Worker went away', 'failed');
  }

  # Old jobs
  $after = time - $minion->remove_after;
  delete $jobs->{$_->{id}}
    for grep { $_->{state} eq 'finished' && $_->{finished} < $after }
    values %$jobs;
}

sub reset { $_[0]->db and delete($_[0]->{db})->clear }

sub retry_job {
  my ($self, $id, $retries) = (shift, shift, shift);
  my $options = shift // {};

  my $guard = $self->_exclusive;
  return undef unless my $job = $self->_job($id, 'failed', 'finished');
  return undef unless $job->{retries} == $retries;
  $job->{retries} += 1;
  $job->{delayed}  = time + $options->{delay} if $options->{delay};
  $job->{priority} = $options->{priority}     if defined $options->{priority};
  $job->{queue}    = $options->{queue}        if defined $options->{queue};
  @$job{qw(retried state)} = (time, 'inactive');
  delete @$job{qw(finished result started worker)};

  return 1;
}

sub stats {
  my $self = shift;

  my $active = 0;
  my (%seen, %states);
  for my $job (values %{$self->_jobs}) {
    $states{$job->{state}}++;
    $active++ if $job->{state} eq 'active' && !$seen{$job->{worker}}++;
  }

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

sub _exclusive {
  my $guard = Minion::Backend::File::_Guard->new(db => shift->db);
  $guard->{db}->lock_exclusive;
  return $guard;
}

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
  my ($self, $id, $options) = @_;

  my $guard  = $self->_exclusive;
  my %queues = map { $_ => 1 } @{$options->{queues} || ['default']};
  my @queue  = grep { $queues{$_->{queue}} } values %{$self->_jobs};
  my @ready  = grep { $_->{state} eq 'inactive' } @queue;
  my $now    = time;
  @ready = grep { $_->{delayed} < $now } @ready;
  @ready = sort { $a->{created} <=> $b->{created} } @ready;
  @ready = sort { $b->{priority} <=> $a->{priority} } @ready;
  my $job = first { $self->minion->tasks->{$_->{task}} } @ready;
  @$job{qw(started state worker)} = (time, 'active', $id) if $job;

  return $job ? $job->export : undef;
}

sub _update {
  my ($self, $fail, $id, $retries, $result) = @_;

  my $guard = $self->_exclusive;
  return undef unless my $job = $self->_job($id, 'active');
  return undef unless $job->{retries} == $retries;
  @$job{qw(finished result)} = (time, $result);
  $job->{state} = $fail ? 'failed' : 'finished';
  return 1;
}

sub _worker_info {
  my ($self, $id) = @_;

  return undef unless $id && (my $worker = $self->_workers->{$id});
  my $jobs = $self->_jobs;
  my @jobs = map { $_->{id} }
    grep { $_->{state} eq 'active' && $_->{worker} eq $id } values %$jobs;
  return {%{$worker->export}, jobs => \@jobs};
}

sub _workers { shift->db->{workers} //= {} }

package Minion::Backend::File::_Guard;
use Mojo::Base -base;

sub DESTROY { shift->{db}->unlock }

1;

=encoding utf8

=head1 NAME

Minion::Backend::File - File backend

=head1 SYNOPSIS

  use Minion::Backend::File;

  my $backend = Minion::Backend::File->new('/home/sri/minion.db');

=head1 DESCRIPTION

L<Minion::Backend::File> is a highly portable backend for L<Minion> based on
L<DBM::Deep>.

=head1 ATTRIBUTES

L<Minion::Backend::File> inherits all attributes from L<Minion::Backend>.

=head1 METHODS

L<Minion::Backend::File> inherits all methods from L<Minion::Backend> and
implements the following new ones.

=head2 db

  my $db = $backend->db;

L<DBM::Deep> object used to store all data.

=head2 dequeue

  my $job_info = $backend->dequeue($worker_id, 0.5);
  my $job_info = $backend->dequeue($worker_id, 0.5, {queues => ['important']});

Wait for job, dequeue it and transition from C<inactive> to C<active> state or
return C<undef> if queues were empty.

These options are currently available:

=over 2

=item queues

  queues => ['important']

One or more queues to dequeue jobs from, defaults to C<default>.

=back

These fields are currently available:

=over 2

=item args

Job arguments.

=item id

Job ID.

=item retries

Number of times job has been retried.

=item task

Task name.

=back

=head2 enqueue

  my $job_id = $backend->enqueue('foo');
  my $job_id = $backend->enqueue(foo => [@args]);
  my $job_id = $backend->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state.

These options are currently available:

=over 2

=item delay

  delay => 10

Delay job for this many seconds (from now).

=item priority

  priority => 5

Job priority, defaults to C<0>.

=item queue

  queue => 'important'

Queue to put job in, defaults to C<default>.

=back

=head2 fail_job

  my $bool = $backend->fail_job($job_id, $retries);
  my $bool = $backend->fail_job($job_id, $retries, 'Something went wrong!');
  my $bool = $backend->fail_job(
    $job_id, $retries, {msg => 'Something went wrong!'});

Transition from C<active> to C<failed> state.

=head2 finish_job

  my $bool = $backend->finish_job($job_id, $retries);
  my $bool = $backend->finish_job($job_id, $retries, 'All went well!');
  my $bool = $backend->finish_job($job_id, $retries, {msg => 'All went well!'});

Transition from C<active> to C<finished> state.

=head2 job_info

  my $job_info = $backend->job_info($job_id);

Get information about a job or return C<undef> if job does not exist.

  # Check job state
  my $state = $backend->job_info($job_id)->{state};

  # Get job result
  my $result = $backend->job_info($job_id)->{result};

These fields are currently available:

=over 2

=item args

Job arguments.

=item created

Time job was created.

=item delayed

Time job was delayed to.

=item finished

Time job was finished.

=item priority

Job priority.

=item queue

Queue name.

=item result

Job result.

=item retried

Time job has been retried.

=item retries

Number of times job has been retried.

=item started

Time job was started.

=item state

Current job state, usually C<active>, C<failed>, C<finished> or C<inactive>.

=item task

Task name.

=item worker

Id of worker that is processing the job.

=back

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

  my $backend = Minion::Backend::File->new('/home/sri/minion.db');

Construct a new L<Minion::Backend::File> object.

=head2 register_worker

  my $worker_id = $backend->register_worker;
  my $worker_id = $backend->register_worker($worker_id);

Register worker or send heartbeat to show that this worker is still alive.

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

  my $bool = $backend->retry_job($job_id, $retries);
  my $bool = $backend->retry_job($job_id, $retries, {delay => 10});

Transition from C<failed> or C<finished> state back to C<inactive>.

These options are currently available:

=over 2

=item delay

  delay => 10

Delay job for this many seconds (from now).

=item priority

  priority => 5

Job priority.

=item queue

  queue => 'important'

Queue to put job in.

=back

=head2 stats

  my $stats = $backend->stats;

Get statistics for jobs and workers.

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker.

=head2 worker_info

  my $worker_info = $backend->worker_info($worker_id);

Get information about a worker or return C<undef> if worker does not exist.

  # Check worker host
  my $host = $backend->worker_info($worker_id)->{host};

These fields are currently available:

=over 2

=item host

Worker host.

=item jobs

Ids of jobs the worker is currently processing.

=item notified

Last time worker sent a heartbeat.

=item pid

Process id of worker.

=item started

Time worker was started.

=back

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
