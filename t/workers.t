use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mango::BSON 'bson_time';
use Minion;
use Sys::Hostname 'hostname';

# Clean up before start
my $minion = Minion->new($ENV{TEST_ONLINE});
is $minion->prefix, 'minion', 'right prefix';
my $workers = $minion->prefix('workers_test')->workers;
is $workers->name, 'workers_test.workers', 'right name';
$_->options && $_->drop for $workers, $minion->jobs;

# Nothing to repair
my $worker = $minion->worker->repair;
isa_ok $worker->minion->app, 'Mojolicious', 'has default application';

# Register and unregister
$worker->register;
ok $workers->find_one({host => hostname, pid => $$, num => $worker->number})
  ->{started}->to_epoch, 'has timestamp';
ok !$worker->unregister->minion->workers->find_one(
  {pid => $$, num => $worker->number}), 'not registered';
ok $worker->register->minion->workers->find_one(
  {pid => $$, num => $worker->number}), 'is registered';
ok !$worker->unregister->minion->workers->find_one(
  {pid => $$, num => $worker->number}), 'not registered';

# Repair dead worker
$minion->add_task(test => sub { });
my $worker2 = $minion->worker->register;
isnt $worker2->number, $worker->number, 'new number';
my $oid = $minion->enqueue('test');
my $job = $worker2->dequeue;
is $job->doc->{_id}, $oid, 'right object id';
my $num = $worker2->number;
undef $worker2;
is $minion->jobs->find_one($oid)->{state}, 'active', 'job is still active';
my $doc = $workers->find_one({pid => $$, num => $num});
ok $doc, 'is registered';
my $pid = 4000;
$pid++ while kill 0, $pid;
$workers->save({%$doc, pid => $pid});
$worker->repair;
ok !$workers->find_one({pid => $$, num => $num}), 'not registered';
$doc = $minion->jobs->find_one($oid);
is $doc->{state}, 'failed',            'job is no longer active';
is $doc->{error}, 'Worker went away.', 'right error';

# Repair abandoned job
$worker->register;
$oid = $minion->enqueue('test');
$job = $worker->dequeue;
is $job->doc->{_id}, $oid, 'right object id';
$worker->unregister->repair;
$doc = $minion->jobs->find_one($oid);
is $doc->{state}, 'failed',            'job is no longer active';
is $doc->{error}, 'Worker went away.', 'right error';
$workers->drop;

done_testing();
