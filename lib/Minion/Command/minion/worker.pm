package Minion::Command::minion::worker;
use Mojo::Base 'Mojolicious::Command';

has description => 'Start Minion worker.';
has usage => sub { shift->extract_usage };

sub run {
  my $self = shift;

  local $SIG{INT} = local $SIG{TERM} = sub { $self->{finished}++ };

  my $worker = $self->app->minion->worker;
  $worker->repair;
  $worker->register;
  while (!$self->{finished}) {
    if   (my $job = $worker->dequeue) { $job->perform }
    else                              { sleep 5 }
  }
  $worker->unregister;
  exit 0;
}

1;

=encoding utf8

=head1 NAME

Minion::Command::minion::worker - Minion worker command

=head1 SYNOPSIS

  Usage: APPLICATION minion worker

=head1 DESCRIPTION

L<Minion::Command::minion::worker> starts a L<Minion> worker.

=head1 ATTRIBUTES

L<Minion::Command::minion::worker> inherits all attributes from
L<Mojolicious::Command> and implements the following new ones.

=head2 description

  my $description = $worker->description;
  $worker         = $worker->description('Foo!');

Short description of this command, used for the command list.

=head2 usage

  my $usage = $worker->usage;
  $worker   = $worker->usage('Foo!');

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
