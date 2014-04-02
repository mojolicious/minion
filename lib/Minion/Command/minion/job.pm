package Minion::Command::minion::job;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use Mango::BSON 'bson_oid';
use Mojo::Util 'dumper';

has description => 'Manage Minion jobs.';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  GetOptionsFromArray \@args,
    'r|remove'  => \my $remove,
    'R|restart' => \my $restart,
    's|stats'   => \my $stats;
  my $oid = @args ? bson_oid(shift @args) : undef;

  # Show stats or list jobs
  return $stats ? $self->_stats : $self->_list unless $oid;
  die "Job does not exist.\n" unless my $job = $self->app->minion->job($oid);

  # Remove job
  return $job->remove if $remove;

  # Restart job
  return $job->restart if $restart;

  # Job info
  $self->_info($job);
}

sub _info {
  my ($self, $job) = @_;

  # Details
  print $job->task, ' (', $job->state, ")\n", dumper($job->args);
  my $err = $job->error;
  say $err if $err;

  # Timing
  my @times   = ('Created: ' . $job->created);
  my $started = $job->started;
  push @times, 'Started: ' . $started if $started;
  my $finished = $job->finished;
  push @times, 'Finished: ' . $finished if $finished;
  say join '  ', @times;
}

sub _list {
  my $cursor = shift->app->minion->jobs->find->sort({_id => -1});
  while (my $doc = $cursor->next) {
    say sprintf '%s  %-8s  %s', @$doc{qw(_id state task)};
  }
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
    ./myapp.pl minion job -s
    ./myapp.pl minion job 533b4e2b5867b4c72b0a0000
    ./myapp.pl minion job 533b4e2b5867b4c72b0a0000 -r

  Options:
    -r, --remove    Remove job.
    -R, --restart   Restart job.
    -s, --stats     Show queue statistics.

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
