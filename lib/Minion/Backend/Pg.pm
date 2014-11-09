package Minion::Backend::Pg;

use Mojo::Base 'Minion::Backend';

use List::Util 'first';
use Mojo::Util qw(md5_sum);
use Mojo::JSON qw(encode_json decode_json);
use Sys::Hostname 'hostname';
use Time::HiRes qw(time usleep);
use Mojo::Pg;

has 'pg';

sub dequeue {
  my ($self, $id, $timeout) = @_;
  usleep $timeout * 1000000 unless my $job = $self->_try($id);
  return $job || $self->_try($id);
}

sub enqueue {
  my ($self, $task) = (shift, shift);
  my $args    = shift // [];
  my $options = shift // {};

  my $job = {
    args    => encode_json($args),
    created => time,
    delayed => $options->{delay} ? (time + $options->{delay}) : 1,
    priority => $options->{priority} // 0,
    retries  => 0,
    state    => 'inactive',
    task     => $task
  };

  my $q = $self->question(7);
  my $tx = $self->pg->db->begin;
  $tx->dbh->do(
      "INSERT INTO job (args, created, delayed, priority, retries, state, task) VALUES ($q)", undef, 
      $job->{args}, $job->{created}, $job->{delayed}, $job->{priority}, $job->{retries}, $job->{state}, $job->{task}
  );
  my $id = $tx->dbh->last_insert_id(undef, undef, "job", undef);
  $tx->commit;

  $job->{id} = $id;

  return $job->{id};
}

sub _job {
  my ($self, $id) = (shift, shift);
  return undef unless my $job = $self->_jobs->{$id};
  return grep({ $job->{state} eq $_ } @_) ? $job : undef;
}

sub job_info {
  return shift->pg->db->query("SELECT * FROM job WHERE id = ?", shift)->hash;
}

sub list_jobs {
  my ($self, $offset, $limit, $options) = @_;

  my @jobs = sort { $b->{created} <=> $a->{created} } values %{$self->_jobs};
  @jobs = grep { $_->{state} eq $options->{state} } @jobs if $options->{state};
  @jobs = grep { $_->{task} eq $options->{task} } @jobs   if $options->{task};
  @jobs = grep {defined} @jobs[$offset .. ($offset + $limit - 1)];

  return \@jobs;
}

sub list_workers {
  my ($self, $offset, $limit) = @_;

  my @workers
    = sort { $b->{started} <=> $a->{started} } values %{$self->_workers};
  @workers = grep {defined} @workers[$offset .. ($offset + $limit - 1)];

  return [map { $self->_worker_info($_->{id}) } @workers];
}

sub question
{
    my $self = shift;
    my $nbr = shift;

    return(join(", ", map({"?"} (1 .. $nbr))));
}

sub new { 
    shift->SUPER::new(pg => Mojo::Pg->new(@_));
}

sub register_worker {
  my $self = shift;

  my $worker = {host => hostname, id => $self->_worker_id, pid => $$, started => time};

  my $tx = $self->pg->db->begin;
  $tx->dbh->do(
      "UPDATE worker SET host = ?, pid = ?, started = ? WHERE id = ?", undef, 
      $worker->{host}, $worker->{pid}, $worker->{started}, $worker->{id}
  );
  $tx->commit;

  # $self->_workers->{$worker->{id}} = $worker;

  return $worker->{id};
}

sub _worker_id {
    my $self = shift;

    my $q = $self->question(3);
    my $tx = $self->pg->db->begin;
    $tx->dbh->do(
        "INSERT INTO worker (host, pid, started) VALUES ($q)", undef, 
        "_stub", "_stub", "_stub"
    );
    my $id = $tx->dbh->last_insert_id(undef, undef, "worker", undef);
    $tx->commit;

    return $id;
}

sub repair {
  my $self = shift;

  my (@del_workers, @del_jobs);

  # Check workers on this host (all should be owned by the same user)
  my $workers = $self->_workers;
  my $host    = hostname;
  push(@del_workers, $_->{id})
    for grep { $_->{host} eq $host && !kill 0, $_->{pid} } values %$workers;

  # Abandoned jobs
  my $jobs = $self->_jobs;
  for my $job (values %$jobs) {
    next if $job->{state} ne 'active' || $workers->{$job->{worker}};
    @$job{qw(error state)} = ('Worker went away', 'failed');
  }

  # Old jobs
  my $after = time - $self->minion->remove_after;
  push(@del_jobs, $_->{id})
    for grep { $_->{state} eq 'finished' && $_->{finished} < $after }
    values %$jobs;

  # Remove the data
  my $tx = $self->pg->db->begin;
  my $q = $self->question(scalar(@del_workers));
  if (@del_workers) {
      $tx->dbh->do(
          "DELETE FROM worker WHERE id IN ($q)", undef,
          @del_workers
      );
  }
  if (@del_jobs) {
      $q = $self->question(scalar(@del_jobs));
      $tx->dbh->do(
          "DELETE FROM job WHERE id IN ($q)", undef,
          @del_jobs
      );
  }
  $tx->commit if (@del_workers || @del_jobs);
}

sub _try {
  my ($self, $id) = @_;

  my $db = $self->pg->db;

  my $sql = qq(
    SELECT * 
    FROM job 
    WHERE state = 'inactive'
        AND to_timestamp(delayed::int) < now()
    ORDER BY created, priority
  );

  my $jobs = $db->query($sql)->hashes;
  my $job = first { $self->minion->tasks->{$_->{task}} } @$jobs;
  $job->{args} = decode_json($job->{args}) if $job;

  if ($job) {
    my $tx = $self->pg->db->begin;
    $tx->dbh->do(
        "UPDATE job SET started = ?, state = ?, worker = ? WHERE id = ?", undef, 
        time, 'active', $id, $job->{id}
    );
    $tx->commit;
  }

  return $job ? $job : undef;
}

sub _jobs {
    my ($self, $id) = @_;

    my $jobs = $self->pg->db->query("SELECT * FROM job ORDER BY id")->hashes;

    my %jobs;
    foreach my $job (@{ $jobs }) {
        $job->{args} = decode_json($job->{args});
        $jobs{$$job{id}} = $job;
    }

    return(\%jobs);
}

sub _update {
    my ($self, $fail, $id, $err) = @_;
    
    my $job = $self->_job($id, 'active');

    if ($job) {
        $job->{finished} = time;
        $job->{state}    = $fail ? 'failed' : 'finished';
        $job->{error}    = $err if $err;
        
        my $tx = $self->pg->db->begin;
        $tx->dbh->do(
            "UPDATE job SET args = ?, created = ?, delayed = ?, priority = ?, retries = ?, state = ?, task = ?, finished = ? WHERE id = ?", undef, 
            encode_json($job->{args}), $job->{created}, $job->{delayed}, $job->{priority}, $job->{retries}, $job->{state}, $job->{task}, $job->{finished}, $job->{id}
        );
        $tx->commit;
    }

  return !!$job;
}

sub fail_job { shift->_update(1, @_) }

sub finish_job { shift->_update(0, @_) }

sub unregister_worker { 
    my $self = shift;
    my $id = shift;

    my $tx = $self->pg->db->begin;
    $tx->dbh->do(
        "DELETE FROM worker WHERE id = ?", undef,
        $id
    );
    $tx->commit;
}

sub remove_job {
    my ($self, $id) = @_;
    
    my $db = $self->pg->db;
    
    my $sql = qq(
      SELECT * 
      FROM job 
      WHERE state IN ('failed', 'finished', 'inactive')
        WHERE ID = ?
    );
    my $job = $db->query($sql, $id)->hash;
    if ($job) {
        my $tx = $db->begin;
        $tx->dbh->do(
            "DELETE FROM job WHERE id = ?", undef,
            $id
        );
        $tx->commit;
    }
    
    return !!$job;
}

sub reset { 
    my $tx = shift->pg->db->begin;
    $tx->dbh->do("DELETE FROM job");
    $tx->dbh->do("DELETE FROM worker");
    $tx->commit;
}

sub retry_job {
  my ($self, $id) = @_;

  my $pg = $self->pg;

  my $tx = $self->pg->db->begin;
  $tx->dbh->do("SELECT * FROM job WHERE state IN ('failed', 'finished') FOR UPDATE");

  my $job = $self->_job($id, 'failed', 'finished');
  if ($job) {
    $job->{retries} += 1;
    $tx->dbh->do(
        "UPDATE job SET retries = ?, retried = ?, state = ?, error = ?, finished = ?, result = ?, started = ?, worker = ? WHERE id = ?", undef, 
        $job->{retries}, time, 'inactive', "", "", "", "", "", $job->{id}
    );
    $tx->commit;
  }

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

sub worker_info { shift->_worker_info(@_) }

sub _worker_info {
  my ($self, $id) = @_;

  return undef unless $id && (my $worker = $self->_workers->{$id});
  my @jobs
    = map { $_->{id} } grep { $_->{worker} eq $id } values %{$self->_jobs};
  return {%{$worker}, jobs => \@jobs};
}

sub _workers { 
    my $workers = shift->pg->db->query("SELECT * FROM worker ORDER BY id")->hashes;

    my %workers;
    foreach my $worker (@{ $workers }) {
        $workers{$$worker{id}} = $worker;
    }

    return(\%workers);
}

1;
