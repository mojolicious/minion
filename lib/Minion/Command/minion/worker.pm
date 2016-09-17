package Minion::Command::minion::worker;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use Mojo::Util 'steady_time';

has description => 'Start Minion worker';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  GetOptionsFromArray \@args,
    'C|command-interval=i'   => \($self->{commands}   = 10),
    'I|heartbeat-interval=i' => \($self->{hearthbeat} = 60),
    'j|jobs=i'               => \($self->{max}        = 4),
    'q|queue=s'              => \my @queues,
    'R|repair-interval=i'    => \($self->{repair}     = 21600);
  $self->{queues} = @queues ? \@queues : ['default'];

  local $SIG{CHLD} = 'DEFAULT';
  local $SIG{INT} = local $SIG{TERM} = sub { $self->{finished}++ };
  local $SIG{QUIT}
    = sub { ++$self->{finished} and kill 'KILL', keys %{$self->{jobs}} };

  # Remote control commands need to validate arguments carefully
  my $app = $self->app;
  my $worker = $self->{worker} = $app->minion->worker;
  $worker->add_command(
    jobs => sub { $self->{max} = $_[1] if ($_[1] // '') =~ /^\d+$/ });
  $worker->add_command(
    stop => sub { $self->{jobs}{$_[1]}->stop if $self->{jobs}{$_[1] // ''} });

  # Log fatal errors
  $app->log->debug("Worker $$ started");
  eval { $self->_work until $self->{finished} && !keys %{$self->{jobs}}; 1 }
    or $app->log->fatal("Worker error: $@");
  $worker->unregister;
}

sub _work {
  my $self = shift;

  # Send heartbeats in regular intervals
  my $worker = $self->{worker};
  $worker->register and $self->{lr} = steady_time + $self->{hearthbeat}
    if ($self->{lr} || 0) < steady_time;

  # Process worker remote control commands in regular intervals
  $worker->process_commands and $self->{lp} = steady_time + $self->{commands}
    if ($self->{lp} || 0) < steady_time;

  # Repair in regular intervals (randomize to avoid congestion)
  if (($self->{check} || 0) < steady_time) {
    my $app = $self->app;
    $app->log->debug('Checking worker registry and job queue');
    $app->minion->repair;
    $self->{check}
      = steady_time + ($self->{repair} - int rand $self->{repair} / 2);
  }

  # Check if jobs are finished
  my $jobs = $self->{jobs} ||= {};
  $jobs->{$_}->is_finished and delete $jobs->{$_} for keys %$jobs;

  # Wait if job limit has been reached or worker is stopping
  if (($self->{max} <= keys %$jobs) || $self->{finished}) { sleep 1 }

  # Try to get more jobs
  elsif (my $job = $worker->dequeue(5 => {queues => $self->{queues}})) {
    $jobs->{my $id = $job->id} = $job->start;
    my ($pid, $task) = ($job->pid, $job->task);
    $self->app->log->debug(
      qq{Performing job "$id" with task "$task" in process $pid});
  }
}

1;

=encoding utf8

=head1 NAME

Minion::Command::minion::worker - Minion worker command

=head1 SYNOPSIS

  Usage: APPLICATION minion worker [OPTIONS]

    ./myapp.pl minion worker
    ./myapp.pl minion worker -m production -I 15 -C 5 -R 3600 -j 10
    ./myapp.pl minion worker -q important -q default

  Options:
    -C, --command-interval <seconds>     Worker remote control command interval,
                                         defaults to 10
    -h, --help                           Show this summary of available options
        --home <path>                    Path to home directory of your
                                         application, defaults to the value of
                                         MOJO_HOME or auto-detection
    -I, --heartbeat-interval <seconds>   Heartbeat interval, defaults to 60
    -j, --jobs <number>                  Number of jobs to perform
                                         concurrently, defaults to 4
    -m, --mode <name>                    Operating mode for your application,
                                         defaults to the value of
                                         MOJO_MODE/PLACK_ENV or "development"
    -q, --queue <name>                   One or more queues to get jobs from,
                                         defaults to "default"
    -R, --repair-interval <seconds>      Repair interval, defaults to 21600
                                         (6 hours)

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
with the following remote control commands.

=head2 jobs

  $ ./myapp.pl minion job -b jobs -a '[10]'
  $ ./myapp.pl minion job -b jobs -a '[10]' 23

Change the number of jobs to perform concurrently. Setting this value to C<0>
will effectively pause the worker. That means all current jobs will be finished,
but no new ones accepted, until the number is increased again.

=head2 stop

  $ ./myapp.pl minion job -b stop -a '[10025]'
  $ ./myapp.pl minion job -b stop -a '[10025]' 23

Stop a job that is currently being performed immediately.

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
