use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mango::BSON qw(bson_oid bson_time);
use Minion;
use Mojo::IOLoop;
use Sys::Hostname 'hostname';

# Clean up before start
my $minion = Minion->new(Mango => $ENV{TEST_ONLINE});
is $minion->backend->prefix, 'minion', 'right prefix';
my $workers = $minion->backend->workers;
my $jobs    = $minion->backend->prefix('jobs_test')->jobs;
is $jobs->name, 'jobs_test.jobs', 'right name';
$minion->reset;

# Nothing to repair
my $worker = $minion->repair->worker;
isa_ok $worker->minion->app, 'Mojolicious', 'has default application';

# Register and unregister
$worker->register;
like $worker->info->{started}, qr/^[\d.]+$/, 'has timestamp';
is $worker->unregister->info, undef, 'no information';
is $worker->register->info->{host}, hostname, 'right host';
is $worker->info->{pid}, $$, 'right pid';
is $worker->unregister->info, undef, 'no information';

# Repair dead worker
$minion->add_task(test => sub { });
my $worker2 = $minion->worker->register;
isnt $worker2->id, $worker->id, 'new id';
my $oid = $minion->enqueue('test');
my $job = $worker2->dequeue;
is $job->id, $oid, 'right object id';
is $worker2->info->{jobs}[0], $job->id, 'right object id';
my $id = $worker2->id;
undef $worker2;
is $job->info->{state}, 'active', 'job is still active';
my $doc = $workers->find_one($id);
ok $doc, 'is registered';
my $pid = 4000;
$pid++ while kill 0, $pid;
$workers->save({%$doc, pid => $pid});
$minion->repair;
ok !$workers->find_one(bson_oid($id)), 'not registered';
is $job->info->{state}, 'failed',            'job is no longer active';
is $job->info->{error}, 'Worker went away.', 'right error';

# Repair abandoned job
$worker->register;
$oid = $minion->enqueue('test');
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
$worker->unregister;
$minion->repair;
is $job->info->{state}, 'failed',            'job is no longer active';
is $job->info->{error}, 'Worker went away.', 'right error';

# List workers
$worker  = $minion->worker->register;
$worker2 = $minion->worker->register;
my $batch = $minion->backend->list_workers(0, 10);
ok $batch->[0]{id},   'has id';
is $batch->[0]{host}, hostname, 'right host';
is $batch->[0]{pid},  $$, 'right pid';
is $batch->[1]{host}, hostname, 'right host';
is $batch->[1]{pid},  $$, 'right pid';
ok !$batch->[2], 'no more results';
$batch = $minion->backend->list_workers(0, 1);
is $batch->[0]{id}, $worker2->id, 'right id';
ok !$batch->[1], 'no more results';
$batch = $minion->backend->list_workers(1, 1);
is $batch->[0]{id}, $worker->id, 'right id';
ok !$batch->[1], 'no more results';
$worker->unregister;
$worker2->unregister;

# Reset
$minion->reset->repair;
ok !$minion->backend->jobs->options,    'no jobs';
ok !$minion->backend->workers->options, 'no workers';

# Tasks
my $add = $jobs->insert({results => []});
$minion->add_task(
  add => sub {
    my ($job, $first, $second) = @_;
    my $doc = $job->minion->backend->jobs->find_one($add);
    push @{$doc->{results}}, $first + $second;
    $job->minion->backend->jobs->save($doc);
  }
);
$minion->add_task(exit => sub { exit 1 });
$minion->add_task(fail => sub { die "Intentional failure!\n" });

# Stats
my $stats = $minion->stats;
is $stats->{active_workers},   0, 'no active workers';
is $stats->{inactive_workers}, 0, 'no inactive workers';
is $stats->{active_jobs},      0, 'no active jobs';
is $stats->{failed_jobs},      0, 'no failed jobs';
is $stats->{finished_jobs},    0, 'no finished jobs';
is $stats->{inactive_jobs},    0, 'no inactive jobs';
$worker = $minion->worker->register;
is $minion->stats->{inactive_workers}, 1, 'one inactive worker';
$minion->enqueue('fail');
$minion->enqueue('fail');
is $minion->stats->{inactive_jobs}, 2, 'two inactive jobs';
$job   = $worker->dequeue;
$stats = $minion->stats;
is $stats->{active_workers}, 1, 'one active worker';
is $stats->{active_jobs},    1, 'one active job';
is $stats->{inactive_jobs},  1, 'one inactive job';
ok $job->finish, 'job finished';
is $minion->stats->{finished_jobs}, 1, 'one finished job';
$job = $worker->dequeue;
ok $job->fail, 'job failed';
is $minion->stats->{failed_jobs}, 1, 'one failed job';
ok $job->restart, 'job restarted';
is $minion->stats->{failed_jobs}, 0, 'no failed jobs';
ok $worker->dequeue->finish, 'job finished';
$worker->unregister;
$stats = $minion->stats;
is $stats->{active_workers},   0, 'no active workers';
is $stats->{inactive_workers}, 0, 'no inactive workers';
is $stats->{active_jobs},      0, 'no active jobs';
is $stats->{failed_jobs},      0, 'one failed job';
is $stats->{finished_jobs},    2, 'one finished job';
is $stats->{inactive_jobs},    0, 'no inactive jobs';

# List jobs
$batch = $minion->backend->list_jobs(0, 10);
ok $batch->[0]{id},       'has id';
is $batch->[0]{task},     'fail', 'right task';
is $batch->[0]{state},    'finished', 'right state';
is $batch->[0]{restarts}, 1, 'job has been restarted';
is $batch->[1]{task},     'fail', 'right task';
is $batch->[1]{state},    'finished', 'right state';
is $batch->[1]{restarts}, 0, 'job has not been restarted';
ok !$batch->[2], 'no more results';
$batch = $minion->backend->list_jobs(0, 1);
is $batch->[0]{restarts}, 1, 'job has been restarted';
ok !$batch->[1], 'no more results';
$batch = $minion->backend->list_jobs(1, 1);
is $batch->[0]{restarts}, 0, 'job has not been restarted';
ok !$batch->[1], 'no more results';

# Enqueue, dequeue and perform
is $minion->job(bson_oid), undef, 'job does not exist';
$oid = $minion->enqueue(add => [2, 2]);
$doc = $jobs->find_one({task => 'add'});
is $doc->{_id}, $oid, 'right object id';
is_deeply $doc->{args}, [2, 2], 'right arguments';
is $doc->{priority}, 0,          'right priority';
is $doc->{state},    'inactive', 'right state';
$worker = $minion->worker;
is $worker->dequeue, undef, 'not registered';
ok !$minion->job($oid)->info->{started}, 'no started timestamp';
$job = $worker->register->dequeue;
like $job->info->{created}, qr/^[\d.]+$/, 'has created timestamp';
like $job->info->{started}, qr/^[\d.]+$/, 'has started timestamp';
is_deeply $job->args, [2, 2], 'right arguments';
is $job->info->{state}, 'active', 'right state';
is $job->task, 'add', 'right task';
is $workers->find_one($jobs->find_one($job->id)->{worker})->{pid}, $$,
  'right worker';
ok !$job->info->{finished}, 'no finished timestamp';
$job->perform;
like $job->info->{finished}, qr/^[\d.]+$/, 'has finished timestamp';
is_deeply $jobs->find_one($add)->{results}, [4], 'right result';
is $job->info->{state}, 'finished', 'right state';
$worker->unregister;
$job = $minion->job($job->id);
is_deeply $job->args, [2, 2], 'right arguments';
is $job->info->{state}, 'finished', 'right state';
is $job->task, 'add', 'right task';

# Restart and remove
$oid = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue;
is $job->info->{restarts}, 0, 'job has not been restarted';
is $job->id, $oid, 'right object id';
ok $job->finish, 'job finished';
ok !$worker->dequeue, 'no more jobs';
$job = $minion->job($oid);
ok !$job->info->{restarted}, 'no restarted timestamp';
ok $job->restart, 'job restarted';
like $job->info->{restarted}, qr/^[\d.]+$/, 'has restarted timestamp';
is $job->info->{state},       'inactive',   'right state';
is $job->info->{restarts},    1,            'job has been restarted once';
$job = $worker->dequeue;
ok !$job->restart, 'job not restarted';
is $job->id, $oid, 'right object id';
ok !$job->remove, 'job has not been removed';
ok $job->fail,    'job failed';
ok $job->restart, 'job restarted';
is $job->info->{restarts}, 2, 'job has been restarted twice';
ok !$job->info->{finished}, 'no finished timestamp';
ok !$job->info->{started},  'no started timestamp';
$doc = $jobs->find_one($oid);
ok !$doc->{error},  'no error';
ok !$doc->{worker}, 'no worker';
$job = $worker->dequeue;
is $job->info->{state}, 'active', 'right state';
ok $job->finish, 'job finished';
ok $job->remove, 'job has been removed';
is $job->info,   undef, 'no information';
$oid = $minion->enqueue(add => [6, 5]);
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
ok $job->fail,   'job failed';
ok $job->remove, 'job has been removed';
is $job->info,   undef, 'no information';
$oid = $minion->enqueue(add => [5, 5]);
$job = $minion->job("$oid");
ok $job->remove, 'job has been removed';
$worker->unregister;

# Jobs with priority
$minion->enqueue(add => [1, 2]);
$oid = $minion->enqueue(add => [2, 4], {priority => 1});
$job = $worker->register->dequeue;
is $job->id, $oid, 'right object id';
is $job->info->{priority}, 1, 'right priority';
ok $job->finish, 'job finished';
isnt $worker->dequeue->id, $oid, 'different object id';
$worker->unregister;

# Delayed jobs
my $epoch = time + 100;
$oid = $minion->enqueue(add => [2, 1] => {delayed => $epoch});
is $worker->register->dequeue, undef, 'too early for job';
$doc = $jobs->find_one($oid);
is $doc->{delayed}->to_epoch, $epoch, 'right delayed timestamp';
$doc->{delayed} = bson_time((time - 100) * 1000);
$jobs->save($doc);
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
like $job->info->{delayed}, qr/^[\d.]+$/, 'has delayed timestamp';
ok $job->finish, 'job finished';
$worker->unregister;

# Enqueue non-blocking
my ($fail, $result) = @_;
$minion->enqueue(
  add => [23] => {priority => 1} => sub {
    my ($minion, $err, $oid) = @_;
    $fail   = $err;
    $result = $oid;
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
ok !$fail, 'no error';
$worker = $minion->worker->register;
$job    = $worker->dequeue;
is $job->id, $result, 'right object id';
is_deeply $job->args, [23], 'right arguments';
is $job->info->{priority}, 1, 'right priority';
ok $job->finish, 'job finished';
$worker->unregister;

# Events
my ($failed, $finished) = (0, 0);
$minion->on(
  worker => sub {
    my ($minion, $worker) = @_;
    $worker->on(
      dequeue => sub {
        my ($worker, $job) = @_;
        $job->on(failed   => sub { $failed++ });
        $job->on(finished => sub { $finished++ });
      }
    );
  }
);
$worker = $minion->worker->register;
$minion->enqueue(add => [3, 3]);
$minion->enqueue(add => [4, 3]);
$job = $worker->dequeue;
is $failed,   0, 'failed event has not been emitted';
is $finished, 0, 'finished event has not been emitted';
$job->finish;
$job->finish;
is $failed,   0, 'failed event has not been emitted';
is $finished, 1, 'finished event has been emitted once';
$job = $worker->dequeue;
my $err;
$job->on(failed => sub { $err = pop });
$job->fail("test\n");
$job->fail;
is $err,      "test\n", 'right error';
is $failed,   1,        'failed event has been emitted once';
is $finished, 1,        'finished event has been emitted once';
$worker->unregister;

# Failed jobs
$oid = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue;
is $job->id, $oid, 'right object id';
is $job->info->{error}, undef, 'no error';
ok $job->fail, 'job failed';
ok !$job->finish, 'job not finished';
is $job->info->{state}, 'failed',        'right state';
is $job->info->{error}, 'Unknown error', 'right error';
$oid = $minion->enqueue(add => [6, 7]);
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
ok $job->fail('Something bad happened!'), 'job failed';
is $job->info->{state}, 'failed', 'right state';
is $job->info->{error}, 'Something bad happened!', 'right error';
$oid = $minion->enqueue('fail');
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
$job->perform;
is $job->info->{state}, 'failed', 'right state';
is $job->info->{error}, "Intentional failure!\n", 'right error';
$worker->unregister;

# Exit
$oid = $minion->enqueue('exit');
$job = $worker->register->dequeue;
is $job->id, $oid, 'right object id';
$job->perform;
is $job->info->{state}, 'failed', 'right state';
is $job->info->{error}, 'Non-zero exit status', 'right error';
$worker->unregister;
$minion->reset;

done_testing();
