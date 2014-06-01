package Minion::Backend;
use Mojo::Base -base;

use Carp 'croak';

has 'minion';

sub dequeue    { croak 'Method "dequeue" not implemented by subclass' }
sub enqueue    { croak 'Method "enqueue" not implemented by subclass' }
sub fail_job   { croak 'Method "fail_job" not implemented by subclass' }
sub finish_job { croak 'Method "finish_job" not implemented by subclass' }
sub job_info   { croak 'Method "job_info" not implemented by subclass' }

sub register_worker {
  croak 'Method "register_worker" not implemented by subclass';
}

sub remove_job  { croak 'Method "remove_job" not implemented by subclass' }
sub repair      { croak 'Method "repair" not implemented by subclass' }
sub reset       { croak 'Method "reset" not implemented by subclass' }
sub restart_job { croak 'Method "restart_job" not implemented by subclass' }
sub stats       { croak 'Method "stats" not implemented by subclass' }

sub unregister_worker {
  croak 'Method "unregister_worker" not implemented by subclass';
}

sub worker_info { croak 'Method "worker_info" not implemented by subclass' }

1;

=encoding utf8

=head1 NAME

Minion::Backend - Backend base class

=head1 SYNOPSIS

  package Minion::Backend::MyBackend;
  use Mojo::Base 'Minion::Backend';

  sub dequeue           {...}
  sub enqueue           {...}
  sub fail_job          {...}
  sub finish_job        {...}
  sub job_info          {...}
  sub register_worker   {...}
  sub remove_job        {...}
  sub repair            {...}
  sub reset             {...}
  sub restart_job       {...}
  sub stats             {...}
  sub unregister_worker {...}
  sub worker_info       {...}

=head1 DESCRIPTION

L<Minion::Backend> is an abstract base class for L<Minion> backends.

=head1 ATTRIBUTES

L<Minion::Backend> implements the following attributes.

=head2 minion

  my $minion = $backend->minion;
  $backend   = $backend->minion(Minion->new);

L<Minion> object this backend belongs to.

=head1 METHODS

L<Minion::Backend> inherits all methods from L<Mojo::Base> and implements the
following new ones.

=head2 dequeue

  my $info = $backend->dequeue($worker_id);

Dequeue job and transition from C<inactive> to C<active> state or return
C<undef> if queue was empty. Meant to be overloaded in a subclass.

=head2 enqueue

  my $job_id = $backend->enqueue('foo');
  my $job_id = $backend->enqueue(foo => [@args]);
  my $job_id = $backend->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state. You can also append a callback to
perform operation non-blocking. Meant to be overloaded in a subclass.

  $backend->enqueue(foo => sub {
    my ($backend, $err, $job_id) = @_;
    ...
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 fail_job

  my $bool = $backend->fail_job;
  my $bool = $backend->fail_job($job_id, 'Something went wrong!');

Transition from C<active> to C<failed> state. Meant to be overloaded in a
subclass.

=head2 finish_job

  my $bool = $backend->finish_job($job_id);

Transition from C<active> to C<finished> state. Meant to be overloaded in a
subclass.

=head2 job_info

  my $info = $backend->job_info($job_id);

Get information about a job. Meant to be overloaded in a subclass.

=head2 register_worker

  my $worker_id = $backend->register_worker;

Register worker. Meant to be overloaded in a subclass.

=head2 remove_job

  my $bool = $backend->remove_job($job_id);

Remove C<failed>, C<finished> or C<inactive> job from queue. Meant to be
overloaded in a subclass.

=head2 repair

  $backend->repair;

Repair worker registry and job queue. Meant to be overloaded in a subclass.

=head2 reset

  $backend->reset;

Reset job queue. Meant to be overloaded in a subclass.

=head2 restart_job

  my $bool = $backend->restart_job;

Transition from C<failed> or C<finished> state back to C<inactive>. Meant to
be overloaded in a subclass.

=head2 stats

  my $stats = $backend->stats;

Get statistics for jobs and workers. Meant to be overloaded in a subclass.

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker. Meant to be overloaded in a subclass.

=head2 worker_info

  my $info = $backend->worker_info($worker_id);

Get information about a worker. Meant to be overloaded in a subclass.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
