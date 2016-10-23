use Mojo::Base -strict;

use Minion;
use Time::HiRes 'time';

my $ENQUEUE     = 10000;
my $DEQUEUE     = 1000;
my $REPETITIONS = 2;
my $WORKERS     = 4;
my $STATS       = 100;
my $REPAIR      = 100;
my $INFO        = 100;

# A benchmark script for comparing backends and evaluating the performance
# impact of proposed changes
my $minion = Minion->new(Pg => 'postgresql://tester:testing@/test');
$minion->add_task(foo => sub { });
$minion->add_task(bar => sub { });
$minion->reset;

# Enqueue
say "Clean start with $ENQUEUE jobs";
my $before = time;
$minion->enqueue($_ % 2 ? 'foo' : 'bar') for 1 .. $ENQUEUE;
my $elapsed = time - $before;
my $avg = sprintf '%.3f', $ENQUEUE / $elapsed;
say "Enqueued $ENQUEUE jobs in $elapsed seconds ($avg/s)";

# Dequeue
sub dequeue {
  my @pids;
  for (1 .. $WORKERS) {
    die "Couldn't fork: $!" unless defined(my $pid = fork);
    unless ($pid) {
      my $worker = $minion->worker->register;
      say "$$ will finish $DEQUEUE jobs";
      my $before = time;
      $worker->dequeue(0.5)->finish for 1 .. $DEQUEUE;
      my $elapsed = time - $before;
      my $avg = sprintf '%.3f', $DEQUEUE / $elapsed;
      say "$$ finished $DEQUEUE jobs in $elapsed seconds ($avg/s)";
      $worker->unregister;
      exit;
    }
    push @pids, $pid;
  }

  say "$$ has started $WORKERS workers";
  my $before = time;
  waitpid $_, 0 for @pids;
  my $elapsed = time - $before;
  my $avg = sprintf '%.3f', ($DEQUEUE * $WORKERS) / $elapsed;
  say
    "$WORKERS workers finished $DEQUEUE jobs each in $elapsed seconds ($avg/s)";
}
dequeue() for 1 .. $REPETITIONS;

# Stats
say "Requesting stats $STATS times";
$before = time;
$minion->stats for 1 .. $STATS;
$elapsed = time - $before;
$avg = sprintf '%.3f', $STATS / $elapsed;
say "Received stats $STATS times in $elapsed seconds ($avg/s)";

# Repair
say "Repairing $REPAIR times";
$before = time;
$minion->repair for 1 .. $REPAIR;
$elapsed = time - $before;
$avg = sprintf '%.3f', $REPAIR / $elapsed;
say "Repaired $REPAIR times in $elapsed seconds ($avg/s)";

# Job info
say "Requesting job info $INFO times";
$before = time;
my $backend = $minion->backend;
$backend->job_info($ENQUEUE) for 1 .. $INFO;
$elapsed = time - $before;
$avg = sprintf '%.3f', $INFO / $elapsed;
say "Received job info $INFO times in $elapsed seconds ($avg/s)";
