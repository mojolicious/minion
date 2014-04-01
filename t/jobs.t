use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mango::BSON qw(bson_oid bson_time);
use Minion;

# Clean up before start
my $minion = Minion->new($ENV{TEST_ONLINE});
is $minion->prefix, 'minion', 'right prefix';
my $workers = $minion->workers;
my $jobs    = $minion->prefix('jobs_test')->jobs;
is $jobs->name, 'jobs_test.jobs', 'right name';
$_->options && $_->drop for $workers, $jobs;

# Tasks
my $add = $jobs->insert({results => []});
$minion->add_task(
  add => sub {
    my ($job, $first, $second) = @_;
    my $doc = $job->minion->jobs->find_one($add);
    push @{$doc->{results}}, $first + $second;
    $job->minion->jobs->save($doc);
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
my $worker = $minion->worker->register;
is $minion->stats->{inactive_workers}, 1, 'one inactive worker';
$minion->enqueue('fail');
$minion->enqueue('fail');
is $minion->stats->{inactive_jobs}, 2, 'two inactive jobs';
my $job = $worker->dequeue;
$stats = $minion->stats;
is $stats->{active_workers}, 1, 'one active worker';
is $stats->{active_jobs},    1, 'one active job';
is $stats->{inactive_jobs},  1, 'one inactive job';
$job->finish;
is $minion->stats->{finished_jobs}, 1, 'one finished job';
$job = $worker->dequeue;
$job->fail;
is $minion->stats->{failed_jobs}, 1, 'one failed job';
$job->restart;
is $minion->stats->{failed_jobs}, 0, 'no failed jobs';
$worker->dequeue->finish;
$worker->unregister;
$stats = $minion->stats;
is $stats->{active_workers},   0, 'no active workers';
is $stats->{inactive_workers}, 0, 'no inactive workers';
is $stats->{active_jobs},      0, 'no active jobs';
is $stats->{failed_jobs},      0, 'one failed job';
is $stats->{finished_jobs},    2, 'one finished job';
is $stats->{inactive_jobs},    0, 'no inactive jobs';

# Enqueue, dequeue and perform
is $minion->job(bson_oid), undef, 'job does not exist';
my $oid = $minion->enqueue(add => [2, 2]);
my $doc = $jobs->find_one({task => 'add'});
is $doc->{_id}, $oid, 'right object id';
is_deeply $doc->{args}, [2, 2], 'right arguments';
ok $doc->{created}->to_epoch, 'has created timestamp';
is $doc->{priority}, 0,          'right priority';
is $doc->{state},    'inactive', 'right state';
$worker = $minion->worker;
is $worker->dequeue, undef, 'not registered';
$job = $worker->register->dequeue;
ok $jobs->find_one($job->id)->{started}->to_epoch, 'has started timestamp';
is_deeply $job->args, [2, 2], 'right arguments';
is $job->state, 'active', 'right state';
is $job->task,  'add',    'right task';
is $workers->find_one($jobs->find_one($job->id)->{worker})->{pid}, $$,
  'right worker';
$job->perform;
is_deeply $jobs->find_one($add)->{results}, [4], 'right result';
$doc = $jobs->find_one($job->id);
is $doc->{state}, 'finished', 'right state';
ok $doc->{finished}->to_epoch, 'has finished timestamp';
$worker->unregister;
$job = $minion->job($job->id);
is_deeply $job->args, [2, 2], 'right arguments';
is $job->state, 'finished', 'right state';
is $job->task,  'add',      'right task';

# Restart and remove
$oid = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue;
is $job->restarts, 0, 'job has not been restarted';
is $job->id, $oid, 'right object id';
$job->finish;
ok !$worker->dequeue, 'no more jobs';
is $minion->job($oid)->restart->state, 'inactive', 'right state';
is $minion->job($oid)->restarts, 1, 'job has been restarted once';
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
ok !$job->remove, 'job has not been removed';
is $job->fail->restart->restarts, 2, 'job has been restarted twice';
$job = $worker->dequeue;
is $job->state, 'active', 'right state';
ok $job->finish->remove, 'job has been removed';
is $job->state, undef, 'no state';
$oid = $minion->enqueue(add => [6, 5]);
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
ok $job->fail->remove, 'job has been removed';
is $job->state, undef, 'no state';
$oid = $minion->enqueue(add => [5, 5]);
$job = $minion->job($oid);
ok $job->remove, 'job has been removed';
$worker->unregister;

# Jobs with priority
$minion->enqueue(add => [1, 2]);
$oid = $minion->enqueue(add => [2, 4], {priority => 1});
$job = $worker->register->dequeue;
is $job->id, $oid, 'right object id';
$job->finish;
isnt $worker->dequeue->id, $oid, 'different object id';
$worker->unregister;

# Delayed jobs
$oid = $minion->enqueue(
  add => [2, 1] => {after => bson_time((time + 100) * 1000)});
is $worker->register->dequeue, undef, 'too early for job';
$doc = $jobs->find_one($oid);
$doc->{after} = bson_time((time - 100) * 1000);
$jobs->save($doc);
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
$job->finish;
$worker->unregister;

# Failed jobs
$oid = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue;
is $job->id, $oid, 'right object id';
is $job->error, undef, 'no error';
$job->fail->finish;
is $job->state, 'failed',         'right state';
is $job->error, 'Unknown error.', 'right error';
$oid = $minion->enqueue(add => [6, 7]);
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
$job->fail('Something bad happened!');
is $job->state, 'failed', 'right state';
is $job->error, 'Something bad happened!', 'right error';
$oid = $minion->enqueue('fail');
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
$job->perform;
is $job->state, 'failed', 'right state';
is $job->error, "Intentional failure!\n", 'right error';
$worker->unregister;

# Exit
$oid = $minion->enqueue('exit');
$job = $worker->register->dequeue;
is $job->id, $oid, 'right object id';
$job->perform;
is $job->state, 'failed', 'right state';
is $job->error, 'Non-zero exit status.', 'right error';
$worker->unregister;
$_->drop for $workers, $jobs;

done_testing();
