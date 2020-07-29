package Minion::Command::minion::worker;
use Mojo::Base 'Mojolicious::Command';

use Mojo::Util qw(getopt);

has description => 'Start Minion worker';
has usage       => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  my $worker = $self->app->minion->worker;
  my $status = $worker->status;
  getopt \@args,
    'C|command-interval=i'   => \$status->{command_interval},
    'D|dequeue-timeout=i'    => \$status->{dequeue_timeout},
    'I|heartbeat-interval=i' => \$status->{heartbeat_interval},
    'j|jobs=i'               => \$status->{jobs},
    'q|queue=s'              => \my @queues,
    'R|repair-interval=i'    => \$status->{repair_interval};
  $status->{queues} = \@queues if @queues;

  my $log = $self->app->log;
  $log->info("Worker $$ started");
  $worker->on(dequeue => sub { pop->once(spawn => \&_spawn) });
  $worker->run;
  $log->info("Worker $$ stopped");
}

sub _spawn {
  my ($job, $pid)  = @_;
  my ($id,  $task) = ($job->id, $job->task);
  $job->app->log->debug(qq{Process $pid is performing job "$id" with task "$task"});
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
    -D, --dequeue-timeout <seconds>      Maximum amount of time to wait for
                                         jobs, defaults to 5
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

L<Minion::Command::minion::worker> starts a L<Minion> worker. You can have as many workers as you like.

=head1 WORKER SIGNALS

The L<Minion::Command::minion::worker> process can be controlled at runtime with the following signals.

=head2 INT, TERM

Stop gracefully after finishing the current jobs.

=head2 QUIT

Stop immediately without finishing the current jobs.

=head1 JOB SIGNALS

The job processes spawned by the L<Minion::Command::minion::worker> process can be controlled at runtime with the
following signals.

=head2 INT, TERM

This signal starts out with the operating system default and allows for jobs to install a custom signal handler to stop
gracefully.

=head2 USR1, USR2

These signals start out being ignored and allow for jobs to install custom signal handlers.

=head1 REMOTE CONTROL COMMANDS

The L<Minion::Command::minion::worker> process can be controlled at runtime through L<Minion::Command::minion::job>,
from anywhere in the network, by broadcasting the following remote control commands.

=head2 jobs

  $ ./myapp.pl minion job -b jobs -a '[10]'
  $ ./myapp.pl minion job -b jobs -a '[10]' 23

Instruct one or more workers to change the number of jobs to perform concurrently. Setting this value to C<0> will
effectively pause the worker. That means all current jobs will be finished, but no new ones accepted, until the number
is increased again.

=head2 kill

  $ ./myapp.pl minion job -b kill -a '["INT", 10025]'
  $ ./myapp.pl minion job -b kill -a '["INT", 10025]' 23

Instruct one or more workers to send a signal to a job that is currently being performed. This command will be ignored
by workers that do not have a job matching the id. That means it is safe to broadcast this command to all workers.

=head2 stop

  $ ./myapp.pl minion job -b stop -a '[10025]'
  $ ./myapp.pl minion job -b stop -a '[10025]' 23

Instruct one or more workers to stop a job that is currently being performed immediately. This command will be ignored
by workers that do not have a job matching the id. That means it is safe to broadcast this command to all workers.

=head1 ATTRIBUTES

L<Minion::Command::minion::worker> inherits all attributes from L<Mojolicious::Command> and implements the following
new ones.

=head2 description

  my $description = $worker->description;
  $worker         = $worker->description('Foo');

Short description of this command, used for the command list.

=head2 usage

  my $usage = $worker->usage;
  $worker   = $worker->usage('Foo');

Usage information for this command, used for the help screen.

=head1 METHODS

L<Minion::Command::minion::worker> inherits all methods from L<Mojolicious::Command> and implements the following new
ones.

=head2 run

  $worker->run(@ARGV);

Run this command.

=head1 SEE ALSO

L<Minion>, L<https://minion.pm>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
