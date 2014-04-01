package Minion::Command::minion::job;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long qw(GetOptionsFromArray :config no_auto_abbrev no_ignore_case);
use Mango::BSON 'bson_oid';
use Mojo::Util 'tablify';

has description => 'Manage Minion jobs.';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  GetOptionsFromArray \@args,
    'r|remove'  => \my $remove,
    's|restart' => \my $restart;
  my $oid = @args ? bson_oid(shift @args) : undef;

  # List jobs
  return $self->_list unless $oid;
  die "Job does not exist.\n" unless my $job = $self->app->minion->job($oid);

  # Remove job
  return $job->remove if $remove;

  # Restart job
  return $job->restart if $restart;

  # Job info
  say join ' ', $job->id, $job->task, $job->state;
}

sub _list {
  my $self = shift;
  my @table;
  my $cursor = $self->app->minion->jobs->find->sort({_id => -1});
  while (my $doc = $cursor->next) {
    my $err = $doc->{error} // '';
    push @table, [$doc->{_id}, $doc->{task}, $doc->{state}, $err];
  }
  say tablify \@table;
}

1;

=encoding utf8

=head1 NAME

Minion::Command::minion::job - Minion job command

=head1 SYNOPSIS

  Usage: APPLICATION minion job [ID]

    ./myapp.pl minion job
    ./myapp.pl minion job 533b4e2b5867b4c72b0a0000
    ./myapp.pl minion job 533b4e2b5867b4c72b0a0000 -r

  Options:
    -r, --remove    Remove job.
    -s, --restart   Restart job.

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
