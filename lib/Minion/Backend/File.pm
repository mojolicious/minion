package Minion::Backend::File;
use Mojo::Base 'Minion::Backend';

use IO::Compress::Gzip 'gzip';
use IO::Uncompress::Gunzip 'gunzip';
use List::Util 'first';
use Mango::BSON 'bson_oid';
use Mojo::IOLoop;
use Storable qw(freeze thaw);
use Sys::Hostname 'hostname';
use Time::HiRes 'time';

has deserialize => sub { \&_deserialize };
has 'file';
has serialize => sub { \&_serialize };

sub dequeue {
  my ($self, $id) = @_;

  my $guard = $self->_guard;

  my @ready = grep { $_->{state} eq 'inactive' } values %{$guard->_jobs};
  my $now = time;
  @ready = grep { $_->{delayed} < $now } @ready;
  @ready = sort { $a->{created} <=> $b->{created} } @ready;
  @ready = sort { $b->{priority} <=> $a->{priority} } @ready;
  return undef
    unless my $job = first { $self->minion->tasks->{$_->{task}} } @ready;

  $guard->_write;
  @$job{qw(started state worker)} = (time, 'active', $id);
  return $job;
}

sub enqueue {
  my ($self, $task) = (shift, shift);
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $args    = shift // [];
  my $options = shift // {};

  my $guard = $self->_guard->_write;

  my $job = {
    args    => $args,
    created => time,
    delayed => $options->{delayed} ? $options->{delayed} : 1,
    id      => bson_oid,
    priority => $options->{priority} // 0,
    restarts => 0,
    state    => 'inactive',
    task     => $task
  };

  # Blocking
  $guard->_jobs->{$job->{id}} = $job;
  return $job->{id} unless $cb;

  # Non-blocking
  Mojo::IOLoop->next_tick(sub { $self->$cb(undef, $job->{id}) });
}

sub fail_job { shift->_update(1, @_) }

sub finish_job { shift->_update(0, @_) }

sub job_info { shift->_guard->_jobs->{shift()} }

sub list_jobs {
  my ($self, $skip, $limit) = @_;
  my $guard = $self->_guard;
  my @jobs = sort { $b->{created} <=> $a->{created} } values %{$guard->_jobs};
  return [grep {defined} @jobs[$skip .. ($skip + $limit - 1)]];
}

sub list_workers {
  my ($self, $skip, $limit) = @_;
  my $guard = $self->_guard;
  my @workers = map { $self->_worker_info($guard, $_->{id}) }
    sort { $b->{started} <=> $a->{started} } values %{$guard->_workers};
  return [grep {defined} @workers[$skip .. ($skip + $limit - 1)]];
}

sub new { shift->SUPER::new(file => shift) }

sub register_worker {
  my $worker = {host => hostname, id => bson_oid, pid => $$, started => time};
  shift->_guard->_write->_workers->{$worker->{id}} = $worker;
  return $worker->{id};
}

sub remove_job {
  my ($self, $id) = @_;

  my $guard = $self->_guard->_write;
  return undef unless my $job = $guard->_jobs->{$id};
  return undef
    unless grep { $job->{state} eq $_ } qw(failed finished inactive);
  return !!delete $guard->_jobs->{$id};
}

sub repair {
  my $self = shift;

  # Check workers on this host (all should be owned by the same user)
  my $guard   = $self->_guard->_write;
  my $workers = $guard->_workers;
  my $host    = hostname;
  delete $workers->{$_->{id}}
    for grep { $_->{host} eq $host && !kill 0, $_->{pid} } values %$workers;

  # Abandoned jobs
  my $jobs = $guard->_jobs;
  for my $job (values %$jobs) {
    next if $job->{state} ne 'active' || $workers->{$job->{worker}};
    @$job{qw(error state)} = ('Worker went away', 'failed');
  }

  # Old jobs
  my $after = time - $self->minion->clean_up_after;
  delete $jobs->{$_->{id}}
    for grep { $_->{state} eq 'finished' && $_->{finished} < $after }
    values %$jobs;
}

sub reset { shift->_guard->_spurt({}) }

sub restart_job {
  my ($self, $id) = @_;

  my $guard = $self->_guard->_write;

  return undef unless my $job = $guard->_jobs->{$id};
  return undef unless $job->{state} eq 'failed' || $job->{state} eq 'finished';

  $job->{restarts} += 1;
  @$job{qw(restarted state)} = (time, 'inactive');
  delete $job->{$_} for qw(error finished result started worker);
  return 1;
}

sub stats {
  my $self = shift;

  my $guard = $self->_guard;

  my @jobs = values %{$guard->_jobs};
  my %seen;
  my $active
    = grep { $_->{state} eq 'active' && !$seen{$_->{worker}}++ } @jobs;
  return {
    active_workers   => $active,
    inactive_workers => values(%{$guard->_workers}) - $active,
    active_jobs      => scalar(grep { $_->{state} eq 'active' } @jobs),
    inactive_jobs    => scalar(grep { $_->{state} eq 'inactive' } @jobs),
    failed_jobs      => scalar(grep { $_->{state} eq 'failed' } @jobs),
    finished_jobs    => scalar(grep { $_->{state} eq 'finished' } @jobs),
  };
}

sub unregister_worker { delete shift->_guard->_write->_workers->{shift()} }

sub worker_info { $_[0]->_worker_info($_[0]->_guard, $_[1]) }

sub _deserialize {
  gunzip \(my $compressed = shift), \my $uncompressed;
  return thaw $uncompressed;
}

sub _guard { Minion::Backend::File::_Guard->new(backend => shift) }

sub _serialize {
  gzip \(my $uncompressed = freeze(pop)), \my $compressed;
  return $compressed;
}

sub _update {
  my ($self, $fail, $id, $err) = @_;

  my $guard = $self->_guard->_write;

  return undef unless my $job = $guard->_jobs->{$id};
  return undef unless $job->{state} eq 'active';

  $job->{finished} = time;
  $job->{state}    = $fail ? 'failed' : 'finished';
  $job->{error}    = $err if $err;

  return 1;
}

sub _worker_info {
  my ($self, $guard, $id) = @_;

  return undef unless $id && (my $worker = $guard->_workers->{$id});
  my @jobs = values %{$guard->_jobs};
  return {%$worker,
    jobs => [map { $_->{id} } grep { $_->{worker} eq $id } @jobs]};
}

package Minion::Backend::File::_Guard;
use Mojo::Base -base;

use Fcntl ':flock';
use Mojo::Util qw(slurp spurt);

sub DESTROY {
  my $self = shift;
  $self->_spurt($self->_data) if $self->{write};
  flock $self->{lock}, LOCK_UN;
}

sub new {
  my $self = shift->SUPER::new(@_);
  $self->_spurt({}) unless -f (my $file = $self->{backend}->file);
  open $self->{lock}, '>', "$file.lock";
  flock $self->{lock}, LOCK_EX;
  return $self;
}

sub _data { $_[0]{data} //= $_[0]->_slurp }

sub _jobs { shift->_data->{jobs} //= {} }

sub _slurp { $_[0]{backend}->deserialize->(slurp $_[0]{backend}->file) }

sub _spurt {
  spurt $_[0]{backend}->serialize->($_[1]), $_[0]{backend}->file;
}

sub _workers { shift->_data->{workers} //= {} }

sub _write { ++$_[0]{write} && return $_[0] }

1;

=encoding utf8

=head1 NAME

Minion::Backend::File - File backend

=head1 SYNOPSIS

  use Minion::Backend::File;

  my $backend = Minion::Backend::File->new('/Users/sri/minion.data');

=head1 DESCRIPTION

L<Minion::Backend::File> is a highly portable file-based backend for
L<Minion>.

=head1 ATTRIBUTES

L<Minion::Backend::File> inherits all attributes from L<Minion::Backend> and
implements the following new ones.

=head2 deserialize

  my $cb   = $backend->deserialize;
  $backend = $backend->deserialize(sub {...});

A callback used to deserialize data, defaults to using L<Storable> with gzip
compression.

  $backend->deserialize(sub {
    my $bytes = shift;
    return {};
  });

=head2 file

  my $file = $backend->file;
  $backend = $backend->file('/Users/sri/minion.data');

File all data is stored in.

=head2 serialize

  my $cb   = $backend->serialize;
  $backend = $backend->serialize(sub {...});

A callback used to serialize data, defaults to using L<Storable> with gzip
compression.

  $backend->serialize(sub {
    my $hash = shift;
    return '';
  });

=head1 METHODS

L<Minion::Backend::File> inherits all methods from L<Minion::Backend> and
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

  my $bool = $backend->fail_job($job_id);
  my $bool = $backend->fail_job($job_id, 'Something went wrong!');

Transition from C<active> to C<failed> state.

=head2 finish_job

  my $bool = $backend->finish_job($job_id);

Transition from C<active> to C<finished> state.

=head2 job_info

  my $info = $backend->job_info($job_id);

Get information about a job or return C<undef> if job does not exist.

=head2 list_jobs

  my $batch = $backend->list_jobs($skip, $limit);

Returns the same information as L</"job_info"> but in batches.

=head2 list_workers

  my $batch = $backend->list_workers($skip, $limit);

Returns the same information as L</"worker_info"> but in batches.

=head2 new

  my $backend = Minion::Backend::File->new('/Users/sri/minion.data');

Construct a new L<Minion::Backend::File> object.

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

  my $bool = $backend->restart_job($job_id);

Transition from C<failed> or C<finished> state back to C<inactive>.

=head2 stats

  my $stats = $backend->stats;

Get statistics for jobs and workers.

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker.

=head2 worker_info

  my $info = $backend->worker_info($worker_id);

Get information about a worker or return C<undef> if worker does not exist.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
