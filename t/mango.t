use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mango::BSON qw(bson_oid bson_time);
use Minion;
use Mojo::IOLoop;
use Sys::Hostname 'hostname';
use Time::HiRes 'time';

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
my $id  = $minion->enqueue('test');
my $job = $worker2->dequeue(0);
is $job->id, $id, 'right id';
is $worker2->info->{jobs}[0], $job->id, 'right id';
$id = $worker2->id;
undef $worker2;
is $job->info->{state}, 'active', 'job is still active';
my $doc = $workers->find_one($id);
ok $doc, 'is registered';
my $pid = 4000;
$pid++ while kill 0, $pid;
$workers->save({%$doc, pid => $pid});
$minion->repair;
ok !$minion->backend->worker_info($id), 'not registered';
is $job->info->{state}, 'failed',           'job is no longer active';
is $job->info->{error}, 'Worker went away', 'right error';

# Repair abandoned job
$worker->register;
$id  = $minion->enqueue('test');
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
$worker->unregister;
$minion->repair;
is $job->info->{state}, 'failed',           'job is no longer active';
is $job->info->{error}, 'Worker went away', 'right error';

# Repair old jobs
$worker->register;
$id = $minion->enqueue('test');
my $id2 = $minion->enqueue('test');
my $id3 = $minion->enqueue('test');
$worker->dequeue(0)->perform for 1 .. 3;
$doc = $jobs->find_one($id2);
$doc->{finished} = bson_time(($doc->{finished}->to_epoch - 864001) * 1000);
$jobs->save($doc);
$doc = $jobs->find_one($id3);
$doc->{finished} = bson_time(($doc->{finished}->to_epoch - 864001) * 1000);
$jobs->save($doc);
$worker->unregister;
$minion->repair;
ok $minion->job($id), 'job has not been cleaned up';
ok !$minion->job($id2), 'job has been cleaned up';
ok !$minion->job($id3), 'job has been cleaned up';

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

# Wait for job
my $before = time;
$worker = $minion->worker->register;
is $worker->dequeue(0.5), undef, 'no jobs yet';
ok !!(($before + 0.5) <= time), 'waited for jobs';
$worker->unregister;

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
$job   = $worker->dequeue(0);
$stats = $minion->stats;
is $stats->{active_workers}, 1, 'one active worker';
is $stats->{active_jobs},    1, 'one active job';
is $stats->{inactive_jobs},  1, 'one inactive job';
$minion->enqueue('fail');
my $job2 = $worker->dequeue(0);
$stats = $minion->stats;
is $stats->{active_workers}, 1, 'one active worker';
is $stats->{active_jobs},    2, 'two active jobs';
is $stats->{inactive_jobs},  1, 'one inactive job';
ok $job2->finish, 'job finished';
ok $job->finish,  'job finished';
is $minion->stats->{finished_jobs}, 2, 'two finished jobs';
$job = $worker->dequeue(0);
ok $job->fail, 'job failed';
is $minion->stats->{failed_jobs}, 1, 'one failed job';
ok $job->retry, 'job retried';
is $minion->stats->{failed_jobs}, 0, 'no failed jobs';
ok $worker->dequeue(0)->finish, 'job finished';
$worker->unregister;
$stats = $minion->stats;
is $stats->{active_workers},   0, 'no active workers';
is $stats->{inactive_workers}, 0, 'no inactive workers';
is $stats->{active_jobs},      0, 'no active jobs';
is $stats->{failed_jobs},      0, 'no failed jobs';
is $stats->{finished_jobs},    3, 'three finished jobs';
is $stats->{inactive_jobs},    0, 'no inactive jobs';

# List jobs
$id = $minion->enqueue('fail');
$batch = $minion->backend->list_jobs(0, 10);
ok $batch->[0]{id},      'has id';
is $batch->[0]{task},    'fail', 'right task';
is $batch->[0]{state},   'inactive', 'right state';
is $batch->[0]{retries}, 0, 'job has not been retried';
is $batch->[1]{task},    'fail', 'right task';
is $batch->[1]{state},   'finished', 'right state';
is $batch->[1]{retries}, 1, 'job has been retried';
is $batch->[2]{task},    'fail', 'right task';
is $batch->[2]{state},   'finished', 'right state';
is $batch->[2]{retries}, 0, 'job has not been retried';
is $batch->[3]{task},    'fail', 'right task';
is $batch->[3]{state},   'finished', 'right state';
is $batch->[3]{retries}, 0, 'job has not been retried';
ok !$batch->[4], 'no more results';
$batch = $minion->backend->list_jobs(0, 10, 'inactive');
is $batch->[0]{state},   'inactive', 'right state';
is $batch->[0]{retries}, 0,          'job has not been retried';
ok !$batch->[1], 'no more results';
$batch = $minion->backend->list_jobs(0, 1);
is $batch->[0]{state},   'inactive', 'right state';
is $batch->[0]{retries}, 0,          'job has not been retried';
ok !$batch->[1], 'no more results';
$batch = $minion->backend->list_jobs(1, 1);
is $batch->[0]{state},   'finished', 'right state';
is $batch->[0]{retries}, 1,          'job has been retried';
ok !$batch->[1], 'no more results';
ok $minion->job($id)->remove, 'job removed';

# Enqueue, dequeue and perform
is $minion->job(bson_oid), undef, 'job does not exist';
$id = $minion->enqueue(add => [2, 2]);
my $info = $minion->job($id)->info;
is $info->{task}, 'add', 'right task';
is_deeply $info->{args}, [2, 2], 'right arguments';
is $info->{priority}, 0,          'right priority';
is $info->{state},    'inactive', 'right state';
$worker = $minion->worker;
is $worker->dequeue(0), undef, 'not registered';
ok !$minion->job($id)->info->{started}, 'no started timestamp';
$job = $worker->register->dequeue(0);
like $job->info->{created}, qr/^[\d.]+$/, 'has created timestamp';
like $job->info->{started}, qr/^[\d.]+$/, 'has started timestamp';
is_deeply $job->args, [2, 2], 'right arguments';
is $job->info->{state}, 'active', 'right state';
is $job->task, 'add', 'right task';
$id = $job->info->{worker};
is $minion->backend->worker_info($id)->{pid}, $$, 'right worker';
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

# Retry and remove
$id = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue(0);
is $job->info->{retries}, 0, 'job has not been retried';
is $job->id, $id, 'right id';
ok $job->finish, 'job finished';
ok !$worker->dequeue(0), 'no more jobs';
$job = $minion->job($id);
ok !$job->info->{retried}, 'no retried timestamp';
ok $job->retry, 'job retried';
like $job->info->{retried}, qr/^[\d.]+$/, 'has retried timestamp';
is $job->info->{state},     'inactive',   'right state';
is $job->info->{retries},   1,            'job has been retried once';
$job = $worker->dequeue(0);
ok !$job->retry, 'job not retried';
is $job->id, $id, 'right id';
ok !$job->remove, 'job has not been removed';
ok $job->fail,  'job failed';
ok $job->retry, 'job retried';
is $job->info->{retries}, 2, 'job has been retried twice';
ok !$job->info->{finished}, 'no finished timestamp';
ok !$job->info->{started},  'no started timestamp';
ok !$job->info->{error},    'no error';
ok !$job->info->{worker},   'no worker';
$job = $worker->dequeue(0);
is $job->info->{state}, 'active', 'right state';
ok $job->finish, 'job finished';
ok $job->remove, 'job has been removed';
is $job->info,   undef, 'no information';
$id = $minion->enqueue(add => [6, 5]);
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
ok $job->fail,   'job failed';
ok $job->remove, 'job has been removed';
is $job->info,   undef, 'no information';
$id = $minion->enqueue(add => [5, 5]);
$job = $minion->job("$id");
ok $job->remove, 'job has been removed';
$worker->unregister;

# Jobs with priority
$minion->enqueue(add => [1, 2]);
$id = $minion->enqueue(add => [2, 4], {priority => 1});
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{priority}, 1, 'right priority';
ok $job->finish, 'job finished';
isnt $worker->dequeue(0)->id, $id, 'different id';
$worker->unregister;

# Delayed jobs
$id = $minion->enqueue(add => [2, 1] => {delay => 100});
is $worker->register->dequeue(0), undef, 'too early for job';
$doc = $jobs->find_one($id);
ok $doc->{delayed}->to_epoch > time, 'delayed timestamp';
$doc->{delayed} = bson_time((time - 100) * 1000);
$jobs->save($doc);
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
like $job->info->{delayed}, qr/^[\d.]+$/, 'has delayed timestamp';
ok $job->finish, 'job finished';
ok $job->retry,  'job retried';
ok $minion->job($id)->info->{delayed} < time, 'no delayed timestamp';
ok $job->remove, 'job removed';
ok !$job->retry, 'job not retried';
$worker->unregister;

# Enqueue non-blocking
my ($fail, $result) = @_;
$minion->enqueue(
  add => [23] => {priority => 1} => sub {
    my ($minion, $err, $id) = @_;
    $fail   = $err;
    $result = $id;
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
ok !$fail, 'no error';
$worker = $minion->worker->register;
$job    = $worker->dequeue(0);
is $job->id, $result, 'right id';
is_deeply $job->args, [23], 'right arguments';
is $job->info->{priority}, 1, 'right priority';
ok $job->finish, 'job finished';
$worker->unregister;

# Failed jobs
$id = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue(0);
is $job->id, $id, 'right id';
is $job->info->{error}, undef, 'no error';
ok $job->fail, 'job failed';
ok !$job->finish, 'job not finished';
is $job->info->{state}, 'failed',        'right state';
is $job->info->{error}, 'Unknown error', 'right error';
$id = $minion->enqueue(add => [6, 7]);
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
ok $job->fail('Something bad happened!'), 'job failed';
is $job->info->{state}, 'failed', 'right state';
is $job->info->{error}, 'Something bad happened!', 'right error';
$id  = $minion->enqueue('fail');
$job = $worker->dequeue(0);
is $job->id, $id, 'right id';
$job->perform;
is $job->info->{state}, 'failed', 'right state';
is $job->info->{error}, "Intentional failure!\n", 'right error';
$worker->unregister;
$minion->reset;

done_testing();
