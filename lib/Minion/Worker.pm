package Minion::Worker;
use Mojo::Base 'Mojo::EventEmitter';

has [qw(commands status)] => sub { {} };
has [qw(id minion)];

sub add_command { $_[0]->commands->{$_[1]} = $_[2] and return $_[0] }

sub dequeue {
  my ($self, $wait, $options) = @_;

  # Worker not registered
  return undef unless my $id = $self->id;

  my $minion = $self->minion;
  return undef unless my $job = $minion->backend->dequeue($id, $wait, $options);
  $job = Minion::Job->new(
    args    => $job->{args},
    id      => $job->{id},
    minion  => $minion,
    retries => $job->{retries},
    task    => $job->{task}
  );
  $self->emit(dequeue => $job);
  return $job;
}

sub info {
  $_[0]->minion->backend->list_workers(0, 1, {ids => [$_[0]->id]})
    ->{workers}[0];
}

sub process_commands {
  my $self = shift;

  for my $command (@{$self->minion->backend->receive($self->id)}) {
    next unless my $cb = $self->commands->{shift @$command};
    $self->$cb(@$command);
  }

  return $self;
}

sub register {
  my $self = shift;
  my $status = {status => $self->status};
  return $self->id($self->minion->backend->register_worker($self->id, $status));
}

sub unregister {
  my $self = shift;
  $self->minion->backend->unregister_worker(delete $self->{id});
  return $self;
}

1;

=encoding utf8

=head1 NAME

Minion::Worker - Minion worker

=head1 SYNOPSIS

  use Minion::Worker;

  my $worker = Minion::Worker->new(minion => $minion);

=head1 DESCRIPTION

L<Minion::Worker> performs jobs for L<Minion>.

=head1 EVENTS

L<Minion::Worker> inherits all events from L<Mojo::EventEmitter> and can emit
the following new ones.

=head2 dequeue

  $worker->on(dequeue => sub {
    my ($worker, $job) = @_;
    ...
  });

Emitted in the worker process after a job has been dequeued.

  $worker->on(dequeue => sub {
    my ($worker, $job) = @_;
    my $id = $job->id;
    say "Job $id has been dequeued.";
  });

=head1 ATTRIBUTES

L<Minion::Worker> implements the following attributes.

=head2 commands

  my $commands = $worker->commands;
  $worker      = $worker->commands({jobs => sub {...}});

Registered worker remote control commands.

=head2 id

  my $id  = $worker->id;
  $worker = $worker->id($id);

Worker id.

=head2 minion

  my $minion = $worker->minion;
  $worker    = $worker->minion(Minion->new);

L<Minion> object this worker belongs to.

=head2 status

  my $status = $worker->status;
  $worker    = $worker->status({queues => ['default', 'important']);

Status information to share every time L</"register"> is called.

=head1 METHODS

L<Minion::Worker> inherits all methods from L<Mojo::EventEmitter> and
implements the following new ones.

=head2 add_command

  $worker = $worker->add_command(jobs => sub {...});

Register a worker remote control command.

  $worker->add_command(foo => sub {
    my ($worker, @args) = @_;
    ...
  });

=head2 dequeue

  my $job = $worker->dequeue(0.5);
  my $job = $worker->dequeue(0.5 => {queues => ['important']});

Wait a given amount of time in seconds for a job, dequeue L<Minion::Job> object
and transition from C<inactive> to C<active> state, or return C<undef> if queues
were empty.

These options are currently available:

=over 2

=item id

  id => '10023'

Dequeue a specific job.

=item queues

  queues => ['important']

One or more queues to dequeue jobs from, defaults to C<default>.

=back

=head2 info

  my $info = $worker->info;

Get worker information.

  # Check worker host
  my $host = $worker->info->{host};

These fields are currently available:

=over 2

=item host

  host => 'localhost'

Worker host.

=item jobs

  jobs => ['10023', '10024', '10025', '10029']

Ids of jobs the worker is currently processing.

=item notified

  notified => 784111777

Epoch time worker sent the last heartbeat.

=item pid

  pid => 12345

Process id of worker.

=item started

  started => 784111777

Epoch time worker was started.

=item status

  status => {queues => ['default', 'important']}

Hash reference with whatever status information the worker would like to share.

=back

=head2 process_commands

  $worker = $worker->process_commands;

Process worker remote control commands.

=head2 register

  $worker = $worker->register;

Register worker or send heartbeat to show that this worker is still alive.

=head2 unregister

  $worker = $worker->unregister;

Unregister worker.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
