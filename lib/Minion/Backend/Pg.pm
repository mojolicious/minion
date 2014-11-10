package Minion::Backend::Pg;

use Mojo::Base 'Minion::Backend';

use List::Util 'first';
use Mojo::Util qw(md5_sum);
use Mojo::JSON qw(encode_json decode_json);
use Sys::Hostname 'hostname';
use Time::HiRes qw(time usleep);
use Mojo::Pg;
use POSIX 'strftime';

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

  my $q = join(", ", map({"?"} (1 .. 7)));
  my @bind = ($job->{args}, $self->timestamp($job->{created}), $job->{delayed}, $job->{priority}, $job->{retries}, $job->{state}, $job->{task});
  my $db = $self->pg->db;
  my $ret = $db->query("INSERT INTO job (args, created, delayed, priority, retries, state, task) VALUES ($q) RETURNING id", @bind)->hash;

  return $ret->{id};
}

sub _job {
  my ($self, $id) = (shift, shift);

  my @states = @_;
  my $q = join(", ", map({"?"} (1 .. scalar(@states))));

  my $sql = qq(
    SELECT * 
    FROM job 
    WHERE id = ?
        AND state in ($q)
    LIMIT 1
  );

  return $self->pg->db->query($sql, $id, @states)->hash;
}

sub job_info {
  my $job = shift->pg->db->query(
    qq(
        SELECT 
            id, EXTRACT(EPOCH FROM started) as started, error, worker, args,
            EXTRACT(EPOCH FROM created) as created, delayed, priority, retries, state, task, 
            EXTRACT(EPOCH FROM finished) as finished, EXTRACT(EPOCH FROM retried) as retried
        FROM job 
        WHERE id = ?
    ), shift
  )->hash;
  $job->{args} = decode_json($job->{args}) if $job;
  return $job;
}

sub list_jobs {
  my ($self, $offset, $limit, $options) = @_;

  my (@and, @bind);

  push(@and, "state = ?") if $options->{state};
  push(@and, "task = ?") if $options->{task};

  my $where = @and ? ("WHERE " . join(" AND ", @and)) : "";
  push(@bind, $options->{state}) if $options->{state};
  push(@bind, $options->{task}) if $options->{task};

  push(@bind, $limit, $offset);

  my $sql = qq(
    SELECT * 
    FROM job 
    $where
    ORDER BY id DESC
    LIMIT ?
    OFFSET ?
  );

  return $self->pg->db->query($sql, @bind)->hashes;
}

sub list_workers {
  my ($self, $offset, $limit) = @_;

  my @workers = sort { $b->{id} <=> $a->{id} } values %{$self->_workers};
  @workers = grep {defined} @workers[$offset .. ($offset + $limit - 1)];

  return [map { $self->_worker_info($_->{id}) } @workers];
}

sub new { 
    shift->SUPER::new(pg => Mojo::Pg->new(@_));
}

sub register_worker {
  my $self = shift;

  my $worker = {host => hostname, pid => $$, started => time};

  my $db = $self->pg->db;
  my $ret = $db->query("INSERT INTO worker (host, pid, started) VALUES (?, ?, ?) RETURNING id",
      $worker->{host}, $worker->{pid}, $self->timestamp($worker->{started})
  )->hash;

  return $ret->{id};
}

sub repair {
  my $self = shift;

  my (@del_workers, @del_jobs);
  my $db = $self->pg->db;

  # Check workers on this host (all should be owned by the same user)
  my $workers = $self->_workers;
  my $host    = hostname;
  push(@del_workers, $_->{id})
    for grep { $_->{host} eq $host && !kill 0, $_->{pid} } values %$workers;

  if (@del_workers) {
      my $q = join(", ", map({"?"} (1 .. scalar(@del_workers))));
      $db->query("DELETE FROM worker WHERE id IN ($q)", @del_workers);
      $workers = $self->_workers;
  }

  # Abandoned jobs
  my $sql = qq(
    SELECT * 
    FROM job 
    WHERE state = 'active'
  );

  my $results = $db->query($sql);
  while (my $job = $results->hash) {
    next if $workers->{$job->{worker}};
    $db->query("UPDATE job SET error = ?, state = ? WHERE id = ?", 'Worker went away', 'failed', $job->{id});
  }

  # Old jobs
  $sql = qq(
    DELETE
    FROM job 
    WHERE state = 'finished'
        AND finished < ?
  );
  my $after = time - $self->minion->remove_after;
  $db->query($sql, $self->timestamp($after));
}

sub timestamp {
    return strftime("%Y-%m-%d %H:%M:%S", localtime(pop));
}

sub _try {
  my ($self, $id) = @_;

  my $db = $self->pg->db;

  my $tx = $db->begin;

  my $tasks = $self->minion->tasks;
  my @tasks = keys(%$tasks);
  my $q = join(", ", map({"?"} (1 .. scalar(@tasks))));

  my $sql = qq(
    SELECT * 
    FROM job 
    WHERE state = 'inactive'
        AND to_timestamp((delayed::real)::int) < now()
        AND task in ($q)
    ORDER BY priority DESC, created
    LIMIT 1
    FOR UPDATE
  );

  my $job = $db->query($sql, @tasks)->hash;
  $job->{args} = decode_json($job->{args}) if $job;

  if ($job) {
    $db->query("UPDATE job SET started = ?, state = ?, worker = ? WHERE id = ?", $self->timestamp(time), 'active', $id, $job->{id});
    $tx->commit;
  }

  return $job ? $job : undef;
}

sub _update {
    my ($self, $fail, $id, $err) = @_;
    
    my $job = $self->_job($id, 'active');

    if ($job) {
        $job->{finished} = time;
        $job->{state}    = $fail ? 'failed' : 'finished';
        $job->{error}    = $err if $err;
        
        my $db = $self->pg->db;
        $db->query(
            "UPDATE job SET finished = ?, state = ?, error = ? WHERE id = ?",
            $self->timestamp($job->{finished}), $job->{state}, $job->{error}, $job->{id}
        );
    }

  return !!$job;
}

sub fail_job { shift->_update(1, @_) }

sub finish_job { shift->_update(0, @_) }

sub unregister_worker { 
    my $self = shift;
    my $id = shift;

    my $db = $self->pg->db;
    $db->query("DELETE FROM worker WHERE id = ?", $id);
}

sub remove_job {
    my ($self, $id) = @_;
    
    my $db = $self->pg->db;
    
    my $sql = qq(
      SELECT * 
      FROM job 
      WHERE state IN ('failed', 'finished', 'inactive')
        AND id = ?
    );
    my $job = $db->query($sql, $id)->hash;
    if ($job) {
        $db->query("DELETE FROM job WHERE id = ?", $id);
    }
    
    return !!$job;
}

sub reset { 
    my $db = shift->pg->db;
    my $tx = $db->begin;
    $db->query("DELETE FROM job");
    $db->query("DELETE FROM worker");
    $tx->commit;
}

sub retry_job {
  my ($self, $id) = @_;

  my $job = $self->_job($id, 'failed', 'finished');

  if ($job) {
    $job->{retries} += 1;
    $self->pg->db->query(
        "UPDATE job SET retries = ?, retried = ?, state = ?, error = ?, finished = null, started = null, worker = ? WHERE id = ?",
        $job->{retries}, $self->timestamp(time), 'inactive', "", 0, $job->{id}
    );
  }

  return !!$job;
}

sub stats {
  my $self = shift;

  my $db = $self->pg->db;

  my $sql = qq(
    SELECT count(distinct worker) as active
    FROM job 
    WHERE state = 'active'
  );
  my $ret = $db->query($sql)->hash;
  my $active = $ret->{active};

  $sql = qq(
    SELECT state, count(state) 
    FROM job 
    GROUP BY 1
  );
  my $states = $db->query($sql)->arrays;
  my %states;

  foreach my $state (@$states) {
    $states{$$state[0]} = $$state[1];
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

sub worker_info { shift->_worker_info(@_) }

sub _worker_info {
  my ($self, $id) = @_;

  return undef unless $id && (my $worker = $self->_workers->{$id});

  my $sql = qq(
    SELECT id
    FROM job 
    WHERE worker = ?
  );

  my $jobs = $self->pg->db->query($sql, $id)->array;

  return {%{$worker}, jobs => $jobs};
}

sub _workers { 
    my $workers = shift->pg->db->query("SELECT id, host, pid, EXTRACT(EPOCH FROM started) as started FROM worker")->hashes;

    my %workers;
    foreach my $worker (@{ $workers }) {
        $workers{$$worker{id}} = $worker;
    }

    return(\%workers);
}

1;
