package Minion::Command::minion::worker;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);

has description => 'Start Minion worker';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  GetOptionsFromArray \@args, 't|task=s' => \my @tasks;

  # Limit tasks
  my $app    = $self->app;
  my $minion = $app->minion;
  my $tasks  = $minion->tasks;
  %$tasks = map { $tasks->{$_} ? ($_ => $tasks->{$_}) : () } @tasks if @tasks;

  local $SIG{INT} = local $SIG{TERM} = sub { $self->{finished}++ };

  my $worker = $minion->worker->register;
  while (!$self->{finished}) {

    # Repair in regular intervals
    if (($self->{next} // 0) <= time) {
      $self->{next} = time + $minion->remove_after;
      $app->log->debug('Checking worker registry and job queue.')
        and $minion->repair;
    }

    # Perform job
    if (my $job = $worker->dequeue(5)) { $job->perform }
  }
  $worker->unregister;
}

1;

=encoding utf8

=head1 NAME

Minion::Command::minion::worker - Minion worker command

=head1 SYNOPSIS

  Usage: APPLICATION minion worker [OPTIONS]

    ./myapp.pl minion worker
    ./myapp.pl minion worker -m production
    ./myapp.pl minion worker -t foo -t bar

  Options:
    -t, --task <name>   One or more tasks to handle, defaults to handling all
                        tasks

=head1 DESCRIPTION

L<Minion::Command::minion::worker> starts a L<Minion> worker. You can have as
many workers as you like, but on every host they should all be owned by the
same user, so they can send each other signals to check which workers are still
alive.

=head1 SIGNALS

The L<Minion::Command::minion::worker> process can be controlled at runtime
with the following signals.

=head2 INT, TERM

Stop gracefully after finishing the current job.

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

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
