use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

use Mojolicious::Lite;

# Isolate tests
require Mojo::Pg;
my $pg = Mojo::Pg->new($ENV{TEST_ONLINE});
$pg->db->query('DROP SCHEMA IF EXISTS minion_command_schedule_test CASCADE');
$pg->db->query('CREATE SCHEMA minion_command_schedule_test');
plugin Minion => {Pg => $ENV{TEST_ONLINE}};
app->minion->backend->pg->search_path(['minion_command_schedule_test']);

app->minion->add_task(test => sub { });

require Minion::Command::minion::schedule;
my $cmd = Minion::Command::minion::schedule->new(app => app);
ok $cmd->description, 'has a description';
like $cmd->usage, qr/schedule/, 'has usage information';

subtest 'Add schedule' => sub {
  subtest 'Basic' => sub {
    my $buffer = '';
    {
      open my $handle, '>', \$buffer;
      local *STDOUT = $handle;
      $cmd->run('-e', 'daily', '-c', '0 4 * * *', '-t', 'test');
    }
    like $buffer, qr/^\d+$/, 'right id';
    my $info = app->minion->list_schedules(0, 1, {names => ['daily']})->{schedules}[0];
    is $info->{name}, 'daily',     'right name';
    is $info->{cron}, '0 4 * * *', 'right cron';
    is $info->{task}, 'test',      'right task';
  };

  subtest 'With options' => sub {
    my $buffer = '';
    {
      open my $handle, '>', \$buffer;
      local *STDOUT = $handle;
      $cmd->run(
        '-e', 'opts', '-c', '*/5 * * * *', '-t', 'test',          '-A', '3',
        '-p', '5',    '-q', 'important',   '-n', '{"foo":"bar"}', '-a', '[1, 2]'
      );
    }
    like $buffer, qr/^\d+$/, 'right id';
    $buffer = '';
    {
      open my $handle, '>', \$buffer;
      local *STDOUT = $handle;
      $cmd->run('opts');
    }
    like $buffer, qr/\*\/5 \* \* \* \*/, 'right cron';
    like $buffer, qr/task:\s*test/,      'right task';
    like $buffer, qr/important/,         'right queue';
    like $buffer, qr/foo/,               'right notes';
  };

  subtest 'Update existing' => sub {
    my $id1    = app->minion->list_schedules(0, 1, {names => ['daily']})->{schedules}[0]{id};
    my $buffer = '';
    {
      open my $handle, '>', \$buffer;
      local *STDOUT = $handle;
      $cmd->run('-e', 'daily', '-c', '0 6 * * *', '-t', 'test');
    }
    chomp(my $id2 = $buffer);
    is $id2, $id1, 'same id';
    my $info = app->minion->list_schedules(0, 1, {names => ['daily']})->{schedules}[0];
    is $info->{cron}, '0 6 * * *', 'right cron';
  };

  subtest 'Missing cron expression' => sub {
    eval { $cmd->run('-e', 'bad', '-t', 'test') };
    like $@, qr/Cron expression is required/, 'right error';
  };

  subtest 'Missing task' => sub {
    eval { $cmd->run('-e', 'bad', '-c', '* * * * *') };
    like $@, qr/Task is required/, 'right error';
  };
};

subtest 'Schedule info' => sub {
  my $id     = app->minion->list_schedules(0, 1, {names => ['daily']})->{schedules}[0]{id};
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $cmd->run('daily');
  }
  like $buffer, qr/id:\s*$id/,     'right id';
  like $buffer, qr/name:\s*daily/, 'right name';
  like $buffer, qr/task:\s*test/,  'right task';
};

subtest 'Schedule does not exist' => sub {
  eval { $cmd->run('nonexistent') };
  like $@, qr/Schedule does not exist/, 'right error';
};

subtest 'List schedules' => sub {
  app->minion->backend->reset({all => 1});
  app->minion->schedule('s1', '0 4 * * *', 'test');
  app->minion->schedule('s2', '0 5 * * *', 'test');
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $cmd->run;
  }
  like $buffer, qr/s1/, 'first schedule listed';
  like $buffer, qr/s2/, 'second schedule listed';
};

subtest 'List schedules with limit and offset' => sub {
  app->minion->backend->reset({all => 1});
  app->minion->schedule('first',  '0 1 * * *', 'test');
  app->minion->schedule('second', '0 2 * * *', 'test');
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $cmd->run('-l', '1');
  }
  my ($shown) = $buffer =~ /(first|second)/;
  my $other = $shown eq 'first' ? 'second' : 'first';
  like $buffer,   qr/$shown/, 'right schedule listed';
  unlike $buffer, qr/$other/, 'other schedule not listed';
  $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $cmd->run('-l', '1', '-o', '1');
  }
  unlike $buffer, qr/$shown/, 'first schedule not listed';
  like $buffer,   qr/$other/, 'right schedule listed';
};

subtest 'Pause schedule' => sub {
  subtest 'Pause' => sub {
    app->minion->schedule('pausable', '0 4 * * *', 'test');
    $cmd->run('-P', 'pausable');
    my $info = app->minion->list_schedules(0, 1, {names => ['pausable']})->{schedules}[0];
    ok $info->{paused}, 'schedule is paused';
  };

  subtest 'Schedule does not exist' => sub {
    eval { $cmd->run('-P', 'nonexistent') };
    like $@, qr/Schedule does not exist/, 'right error';
  };
};

subtest 'Resume schedule' => sub {
  subtest 'Resume' => sub {
    $cmd->run('-r', 'pausable');
    my $info = app->minion->list_schedules(0, 1, {names => ['pausable']})->{schedules}[0];
    ok !$info->{paused}, 'schedule is not paused';
  };

  subtest 'Schedule does not exist' => sub {
    eval { $cmd->run('-r', 'nonexistent') };
    like $@, qr/Schedule does not exist/, 'right error';
  };
};

subtest 'Remove schedule' => sub {
  subtest 'Remove' => sub {
    app->minion->schedule('removable', '0 4 * * *', 'test');
    $cmd->run('-R', 'removable');
    my $info = app->minion->list_schedules(0, 1, {names => ['removable']})->{schedules}[0];
    is $info, undef, 'schedule removed';
  };

  subtest 'Schedule does not exist' => sub {
    eval { $cmd->run('-R', 'nonexistent') };
    like $@, qr/Schedule does not exist/, 'right error';
  };
};

subtest 'Dispatch' => sub {
  my $id = app->minion->schedule('due', '0 4 * * *', 'test');
  app->minion->backend->pg->db->query(
    q{UPDATE minion_schedules SET next_run = NOW() - INTERVAL '1 minute' WHERE id = ?}, $id);
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $cmd->run('-d');
  }
  like $buffer, qr/\d+/, 'dispatched job id';
  my $info = app->minion->list_schedules(0, 1, {names => ['due']})->{schedules}[0];
  ok $info->{last_job}, 'last job recorded';
};

# Clean up once we are done
$pg->db->query('DROP SCHEMA minion_command_schedule_test CASCADE');

done_testing();
