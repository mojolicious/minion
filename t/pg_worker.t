use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

use Minion;

# Isolate tests
require Mojo::Pg;
my $pg = Mojo::Pg->new($ENV{TEST_ONLINE});
$pg->db->query('drop schema if exists minion_worker_test cascade');
$pg->db->query('create schema minion_worker_test');
my $minion = Minion->new(Pg => $ENV{TEST_ONLINE});
$minion->backend->pg->search_path(['minion_worker_test']);

# Basics
$minion->add_task(
  test => sub {
    my $job = shift;
    $job->finish({just => 'works!'});
  }
);
my $worker = $minion->worker;
$worker->on(
  dequeue => sub {
    my ($worker, $job) = @_;
    $job->on(reap => sub { kill 'INT', $$ });
  }
);
my $id = $minion->enqueue('test');
my $max;
$worker->once(wait => sub { $max = shift->status->{jobs} });
$worker->run;
is $max, 4, 'right value';
is_deeply $minion->job($id)->info->{result}, {just => 'works!'}, 'right result';

# Signals
$minion->add_task(
  int => sub {
    my $job     = shift;
    my $forever = 1;
    my $message = 'signals:';
    local $SIG{INT}  = sub { $forever = 0 };
    local $SIG{USR1} = sub { $message .= ' usr1' };
    local $SIG{USR2} = sub { $message .= ' usr2' };
    $job->minion->broadcast('kill', [$_, $job->id]) for qw(USR1 USR2 INT);
    while ($forever) { sleep 1 }
    $job->finish({msg => $message});
  }
);
$worker = $minion->worker;
$worker->status->{command_interval} = 1;
$worker->on(
  dequeue => sub {
    my ($worker, $job) = @_;
    $job->on(reap => sub { kill 'INT', $$ });
  }
);
$id = $minion->enqueue('int');
$worker->run;
is_deeply $minion->job($id)->info->{result}, {msg => 'signals: usr1 usr2'},
  'right result';

# Status
my $status = $worker->status;
is $status->{command_interval},   1,   'right value';
is $status->{dequeue_timeout},    5,   'right value';
is $status->{heartbeat_interval}, 300, 'right value';
is $status->{jobs},               4,   'right value';
is_deeply $status->{queues}, ['default'], 'right structure';
is $status->{performed}, 1, 'right value';
ok $status->{repair_interval}, 'has a value';

# Clean up once we are done
$pg->db->query('drop schema minion_worker_test cascade');

done_testing();
