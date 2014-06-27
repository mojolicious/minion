use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

use File::Spec::Functions 'catfile';
use File::Temp 'tempdir';
use Minion;
use Mojo::IOLoop;
use Storable qw(retrieve store);
use Sys::Hostname 'hostname';

# Clean up before start
my $tmpdir = tempdir CLEANUP => 1;
my $file = catfile $tmpdir, 'minion.data';
my $minion = Minion->new(File => $file);
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
my $job = $worker2->dequeue;
is $job->id, $id, 'right id';
is $worker2->info->{jobs}[0], $job->id, 'right id';
$id = $worker2->id;
undef $worker2;
is $job->info->{state}, 'active', 'job is still active';
my $guard = $minion->backend->_guard->_write;
my $info  = $guard->_workers->{$id};
ok $info, 'is registered';
my $pid = 4000;
$pid++ while kill 0, $pid;
$info->{pid} = $pid;
undef $guard;
$minion->repair;
ok !$minion->worker->id($id)->info, 'not registered';
is $job->info->{state}, 'failed',           'job is no longer active';
is $job->info->{error}, 'Worker went away', 'right error';

# Repair abandoned job
$worker->register;
$id  = $minion->enqueue('test');
$job = $worker->dequeue;
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
$worker->dequeue->perform for 1 .. 3;
$guard = $minion->backend->_guard->_write;
$guard->_jobs->{$id2}{finished} -= 864001;
$guard->_jobs->{$id3}{finished} -= 864001;
undef $guard;
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
ok !keys %{$minion->backend->_guard->_jobs},    'no jobs';
ok !keys %{$minion->backend->_guard->_workers}, 'no workers';

# Tasks
my $results = catfile $tmpdir, 'results.data';
store [], $results;
$minion->add_task(
  add => sub {
    my ($job, $first, $second) = @_;
    my $result = retrieve $results;
    push @$result, $first + $second;
    store $result, $results;
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
$job   = $worker->dequeue;
$stats = $minion->stats;
is $stats->{active_workers}, 1, 'one active worker';
is $stats->{active_jobs},    1, 'one active job';
is $stats->{inactive_jobs},  1, 'one inactive job';
$minion->enqueue('fail');
my $job2 = $worker->dequeue;
$stats = $minion->stats;
is $stats->{active_workers}, 1, 'one active worker';
is $stats->{active_jobs},    2, 'two active jobs';
is $stats->{inactive_jobs},  1, 'one inactive job';
ok $job2->finish, 'job finished';
ok $job->finish,  'job finished';
is $minion->stats->{finished_jobs}, 2, 'two finished jobs';
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
is $stats->{failed_jobs},      0, 'no failed jobs';
is $stats->{finished_jobs},    3, 'three finished jobs';
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
is $batch->[2]{task},     'fail', 'right task';
is $batch->[2]{state},    'finished', 'right state';
is $batch->[2]{restarts}, 0, 'job has not been restarted';
ok !$batch->[3], 'no more results';
$batch = $minion->backend->list_jobs(0, 1);
is $batch->[0]{restarts}, 1, 'job has been restarted';
ok !$batch->[1], 'no more results';
$batch = $minion->backend->list_jobs(1, 1);
is $batch->[0]{restarts}, 0, 'job has not been restarted';
ok !$batch->[1], 'no more results';

# Enqueue, dequeue and perform
is $minion->job(12345), undef, 'job does not exist';
$id = $minion->enqueue(add => [2, 2]);
ok $minion->job($id), 'job does exist';
$info = $minion->job($id)->info;
is_deeply $info->{args}, [2, 2], 'right arguments';
is $info->{priority}, 0,          'right priority';
is $info->{state},    'inactive', 'right state';
$worker = $minion->worker;
my $before = (stat $minion->backend->file)[9];
is $worker->dequeue, undef, 'not registered';
is $before, (stat $minion->backend->file)[9], 'file has not changed';
ok !$minion->job($id)->info->{started}, 'no started timestamp';
$job = $worker->register->dequeue;
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
is_deeply retrieve($results), [4], 'right result';
is $job->info->{state}, 'finished', 'right state';
$worker->unregister;
$job = $minion->job($job->id);
is_deeply $job->args, [2, 2], 'right arguments';
is $job->info->{state}, 'finished', 'right state';
is $job->task, 'add', 'right task';

# Restart and remove
$id = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue;
is $job->info->{restarts}, 0, 'job has not been restarted';
is $job->id, $id, 'right id';
ok $job->finish, 'job finished';
ok !$worker->dequeue, 'no more jobs';
$job = $minion->job($id);
ok !$job->info->{restarted}, 'no restarted timestamp';
ok $job->restart, 'job restarted';
like $job->info->{restarted}, qr/^[\d.]+$/, 'has restarted timestamp';
is $job->info->{state},       'inactive',   'right state';
is $job->info->{restarts},    1,            'job has been restarted once';
$job = $worker->dequeue;
ok !$job->restart, 'job not restarted';
is $job->id, $id, 'right id';
ok !$job->remove, 'job has not been removed';
ok $job->fail,    'job failed';
ok $job->restart, 'job restarted';
is $job->info->{restarts}, 2, 'job has been restarted twice';
ok !$job->info->{finished}, 'no finished timestamp';
ok !$job->info->{started},  'no started timestamp';
ok !$job->info->{error},    'no error';
ok !$job->info->{worker},   'no worker';
$job = $worker->dequeue;
is $job->info->{state}, 'active', 'right state';
ok $job->finish, 'job finished';
ok $job->remove, 'job has been removed';
is $job->info,   undef, 'no information';
$id = $minion->enqueue(add => [6, 5]);
$job = $worker->dequeue;
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
$job = $worker->register->dequeue;
is $job->id, $id, 'right id';
is $job->info->{priority}, 1, 'right priority';
ok $job->finish, 'job finished';
isnt $worker->dequeue->id, $id, 'different id';
$worker->unregister;

# Delayed jobs
$id = $minion->enqueue(add => [2, 1] => {delay => 100});
is $worker->register->dequeue, undef, 'too early for job';
ok $minion->job($id)->info->{delayed} > time, 'delayed timestamp';
$guard           = $minion->backend->_guard->_write;
$info            = $guard->_jobs->{$id};
$info->{delayed} = time - 100;
undef $guard;
$job = $worker->dequeue;
is $job->id, $id, 'right id';
like $job->info->{delayed}, qr/^[\d.]+$/, 'has delayed timestamp';
ok $job->finish,  'job finished';
ok $job->restart, 'job restarted';
ok $minion->job($id)->info->{delayed} < time, 'no delayed timestamp';
ok $job->remove, 'job removed';
ok !$job->restart, 'job not restarted';
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
$job    = $worker->dequeue;
is $job->id, $result, 'right id';
is_deeply $job->args, [23], 'right arguments';
is $job->info->{priority}, 1, 'right priority';
ok $job->finish, 'job finished';
$worker->unregister;

# Events
$pid = $$;
my ($failed, $finished) = (0, 0);
$minion->on(
  worker => sub {
    my ($minion, $worker) = @_;
    $worker->on(
      dequeue => sub {
        my ($worker, $job) = @_;
        $job->on(failed   => sub { $failed++ });
        $job->on(finished => sub { $finished++ });
        $job->on(spawn    => sub { $pid = pop });
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
$job->perform;
is $failed,   0, 'failed event has not been emitted';
is $finished, 1, 'finished event has been emitted once';
isnt $pid, $$, 'new process id';
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
$id = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue;
is $job->id, $id, 'right id';
is $job->info->{error}, undef, 'no error';
ok $job->fail, 'job failed';
ok !$job->finish, 'job not finished';
is $job->info->{state}, 'failed',        'right state';
is $job->info->{error}, 'Unknown error', 'right error';
$id = $minion->enqueue(add => [6, 7]);
$job = $worker->dequeue;
is $job->id, $id, 'right id';
ok $job->fail('Something bad happened!'), 'job failed';
is $job->info->{state}, 'failed', 'right state';
is $job->info->{error}, 'Something bad happened!', 'right error';
$id  = $minion->enqueue('fail');
$job = $worker->dequeue;
is $job->id, $id, 'right id';
$job->perform;
is $job->info->{state}, 'failed', 'right state';
is $job->info->{error}, "Intentional failure!\n", 'right error';
$worker->unregister;

# Exit
$minion->add_task(exit => sub { exit 1 });
$id  = $minion->enqueue('exit');
$job = $worker->register->dequeue;
is $job->id, $id, 'right id';
$job->perform;
is $job->info->{state}, 'failed', 'right state';
is $job->info->{error}, 'Non-zero exit status', 'right error';
$worker->unregister;
$minion->reset;

done_testing();
