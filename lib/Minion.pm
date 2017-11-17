package Minion;
use Mojo::Base 'Mojo::EventEmitter';

use Carp 'croak';
use Config;
use Minion::Job;
use Minion::Worker;
use Mojo::Date;
use Mojo::Loader 'load_class';
use Mojo::Server;
use Scalar::Util 'weaken';

has app => sub { Mojo::Server->new->build_app('Mojo::HelloWorld') };
has 'backend';
has backoff => sub { \&_backoff };
has missing_after => 1800;
has remove_after  => 172800;
has tasks         => sub { {} };

our $VERSION = '8.0';

sub add_task { ($_[0]->tasks->{$_[1]} = $_[2]) and return $_[0] }

sub enqueue {
  my $self = shift;
  my $id   = $self->backend->enqueue(@_);
  $self->emit(enqueue => $id);
  return $id;
}

sub foreground {
  my ($self, $id) = @_;

  return undef unless my $job = $self->job($id);
  return undef
    unless $job->retry({attempts => 1, queue => 'minion_foreground'});

  my $worker = $self->worker->register;
  $job = $worker->dequeue(0 => {id => $id, queues => ['minion_foreground']});
  my $err;
  if ($job) { $job->finish unless defined($err = $job->_run) }
  $worker->unregister;

  return defined $err ? die $err : !!$job;
}

sub guard {
  my ($self, $lock) = (shift, shift);
  return undef unless $self->lock($lock, @_);
  return Minion::_Guard->new(minion => $self, lock => $lock);
}

sub job {
  my ($self, $id) = @_;

  return undef
    unless my $job = $self->backend->list_jobs(0, 1, {ids => [$id]})->{jobs}[0];
  return Minion::Job->new(
    args    => $job->{args},
    id      => $job->{id},
    minion  => $self,
    retries => $job->{retries},
    task    => $job->{task}
  );
}

sub lock { shift->backend->lock(@_) }

sub new {
  my $self = shift->SUPER::new;

  my $class = 'Minion::Backend::' . shift;
  my $e     = load_class $class;
  croak ref $e ? $e : qq{Backend "$class" missing} if $e;

  $self->backend($class->new(@_));
  weaken $self->backend->minion($self)->{minion};

  return $self;
}

sub perform_jobs {
  my ($self, $options) = @_;
  my $worker = $self->worker;
  while (my $job = $worker->register->dequeue(0, $options)) { $job->perform }
  $worker->unregister;
}

sub repair { shift->_delegate('repair') }
sub reset  { shift->_delegate('reset') }

sub stats  { shift->backend->stats }
sub unlock { shift->backend->unlock(@_) }

sub worker {
  my $self = shift;

  # No fork emulation support
  croak 'Minion workers do not support fork emulation' if $Config{d_pseudofork};

  my $worker = Minion::Worker->new(minion => $self);
  $self->emit(worker => $worker);
  return $worker;
}

sub _backoff { (shift()**4) + 15 }

# Used by the job command and admin plugin
sub _datetime {
  my $hash = shift;
  $hash->{$_} and $hash->{$_} = Mojo::Date->new($hash->{$_})->to_datetime
    for qw(created delayed finished notified retried started);
  return $hash;
}

sub _delegate {
  my ($self, $method) = @_;
  $self->backend->$method;
  return $self;
}

package Minion::_Guard;
use Mojo::Base -base;

sub DESTROY { $_[0]{minion}->unlock($_[0]{lock}) }

1;

=encoding utf8

=head1 NAME

Minion - Job queue

=head1 SYNOPSIS

  use Minion;

  # Connect to backend
  my $minion = Minion->new(Pg => 'postgresql://postgres@/test');

  # Add tasks
  $minion->add_task(something_slow => sub {
    my ($job, @args) = @_;
    sleep 5;
    say 'This is a background worker process.';
  });

  # Enqueue jobs
  $minion->enqueue(something_slow => ['foo', 'bar']);
  $minion->enqueue(something_slow => [1, 2, 3] => {priority => 5});

  # Perform jobs for testing
  $minion->enqueue(something_slow => ['foo', 'bar']);
  $minion->perform_jobs;

  # Build more sophisticated workers
  my $worker = $minion->repair->worker;
  while (int rand 2) {
    if (my $job = $worker->register->dequeue(5)) { $job->perform }
  }
  $worker->unregister;

=head1 DESCRIPTION

=begin html

<p>
  <img alt="Screenshot"
    src="https://raw.github.com/kraih/minion/master/examples/admin.png?raw=true"
    width="600px">
</p>

=end html

L<Minion> is a job queue for the L<Mojolicious|http://mojolicious.org> real-time
web framework, with support for multiple named queues, priorities, delayed jobs,
job dependencies, job progress, job results, retries with backoff, rate
limiting, unique jobs, statistics, distributed workers, parallel processing,
autoscaling, remote control, admin ui, resource leak protection and multiple
backends (such as L<PostgreSQL|http://www.postgresql.org>).

Job queues allow you to process time and/or computationally intensive tasks in
background processes, outside of the request/response lifecycle. Among those
tasks you'll commonly find image resizing, spam filtering, HTTP downloads,
building tarballs, warming caches and basically everything else you can imagine
that's not super fast.

  use Mojolicious::Lite;

  plugin Minion => {Pg => 'postgresql://sri:s3cret@localhost/test'};

  # Slow task
  app->minion->add_task(poke_mojo => sub {
    my $job = shift;
    $job->app->ua->get('mojolicious.org');
    $job->app->log->debug('We have poked mojolicious.org for a visitor');
  });

  # Perform job in a background worker process
  get '/' => sub {
    my $c = shift;
    $c->minion->enqueue('poke_mojo');
    $c->render(text => 'We will poke mojolicious.org for you soon.');
  };

  app->start;

Background worker processes are usually started with the command
L<Minion::Command::minion::worker>, which becomes automatically available when
an application loads the plugin L<Mojolicious::Plugin::Minion>.

  $ ./myapp.pl minion worker

Jobs can be managed right from the command line with
L<Minion::Command::minion::job>.

  $ ./myapp.pl minion job

You can also add an admin ui to your application by loading the plugin
L<Mojolicious::Plugin::Minion::Admin>. Just make sure to secure access before
making your application publically accessible.

  # Make admin ui available under "/minion"
  plugin 'Minion::Admin';

To manage background worker processes with systemd, you can use a unit
configuration file like this.

  [Unit]
  Description=My Mojolicious application workers
  After=postgresql.service

  [Service]
  Type=simple
  ExecStart=/home/sri/myapp/myapp.pl minion worker -m production
  KillMode=process

  [Install]
  WantedBy=multi-user.target

Every job can fail or succeed, but not get lost, the system is eventually
consistent and will preserve job results for as long as you like, depending on
L</"remove_after">. While individual workers can fail in the middle of
processing a job, the system will detect this and ensure that no job is left in
an uncertain state, depending on L</"missing_after">.

=head1 GROWING

And as your application grows, you can move tasks into application specific
plugins.

  package MyApp::Task::PokeMojo;
  use Mojo::Base 'Mojolicious::Plugin';

  sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(poke_mojo => sub {
      my $job = shift;
      $job->app->ua->get('mojolicious.org');
      $job->app->log->debug('We have poked mojolicious.org for a visitor');
    });
  }

  1;

Which are loaded like any other plugin from your application.

  # Mojolicious
  $app->plugin('MyApp::Task::PokeMojo');

  # Mojolicious::Lite
  plugin 'MyApp::Task::PokeMojo';

=head1 EXAMPLES

This distribution also contains a great example application you can use for
inspiration. The
L<link checker|https://github.com/kraih/minion/tree/master/examples/linkcheck>
will show you how to integrate background jobs into well-structured
L<Mojolicious> applications.

=head1 EVENTS

L<Minion> inherits all events from L<Mojo::EventEmitter> and can emit the
following new ones.

=head2 enqueue

  $minion->on(enqueue => sub {
    my ($minion, $id) = @_;
    ...
  });

Emitted after a job has been enqueued, in the process that enqueued it.

  $minion->on(enqueue => sub {
    my ($minion, $id) = @_;
    say "Job $id has been enqueued.";
  });

=head2 worker

  $minion->on(worker => sub {
    my ($minion, $worker) = @_;
    ...
  });

Emitted in the worker process after it has been created.

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

=head2 backend

  my $backend = $minion->backend;
  $minion     = $minion->backend(Minion::Backend::Pg->new);

Backend, usually a L<Minion::Backend::Pg> object.

=head2 backoff

  my $cb  = $minion->backoff;
  $minion = $minion->backoff(sub {...});

A callback used to calculate the delay for automatically retried jobs, defaults
to C<(retries ** 4) + 15> (15, 16, 31, 96, 271, 640...), which means that
roughly C<25> attempts can be made in C<21> days.

  $minion->backoff(sub {
    my $retries = shift;
    return ($retries ** 4) + 15 + int(rand 30);
  });

=head2 missing_after

  my $after = $minion->missing_after;
  $minion   = $minion->missing_after(172800);

Amount of time in seconds after which workers without a heartbeat will be
considered missing and removed from the registry by L</"repair">, defaults to
C<1800> (30 minutes).

=head2 remove_after

  my $after = $minion->remove_after;
  $minion   = $minion->remove_after(86400);

Amount of time in seconds after which jobs that have reached the state
C<finished> and have no unresolved dependencies will be removed automatically by
L</"repair">, defaults to C<172800> (2 days).

=head2 tasks

  my $tasks = $minion->tasks;
  $minion   = $minion->tasks({foo => sub {...}});

Registered tasks.

=head1 METHODS

L<Minion> inherits all methods from L<Mojo::EventEmitter> and implements the
following new ones.

=head2 add_task

  $minion = $minion->add_task(foo => sub {...});

Register a task.

  # Job with result
  $minion->add_task(add => sub {
    my ($job, $first, $second) = @_;
    $job->finish($first + $second);
  });
  my $id = $minion->enqueue(add => [1, 1]);
  my $result = $minion->job($id)->info->{result};

=head2 enqueue

  my $id = $minion->enqueue('foo');
  my $id = $minion->enqueue(foo => [@args]);
  my $id = $minion->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state. Arguments get serialized by the
L</"backend"> (often with L<Mojo::JSON>), so you shouldn't send objects and be
careful with binary data, nested data structures with hash and array references
are fine though.

These options are currently available:

=over 2

=item attempts

  attempts => 25

Number of times performing this job will be attempted, with a delay based on
L</"backoff"> after the first attempt, defaults to C<1>.

=item delay

  delay => 10

Delay job for this many seconds (from now), defaults to C<0>.

=item notes

  notes => {foo => 'bar', baz => [1, 2, 3]}

Hash reference with arbitrary metadata for this job that gets serialized by the
L</"backend"> (often with L<Mojo::JSON>), so you shouldn't send objects and be
careful with binary data, nested data structures with hash and array references
are fine though.

=item parents

  parents => [$id1, $id2, $id3]

One or more existing jobs this job depends on, and that need to have
transitioned to the state C<finished> before it can be processed.

=item priority

  priority => 5

Job priority, defaults to C<0>. Jobs with a higher priority get performed first.

=item queue

  queue => 'important'

Queue to put job in, defaults to C<default>.

=back

=head2 foreground

  my $bool = $minion->foreground($id);

Retry job in C<minion_foreground> queue, then perform it right away with a
temporary worker in this process, very useful for debugging.

=head2 guard

  my $guard = $minion->guard('foo', 3600);
  my $guard = $minion->guard('foo', 3600, {limit => 20});

Same as L</"lock">, but returns a scope guard object that automatically releases
the lock as soon as the object is destroyed, or C<undef> if aquiring the lock
failed.

  # Only one job should run at a time (unique job)
  $minion->add_task(do_unique_stuff => sub {
    my ($job, @args) = @_;
    return $job->finish('Previous job is still active')
      unless my $guard = $minion->guard('fragile_backend_service', 7200);
    ...
  });

  # Only five jobs should run at a time and we try again later if necessary
  $minion->add_task(do_concurrent_stuff => sub {
    my ($job, @args) = @_;
    return $job->retry({delay => 30})
      unless my $guard = $minion->guard('some_web_service', 60, {limit => 5});
    ...
  });

=head2 job

  my $job = $minion->job($id);

Get L<Minion::Job> object without making any changes to the actual job or
return C<undef> if job does not exist.

  # Check job state
  my $state = $minion->job($id)->info->{state};

  # Get job metadata
  my $progress = $minion->$job($id)->info->{notes}{progress};

  # Get job result
  my $result = $minion->job($id)->info->{result};

=head2 lock

  my $bool = $minion->lock('foo', 3600);
  my $bool = $minion->lock('foo', 3600, {limit => 20});

Try to acquire a named lock that will expire automatically after the given
amount of time in seconds. You can release the lock manually with L</"unlock">
to limit concurrency, or let it expire for rate limiting. For convenience you
can also use L</"guard"> to release the lock automatically, even if the job
failed.

  # Only one job should run at a time (unique job)
  $minion->add_task(do_unique_stuff => sub {
    my ($job, @args) = @_;
    return $job->finish('Previous job is still active')
      unless $minion->lock('fragile_backend_service', 7200);
    ...
    $minion->unlock('fragile_backend_service');
  });

  # Only five jobs should run at a time and we wait for our turn
  $minion->add_task(do_concurrent_stuff => sub {
    my ($job, @args) = @_;
    sleep 1 until $minion->lock('some_web_service', 60, {limit => 5});
    ...
    $minion->unlock('some_web_service');
  });

  # Only a hundred jobs should run per hour and we try again later if necessary
  $minion->add_task(do_rate_limited_stuff => sub {
    my ($job, @args) = @_;
    return $job->retry({delay => 3600})
      unless $minion->lock('another_web_service', 3600, {limit => 100});
    ...
  });

These options are currently available:

=over 2

=item limit

  limit => 20

Number of shared locks with the same name that can be active at the same time,
defaults to C<1>.

=back

=head2 new

  my $minion = Minion->new(Pg => 'postgresql://postgres@/test');
  my $minion = Minion->new(Pg => Mojo::Pg->new);

Construct a new L<Minion> object.

=head2 perform_jobs

  $minion->perform_jobs;
  $minion->perform_jobs({queues => ['important']});

Perform all jobs with a temporary worker, very useful for testing.

  # Longer version
  my $worker = $minion->worker;
  while (my $job = $worker->register->dequeue(0)) { $job->perform }
  $worker->unregister;

These options are currently available:

=over 2

=item queues

  queues => ['important']

One or more queues to dequeue jobs from, defaults to C<default>.

=back

=head2 repair

  $minion = $minion->repair;

Repair worker registry and job queue if necessary.

=head2 reset

  $minion = $minion->reset;

Reset job queue.

=head2 stats

  my $stats = $minion->stats;

Get statistics for jobs and workers.

  # Check idle workers
  my $idle = $minion->stats->{inactive_workers};

These fields are currently available:

=over 2

=item active_jobs

  active_jobs => 100

Number of jobs in C<active> state.

=item active_workers

  active_workers => 100

Number of workers that are currently processing a job.

=item delayed_jobs

  delayed_jobs => 100

Number of jobs in C<inactive> state that are scheduled to run at specific time
in the future or have unresolved dependencies. Note that this field is
EXPERIMENTAL and might change without warning!

=item enqueued_jobs

  enqueued_jobs => 100000

Rough estimate of how many jobs have ever been enqueued. Note that this field is
EXPERIMENTAL and might change without warning!

=item failed_jobs

  failed_jobs => 100

Number of jobs in C<failed> state.

=item finished_jobs

  finished_jobs => 100

Number of jobs in C<finished> state.

=item inactive_jobs

  inactive_jobs => 100

Number of jobs in C<inactive> state.

=item inactive_workers

  inactive_workers => 100

Number of workers that are currently not processing a job.

=item uptime

  uptime => 1000

Uptime in seconds.

=back

=head2 unlock

  my $bool = $minion->unlock('foo');

Release a named lock that has been previously acquired with L</"lock">.

=head2 worker

  my $worker = $minion->worker;

Build L<Minion::Worker> object.

=head1 REFERENCE

This is the class hierarchy of the L<Minion> distribution.

=over 2

=item * L<Minion>

=item * L<Minion::Backend>

=over 2

=item * L<Minion::Backend::Pg>

=back

=item * L<Minion::Command::minion>

=item * L<Minion::Command::minion::job>

=item * L<Minion::Command::minion::worker>

=item * L<Minion::Job>

=item * L<Minion::Worker>

=item * L<Mojolicious::Plugin::Minion>

=item * L<Mojolicious::Plugin::Minion::Admin>

=back

=head1 BUNDLED FILES

The L<Minion> distribution includes a few files with different licenses that
have been bundled for internal use.

=head2 Minion Artwork

  Copyright (C) 2017, Sebastian Riedel.

Licensed under the CC-SA License, Version 4.0
L<http://creativecommons.org/licenses/by-sa/4.0>.

=head2 Bootstrap

  Copyright (C) 2011-2016 Twitter, Inc.

Licensed under the MIT License, L<http://creativecommons.org/licenses/MIT>.

=head2 D3.js

  Copyright (C) 2010-2016, Michael Bostock.

Licensed under the 3-Clause BSD License,
L<https://opensource.org/licenses/BSD-3-Clause>.

=head2 epoch.js

  Copyright (C) 2014 Fastly, Inc.

Licensed under the MIT License, L<http://creativecommons.org/licenses/MIT>.

=head2 Font Awesome

  Copyright (C) Dave Gandy.

Licensed under the MIT License, L<http://creativecommons.org/licenses/MIT>, and
the SIL OFL 1.1, L<http://scripts.sil.org/OFL>.

=head2 moment.js

  Copyright (C) JS Foundation and other contributors.

Licensed under the MIT License, L<http://creativecommons.org/licenses/MIT>.

=head1 AUTHOR

Sebastian Riedel, C<sri@cpan.org>.

=head1 CREDITS

In alphabetical order:

=over 2

Andrey Khozov

Brian Medley

Hubert "depesz" Lubaczewski

Joel Berger

Paul Williams

=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014-2017, Sebastian Riedel and others.

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<https://github.com/kraih/minion>, L<Mojolicious::Guides>,
L<http://mojolicious.org>.

=cut
