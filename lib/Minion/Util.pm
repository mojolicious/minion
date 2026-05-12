package Minion::Util;
use Mojo::Base -strict;

use Carp     qw(croak);
use Exporter qw(import);

our @EXPORT_OK = qw(desired_tasks next_cron_time parse_cron);

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
  my ($expr, $from) = @_;

  my $parsed = parse_cron($expr);
  my $t      = int($from / 60) * 60 + 60;
  my $limit  = $t + 5 * 366 * 86400;
  while ($t < $limit) {
    my (undef, $min, $hour, $mday, $mon, undef, $wday) = localtime $t;
    return $t
      if $parsed->[0]{set}{$min}
      && $parsed->[1]{set}{$hour}
      && _day_match($parsed, $mday, $wday)
      && $parsed->[3]{set}{$mon + 1};
    $t += 60;
  }

  croak qq{No matching time found for cron expression "$expr"};
}

sub parse_cron {
  my $expr = shift;

  my @fields = split /\s+/, $expr // '';
  croak qq{Invalid cron expression "$expr": expected 5 fields} unless @fields == 5;

  my @ranges = ([0, 59], [0, 23], [1, 31], [1, 12], [0, 6]);
  return [map { _parse_field($fields[$_], @{$ranges[$_]}) } 0 .. 4];
}

sub _day_match {
  my ($parsed, $mday, $wday) = @_;
  return 1                        if $parsed->[2]{is_star} && $parsed->[4]{is_star};
  return $parsed->[4]{set}{$wday} if $parsed->[2]{is_star};
  return $parsed->[2]{set}{$mday} if $parsed->[4]{is_star};
  return $parsed->[2]{set}{$mday} || $parsed->[4]{set}{$wday};
}

sub _parse_field {
  my ($field, $min, $max) = @_;

  my $is_star = $field eq '*' ? 1 : 0;
  my %set;
  for my $part (split /,/, $field) {
    my ($range, $step) = split m{/}, $part, 2;
    $step //= 1;
    croak qq{Invalid cron step "$step"} unless $step =~ /^[1-9]\d*$/;

    my ($a, $b);
    if    ($range eq '*')             { ($a, $b) = ($min, $max) }
    elsif ($range =~ /^(\d+)-(\d+)$/) { ($a, $b) = ($1, $2) }
    elsif ($range =~ /^(\d+)$/)       { ($a, $b) = ($1, $step > 1 ? $max : $1) }
    else                              { croak qq{Invalid cron field "$part"} }
    croak qq{Cron value out of range in "$part"} if $a < $min || $b > $max || $a > $b;

    for (my $v = $a; $v <= $b; $v += $step) { $set{$v} = 1 }
  }

  return {set => \%set, is_star => $is_star};
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

  my $epoch = next_cron_time $expr, $from;

Compute the next epoch time matching a five field cron expression, strictly after the given epoch. Times are
interpreted in the local timezone, matching the convention of Unix L<cron(8)>.

  # 1747053900 (next 12:05 local time after 1747053600)
  next_cron_time '*/5 * * * *', 1747053600;

=head2 parse_cron

  my $parsed = parse_cron $expr;

Parse a five field cron expression into a structure suitable for matching. Croaks on invalid input. The supported syntax
covers C<*>, C<*/N>, C<a-b>, C<a-b/N> and comma separated lists for the fields C<minute>, C<hour>, C<day-of-month>,
C<month> and C<day-of-week> (C<0> is Sunday). When both C<day-of-month> and C<day-of-week> are restricted, jobs run when
B<either> matches, following the standard Vixie L<cron(8)> behavior.

  # Every weekday at 9 in the morning
  parse_cron '0 9 * * 1-5';

=head1 SEE ALSO

L<Minion>, L<Minion::Guide>, L<https://minion.pm>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
