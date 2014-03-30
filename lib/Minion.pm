package Minion;
use Mojo::Base -base;

use Mango;
use Mango::BSON 'bson_time';
use Minion::Job;
use Minion::Worker;
use Mojo::Server;

our $VERSION = '0.03';

has app  => sub { Mojo::Server->new->build_app('Mojo::HelloWorld') };
has jobs => sub { $_[0]->mango->db->collection($_[0]->prefix . '.jobs') };
has 'mango';
has prefix => 'minion';
has tasks => sub { {} };
has workers =>
  sub { $_[0]->mango->db->collection($_[0]->prefix . '.workers') };

sub add_task {
  my ($self, $name, $cb) = @_;
  $self->tasks->{$name} = $cb;
  return $self;
}

sub enqueue {
  my ($self, $task, $args, $options) = @_;
  $options //= {};

  my $doc = {
    after => $options->{after} // bson_time(1),
    args  => $args             // [],
    created  => bson_time,
    priority => $options->{priority} // 0,
    state    => 'inactive',
    task     => $task
  };
  return $self->jobs->insert($doc);
}

sub job {
  my ($self, $oid) = @_;

  return undef
    unless my $job = $self->jobs->find_one($oid, {args => 1, task => 1});
  return Minion::Job->new(
    args   => $job->{args},
    id     => $job->{_id},
    minion => $self,
    task   => $job->{task}
  );
}

sub new { shift->SUPER::new(mango => Mango->new(@_)) }

sub stats {
  my $self = shift;

  my $jobs    = $self->jobs;
  my $active  = @{$jobs->find({state => 'active'})->distinct('worker')};
  my $workers = $self->workers;
  my $all     = $workers->find->count;
  my $stats = {active_workers => $active, inactive_workers => $all - $active};
  $stats->{"${_}_jobs"} = $jobs->find({state => $_})->count
    for qw(active failed finished inactive);
  return $stats;
}

sub worker { Minion::Worker->new(minion => shift) }

1;

=encoding utf8

=head1 NAME

Minion - Job queue

=head1 SYNOPSIS

  use Minion;

  # Add tasks
  my $minion = Minion->new('mongodb://localhost:27017');
  $minion->add_task(something_slow => sub {
    my ($job, @args) = @_;
    sleep 5;
    say 'This is a background worker process.';
  });

  # Enqueue jobs (data gets BSON serialized)
  $minion->enqueue(something_slow => ['foo', 'bar']);
  $minion->enqueue(something_slow => [1, 2, 3]);

  # Create a worker and perform jobs right away (useful for testing)
  my $worker = $minion->worker;
  $worker->one_job;
  $worker->all_jobs;

  # Build more sophisticated workers
  my $worker = $minion->worker->repair->register;
  if (my $job = $worker->dequeue) { $job->perform }
  $worker->unregister;

=head1 DESCRIPTION

L<Minion> is a L<Mango> job queue for the L<Mojolicious> real-time web
framework.

Background worker processes are usually started with the command
L<Minion::Command::minion::worker>, which becomes automatically available when
an application loads the plugin L<Mojolicious::Plugin::Minion>.

  $ ./myapp.pl minion worker

Note that this whole distribution is EXPERIMENTAL and will change without
warning!

Many features are still incomplete or missing, so you should wait for a stable
1.0 release before using any of the modules in this distribution in a
production environment.

=head1 ATTRIBUTES

L<Minion> implements the following attributes.

=head2 app

  my $app = $minion->app;
  $minion = $minion->app(MyApp->new);

Application for job queue, defaults to a L<Mojo::HelloWorld> object.

=head2 jobs

  my $jobs = $minion->jobs;
  $minion  = $minion->jobs(Mango::Collection->new);

L<Mango::Collection> object for C<jobs> collection, defaults to one based on
L</"prefix">.

=head2 mango

  my $mango = $minion->mango;
  $minion   = $minion->mango(Mango->new);

L<Mango> object used to store collections.

=head2 prefix

  my $prefix = $minion->prefix;
  $minion    = $minion->prefix('foo');

Prefix for collections, defaults to C<minion>.

=head2 tasks

  my $tasks = $minion->tasks;
  $minion   = $minion->tasks({foo => sub {...}});

Registered tasks.

=head2 workers

  my $workers = $minion->workers;
  $minion     = $minion->workers(Mango::Collection->new);

L<Mango::Collection> object for C<workers> collection, defaults to one based
on L</"prefix">.

=head1 METHODS

L<Minion> inherits all methods from L<Mojo::Base> and implements the following
new ones.

=head2 add_task

  $minion = $minion->add_task(foo => sub {...});

Register a new task.

=head2 enqueue

  my $oid = $minion->enqueue('foo');
  my $oid = $minion->enqueue(foo => [@args]);
  my $oid = $minion->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state.

These options are currently available:

=over 2

=item after

  after => bson_time((time + 1) * 1000)

Perform job only after this point in time.

=item priority

  priority => 5

Job priority.

=back

=head2 job

  my $job = $minion->job($oid);

Get L<Minion::Job> object without making any changes to the actual job or
return C<undef> if job does not exist.

=head2 new

  my $minion = Minion->new;
  my $minion = Minion->new('mongodb://127.0.0.1:27017');

Construct a new L<Minion> object and pass connection string to L</"mango"> if
necessary.

=head2 stats

  my $stats = $minion->stats;

Get statistics for jobs and workers.

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

L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
