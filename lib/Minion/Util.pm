package Minion::Util;
use Mojo::Base -strict;

use Carp        qw(croak);
use Exporter    qw(import);
use Time::Local qw(timegm);

our @EXPORT_OK = qw(desired_tasks next_cron_time parse_cron);

my %NICKNAMES = (
  '@yearly'   => '0 0 1 1 *',
  '@annually' => '0 0 1 1 *',
  '@monthly'  => '0 0 1 * *',
  '@weekly'   => '0 0 * * 0',
  '@daily'    => '0 0 * * *',
  '@midnight' => '0 0 * * *',
  '@hourly'   => '0 * * * *',
);

my %MONTH_NAMES = (
  jan => 1,
  feb => 2,
  mar => 3,
  apr => 4,
  may => 5,
  jun => 6,
  jul => 7,
  aug => 8,
  sep => 9,
  oct => 10,
  nov => 11,
  dec => 12
);
my %DAY_NAMES = (sun => 0, mon => 1, tue => 2, wed => 3, thu => 4, fri => 5, sat => 6);

my @FIELDS = (
  ['minute',       0, 59],
  ['hour',         0, 23],
  ['day-of-month', 1, 31],
  ['month',        1, 12, \%MONTH_NAMES],
  ['day-of-week',  0, 7,  \%DAY_NAMES],
);

sub desired_tasks {
  my ($limits, $available_tasks, $active_tasks) = @_;

  my %count;
  $count{$_}++ for @$active_tasks;

  my @desired;
  for my $task (@$available_tasks) {
    my $count = $count{$task} // 0;
    my $limit = $limits->{$task};
    push @desired, $task if !defined($limit) || $count < $limit;
  }

  return \@desired;
}

sub next_cron_time {
  my ($cron, $from) = @_;
  my $parsed = ref $cron ? $cron : parse_cron($cron);

  my $t     = int($from / 60) * 60 + 60;
  my $limit = $t + 5 * 366 * 86400;
  while ($t < $limit) {
    my (undef, $min, $hour, $mday, $mon, $year, $wday) = gmtime $t;
    $mon++;

    # Month
    if (!$parsed->[3]{set}{$mon}) {
      my $next = _next_value($parsed->[3]{values}, $mon);
      $t
        = defined $next
        ? timegm(0, 0, 0, 1, $next - 1,                   $year)
        : timegm(0, 0, 0, 1, $parsed->[3]{values}[0] - 1, $year + 1);
      next;
    }

    # Day of month / day of week (Vixie OR semantics)
    if (!_day_match($parsed, $mday, $wday)) {
      $t = timegm(0, 0, 0, $mday, $mon - 1, $year) + 86400;
      next;
    }

    # Hour
    if (!$parsed->[1]{set}{$hour}) {
      my $next = _next_value($parsed->[1]{values}, $hour);
      $t
        = defined $next ? timegm(0, 0, $next, $mday, $mon - 1, $year) : timegm(0, 0, 0, $mday, $mon - 1, $year) + 86400;
      next;
    }

    # Minute
    if (!$parsed->[0]{set}{$min}) {
      my $next = _next_value($parsed->[0]{values}, $min);
      $t
        = defined $next
        ? timegm(0, $next, $hour, $mday, $mon - 1, $year)
        : timegm(0, 0,     $hour, $mday, $mon - 1, $year) + 3600;
      next;
    }

    return $t;
  }

  croak qq{No matching time found for cron expression};
}

sub parse_cron {
  my $expr = shift // '';

  if ($expr =~ /^@/) {
    croak qq{Unknown cron nickname "$expr"} unless exists $NICKNAMES{$expr};
    $expr = $NICKNAMES{$expr};
  }

  my @fields = split /\s+/, $expr;
  croak qq{Invalid cron expression "$expr": expected 5 fields} unless @fields == 5;

  return [map { _parse_field($fields[$_], @{$FIELDS[$_]}) } 0 .. 4];
}

sub _day_match {
  my ($parsed, $mday, $wday) = @_;
  return 1                        if $parsed->[2]{is_star} && $parsed->[4]{is_star};
  return $parsed->[4]{set}{$wday} if $parsed->[2]{is_star};
  return $parsed->[2]{set}{$mday} if $parsed->[4]{is_star};
  return $parsed->[2]{set}{$mday} || $parsed->[4]{set}{$wday};
}

sub _next_value {
  my ($values, $after) = @_;
  for my $v (@$values) { return $v if $v >= $after }
  return undef;
}

sub _parse_field {
  my ($field, $name, $min, $max, $names) = @_;

  my $is_star = $field eq '*' ? 1 : 0;
  my %set;
  for my $part (split /,/, $field) {
    my ($range, $step) = split m{/}, $part, 2;
    $step //= 1;
    croak qq{Invalid step "$step" in $name field} unless $step =~ /^[1-9]\d*$/;

    my ($a, $b);
    if    ($range eq '*')             { ($a, $b) = ($min, $max) }
    elsif ($range =~ /^(\w+)-(\w+)$/) { ($a, $b) = (_resolve($1, $name, $names), _resolve($2, $name, $names)) }
    elsif ($range =~ /^(\w+)$/)       { $a = $b = _resolve($1, $name, $names) }
    else                              { croak qq{Invalid $name field "$part"} }
    croak qq{Value out of range in $name field "$part" ($min-$max)} if $a < $min || $b > $max || $a > $b;

    for (my $v = $a; $v <= $b; $v += $step) { $set{$v} = 1 }
  }

  # Day-of-week 7 is an alias for Sunday (0)
  $set{0} = 1 if $name eq 'day-of-week' && delete $set{7};

  return {set => \%set, values => [sort { $a <=> $b } keys %set], is_star => $is_star};
}

sub _resolve {
  my ($value, $name, $names) = @_;
  return $value + 0 if $value =~ /^\d+$/;
  croak qq{Invalid name "$value" in $name field} unless $names && exists $names->{lc $value};
  return $names->{lc $value};
}

1;

=encoding utf8

=head1 NAME

Minion::Util - Minion utility functions

=head1 SYNOPSIS

  use Minion::Util qw(desired_tasks next_cron_time parse_cron);

=head1 DESCRIPTION

L<Minion::Util> provides utility functions for L<Minion>.

=head1 FUNCTIONS

L<Minion::Util> implements the following functions, which can be imported individually.

=head2 desired_tasks

  my $desired_tasks = desired_tasks $limits, $available_tasks, $active_tasks;

Enforce limits and generate list of currently desired tasks.

  # ['bar']
  desired_tasks {foo => 2}, ['foo', 'bar'], ['foo', 'foo'];

=head2 next_cron_time

  my $epoch = next_cron_time $expr,   $from;
  my $epoch = next_cron_time $parsed, $from;

Compute the next epoch time matching a five field cron expression, strictly after the given epoch. All times are
interpreted in B<UTC>, not local time. Accepts either a cron expression string or a structure returned by
L</"parse_cron">, so the parsed form can be reused across calls without reparsing.

  # 1747051500 (next 12:05 UTC after 1747051200)
  next_cron_time '*/5 * * * *', 1747051200;

  # Reuse the parsed structure
  my $cron = parse_cron '0 4 * * *';
  my $next = next_cron_time $cron, time;

=head2 parse_cron

  my $parsed = parse_cron $expr;

Parse a five field cron expression into a structure suitable for matching. Croaks on invalid input. The supported
syntax covers C<*>, C<*/N>, C<a-b>, C<a-b/N> and comma separated lists for the fields C<minute>, C<hour>,
C<day-of-month>, C<month> and C<day-of-week>. The C<month> field also accepts the names C<JAN>-C<DEC>, and the
C<day-of-week> field accepts C<SUN>-C<SAT> and treats both C<0> and C<7> as Sunday (names are case-insensitive). When
both C<day-of-month> and C<day-of-week> are restricted, jobs run when B<either> matches, following the standard Vixie
L<cron(8)> behavior. The nicknames C<@yearly>, C<@annually>, C<@monthly>, C<@weekly>, C<@daily>, C<@midnight> and
C<@hourly> expand to the equivalent five field expression.

  # Every weekday at 9 in the morning
  parse_cron '0 9 * * MON-FRI';

  # Every day at midnight
  parse_cron '@daily';

=head1 SEE ALSO

L<Minion>, L<Minion::Guide>, L<https://minion.pm>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
