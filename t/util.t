use Mojo::Base -strict;

use Test::More;
use Minion::Util qw(desired_tasks next_cron_time parse_cron);
use Time::Local  qw(timelocal);

subtest 'desired_tasks' => sub {
  is_deeply desired_tasks({},                   [],                    []),                    [],      'no tasks';
  is_deeply desired_tasks({foo => 2},           ['foo', 'bar'],        ['foo', 'foo']),        ['bar'], 'right tasks';
  is_deeply desired_tasks({foo => 0},           ['foo', 'bar'],        []),                    ['bar'], 'right tasks';
  is_deeply desired_tasks({foo => 2},           ['foo', 'bar'],        ['foo', 'foo', 'foo']), ['bar'], 'right tasks';
  is_deeply desired_tasks({foo => 2, bar => 1}, ['foo', 'bar', 'baz'], ['foo', 'bar', 'foo']), ['baz'], 'right tasks';
  is_deeply desired_tasks({foo => 2, bar => 1}, ['foo', 'bar'],        ['foo', 'foo', 'bar']), [],      'no tasks';
  is_deeply desired_tasks({},                   ['foo', 'bar'],        ['foo', 'foo']), ['foo', 'bar'], 'right tasks';
};

subtest 'parse_cron: basic forms' => sub {
  is_deeply [sort { $a <=> $b } keys %{parse_cron('* * * * *')->[0]{set}}], [0 .. 59], 'star expands minutes';
  is parse_cron('* * * * *')->[0]{is_star}, 1, 'star flag set';
  is parse_cron('5 * * * *')->[0]{is_star}, 0, 'is_star clear for value';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('5,15,25 * * * *')->[0]{set}}], [5, 15, 25], 'list parsed';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('0 9-17 * * *')->[1]{set}}], [9 .. 17], 'range parsed';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('*/15 * * * *')->[0]{set}}], [0, 15, 30, 45], 'star step parsed';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('0-30/10 * * * *')->[0]{set}}], [0, 10, 20, 30], 'range step parsed';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('5/10 * * * *')->[0]{set}}], [5, 15, 25, 35, 45, 55], 'value step';
};

subtest 'parse_cron: errors' => sub {
  eval { parse_cron('* * * *') };
  like $@, qr/expected 5 fields/, 'too few fields';
  eval { parse_cron('* * * * * *') };
  like $@, qr/expected 5 fields/, 'too many fields';
  eval { parse_cron('60 * * * *') };
  like $@, qr/out of range/, 'minute out of range';
  eval { parse_cron('* 24 * * *') };
  like $@, qr/out of range/, 'hour out of range';
  eval { parse_cron('* * 0 * *') };
  like $@, qr/out of range/, 'day-of-month out of range';
  eval { parse_cron('* * * 13 *') };
  like $@, qr/out of range/, 'month out of range';
  eval { parse_cron('* * * * 7') };
  like $@, qr/out of range/, 'day-of-week out of range';
  eval { parse_cron('?? * * * *') };
  like $@, qr/Invalid cron field/, 'garbage rejected';
  eval { parse_cron('*/0 * * * *') };
  like $@, qr/Invalid cron step/, 'zero step rejected';
  eval { parse_cron('5-2 * * * *') };
  like $@, qr/out of range/, 'reversed range rejected';
};

subtest 'next_cron_time' => sub {

  # Pin all expectations to local time so the test is timezone independent
  my $base = timelocal 0, 0, 12, 12, 4, 2026;    # 2026-05-12 12:00:00 local (Tuesday)

  is next_cron_time('* * * * *', $base), $base + 60, 'every minute';
  is next_cron_time('*/5 * * * *', $base), $base + 60 * 5, 'every 5 minutes (next is 12:05)';
  is next_cron_time('0 13 * * *', $base), timelocal(0, 0, 13, 12, 4, 2026), 'today 13:00';

  # 9am on 2026-05-12 is in the past for $base, so next is 2026-05-13 09:00
  is next_cron_time('0 9 * * *', $base), timelocal(0, 0, 9, 13, 4, 2026), 'tomorrow 09:00';

  # Weekday filter: 2026-05-12 is Tuesday, next Mon-Fri 9am after 12:00 is Wed 09:00
  is next_cron_time('0 9 * * 1-5', $base), timelocal(0, 0, 9, 13, 4, 2026), 'next weekday 09:00';

  # Vixie OR semantics: dom = 1, dow = 0 (Sunday) => fire on either
  # Next 1st of any month is 2026-06-01, next Sunday after $base is 2026-05-17 — Sunday wins
  is next_cron_time('0 0 1 * 0', $base), timelocal(0, 0, 0, 17, 4, 2026), 'dom OR dow (Sunday wins)';

  # Yearly: 0 0 1 1 *  -> next 2027-01-01 00:00
  is next_cron_time('0 0 1 1 *', $base), timelocal(0, 0, 0, 1, 0, 2027), 'next New Year';

  # Right at the boundary: we round up to the *next* minute strictly after $from
  is next_cron_time('* * * * *', $base + 30), $base + 60, 'rounds up to next minute';
};

done_testing();
