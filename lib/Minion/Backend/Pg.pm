package Minion::Backend::Pg;
use Mojo::Base 'Minion::Backend';

use Mojo::IOLoop;
use Mojo::Pg;
use Sys::Hostname 'hostname';

has 'pg';

sub dequeue {
  my ($self, $id, $timeout) = @_;

  if ((my $job = $self->_try($id)) || Mojo::IOLoop->is_running) { return $job }

  my $db = $self->pg->db;
  $db->listen('minion.job')->on(notification => sub { Mojo::IOLoop->stop });
  my $timer = Mojo::IOLoop->timer($timeout => sub { Mojo::IOLoop->stop });
  Mojo::IOLoop->start;
  $db->unlisten('*') and Mojo::IOLoop->remove($timer);
  undef $db;

  return $self->_try($id);
}

sub enqueue {
  my ($self, $task) = (shift, shift);
  my $args    = shift // [];
  my $options = shift // {};

  my $db = $self->pg->db;
  return $db->query(
    "insert into minion_jobs (args, delayed, priority, task)
     values (?, (now() + (interval '1 second' * ?)), ?, ?)
     returning id", {json => $args}, $options->{delay} // 0,
    $options->{priority} // 0, $task
  )->hash->{id};
}

sub fail_job   { shift->_update(1, @_) }
sub finish_job { shift->_update(0, @_) }

sub job_info {
  shift->pg->db->query(
    'select id, args, extract(epoch from created) as created,
       extract(epoch from delayed) as delayed,
       extract(epoch from finished) as finished, priority, result,
       extract(epoch from retried) as retried, retries,
       extract(epoch from started) as started, state, task, worker
     from minion_jobs where id = ?', shift
  )->expand->hash;
}

sub list_jobs {
  my ($self, $offset, $limit, $options) = @_;

  return $self->pg->db->query(
    'select id from minion_jobs
     where (state = $1 or $1 is null) and (task = $2 or $2 is null)
     order by id desc
     limit $3
     offset $4', @$options{qw(state task)}, $limit, $offset
  )->arrays->map(sub { $self->job_info($_->[0]) })->to_array;
}

sub list_workers {
  my ($self, $offset, $limit) = @_;

  my $sql = 'select id from minion_workers order by id desc limit ? offset ?';
  return $self->pg->db->query($sql, $limit, $offset)
    ->arrays->map(sub { $self->worker_info($_->[0]) })->to_array;
}

sub new {
  my $self = shift->SUPER::new(pg => Mojo::Pg->new(@_));
  my $pg = $self->pg->max_connections(1);
  $pg->migrations->name('minion')->from_data;
  $pg->once(connection => sub { shift->migrations->migrate });
  return $self;
}

sub register_worker {
  my ($self, $id) = @_;

  my $sql
    = 'update minion_workers set notified = now() where id = ? returning 1';
  return $id if $id && $self->pg->db->query($sql, $id)->rows;

  $sql = 'insert into minion_workers (host, pid) values (?, ?) returning id';
  return $self->pg->db->query($sql, hostname, $$)->hash->{id};
}

sub remove_job {
  !!shift->pg->db->query(
    "delete from minion_jobs
     where id = ? and state in ('inactive', 'failed', 'finished')
     returning 1", shift
  )->rows;
}

sub repair {
  my $self = shift;

  # Check worker registry
  my $db     = $self->pg->db;
  my $minion = $self->minion;
  $db->query(
    "delete from minion_workers
     where notified < now() - interval '1 second' * ?", $minion->missing_after
  );

  # Abandoned jobs
  $db->query(
    "update minion_jobs as j
     set result = to_json('Worker went away'::text), state = 'failed'
     where state = 'active'
       and not exists(select 1 from minion_workers where id = j.worker)"
  );

  # Old jobs
  $db->query(
    "delete from minion_jobs
     where state = 'finished' and finished < now() - interval '1 second' * ?",
    $minion->remove_after
  );
}

sub reset {
  my $db = shift->pg->db;
  $db->query('delete from minion_jobs');
  $db->query('delete from minion_workers');
}

sub retry_job {
  !!shift->pg->db->query(
    "update minion_jobs
     set finished = null, result = null, retried = now(),
       retries = retries + 1, started = null, state = 'inactive', worker = null
     where id = ? and state in ('failed', 'finished')
     returning 1", shift
  )->rows;
}

sub stats {
  my $self = shift;

  my $db  = $self->pg->db;
  my $all = $db->query('select count(*) from minion_workers')->array->[0];
  my $sql
    = "select count(distinct worker) from minion_jobs where state = 'active'";
  my $active = $db->query($sql)->array->[0];

  $sql = 'select state, count(state) from minion_jobs group by 1';
  my $states = $db->query($sql)
    ->arrays->reduce(sub { $a->{$b->[0]} = $b->[1]; $a }, {});

  return {
    active_workers   => $active,
    inactive_workers => $all - $active,
    active_jobs      => $states->{active} || 0,
    inactive_jobs    => $states->{inactive} || 0,
    failed_jobs      => $states->{failed} || 0,
    finished_jobs    => $states->{finished} || 0,
  };
}

sub unregister_worker {
  shift->pg->db->query('delete from minion_workers where id = ?', shift);
}

sub worker_info {
  shift->pg->db->query(
    'select id, extract(epoch from notified) as notified, array(
       select id from minion_jobs where worker = minion_workers.id
     ) as jobs, host, pid, extract(epoch from started) as started
     from minion_workers
     where id = ?', shift
  )->hash;
}

sub _try {
  my ($self, $id) = @_;

  return $self->pg->db->query(
    "update minion_jobs
     set started = now(), state = 'active', worker = ?
     where id = (
       select id from minion_jobs
       where state = 'inactive' and delayed < now() and task = any (?)
       order by priority desc, created
       limit 1
       for update
     )
     returning id, args, task", $id, [keys %{$self->minion->tasks}]
  )->expand->hash;
}

sub _update {
  my ($self, $fail, $id, $result) = @_;

  return !!$self->pg->db->query(
    "update minion_jobs
     set finished = now(), result = ?, state = ?, worker = null
     where id = ? and state = 'active'
     returning 1", {json => $result}, $fail ? 'failed' : 'finished', $id
  )->rows;
}

1;

=encoding utf8

=head1 NAME

Minion::Backend::Pg - PostgreSQL backend

=head1 SYNOPSIS

  use Minion::Backend::Pg;

  my $backend = Minion::Backend::Pg->new('postgresql://postgres@/test');

=head1 DESCRIPTION

L<Minion::Backend::Pg> is a backend for L<Minion> based on L<Mojo::Pg>. All
necessary tables will be created automatically with a set of migrations named
C<minion>. Note that this backend uses many bleeding edge features, so only the
latest, stable version of PostgreSQL is fully supported.

=head1 ATTRIBUTES

L<Minion::Backend::Pg> inherits all attributes from L<Minion::Backend> and
implements the following new ones.

=head2 pg

  my $pg   = $backend->pg;
  $backend = $backend->pg(Mojo::Pg->new);

L<Mojo::Pg> object used to store all data.

=head1 METHODS

L<Minion::Backend::Pg> inherits all methods from L<Minion::Backend> and
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
  my $bool = $backend->fail_job($job_id, {msg => 'Something went wrong!'});

Transition from C<active> to C<failed> state.

=head2 finish_job

  my $bool = $backend->finish_job($job_id);
  my $bool = $backend->finish_job($job_id, 'All went well!');
  my $bool = $backend->finish_job($job_id, {msg => 'All went well!'});

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

  my $backend = Minion::Backend::Pg->new('postgresql://postgres@/test');

Construct a new L<Minion::Backend::Pg> object.

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

__DATA__

@@ minion
-- 1 up
create table if not exists minion_jobs (
  id       bigserial not null primary key,
  args     json not null,
  created  timestamp with time zone not null,
  delayed  timestamp with time zone not null,
  finished timestamp with time zone,
  priority int not null,
  result   json,
  retried  timestamp with time zone,
  retries  int not null,
  started  timestamp with time zone,
  state    text not null,
  task     text not null,
  worker   bigint
);
create index on minion_jobs (priority DESC, created);
create table if not exists minion_workers (
  id      bigserial not null primary key,
  host    text not null,
  pid     int not null,
  started timestamp with time zone not null
);
create or replace function minion_jobs_insert_notify() returns trigger as $$
  begin
    perform pg_notify('minion.job', '');
    return null;
  end;
$$ language plpgsql;
set client_min_messages to warning;
drop trigger if exists minion_jobs_insert_trigger on minion_jobs;
set client_min_messages to notice;
create trigger minion_jobs_insert_trigger after insert on minion_jobs
  for each row execute procedure minion_jobs_insert_notify();

-- 1 down
drop table if exists minion_jobs;
drop function if exists minion_jobs_insert_notify();
drop table if exists minion_workers;

-- 2 up
alter table minion_jobs alter column created set default now();
alter table minion_jobs alter column state set default 'inactive';
alter table minion_jobs alter column retries set default 0;
alter table minion_workers add column
  notified timestamp with time zone not null default now();
alter table minion_workers alter column started set default now();
