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

  my $pg = $self->pg;
  my $job = {
    args    => encode_json($args),
    created => time,
    delayed => $options->{delay} ? (time + $options->{delay}) : 1,
    id      => $self->_job_id,
    priority => $options->{priority} // 0,
    retries  => 0,
    state    => 'inactive',
    task     => $task
  };

  $self->_jobs->{$job->{id}} = $job;

  my $tx = Mojo::Pg::Transaction->new(dbh => $pg->db->dbh);
  $tx->dbh->do(
      "UPDATE job SET args = ?, created = ?, delayed = ?, priority = ?, retries = ?, state = ?, task = ? WHERE id = ?", undef, 
      $job->{args}, $job->{created}, $job->{delayed}, $job->{priority}, $job->{retries}, $job->{state}, $job->{task}, $job->{id}
  );
  $tx->commit;

  return $job->{id};
}

sub _job {
  my ($self, $id) = (shift, shift);
  return undef unless my $job = $self->_jobs->{$id};
  return grep({ $job->{state} eq $_ } @_) ? $job : undef;
}

sub _job_id {
    my $self = shift;

    my $q = $self->question(7);
    my $tx = Mojo::Pg::Transaction->new(dbh => $self->pg->db->dbh);
    $tx->dbh->do(
        "INSERT INTO job (args, created, delayed, priority, retries, state, task) VALUES ($q)", undef, 
        '{"_stub":"_stub"}', "_stub", "_stub", "_stub", "_stub", "_stub", "_stub"
    );
    my $id = $tx->dbh->last_insert_id(undef, undef, "job", undef);
    $tx->commit;

    return $id;
}

sub question
{
    my $self = shift;
    my $nbr = shift;

    return(join(", ", map({"?"} (1 .. $nbr))));
}

sub new { 
    $DB::single = 1;
    shift->SUPER::new(pg => Mojo::Pg->new('postgresql://username:password@localhost/jobs?AutoCommit=0'));
}

sub register_worker {
  my $self = shift;

  $DB::single = 1;
  my $worker = {host => hostname, id => $self->_worker_id, pid => $$, started => time};

  my $tx = Mojo::Pg::Transaction->new(dbh => $self->pg->db->dbh);
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
    $DB::single = 1;
    my $tx = Mojo::Pg::Transaction->new(dbh => $self->pg->db->dbh);
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

  return;

  ### One day this will work

  # Check workers on this host (all should be owned by the same user)
  my $pg = $self->pg;
  # $pg->lock_exclusive;
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
    # $pg->unlock;
}

sub _try {
  my ($self, $id) = @_;

  my $pg = $self->pg;

  $DB::single = 1;

  my @ready = grep { $_->{state} eq 'inactive' } values %{$self->_jobs};
  my $now = time;
  @ready = grep { $_->{delayed} < $now } @ready;
  @ready = sort { $a->{created} <=> $b->{created} } @ready;
  @ready = sort { $b->{priority} <=> $a->{priority} } @ready;
  my $job = first { $self->minion->tasks->{$_->{task}} } @ready;
  #  @$job{qw(started state worker)} = (time, 'active', $id) if $job;

  if ($job) {
    my $tx = Mojo::Pg::Transaction->new(dbh => $pg->db->dbh);
    $tx->dbh->do(
        "UPDATE job SET started = ?, state = ?, worker = ? WHERE id = ?", undef, 
        time, 'active', $id, $job->{id}
    );
    $tx->commit;
  }

  return $job ? $job : undef;   # export?
}

sub _jobs {
    my ($self, $id) = @_;

    $DB::single = 1;
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
    
    $DB::single = 1;

    my $job = $self->_job($id, 'active');

    if ($job) {
        $job->{finished} = time;
        $job->{state}    = $fail ? 'failed' : 'finished';
        $job->{error}    = $err if $err;
        
        my $tx = Mojo::Pg::Transaction->new(dbh => $self->pg->db->dbh);
        $tx->dbh->do(
            "UPDATE job SET args = ?, created = ?, delayed = ?, priority = ?, retries = ?, state = ?, task = ? WHERE id = ?", undef, 
            encode_json($job->{args}), $job->{created}, $job->{delayed}, $job->{priority}, $job->{retries}, $job->{state}, $job->{task}, $job->{id}
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

    my $tx = Mojo::Pg::Transaction->new(dbh => $self->pg->db->dbh);
    $tx->dbh->do(
        "DELETE FROM worker WHERE id = ?", undef,
        $id
    );
    $tx->commit;
}

sub remove_job {
    my ($self, $id) = @_;
    
    $DB::single = 1;
    my $removed = !!$self->_job($id, 'failed', 'finished', 'inactive');
    if ($removed) {
        my $tx = Mojo::Pg::Transaction->new(dbh => $self->pg->db->dbh);
        $tx->dbh->do(
            "DELETE FROM job WHERE id = ?", undef,
            $id
        );
        $tx->commit;
    }
    
    return $removed;
}

1;

__END__
BEGIN;
CREATE TABLE job(
  id serial not null PRIMARY KEY,
  args json NOT NULL,
  started VARCHAR(64),
  error VARCHAR(64),
  worker VARCHAR(64),
  created VARCHAR(64) NOT NULL,
  delayed VARCHAR(64) NOT NULL,
  priority VARCHAR(64) NOT NULL,
  retries VARCHAR(64) NOT NULL,
  state VARCHAR(64) NOT NULL,
  task VARCHAR(64) NOT NULL,
  updated timestamp default CURRENT_TIMESTAMP,
  inserted timestamp default CURRENT_TIMESTAMP
);

CREATE TRIGGER user_timestamp BEFORE INSERT OR UPDATE ON job
FOR EACH ROW EXECUTE PROCEDURE update_timestamp();

GRANT SELECT ON TABLE job TO username;
GRANT INSERT ON TABLE job TO username;
GRANT UPDATE ON TABLE job TO username;
GRANT DELETE ON TABLE job TO username;

GRANT USAGE, SELECT ON SEQUENCE job_id_seq TO username;
COMMIT;

BEGIN;
CREATE TABLE worker(
  id serial not null PRIMARY KEY,
  host VARCHAR(64) NOT NULL,
  pid VARCHAR(64) NOT NULL,
  started VARCHAR(64) NOT NULL,
  updated timestamp default CURRENT_TIMESTAMP,
  inserted timestamp default CURRENT_TIMESTAMP
);

CREATE TRIGGER user_timestamp BEFORE INSERT OR UPDATE ON worker
FOR EACH ROW EXECUTE PROCEDURE update_timestamp();

GRANT SELECT ON TABLE worker TO username;
GRANT INSERT ON TABLE worker TO username;
GRANT UPDATE ON TABLE worker TO username;
GRANT DELETE ON TABLE worker TO username;

GRANT USAGE, SELECT ON SEQUENCE worker_id_seq TO username;
COMMIT;
