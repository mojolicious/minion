package Minion::Command::minion::worker;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use Mojo::Util 'steady_time';

has description => 'Start Minion worker';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  GetOptionsFromArray \@args,
    'I|heartbeat-interval=i' => \($self->{interval} = 60),
    'j|jobs=i'               => \($self->{max}      = 4),
    'q|queue=s'              => ($self->{queues}    = []);
  $self->{queues} = ['default'] unless @{$self->{queues}};

  local $SIG{CHLD} = 'DEFAULT';
  local $SIG{INT} = local $SIG{TERM} = sub { $self->{finished}++ };

  # Log fatal errors
  my $app = $self->app;
  my $worker = $self->{worker} = $app->minion->worker;
  @$self{qw(register repair)} = (0, 0);
  eval { $self->_work until $self->{finished} && !keys %{$self->{jobs}}; 1 }
    or $app->log->fatal("Worker error: $@");
  $worker->unregister;
}

sub _work {
  my $self = shift;

  # Send heartbeats in regular intervals
  my $worker = $self->{worker};
  $worker->register and $self->{register} = steady_time + $self->{interval}
    if $self->{register} < steady_time;

  # Repair in regular intervals
  if ($self->{repair} < steady_time) {
    my $app = $self->app;
    $app->log->debug('Checking worker registry and job queue');
    my $minion = $app->minion;
    $minion->repair;
    $self->{repair} = steady_time + $minion->missing_after;
  }

  # Check if jobs are finished
  my $jobs = $self->{jobs} ||= {};
  $jobs->{$_}->is_finished($_) and delete $jobs->{$_} for keys %$jobs;

  # Wait if job limit has been reached or worker is stopping
  if (($self->{max} <= keys %$jobs) || $self->{finished}) { sleep 1 }

  # Try to get more jobs
  elsif (my $job = $worker->dequeue(5 => {queues => $self->{queues}})) {
    $jobs->{$job->start} = $job;
  }
}

1;

=encoding utf8

=head1 NAME

Minion::Command::minion::worker - Minion worker command

=head1 SYNOPSIS

  Usage: APPLICATION minion worker [OPTIONS]

    ./myapp.pl minion worker
    ./myapp.pl minion worker -m production -I 15 -j 10
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

=head1 DESCRIPTION

L<Minion::Command::minion::worker> starts a L<Minion> worker. You can have as
many workers as you like.

=head1 SIGNALS

The L<Minion::Command::minion::worker> process can be controlled at runtime
with the following signals.

=head2 INT, TERM

Stop gracefully after finishing the current jobs.

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
