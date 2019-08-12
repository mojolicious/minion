package Mojolicious::Plugin::Minion;
use Mojo::Base 'Mojolicious::Plugin';

use Minion;
use Mojo::IOLoop;

sub register {
  my ($self, $app, $conf) = @_;
  push @{$app->commands->namespaces}, 'Minion::Command';
  my $minion = Minion->new(%$conf)->app($app);
  $app->helper(minion => sub {$minion});
  $app->helper(minion_dev_server => \&_dev_server);
}

sub _dev_server {
  my ($c, @args) = @_;

  $c->app->hook(
    before_server_start => sub {
      my ($server, $app) = @_;
      return unless $server->isa('Mojo::Server::Daemon');
      $app->minion->missing_after(0)->repair;

      # without server event finish, use server pid going away to set finished
      my $server_pid = $$;
      Mojo::IOLoop->subprocess(
        sub {
          $app->minion->on(worker => sub {
            my ($minion, $worker) = @_;
            $minion->missing_after(180);
            $worker->status(@args);
            $worker->on(dequeue => sub { pop->once(spawn => \&_job_spawned) });
            $worker->on(wait => sub { shift->{finished} = !kill 0, $server_pid});
          });
          $app->minion->worker->run;
        },
        sub {
          $app->log->warn("Subprocess error: $_[1]") and return if $_[1];
        }
      );
    }
  ) if $c->app->mode eq 'development';
}

sub _job_spawned {
  my ($job, $pid) = @_;
  my ($id, $task) = ($job->id, $job->task);
  $job->app->log->debug(
    qq{Process $pid is performing job "$id" with task "$task"});
}

1;

=encoding utf8

=head1 NAME

Mojolicious::Plugin::Minion - Minion job queue plugin

=head1 SYNOPSIS

  # Mojolicious (choose a backend)
  $self->plugin(Minion => {Pg => 'postgresql://postgres@/test'});

  # Mojolicious::Lite (choose a backend)
  plugin Minion => {Pg => 'postgresql://postgres@/test'};

  # Share the database connection cache (PostgreSQL backend)
  helper pg => sub { state $pg = Mojo::Pg->new('postgresql://postgres@/test') };
  plugin Minion => {Pg => app->pg};

  # Perform jobs in the web server during development
  plugin Minion => {Pg =>  'postgresql://postgres@/test'};
  app->minion_dev_server;

  # Add tasks to your application
  app->minion->add_task(slow_log => sub {
    my ($job, $msg) = @_;
    sleep 5;
    $job->app->log->debug(qq{Received message "$msg"});
  });

  # Start jobs from anywhere in your application
  $c->minion->enqueue(slow_log => ['test 123']);

  # Perform jobs in your tests
  $t->get_ok('/start_slow_log_job')->status_is(200);
  $t->get_ok('/start_another_job')->status_is(200);
  $t->app->minion->perform_jobs;

=head1 DESCRIPTION

L<Mojolicious::Plugin::Minion> is a L<Mojolicious> plugin for the L<Minion> job
queue.

=head1 HELPERS

L<Mojolicious::Plugin::Minion> implements the following helpers.

=head2 minion

  my $minion = $app->minion;
  my $minion = $c->minion;

Get L<Minion> object for application.

  # Add job to the queue
  $c->minion->enqueue(foo => ['bar', 'baz']);

  # Perform jobs for testing
  $app->minion->perform_jobs;

=head2 minion_dev_server

  $app->minion_dev_server;

In C<development> mode when started with a development web server perform all
jobs from the web server without starting a separate worker process, takes the
same arguments as L<Minion::Worker/"status">.

=head1 METHODS

L<Mojolicious::Plugin::Minion> inherits all methods from
L<Mojolicious::Plugin> and implements the following new ones.

=head2 register

  $plugin->register(Mojolicious->new, {Pg => 'postgresql://postgres@/test'});

Register plugin in L<Mojolicious> application.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
