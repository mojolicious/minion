package Minion::Iterator;
use Mojo::Base -base;

has fetch => 10;
has [qw(minion options what)];

sub next { shift @{shift->_fetch->{results}} }

sub _fetch {
  my $self = shift;

  return $self if @{$self->{results} // []};

  my $what    = $self->what;
  my $method  = "list_$what";
  my $options = $self->options;
  my $results = $self->minion->backend->$method(0, $self->fetch, $options);

  push @{$self->{results}}, my @results = @{$results->{$what}};
  $options->{before} = $results[-1]{id} if @results;

  return $self;
}

1;

=encoding utf8

=head1 NAME

Minion::Iterator - Minion iterator

=head1 SYNOPSIS

  use Minion::Iterator;

  my $iter = Minion::Iterator->new(
    minion  => $minion,
    options => {states => ['inactive']},
    what    => 'jobs'
  );
  while (my $info = $iter->next) {
    say $info->{id};
  }

=head1 DESCRIPTION

L<Minion::Iterator> is an iterator for L<Minion> listing methods. Note that this
module is EXPERIMENTAL and might change without warning!

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

Options to be passed to L<Minion::Backend/"list_jobs"> or
L<Minion::Backend/"list_workers">.

=head2 what

  my $what = $iter->what;
  $iter    = $iter->what('jobs');

What to L</"fetch">.

=head1 METHODS

L<Minion::Iterator> inherits all methods from L<Mojo::Base> and implements the
following new ones.

=head2 next

  my $value = $iter->next;

Get next value.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
