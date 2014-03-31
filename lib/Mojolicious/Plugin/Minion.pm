package Mojolicious::Plugin::Minion;
use Mojo::Base 'Mojolicious::Plugin';

use Minion;
use Scalar::Util 'weaken';

sub register {
  my ($self, $app, $conf) = @_;

  push @{$app->commands->namespaces}, 'Minion::Command';

  my $minion = Minion->new;
  $minion->mango->from_string($conf->{uri}) if $conf->{uri};
  weaken $minion->app($app)->{app};
  $app->helper(minion => sub {$minion});
}

1;

=encoding utf8

=head1 NAME

Mojolicious::Plugin::Minion - Minion job queue plugin

=head1 SYNOPSIS

  # Mojolicious
  $self->plugin(Minion => {uri => 'mongodb://127.0.0.1:27017'});

  # Mojolicious::Lite
  plugin Minion => {uri => 'mongodb://127.0.0.1:27017'};

  # Add tasks to your application
  app->minion->add_task(slow_log => sub {
    my ($job, $msg) = @_;
    sleep 5;
    $job->app->log->debug(qq{Received message "$msg".});
    return undef;
  });

  # Start jobs from anywhere in your application (data gets BSON serialized)
  $c->minion->enqueue(slow_log => ['test 123']);

  # Perform jobs automatically in your tests
  $t->minion->auto_perform(1);
  $t->get_ok('/start_slow_log_job')->status_is(200);

=head1 DESCRIPTION

L<Mojolicious::Plugin::Minion> is a L<Mojolicious> plugin for the L<Minion>
job queue.

=head1 OPTIONS

L<Mojolicious::Plugin::Minion> supports the following options.

=head2 uri

  # Mojolicious::Lite
  plugin Minion => {uri => 'mongodb://127.0.0.1:27017'};

L<Mango> connection string.

=head1 HELPERS

L<Mojolicious::Plugin::Minion> implements the following helpers.

=head2 minion

  my $minion = $app->minion;
  my $minion = $c->minion;

Get L<Minion> object for application.

  # Add job to the queue
  $c->minion->enqueue(foo => ['bar', 'baz']);

  # Perform jobs automatically for testing
  $app->minion->auto_perform(1);

=head1 METHODS

L<Mojolicious::Plugin::Minion> inherits all methods from
L<Mojolicious::Plugin> and implements the following new ones.

=head2 register

  $plugin->register(Mojolicious->new, {uri => 'mongodb://127.0.0.1:27017'});

Register plugin in L<Mojolicious> application.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
