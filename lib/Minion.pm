package Minion;
use Mojo::Base 'Mojo::EventEmitter';

use Carp 'croak';
use Minion::Job;
use Minion::Worker;
use Mojo::IOLoop;
use Mojo::Loader;
use Mojo::Server;
use Mojo::URL;
use Scalar::Util 'weaken';
use Time::HiRes 'usleep';

our $VERSION = '0.10';

has app => sub { Mojo::Server->new->build_app('Mojo::HelloWorld') };
has [qw(auto_perform backend)];
has tasks => sub { {} };

sub add_task {
  my ($self, $name, $cb) = @_;
  $self->tasks->{$name} = $cb;
  return $self;
}

sub enqueue {
  my $self = shift;
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;

  # Blocking
  unless ($cb) {
    my $id = $self->backend->enqueue(@_);
    $self->_perform;
    return $id;
  }

  # Non-blocking
  weaken $self;
  $self->backend->enqueue(@_ => sub { shift; $self->_perform->$cb(@_) });
}

sub job {
  my ($self, $id) = @_;

  my $job = $self->backend->job_info($id);
  return undef unless $job->{state};
  return Minion::Job->new(
    args   => $job->{args},
    id     => $id,
    minion => $self,
    task   => $job->{task}
  );
}

sub new {
  my $self = shift->SUPER::new;

  my $class = 'Minion::Backend::' . shift;
  my $e     = Mojo::Loader->new->load($class);
  croak ref $e ? $e : qq{Missing backend "$class"} if $e;

  $self->backend($class->new(@_));
  weaken $self->backend->minion($self)->{minion};

  return $self;
}

sub repair {
  my $self = shift;
  $self->backend->repair;
  return $self;
}

sub stats { shift->backend->stats }

sub wait_for {
  my ($self, $id, $cb) = @_;

  # Blocking
  unless ($cb) {
    while (1) {
      my $info = $self->backend->job_info($id);
      return $info->{result}
        if !$info->{state} || $info->{state} eq 'finished';
      croak $info->{error} if $info->{state} eq 'failed';
      usleep 0.5 * 1000000;
    }
  }

  # Non-blocking
  $self->_try($id, $cb);
}

sub _try {
  my ($self, $id, $cb) = @_;

  weaken $self;
  $self->backend->job_info(
    $id => sub {
      my ($backend, $err, $info) = @_;
      if ($err //= $info->{error}) { return $self->$cb($err) }
      return $self->$cb(undef, $info->{result})
        if !$info->{state} || $info->{state} eq 'finished';
      Mojo::IOLoop->timer(0.5 => sub { $self->_try($id, $cb) });
    }
  );
}

sub worker {
  my $self = shift;
  my $worker = Minion::Worker->new(minion => $self);
  $self->emit(worker => $worker);
  return $worker;
}

sub _perform {
  my $self = shift;

  # No recursion
  return $self if !$self->auto_perform || $self->{lock};
  local $self->{lock} = 1;

  my $worker = $self->worker->register;
  while (my $job = $worker->dequeue) { $job->perform }
  $worker->unregister;
  return $self;
}

1;

=encoding utf8

=head1 NAME

Minion - Job queue

=head1 SYNOPSIS

  use Minion;

  # Connect to backend
  my $minion = Minion->new(Mango => 'mongodb://localhost:27017');

  # Add tasks without result
  $minion->add_task(something_slow => sub {
    my ($job, @args) = @_;
    sleep 5;
    say 'This is a background worker process.';
  });

  # Add tasks with result
  $minion->add_task(slow_add => sub {
    my ($job, $first, $second) = @_;
    sleep 5;
    my $result = $first + $second;
    $job->finish($result);
  });

  # Enqueue jobs
  $minion->enqueue(something_slow => ['foo', 'bar']);
  $minion->enqueue(something_slow => [1, 2, 3]);

  # Wait for results
  my $id     = $minion->enqueue(slow_add => [3, 1]);
  my $result = $minion->wait_for($id);

  # Perform jobs automatically for testing
  $minion->auto_perform(1);
  $minion->enqueue(something_slow => ['foo', 'bar']);

  # Build more sophisticated workers
  my $worker = $minion->repair->worker->register;
  if (my $job = $worker->dequeue) { $job->perform }
  $worker->unregister;

=head1 DESCRIPTION

L<Minion> is a job queue for the L<Mojolicious> real-time web framework.

Background worker processes are usually started with the command
L<Minion::Command::minion::worker>, which becomes automatically available when
an application loads the plugin L<Mojolicious::Plugin::Minion>.

  $ ./myapp.pl minion worker

Jobs can be managed right from the command line with
L<Minion::Command::minion::job>.

  $ ./myapp.pl minion job

Note that this whole distribution is EXPERIMENTAL and will change without
warning!

Most of the API is not changing much anymore, but you should wait for a stable
1.0 release before using any of the modules in this distribution in a
production environment.

=head1 EVENTS

L<Minion> inherits all events from L<Mojo::EventEmitter> and can emit the
following new ones.

=head2 worker

  $minion->on(worker => sub {
    my ($minion, $worker) = @_;
    ...
  });

Emitted when a new worker is created.

  $minion->on(worker => sub {
    my ($minion, $worker) = @_;
    my $id = $worker->id;
    say "Worker $$:$id started.";
  });

=head1 ATTRIBUTES

L<Minion> implements the following attributes.

=head2 app

  my $app = $minion->app;
  $minion = $minion->app(MyApp->new);

Application for job queue, defaults to a L<Mojo::HelloWorld> object.

=head2 auto_perform

  my $bool = $minion->auto_perform;
  $minion  = $minion->auto_perform($bool);

Perform jobs automatically when a new one has been enqueued with
L</"enqueue">, very useful for testing.

=head2 backend

  my $backend = $minion->backend;
  $minion     = $minion->backend(Minion::Backend::Mango->new);

Backend.

=head2 tasks

  my $tasks = $minion->tasks;
  $minion   = $minion->tasks({foo => sub {...}});

Registered tasks.

=head1 METHODS

L<Minion> inherits all methods from L<Mojo::EventEmitter> and implements the
following new ones.

=head2 add_task

  $minion = $minion->add_task(foo => sub {...});

Register a new task.

=head2 enqueue

  my $id = $minion->enqueue('foo');
  my $id = $minion->enqueue(foo => [@args]);
  my $id = $minion->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state. You can also append a callback to
perform operation non-blocking.

  $minion->enqueue(foo => sub {
    my ($minion, $err, $id) = @_;
    ...
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

These options are currently available:

=over 2

=item delayed

  delayed => (time + 1) * 1000

Delay job until after this point in time.

=item priority

  priority => 5

Job priority, defaults to C<0>.

=back

=head2 job

  my $job = $minion->job($id);

Get L<Minion::Job> object without making any changes to the actual job or
return C<undef> if job does not exist.

=head2 new

  my $minion = Minion->new(Mango => 'mongodb://127.0.0.1:27017');

Construct a new L<Minion> object.

=head2 repair

  $minion = $minion->repair;

Repair worker registry and job queue, all workers on this host should be owned
by the same user.

=head2 stats

  my $stats = $minion->stats;

Get statistics for jobs and workers.

=head2 wait_for

  my $result = $minion->wait_for($id);

Wait for job to transition to C<failed> or C<finished> state and return
result. You can also append a callback to perform operation non-blocking.

  $minion->wait_for($id => sub {
    my ($minion, $err, $result) = @_;
    ...
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 worker

  my $worker = $minion->worker;

Build L<Minion::Worker> object.

=head1 AUTHOR

Sebastian Riedel, C<sri@cpan.org>.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Sebastian Riedel.

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<https://github.com/kraih/minion>, L<Mojolicious::Guides>,
L<http://mojolicio.us>.

=cut
