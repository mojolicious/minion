use Mojo::Base -strict;

use Test::More;
use Minion::Util qw(desired_tasks next_cron_time parse_cron);
use Time::Local  qw(timegm);

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
  is_deeply [sort { $a <=> $b } keys %{parse_cron('5,15,25 * * * *')->[0]{set}}], [5, 15, 25],     'list parsed';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('0 9-17 * * *')->[1]{set}}],    [9 .. 17],       'range parsed';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('*/15 * * * *')->[0]{set}}],    [0, 15, 30, 45], 'star step parsed';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('0-30/10 * * * *')->[0]{set}}], [0, 10, 20, 30], 'range step parsed';
  is_deeply parse_cron('*/15 * * * *')->[0]{values}, [0, 15, 30, 45], 'sorted values populated';
  is_deeply parse_cron('5/10 * * * *')->[0]{values}, [5],             'step on single value has no effect';
};

subtest 'parse_cron: nicknames' => sub {
  is_deeply parse_cron('@hourly'),   parse_cron('0 * * * *'), 'hourly';
  is_deeply parse_cron('@daily'),    parse_cron('0 0 * * *'), 'daily';
  is_deeply parse_cron('@midnight'), parse_cron('0 0 * * *'), 'midnight';
  is_deeply parse_cron('@weekly'),   parse_cron('0 0 * * 0'), 'weekly';
  is_deeply parse_cron('@monthly'),  parse_cron('0 0 1 * *'), 'monthly';
  is_deeply parse_cron('@yearly'),   parse_cron('0 0 1 1 *'), 'yearly';
  is_deeply parse_cron('@annually'), parse_cron('0 0 1 1 *'), 'annually';
  eval { parse_cron('@bogus') };
  like $@, qr/Unknown cron nickname/, 'unknown nickname rejected';
};

subtest 'parse_cron: symbolic names' => sub {
  is_deeply [sort { $a <=> $b } keys %{parse_cron('0 0 * JAN *')->[3]{set}}],     [1],             'JAN';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('0 0 * jan-mar *')->[3]{set}}], [1, 2, 3],       'jan-mar';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('0 0 * * MON-FRI')->[4]{set}}], [1, 2, 3, 4, 5], 'MON-FRI';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('0 0 * * sat,sun')->[4]{set}}], [0, 6],          'sat,sun';
  eval { parse_cron('* * * BOGUS *') };
  like $@, qr/Invalid name "BOGUS" in month field/, 'unknown name rejected';
  eval { parse_cron('* MON * * *') };
  like $@, qr/Invalid name "MON" in hour field/, 'name not allowed in numeric field';
};

subtest 'parse_cron: 7 as Sunday' => sub {
  is_deeply [sort { $a <=> $b } keys %{parse_cron('0 0 * * 7')->[4]{set}}],   [0],       '7 normalizes to 0';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('0 0 * * 5-7')->[4]{set}}], [0, 5, 6], 'range with 7 includes Sunday';
  is_deeply [sort { $a <=> $b } keys %{parse_cron('0 0 * * 0,7')->[4]{set}}], [0],       'list with 0,7 dedupes';
};

subtest 'parse_cron: errors' => sub {
  eval { parse_cron('* * * *') };
  like $@, qr/expected 5 fields/, 'too few fields';
  eval { parse_cron('* * * * * *') };
  like $@, qr/expected 5 fields/, 'too many fields';
  eval { parse_cron('60 * * * *') };
  like $@, qr/Value out of range in minute field/, 'minute out of range';
  eval { parse_cron('* 24 * * *') };
  like $@, qr/Value out of range in hour field/, 'hour out of range';
  eval { parse_cron('* * 0 * *') };
  like $@, qr/Value out of range in day-of-month field/, 'day-of-month out of range';
  eval { parse_cron('* * * 13 *') };
  like $@, qr/Value out of range in month field/, 'month out of range';
  eval { parse_cron('* * * * 8') };
  like $@, qr/Value out of range in day-of-week field/, 'day-of-week out of range';
  eval { parse_cron('?? * * * *') };
  like $@, qr/Invalid minute field/, 'garbage rejected';
  eval { parse_cron('*/0 * * * *') };
  like $@, qr/Invalid step "0" in minute field/, 'zero step rejected';
  eval { parse_cron('5-2 * * * *') };
  like $@, qr/Value out of range in minute field/, 'reversed range rejected';
};

subtest 'next_cron_time' => sub {
  my $base = timegm 0, 0, 12, 12, 4, 2026;    # 2026-05-12 12:00:00 UTC (Tuesday)

  subtest 'basic operations' => sub {
    is next_cron_time('* * * * *', $base),   $base + 60,                    'every minute';
    is next_cron_time('*/5 * * * *', $base), $base + 60 * 5,                'every 5 minutes (next is 12:05)';
    is next_cron_time('0 13 * * *', $base),  timegm(0, 0, 13, 12, 4, 2026), 'today 13:00';
    is next_cron_time('0 9 * * *', $base),   timegm(0, 0, 9, 13, 4, 2026),  'tomorrow 09:00';
  };

  subtest 'weekday filter' => sub {
    is next_cron_time('0 9 * * 1-5', $base), timegm(0, 0, 9, 13, 4, 2026), 'next weekday 09:00';
  };

  subtest 'Vixie OR semantics' => sub {
    is next_cron_time('0 0 1 * 0', $base), timegm(0, 0, 0, 17, 4, 2026), 'dom OR dow (Sunday wins)';
  };

  subtest 'yearly' => sub {
    is next_cron_time('0 0 1 1 *', $base), timegm(0, 0, 0, 1, 0, 2027), 'next New Year';
  };

  subtest 'boundary rounding' => sub {
    is next_cron_time('* * * * *', $base + 30), $base + 60, 'rounds up to next minute';
  };

  subtest 'quadrennial leap years' => sub {
    is next_cron_time('0 0 29 2 *', timegm(0, 0, 0, 1, 0, 2027)), timegm(0, 0, 0, 29, 1, 2028), 'next Feb 29';
  };

  subtest 'nicknames' => sub {
    is next_cron_time('@hourly', $base), timegm(0, 0, 13, 12, 4, 2026), 'nickname @hourly';
    is next_cron_time('@daily',  $base), timegm(0, 0, 0,  13, 4, 2026), 'nickname @daily';
    is next_cron_time('@yearly', $base), timegm(0, 0, 0,  1,  0, 2027), 'nickname @yearly';
  };

  subtest 'symbolic names' => sub {
    is next_cron_time('0 9 * * MON-FRI', $base), timegm(0, 0, 9, 13, 4, 2026), 'symbolic dow range';
    is next_cron_time('0 0 1 JAN *',     $base), timegm(0, 0, 0, 1,  0, 2027), 'symbolic month';
  };

  subtest '7 as Sunday' => sub {
    is next_cron_time('0 0 * * 7', $base), timegm(0, 0, 0, 17, 4, 2026), '7 means Sunday';
  };

  subtest 'parse-once API' => sub {
    my $cron = parse_cron('*/5 * * * *');
    is next_cron_time($cron, $base),       $base + 300, 'parsed structure accepted';
    is next_cron_time($cron, $base + 300), $base + 600, 'parsed structure reusable';
  };
};

done_testing();
