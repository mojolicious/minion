package Minion::Command::minion;
use Mojo::Base 'Mojolicious::Commands';

has description => 'Minion job queue';
has hint        => <<EOF;

See 'APPLICATION minion help COMMAND' for more information on a specific
command.
EOF
has message    => sub { shift->extract_usage . "\nCommands:\n" };
has namespaces => sub { ['Minion::Command::minion'] };

sub help { shift->run(@_) }

1;

=encoding utf8

=head1 NAME

Minion::Command::minion - Minion command

=head1 SYNOPSIS

  Usage: APPLICATION minion COMMAND [OPTIONS]

=head1 DESCRIPTION

L<Minion::Command::minion> lists available L<Minion> commands.

=head1 ATTRIBUTES

L<Minion::Command::minion> inherits all attributes from L<Mojolicious::Commands> and implements the following new ones.

=head2 description

  my $description = $minion->description;
  $minion         = $minion->description('Foo');

Short description of this command, used for the command list.

=head2 hint

  my $hint = $minion->hint;
  $minion  = $minion->hint('Foo');

Short hint shown after listing available L<Minion> commands.

=head2 message

  my $msg = $minion->message;
  $minion = $minion->message('Bar');

Short usage message shown before listing available L<Minion> commands.

=head2 namespaces

  my $namespaces = $minion->namespaces;
  $minion        = $minion->namespaces(['MyApp::Command::minion']);

Namespaces to search for available L<Minion> commands, defaults to L<Minion::Command::minion>.

=head1 METHODS

L<Minion::Command::minion> inherits all methods from L<Mojolicious::Commands> and implements the following new ones.

=head2 help

  $minion->help('app');

Print usage information for L<Minion> command.

=head1 SEE ALSO

L<Minion>, L<https://minion.pm>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
