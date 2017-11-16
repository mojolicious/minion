package Minion::Command::minion::job;
use Mojo::Base 'Mojolicious::Command';

use Mojo::JSON 'decode_json';
use Mojo::Util qw(dumper getopt tablify);

has description => 'Manage Minion jobs';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  my ($args, $options) = ([], {});
  getopt \@args,
    'A|attempts=i'  => \$options->{attempts},
    'a|args=s'      => sub { $args = decode_json($_[1]) },
    'b|broadcast=s' => (\my $command),
    'd|delay=i'     => \$options->{delay},
    'e|enqueue=s'   => \my $enqueue,
    'f|foreground'  => \my $foreground,
    'l|limit=i'  => \(my $limit          = 100),
    'o|offset=i' => \(my $offset         = 0),
    'P|parent=s' => ($options->{parents} = []),
    'p|priority=i' => \$options->{priority},
    'q|queue=s'    => \$options->{queue},
    'R|retry'      => \my $retry,
    'remove'       => \my $remove,
    'S|state=s'    => \$options->{state},
    's|stats'      => \my $stats,
    't|task=s'     => \$options->{task},
    'w|workers'    => \my $workers;

  # Worker remote control command
  my $minion = $self->app->minion;
  return $minion->backend->broadcast($command, $args, \@args) if $command;

  # Enqueue
  return say $minion->enqueue($enqueue, $args, $options) if $enqueue;

  # Show stats
  return $self->_stats if $stats;

  # List jobs/workers
  my $id = @args ? shift @args : undef;
  return $id ? $self->_worker($id) : $self->_list_workers($offset, $limit)
    if $workers;
  return $self->_list_jobs($offset, $limit, $options) unless defined $id;
  die "Job does not exist.\n" unless my $job = $minion->job($id);

  # Remove job
  return $job->remove || die "Job is active.\n" if $remove;

  # Retry job
  return $job->retry($options) || die "Job is active.\n" if $retry;

  # Perform job in foreground
  return $minion->foreground($id) || die "Job is not ready.\n" if $foreground;

  # Job info
  print dumper Minion::_datetime($job->info);
}

sub _list_jobs {
  my $jobs = shift->app->minion->backend->list_jobs(@_)->{jobs};
  print tablify [map { [@$_{qw(id state queue task)}] } @$jobs];
}

sub _list_workers {
  my $workers = shift->app->minion->backend->list_workers(@_)->{workers};
  my @workers = map { [$_->{id}, $_->{host} . ':' . $_->{pid}] } @$workers;
  print tablify \@workers;
}

sub _stats { print dumper shift->app->minion->stats }

sub _worker {
  my $worker = shift->app->minion->backend->list_workers(0, 1, {ids => [shift]})
    ->{workers}[0];
  die "Worker does not exist.\n" unless $worker;
  print dumper Minion::_datetime($worker);
}

1;

=encoding utf8

=head1 NAME

Minion::Command::minion::job - Minion job command

=head1 SYNOPSIS

  Usage: APPLICATION minion job [OPTIONS] [IDS]

    ./myapp.pl minion job
    ./myapp.pl minion job 10023
    ./myapp.pl minion job -w
    ./myapp.pl minion job -w 23
    ./myapp.pl minion job -s
    ./myapp.pl minion job -f 10023
    ./myapp.pl minion job -q important -t foo -S inactive
    ./myapp.pl minion job -e foo -a '[23, "bar"]'
    ./myapp.pl minion job -e foo -P 10023 -P 10024 -p 5 -q important
    ./myapp.pl minion job -R -d 10 10023
    ./myapp.pl minion job --remove 10023
    ./myapp.pl minion job -b jobs -a '[12]'
    ./myapp.pl minion job -b jobs -a '[12]' 23 24 25

  Options:
    -A, --attempts <number>     Number of times performing this new job will be
                                attempted, defaults to 1
    -a, --args <JSON array>     Arguments for new job or worker remote control
                                command in JSON format
    -b, --broadcast <command>   Broadcast remote control command to one or more
                                workers
    -d, --delay <seconds>       Delay new job for this many seconds
    -e, --enqueue <task>        New job to be enqueued
    -f, --foreground            Retry job in "minion_foreground" queue and
                                perform it right away in the foreground (very
                                useful for debugging)
    -h, --help                  Show this summary of available options
        --home <path>           Path to home directory of your application,
                                defaults to the value of MOJO_HOME or
                                auto-detection
    -l, --limit <number>        Number of jobs/workers to show when listing
                                them, defaults to 100
    -m, --mode <name>           Operating mode for your application, defaults to
                                the value of MOJO_MODE/PLACK_ENV or
                                "development"
    -o, --offset <number>       Number of jobs/workers to skip when listing
                                them, defaults to 0
    -P, --parent <id>           One or more jobs the new job depends on
    -p, --priority <number>     Priority of new job, defaults to 0
    -q, --queue <name>          Queue to put new job in, defaults to "default",
                                or list only jobs in this queue
    -R, --retry                 Retry job
        --remove                Remove job
    -S, --state <name>          List only jobs in this state
    -s, --stats                 Show queue statistics
    -t, --task <name>           List only jobs for this task
    -w, --workers               List workers instead of jobs, or show
                                information for a specific worker

=head1 DESCRIPTION

L<Minion::Command::minion::job> manages the L<Minion> job queue.

=head1 ATTRIBUTES

L<Minion::Command::minion::job> inherits all attributes from
L<Mojolicious::Command> and implements the following new ones.

=head2 description

  my $description = $job->description;
  $job            = $job->description('Foo');

Short description of this command, used for the command list.

=head2 usage

  my $usage = $job->usage;
  $job      = $job->usage('Foo');

Usage information for this command, used for the help screen.

=head1 METHODS

L<Minion::Command::minion::job> inherits all methods from
L<Mojolicious::Command> and implements the following new ones.

=head2 run

  $job->run(@ARGV);

Run this command.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
