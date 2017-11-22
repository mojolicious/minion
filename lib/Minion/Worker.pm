package Minion::Worker;
use Mojo::Base 'Mojo::EventEmitter';

use Carp 'croak';
use Mojo::Util 'steady_time';

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

sub run {
  my $self = shift;

  my $status = $self->status;
  $status->{command_interval}   //= 10;
  $status->{heartbeat_interval} //= 300;
  $status->{jobs}               //= 4;
  $status->{queues} ||= ['default'];
  $status->{performed}       //= 0;
  $status->{repair_interval} //= 21600;
  $status->{repair_interval} -= int rand $status->{repair_interval} / 2;

  local $SIG{CHLD} = sub { };
  local $SIG{INT} = local $SIG{TERM} = sub { $self->{finished}++ };
  local $SIG{QUIT}
    = sub { ++$self->{finished} and kill 'KILL', keys %{$self->{jobs}} };

  # Remote control commands need to validate arguments carefully
  my $commands = $self->commands;
  local $commands->{jobs}
    = sub { $status->{jobs} = $_[1] if ($_[1] // '') =~ /^\d+$/ };
  local $commands->{stop}
    = sub { $self->{jobs}{$_[1]}->stop if $self->{jobs}{$_[1] // ''} };

  eval { $self->_work until $self->{finished} && !keys %{$self->{jobs}} };
  my $err = $@;
  $self->unregister;
  croak $err if $err;
}

sub unregister {
  my $self = shift;
  $self->minion->backend->unregister_worker(delete $self->{id});
  return $self;
}

sub _work {
  my $self = shift;

  # Send heartbeats in regular intervals
  my $status = $self->status;
  $self->{last_heartbeat} ||= -$status->{heartbeat_interval};
  $self->register and $self->{last_heartbeat} = steady_time
    if ($self->{last_heartbeat} + $status->{heartbeat_interval}) < steady_time;

  # Process worker remote control commands in regular intervals
  $self->{last_command} ||= 0;
  $self->process_commands and $self->{last_command} = steady_time
    if ($self->{last_command} + $status->{command_interval}) < steady_time;

  # Repair in regular intervals (randomize to avoid congestion)
  $self->{last_repair} ||= 0;
  if (($self->{last_repair} + $status->{repair_interval}) < steady_time) {
    $self->minion->repair;
    $self->{last_repair} = steady_time;
  }

  # Check if jobs are finished
  my $jobs = $self->{jobs} ||= {};
  $jobs->{$_}->is_finished and ++$status->{performed} and delete $jobs->{$_}
    for keys %$jobs;

  # Wait if job limit has been reached or worker is stopping
  if (($status->{jobs} <= keys %$jobs) || $self->{finished}) { sleep 1 }

  # Try to get more jobs
  elsif (my $job = $self->dequeue(5 => {queues => $status->{queues}})) {
    $jobs->{my $id = $job->id} = $job->start;
    my ($pid, $task) = ($job->pid, $job->task);
  }
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

=head1 SIGNALS

The L<Minion::Worker> process can be controlled at runtime with the following
signals.

=head2 INT, TERM

Stop gracefully after finishing the current jobs.

=head2 QUIT

Stop immediately without finishing the current jobs.

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

Status information to configure workers started with L</"run"> and to share
every time L</"register"> is called.

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

=head2 run

  $worker->run;

Run worker and wait for L</"SIGNALS">.

These L</"status"> options are currently available:

=over 2

=item command_interval

  command_interval => 20

Worker remote control command interval, defaults to C<10>.

=item heartbeat_interval

  heartbeat_interval => 60

Heartbeat interval, defaults to C<300>.

=item jobs

  jobs => 12

Maximum number of jobs to perform parallel in forked worker processes, defaults
to C<4>.

=item queues

  queues => ['test']

One or more queues to get jobs from, defaults to C<default>.

=item repair_interval

  repair_interval => 3600

Repair interval, up to half of this value can be subtracted randomly to make
sure not all workers repair at the same time, defaults to C<21600> (6 hours).

=back

These remote control L</"commands"> are currently available:

=over 2

=item jobs

  $minion->broadcast('jobs', [10]);
  $minion->broadcast('jobs', [10], [$worker_id]);

Instruct one or more workers to change the number of jobs to perform
concurrently. Setting this value to C<0> will effectively pause the worker. That
means all current jobs will be finished, but no new ones accepted, until the
number is increased again.

=item stop

  $minion->broadcast('stop', [10025]);
  $minion->broadcast('stop', [10025], [$worker_id]);

Instruct one or more workers to stop a job that is currently being performed
immediately. This command will be ignored by workers that do not have a job
matching the id. That means it is safe to broadcast this command to all workers.

=back

=head2 unregister

  $worker = $worker->unregister;

Unregister worker.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
