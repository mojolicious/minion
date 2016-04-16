package Minion::Command::minion::job;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use Mojo::Date;
use Mojo::JSON 'decode_json';
use Mojo::Util qw(dumper tablify);

has description => 'Manage Minion jobs';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  my ($args, $options) = ([], {});
  GetOptionsFromArray \@args,
    'A|attempts=i' => \$options->{attempts},
    'a|args=s'     => sub { $args = decode_json($_[1]) },
    'd|delay=i'    => \$options->{delay},
    'e|enqueue=s'  => \my $enqueue,
    'l|limit=i'  => \(my $limit  = 100),
    'o|offset=i' => \(my $offset = 0),
    'p|priority=i' => \$options->{priority},
    'q|queue=s'    => \$options->{queue},
    'R|retry'      => \my $retry,
    'r|remove'     => \my $remove,
    'S|state=s'    => \$options->{state},
    's|stats'      => \my $stats,
    't|task=s'     => \$options->{task},
    'w|workers'    => \my $workers;
  my $id = @args ? shift @args : undef;

  # Enqueue
  return say $self->app->minion->enqueue($enqueue, $args, $options) if $enqueue;

  # Show stats or list jobs/workers
  return $self->_stats if $stats;
  return $self->_list_workers($offset, $limit) if $workers;
  return $self->_list_jobs($offset, $limit, $options) unless defined $id;
  die "Job does not exist.\n" unless my $job = $self->app->minion->job($id);

  # Remove job
  return $job->remove || die "Job is active.\n" if $remove;

  # Retry job
  return $job->retry($options) || die "Job is active.\n" if $retry;

  # Job info
  $self->_info($job);
}

sub _date { Mojo::Date->new(@_)->to_datetime }

sub _info {
  my ($self, $job) = @_;

  # Details
  my $info = $job->info;
  my ($queue, $state, $priority, $retries)
    = @$info{qw(queue state priority retries)};
  say $info->{task}, " ($queue, $state, p$priority, r$retries)";
  print dumper $info->{args};
  if (my $result = $info->{result}) { print dumper $result }

  # Timing
  my ($created, $delayed) = @$info{qw(created delayed)};
  say _date($created), ' (created)';
  say _date($delayed), ' (delayed)' if $delayed > $created;
  $info->{$_} and say _date($info->{$_}), " ($_)"
    for qw(retried started finished);
}

sub _list_jobs {
  my $jobs = shift->app->minion->backend->list_jobs(@_);
  print tablify [map { [@$_{qw(id state queue task)}] } @$jobs];
}

sub _list_workers {
  my $workers = shift->app->minion->backend->list_workers(@_);
  print tablify [map { [_worker($_)] } @$workers];
}

sub _stats {
  my $stats = shift->app->minion->stats;
  say "Inactive workers: $stats->{inactive_workers}";
  say "Active workers:   $stats->{active_workers}";
  say "Inactive jobs:    $stats->{inactive_jobs}";
  say "Active jobs:      $stats->{active_jobs}";
  say "Failed jobs:      $stats->{failed_jobs}";
  say "Finished jobs:    $stats->{finished_jobs}";
}

sub _worker {
  my $worker = shift;
  my $state  = @{$worker->{jobs}} ? 'active' : 'inactive';
  my $name   = $worker->{host} . ':' . $worker->{pid};
  return $worker->{id}, $state, $name, _date($worker->{notified});
}

1;

=encoding utf8

=head1 NAME

Minion::Command::minion::job - Minion job command

=head1 SYNOPSIS

  Usage: APPLICATION minion job [OPTIONS] [ID]

    ./myapp.pl minion job
    ./myapp.pl minion job -t foo -S inactive
    ./myapp.pl minion job -e foo -a '[23, "bar"]'
    ./myapp.pl minion job -e foo -p 5 -q important
    ./myapp.pl minion job -s
    ./myapp.pl minion job -w -l 5
    ./myapp.pl minion job 10023
    ./myapp.pl minion job -R -d 10 10023
    ./myapp.pl minion job -r 10023

  Options:
    -A, --attempts <number>   Number of times performing this job will be
                              attempted, defaults to 1
    -a, --args <JSON array>   Arguments for new job in JSON format
    -d, --delay <seconds>     Delay new job for this many seconds
    -e, --enqueue <name>      New job to be enqueued
    -h, --help                Show this summary of available options
        --home <path>         Path to home directory of your application,
                              defaults to the value of MOJO_HOME or
                              auto-detection
    -l, --limit <number>      Number of jobs/workers to show when listing them,
                              defaults to 100
    -m, --mode <name>         Operating mode for your application, defaults to
                              the value of MOJO_MODE/PLACK_ENV or "development"
    -o, --offset <number>     Number of jobs/workers to skip when listing them,
                              defaults to 0
    -p, --priority <number>   Priority of new job, defaults to 0
    -q, --queue <name>        Queue to put job in, defaults to "default"
    -R, --retry               Retry job
    -r, --remove              Remove job
    -S, --state <state>       List only jobs in this state
    -s, --stats               Show queue statistics
    -t, --task <name>         List only jobs for this task
    -w, --workers             List workers instead of jobs

=head1 DESCRIPTION

L<Minion::Command::minion::job> manages L<Minion> jobs.

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
