package Minion::Command::minion::worker;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use Mojo::Util 'steady_time';

has description => 'Start Minion worker';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  GetOptionsFromArray \@args,
    'I|heartbeat-interval=i' => \($self->{hearthbeat} = 60),
    'j|jobs=i'               => \($self->{max}        = 4),
    'q|queue=s'              => \my @queues,
    'R|repair-interval=i'    => \($self->{repair}     = 21600);
  $self->{queues} = @queues ? \@queues : ['default'];

  local $SIG{CHLD} = 'DEFAULT';
  local $SIG{INT} = local $SIG{TERM} = sub { $self->{finished}++ };
  local $SIG{QUIT}
    = sub { ++$self->{finished} and kill 'KILL', keys %{$self->{jobs}} };
  local $SIG{TTIN} = sub { $self->{max}++ };
  local $SIG{TTOU} = sub { $self->{max}-- if $self->{max} > 0 };
  local $SIG{USR1} = sub { $self->{max} = 0 };

  # Log fatal errors
  my $app = $self->app;
  $app->log->debug("Worker $$ started");
  my $worker = $self->{worker} = $app->minion->worker;
  eval { $self->_work until $self->{finished} && !keys %{$self->{jobs}}; 1 }
    or $app->log->fatal("Worker error: $@");
  $worker->unregister;
}

sub _work {
  my $self = shift;

  # Send heartbeats in regular intervals
  my $worker = $self->{worker};
  $worker->register and $self->{register} = steady_time + $self->{hearthbeat}
    if ($self->{register} || 0) < steady_time;

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
  $jobs->{$_}->is_finished($_) and delete $jobs->{$_} for keys %$jobs;

  # Wait if job limit has been reached or worker is stopping
  if (($self->{max} <= keys %$jobs) || $self->{finished}) { sleep 1 }

  # Try to get more jobs
  elsif (my $job = $worker->dequeue(5 => {queues => $self->{queues}})) {
    $jobs->{my $pid = $job->start} = $job;
    my ($id, $task) = ($job->id, $job->task);
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
    ./myapp.pl minion worker -m production -I 15 -R 3600 -j 10
    ./myapp.pl minion worker -q important -q default

  Options:
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

=head2 TTIN

Increase the number of jobs to perform concurrently by one.

=head2 TTOU

Decrease the number of jobs to perform concurrently by one.

=head2 USR1

Set the number of jobs to perform concurrently to C<0>, effectively pausing the
worker. That means it will finish all current jobs, but not accept new ones.

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
