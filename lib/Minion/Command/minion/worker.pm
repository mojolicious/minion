package Minion::Command::minion::worker;
use Mojo::Base 'Mojolicious::Command';

use Mojo::Util qw(getopt steady_time);

has description => 'Start Minion worker';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  my $app    = $self->app;
  my $worker = $self->{worker} = $app->minion->worker;
  my $status = $worker->status;
  $status->{performed} //= 0;

  getopt \@args,
    'C|command-interval=i'   => \($status->{command_interval}   //= 10),
    'f|fast-start'           => \my $fast,
    'I|heartbeat-interval=i' => \($status->{heartbeat_interval} //= 300),
    'j|jobs=i'               => \($status->{jobs}               //= 4),
    'q|queue=s'              => ($status->{queues}              //= []),
    'R|repair-interval=i'    => \($status->{repair_interval}    //= 21600);
  @{$status->{queues}} = ('default') unless @{$status->{queues}};
  $status->{repair_interval} -= int rand $status->{repair_interval} / 2;
  $self->{last_repair} = $fast ? steady_time : 0;

  local $SIG{CHLD} = sub { };
  local $SIG{INT} = local $SIG{TERM} = sub { $self->{finished}++ };
  local $SIG{QUIT}
    = sub { ++$self->{finished} and kill 'KILL', keys %{$self->{jobs}} };

  # Remote control commands need to validate arguments carefully
  $worker->add_command(
    jobs => sub { $status->{jobs} = $_[1] if ($_[1] // '') =~ /^\d+$/ });
  $worker->add_command(
    stop => sub { $self->{jobs}{$_[1]}->stop if $self->{jobs}{$_[1] // ''} });

  # Log fatal errors
  my $log = $app->log;
  $log->info("Worker $$ started");
  eval { $self->_work until $self->{finished} && !keys %{$self->{jobs}}; 1 }
    or $log->fatal("Worker error: $@");
  $worker->unregister;
  $log->info("Worker $$ stopped");
}

sub _work {
  my $self = shift;

  # Send heartbeats in regular intervals
  my $worker = $self->{worker};
  my $status = $worker->status;
  $self->{last_heartbeat} ||= -$status->{heartbeat_interval};
  $worker->register and $self->{last_heartbeat} = steady_time
    if ($self->{last_heartbeat} + $status->{heartbeat_interval}) < steady_time;

  # Process worker remote control commands in regular intervals
  $self->{last_command} ||= 0;
  $worker->process_commands and $self->{last_command} = steady_time
    if ($self->{last_command} + $status->{command_interval}) < steady_time;

  # Repair in regular intervals (randomize to avoid congestion)
  my $app = $self->app;
  my $log = $app->log;
  if (($self->{last_repair} + $status->{repair_interval}) < steady_time) {
    $log->debug('Checking worker registry and job queue');
    $app->minion->repair;
    $self->{last_repair} = steady_time;
  }

  # Check if jobs are finished
  my $jobs = $self->{jobs} ||= {};
  $jobs->{$_}->is_finished and ++$status->{performed} and delete $jobs->{$_}
    for keys %$jobs;

  # Wait if job limit has been reached or worker is stopping
  if (($status->{jobs} <= keys %$jobs) || $self->{finished}) { sleep 1 }

  # Try to get more jobs
  elsif (my $job = $worker->dequeue(5 => {queues => $status->{queues}})) {
    $jobs->{my $id = $job->id} = $job->start;
    my ($pid, $task) = ($job->pid, $job->task);
    $log->debug(qq{Process $pid is performing job "$id" with task "$task"});
  }
}

1;

=encoding utf8

=head1 NAME

Minion::Command::minion::worker - Minion worker command

=head1 SYNOPSIS

  Usage: APPLICATION minion worker [OPTIONS]

    ./myapp.pl minion worker
    ./myapp.pl minion worker -f
    ./myapp.pl minion worker -m production -I 15 -C 5 -R 3600 -j 10
    ./myapp.pl minion worker -q important -q default

  Options:
    -C, --command-interval <seconds>     Worker remote control command interval,
                                         defaults to 10
    -f, --fast-start                     Start processing jobs as fast as
                                         possible and skip repairing on startup
    -h, --help                           Show this summary of available options
        --home <path>                    Path to home directory of your
                                         application, defaults to the value of
                                         MOJO_HOME or auto-detection
    -I, --heartbeat-interval <seconds>   Heartbeat interval, defaults to 300
    -j, --jobs <number>                  Maximum number of jobs to perform
                                         parallel in forked worker processes,
                                         defaults to 4
    -m, --mode <name>                    Operating mode for your application,
                                         defaults to the value of
                                         MOJO_MODE/PLACK_ENV or "development"
    -q, --queue <name>                   One or more queues to get jobs from,
                                         defaults to "default"
    -R, --repair-interval <seconds>      Repair interval, up to half of this
                                         value can be subtracted randomly to
                                         make sure not all workers repair at the
                                         same time, defaults to 21600 (6 hours)

=head1 DESCRIPTION

L<Minion::Command::minion::worker> starts a L<Minion> worker. You can have as
many workers as you like.

=head1 SIGNALS

The L<Minion::Command::minion::worker> process can be controlled at runtime
with the following signals.

=head2 INT, TERM

Stop gracefully after finishing the current jobs.

=head2 QUIT

Stop immediately without finishing the current jobs.

=head1 REMOTE CONTROL COMMANDS

The L<Minion::Command::minion::worker> process can be controlled at runtime
through L<Minion::Command::minion::job>, from anywhere in the network, by
broadcasting the following remote control commands.

=head2 jobs

  $ ./myapp.pl minion job -b jobs -a '[10]'
  $ ./myapp.pl minion job -b jobs -a '[10]' 23

Instruct one or more workers to change the number of jobs to perform
concurrently. Setting this value to C<0> will effectively pause the worker. That
means all current jobs will be finished, but no new ones accepted, until the
number is increased again.

=head2 stop

  $ ./myapp.pl minion job -b stop -a '[10025]'
  $ ./myapp.pl minion job -b stop -a '[10025]' 23

Instruct one or more workers to stop a job that is currently being performed
immediately. This command will be ignored by workers that do not have a job
matching the id. That means it is safe to broadcast this command to all workers.

=head1 ATTRIBUTES

L<Minion::Command::minion::worker> inherits all attributes from
L<Mojolicious::Command> and implements the following new ones.

=head2 description

  my $description = $worker->description;
  $worker         = $worker->description('Foo');

Short description of this command, used for the command list.

=head2 usage

  my $usage = $worker->usage;
  $worker   = $worker->usage('Foo');

Usage information for this command, used for the help screen.

=head1 METHODS

L<Minion::Command::minion::worker> inherits all methods from
L<Mojolicious::Command> and implements the following new ones.

=head2 run

  $worker->run(@ARGV);

Run this command.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
