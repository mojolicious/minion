package Minion::Iterator;
use Mojo::Base -base;

has fetch => 10;
has [qw(minion options)];

sub next { shift @{shift->_fetch(0)->{results}} }

sub total { shift->_fetch(1)->{total} }

sub _fetch {
  my ($self, $lazy) = @_;

  return $self if ($lazy && exists $self->{total}) || @{$self->{results} // []};

  my $what    = $self->{jobs} ? 'jobs' : 'workers';
  my $method  = "list_$what";
  my $options = $self->options;
  my $results = $self->minion->backend->$method(0, $self->fetch, $options);

  $self->{total} = $results->{total} + ($self->{count} // 0);
  $self->{count} += my @results = @{$results->{$what}};
  push @{$self->{results}}, @results;
  $options->{before} = $results[-1]{id} if @results;

  return $self;
}

1;

=encoding utf8

=head1 NAME

Minion::Iterator - Minion iterator

=head1 SYNOPSIS

  use Minion::Iterator;

  my $iter = Minion::Iterator->new(minion  => $minion, options => {states => ['inactive']});

=head1 DESCRIPTION

L<Minion::Iterator> is an iterator for L<Minion> listing methods.

=head1 ATTRIBUTES

L<Minion::Iterator> implements the following attributes.

=head2 fetch

  my $fetch = $iter->fetch;
  $iter     = $iter->fetch(2);

Number of results to cache, defaults to C<10>.

=head2 minion

  my $minion = $iter->minion;
  $iter      = $iter->minion(Minion->new);

L<Minion> object this job belongs to.

=head2 options

  my $options = $iter->options;
  $iter       = $iter->options({states => ['inactive']});

Options to be passed to L<Minion::Backend/"list_jobs"> or L<Minion::Backend/"list_workers">.

=head1 METHODS

L<Minion::Iterator> inherits all methods from L<Mojo::Base> and implements the following new ones.

=head2 next

  my $value = $iter->next;

Get next value.

=head2 total

  my $num = $iter->total;

Total number of results. If results are removed in the backend while iterating, this number will become an estimate
that gets updated every time new results are fetched.

=head1 SEE ALSO

L<Minion>, L<https://minion.pm>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
