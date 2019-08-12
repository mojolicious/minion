use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

use Mojo::IOLoop;
use Mojolicious::Lite;
use Test::Mojo;
use Mojo::Util qw{monkey_patch steady_time};
use POSIX 'WNOHANG';

# Isolate tests
require Mojo::Pg;
my $pg = Mojo::Pg->new($ENV{TEST_ONLINE});
$pg->db->query('drop schema if exists minion_dev_server_test cascade');
$pg->db->query('create schema minion_dev_server_test');

# make Test::Mojo subprocess aware and record the correct number of tests
Test::Mojo->attr(['subprocess']);

# majority of the tests run in a subprocess so proxy back to parent
monkey_patch 'Test::Mojo', '_test' => sub {
  my ($self, $name, @args) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 2;

  my ($stdout, $stderr) = ('', '');
  local (*STDOUT, *STDERR);
  open STDOUT, '>', \$stdout;
  open STDERR, '>', \$stderr;
  Test::More->builder->output(\*STDOUT);
  Test::More->builder->failure_output(\*STDERR);
  my $sucess = $self->success(!!Test::More->can($name)->(@args));
  Test::More->builder->reset_outputs;

  my $subprocess = $self->subprocess or return $sucess;
  $subprocess->progress({id => 0, stderr => $stderr}) if $stderr;
  $subprocess->progress({id => 1, stdout => $stdout});
  return $sucess;
  },

  # often need to wait for a job to finish
  'wait_for_job' => sub {
  my ($self, $job_id, $interval) = (shift, shift, shift || 5);
  my ($limit, $jobs) = (steady_time + $interval);
  do {
    $self->subprocess->ioloop->timer(1 => sub { shift->stop });
    $self->subprocess->ioloop->start;
    $self->app->log->info("waiting");
    $jobs = $self->app->minion->backend->list_jobs(0, 1, {ids => [$job_id]});
  } until ($jobs->{jobs}[0]{state} eq 'finished' || $limit < steady_time);
  };

my $minion_worker_pids = [];

# Mojo::IOLoop::Subprocess progress callback
sub progress_reporter {
  my ($subprocess, $data) = @_;

  if (my $cmd = $data->{command}) {
    if ($cmd eq 'worker_pid') {
      my $pid = $data->{pid};
      return diag "invalid PID" if !defined($pid) || $pid < 0;
      push @$minion_worker_pids, $data->{pid};
    }
    else {
      die "unknown command '$cmd'";
    }
    return;
  }

  my ($id, $stdout, $stderr) = @$data{qw{id stdout stderr}};
  record_test()          if $id;
  print STDOUT "$stdout" if $stdout;
  print STDERR "$stderr" if $stderr;
}

# updates Test::More's idea of how many tests
sub record_test {
  state $test_number //= 0;
  Test::More->builder->current_test($test_number++);
  return shift();
}

# run a server in subprocess for reasons
sub run_server_ok {
  my ($run, $finished, $until) = (shift, 0);
  $minion_worker_pids = [];

  local $SIG{CHLD} = 'DEFAULT';
  Mojo::IOLoop->subprocess(
    $run,
    sub {
      my ($subprocess, $err, $results) = @_;

      # end testing if this is the case
      die "not ok $err" if ($err);
      is_deeply $results, ['finished', $subprocess->pid],
        record_test('correct result');
      $finished = 1;
    }
    )->on(
    spawn => sub {
      $_[0]->on(progress => \&progress_reporter);
      my $pid = $_[0]->pid;

      # still local - so that server goes away triggering minion worker's
      # finished state with kill 0, $parent
      $SIG{CHLD} = sub { waitpid $pid, WNOHANG; };
    }
    );

  $until = Mojo::IOLoop->recurring(
    1 => sub { $_[0]->remove($until) and $_[0]->stop if $finished == 1; });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
  is $finished, 1, record_test('run_server_ok');
}

plugin Minion => {Pg => $pg->search_path(['minion_dev_server_test'])};

plugin 'Minion::Admin' => {};

app->mode('testing');

# Development server
app->minion_dev_server({queues => ['test']});

app->minion->add_task(
  add => sub {
    my ($job, $first, $second) = @_;
    Mojo::IOLoop->next_tick(
      sub {
        $job->finish($first + $second);
        Mojo::IOLoop->stop;
      }
    );
    Mojo::IOLoop->start;
  }
);

app->minion->add_task(
  block => sub {
    Mojo::IOLoop->timer(10 => sub { Mojo::IOLoop->stop });
    Mojo::IOLoop->start;
    shift->finish("$$");
  }
);

get '/' => sub { shift->render(text => 'index') };

get '/add' => sub {
  my $c  = shift;
  my $id = $c->minion->enqueue(
    add => [$c->param('first'), $c->param('second')] => {queue => 'test'});
  $c->render(text => $id);
};

get '/add-many' => sub {
  my $c   = shift;
  my $ids = [];
  push @$ids,
    $c->minion->enqueue(
    add => [$c->param('first'), $c->param('second')] => {queue => 'test'})
    for 0 .. 99;
  $c->render(json => $ids);
};

get '/block' => sub {
  my $c = shift;
  my $id = $c->minion->enqueue(block => [] => {queue => 'test'});
  $c->render(text => $id);
};

get '/result' => sub {
  my $c = shift;
  $c->render(text => $c->minion->job($c->param('id'))->info->{result});
};

get '/status' => sub {
  my $c = shift;
  $c->render(text => $c->minion->job($c->param('id'))->info->{state});
};

get '/workers' => sub {
  my $c = shift;
  $c->render(json => $c->minion->backend->list_workers(0, 100, {}));
};


run_server_ok sub {
  my ($subprocess) = @_;
  my $t = Test::Mojo->new;
  $t->subprocess($subprocess)->get_ok('/')->status_is(200);
  $t->get_ok('/')->status_is(200) for 0 .. 1;

  return ['finished', $$];
};

run_server_ok sub {
  my ($subprocess) = @_;
  my $t = Test::Mojo->new;
  $t->app->mode('testing');
  $t->app->minion_dev_server({queues => ['test']});

  $t->subprocess($subprocess)
    ->get_ok('/add' => form => {first => 1, second => 2})
    ->status_is(200, 'job enqueued');
  $subprocess->ioloop->timer(2 => sub { shift->stop });
  $subprocess->ioloop->start;
  $t->get_ok('/result' => form => {id => $t->tx->res->text})
    ->status_is(404, 'this job has not dequeued or run');

  return ['finished', $$];
};

run_server_ok sub {
  my ($subprocess) = @_;
  my $t = Test::Mojo->new;
  $0 = 'test-server';
  $t->app->mode('development');
  $t->app->minion_dev_server(
    {queues => ['test'], jobs => 1, dequeue_timeout => 0,});
  $t->subprocess($subprocess);

  # Perform jobs automatically
  $t->get_ok('/add' => form => {first => 1, second => 2})->status_is(200);

  # wait for job to finish
  $t->wait_for_job($t->tx->res->text, 2);
  $t->get_ok('/result' => form => {id => $t->tx->res->text})->status_is(200)
    ->content_is('3', 'simple 1 + 2');

  $t->get_ok('/block')->status_is(200)
    ->content_like(qr/^[0-9]+$/, 'numeric id');
  my $job_id = $t->tx->res->text;

  # test worker has started - one of two
  $t->get_ok('/workers')->status_is(200)
    ->json_is('/total', 2, 'have 2 workers (blocking + non blocking)')
    ->json_like('/workers/0/pid', qr/^[0-9]+$/, 'with a process id');
  my $workers = $t->tx->res->json('/workers');
  $subprocess->progress({command => 'worker_pid', pid => $_->{pid}})
    for @$workers;

  # get status while job is running
  $t->get_ok('/status' => form => {id => $job_id})->status_is(200)
    ->content_is('active', 'request not blocked')
    for 0 .. 1;

  # wait for job to finish and check
  my $before = steady_time;
  $t->wait_for_job($job_id, 30);
  $t->_test('cmp_ok', (steady_time - $before), '>', 5, "waited this long");

  $t->get_ok('/result' => form => {id => $job_id})->status_is(200)
    ->content_like(qr/^[0-9]+$/, 'result is process id or job process');

  $t->get_ok('/add' => form => {first => 40, second => 2})->status_is(200);
  $t->wait_for_job($t->tx->res->text);
  $t->get_ok('/result' => form => {id => $t->tx->res->text})->status_is(200)
    ->content_is('42', 'simple 40 + 2');

  return ['finished', $$];
};

ok @$minion_worker_pids > 0, record_test("saved a worker");
for my $pid (@$minion_worker_pids) {
  is kill(0, $pid), 0, record_test("worker (pid=$pid) finished with server");
}

run_server_ok sub {
  my ($subprocess) = @_;
  my $t = Test::Mojo->new;
  $0 = 'fast-finishing';
  $t->app->mode('development');
  $t->app->minion_dev_server({queues => ['test'], jobs => 2});
  $t->subprocess($subprocess);
  my $input = [map { [int(rand(200)), 1] } 0 .. 7];

  for my $i (@$input) {
    $t->get_ok('/add-many' => form => {first => $i->[0], second => $i->[1]})
      ->status_is(200);
  }

  # test worker has started - one of two
  $t->get_ok('/workers')->status_is(200)
    ->json_is('/total', 2, 'have 2 workers (blocking + non blocking)')
    ->json_like('/workers/0/pid', qr/^[0-9]+$/, 'with a process id');
  my $workers = $t->tx->res->json('/workers');
  $subprocess->progress({command => 'worker_pid', pid => $_->{pid}})
    for @$workers;

  return ['finished', $$];
};

my $result = app->minion->backend->list_jobs(0, 1, {states => ['inactive']});
my $jobs = $result->{jobs};
cmp_ok $result->{total}, '>=', 1,
  record_test("left inactive jobs - fast finished");

cmp_ok @$minion_worker_pids, '>', 0, record_test("saved a worker");
for my $pid (@$minion_worker_pids) {
  is kill(0, $pid), 0, record_test("worker (pid=$pid) finished with server");
}

run_server_ok sub {
  my ($subprocess) = @_;
  my $t = Test::Mojo->new;
  $t->app->mode('development');
  $t->app->minion_dev_server(
    {
      queues             => ['test'],
      jobs               => 100,
      heartbeat_interval => 1,
      dequeue_timeout    => 0,
    }
  );

  # run the inactive jobs and add a few more
  $t->subprocess($subprocess)
    ->get_ok('/add' => form => {first => 1, second => 2})
    ->status_is(200, 'job enqueued');
  my $job_id = $t->tx->res->text;
  $t->wait_for_job($job_id, 60);
  $t->get_ok('/result' => form => {id => $job_id})
    ->status_is(200, 'this job ran')->content_is(3, 'add');

  # wait for worker heartbeat update status
  $subprocess->ioloop->timer(5 => sub { shift->stop });
  $subprocess->ioloop->start;
  my $results = $t->app->minion->backend->list_workers();
  $t->_test('is', $results->{total}, 2, 'two workers');
  for my $w (@{$results->{workers}}) {
    $t->_test('is',     $w->{status}{dequeue_timeout},    0,   'configuration');
    $t->_test('is',     $w->{status}{heartbeat_interval}, 1,   'configuration');
    $t->_test('is',     $w->{status}{jobs},               100, 'configuration');
    $t->_test('cmp_ok', $w->{status}{performed},          '>', 1, 'heartbeat');
    $t->_test('is_deeply', $w->{status}{queues}, ["test"], 'configuration');
  }

  return ['finished', $$];
};

is $SIG{CHLD}, undef, record_test('local sig chld');

# Clean up once we are done
$pg->db->query('drop schema minion_dev_server_test cascade');

done_testing();
