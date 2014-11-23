package Minion::Command::minion::job;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use Mojo::Date;
use Mojo::JSON 'decode_json';
use Mojo::Util qw(dumper tablify);

has description => 'Manage Minion jobs.';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  my $args    = [];
  my $options = {};
  GetOptionsFromArray \@args,
    'a|args=s' => sub { $args = decode_json($_[1]) },
    'd|delay=i'    => \$options->{delay},
    'e|enqueue=s'  => \my $enqueue,
    'l|limit=i'    => \(my $limit = 100),
    'o|offset=i'   => \(my $offset = 0),
    'p|priority=i' => \$options->{priority},
    'r|remove'     => \my $remove,
    'R|retry'      => \my $retry,
    's|stats'      => \my $stats,
    't|task=s'     => \$options->{task},
    'T|state=s'    => \$options->{state},
    'w|workers'    => \my $workers;
  my $id = @args ? shift @args : undef;

  # Enqueue
  return say $self->app->minion->enqueue($enqueue, $args, $options)
    if $enqueue;

  # Show stats or list jobs/workers
  return $self->_stats if $stats;
  return $self->_list_workers($offset, $limit) if !$id && $workers;
  return $self->_list_jobs($offset, $limit, $options) if !$id;
  die "Job does not exist.\n" unless my $job = $self->app->minion->job($id);

  # Remove job
  return $job->remove ? 1 : die "Job is active.\n" if $remove;

  # Retry job
  return $job->retry ? 1 : die "Job is active.\n" if $retry;

  # Job info
  $self->_info($job);
}

sub _info {
  my ($self, $job) = @_;

  # Details
  my $info = $job->info;
  my ($state, $priority, $retries) = @$info{qw(state priority retries)};
  print $info->{task}, " ($state, p$priority, r$retries)\n",
    dumper($info->{args});
  if (my $result = $info->{result}) { print dumper $result }

  # Timing
  say Mojo::Date->new($info->{created})->to_datetime, ' (created)';
  my $delayed = $info->{delayed};
  say Mojo::Date->new($delayed)->to_datetime, ' (delayed)' if $delayed > time;
  my $retried = $info->{retried};
  say Mojo::Date->new($retried)->to_datetime, ' (retried)' if $retried;
  my $started = $info->{started};
  say Mojo::Date->new($started)->to_datetime, ' (started)' if $started;
  my $finished = $info->{finished};
  say Mojo::Date->new($finished)->to_datetime, ' (finished)' if $finished;
}

sub _list_jobs {
  my $jobs = shift->app->minion->backend->list_jobs(@_);
  print tablify [map { [@$_{qw(id state task)}] } @$jobs];
}

sub _list_workers {
  my $workers = shift->app->minion->backend->list_workers(@_);
  print tablify [map { [_worker()] } @$workers];
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
  $_->{id}, @{$_->{jobs}} ? 'active' : 'inactive', "$_->{host}:$_->{pid}";
}

1;

=encoding utf8

=head1 NAME

Minion::Command::minion::job - Minion job command

=head1 SYNOPSIS

  Usage: APPLICATION minion job [ID]

    ./myapp.pl minion job
    ./myapp.pl minion job -t test -T inactive
    ./myapp.pl minion job -e foo -a '[23, "bar"]'
    ./myapp.pl minion job -e foo -p 5
    ./myapp.pl minion job -s
    ./myapp.pl minion job -w -l 5
    ./myapp.pl minion job acbd18db4cc2f85cedef654fccc4a4d8
    ./myapp.pl minion job acbd18db4cc2f85cedef654fccc4a4d8 -r

  Options:
    -a, --args <JSON array>   Arguments for new job in JSON format.
    -d, --delay <seconds>     Delay new job for this many seconds.
    -e, --enqueue <name>      New job to be enqueued.
    -l, --limit <number>      Number of jobs/workers to show when listing
                              them, defaults to 100.
    -o, --offset <number>     Number of jobs/workers to skip when listing
                              them, defaults to 0.
    -p, --priority <number>   Priority of new job, defaults to 0.
    -r, --remove              Remove job.
    -R, --retry               Retry job.
    -s, --stats               Show queue statistics.
    -t, --task <name>         List only jobs for this task.
    -T, --state <state>       List only jobs in this state.
    -w, --workers             List workers instead of jobs.

=head1 DESCRIPTION

L<Minion::Command::minion::job> manages L<Minion> jobs.

=head1 ATTRIBUTES

L<Minion::Command::minion::job> inherits all attributes from
L<Mojolicious::Command> and implements the following new ones.

=head2 description

  my $description = $job->description;
  $job            = $job->description('Foo!');

Short description of this command, used for the command list.

=head2 usage

  my $usage = $job->usage;
  $job      = $job->usage('Foo!');

Usage information for this command, used for the help screen.

=head1 METHODS

L<Minion::Command::minion::job> inherits all methods from
L<Mojolicious::Command> and implements the following new ones.

=head2 run

  $job->run(@ARGV);

Run this command.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
