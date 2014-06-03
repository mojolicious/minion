package Minion::Command::minion::job;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use Mojo::JSON 'decode_json';
use Mojo::Util 'dumper';
use Time::Piece 'localtime';

has description => 'Manage Minion jobs.';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  my $args    = [];
  my $options = {};
  GetOptionsFromArray \@args,
    'a|args=s'    => sub { $args               = decode_json($_[1]) },
    'd|delayed=i' => sub { $options->{delayed} = $_[1] * 1000 },
    'e|enqueue=s' => \my $enqueue,
    'L|limit=i' => \(my $limit = 100),
    'p|priority=i' => sub { $options->{priority} = $_[1] },
    'r|remove'     => \my $remove,
    'R|restart'    => \my $restart,
    's|stats'      => \my $stats,
    'S|skip=i' => \(my $skip = 0),
    'w|workers' => \my $workers;
  my $id = @args ? shift @args : undef;

  # Enqueue
  return say $self->app->minion->enqueue($enqueue, $args, $options)
    if $enqueue;

  # Show stats or list jobs/workers
  return $self->_stats if $stats;
  my $sub = $workers ? \&_list_workers : \&_list_jobs;
  return $self->$sub($skip, $limit) unless $id;
  die "Job does not exist.\n" unless my $job = $self->app->minion->job($id);

  # Remove job
  return $job->remove ? 1 : die "Job is active.\n" if $remove;

  # Restart job
  return $job->restart ? 1 : die "Job is active.\n" if $restart;

  # Job info
  $self->_info($job);
}

sub _info {
  my ($self, $job) = @_;

  # Details
  my $info = $job->info;
  my ($state, $priority, $restarts) = @$info{qw(state priority restarts)};
  print $info->{task}, " ($state, p$priority, r$restarts)\n",
    dumper($info->{args});
  my $err = $info->{error};
  say chomp $err ? $err : $err if $err;

  # Timing
  say localtime($info->{created})->datetime, ' (created)';
  my $delayed = $info->{delayed};
  say localtime($delayed)->datetime, ' (delayed)' if $delayed > time;
  my $restarted = $info->{restarted};
  say localtime($restarted)->datetime, ' (restarted)' if $restarted;
  my $started = $info->{started};
  say localtime($started)->datetime, ' (started)' if $started;
  my $finished = $info->{finished};
  say localtime($finished)->datetime, ' (finished)' if $finished;
}

sub _list_jobs {
  my ($self, $skip, $limit) = @_;
  say sprintf '%s  %-8s  %s', @$_{qw(id state task)}
    for @{$self->app->minion->backend->list_jobs($skip, $limit)};
}

sub _list_workers {
  my ($self, $skip, $limit) = @_;
  say sprintf '%s  %-8s  %s', $_->{id}, @{$_->{jobs}} ? 'active' : 'inactive',
    "$_->{host}:$_->{pid}"
    for @{$self->app->minion->backend->list_workers($skip, $limit)};
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

1;

=encoding utf8

=head1 NAME

Minion::Command::minion::job - Minion job command

=head1 SYNOPSIS

  Usage: APPLICATION minion job [ID]

    ./myapp.pl minion job
    ./myapp.pl minion job -e foo -a '[23, "bar"]'
    ./myapp.pl minion job -e foo -p 5
    ./myapp.pl minion job -s
    ./myapp.pl minion job -w -L 5
    ./myapp.pl minion job 533b4e2b5867b4c72b0a0000
    ./myapp.pl minion job 533b4e2b5867b4c72b0a0000 -r

  Options:
    -a, --args <JSON array>   Arguments for new job in JSON format.
    -d, --delayed <epoch>     Delay new job until after this point in time.
    -e, --enqueue <name>      New job to be enqueued.
    -L, --limit <number>      Number of jobs/workers to show when listing
                              them, defaults to 100.
    -p, --priority <number>   Priority of new job, defaults to 0.
    -r, --remove              Remove job.
    -R, --restart             Restart job.
    -s, --stats               Show queue statistics.
    -S, --skip <number>       Number of jobs/workers to skip when listing
                              them, defaults to 0.
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
