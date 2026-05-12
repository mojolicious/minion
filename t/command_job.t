use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

use Mojolicious::Lite;

# Isolate tests
require Mojo::Pg;
my $pg = Mojo::Pg->new($ENV{TEST_ONLINE});
$pg->db->query('DROP SCHEMA IF EXISTS minion_command_job_test CASCADE');
$pg->db->query('CREATE SCHEMA minion_command_job_test');
plugin Minion => {Pg => $ENV{TEST_ONLINE}};
app->minion->backend->pg->search_path(['minion_command_job_test']);

app->minion->add_task(test => sub { });
app->minion->add_task(add  => sub { my ($job, $a, $b) = @_; $job->finish($a + $b) });

require Minion::Command::minion::job;
my $job = Minion::Command::minion::job->new(app => app);
ok $job->description, 'has a description';
like $job->usage, qr/job/, 'has usage information';

subtest 'Enqueue' => sub {
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-e', 'test');
  }
  like $buffer, qr/^\d+$/, 'right id';
  chomp(my $id = $buffer);
  is app->minion->job($id)->info->{task}, 'test', 'right task';
};

subtest 'Enqueue with arguments' => sub {
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-e', 'test', '-a', '[23, "bar"]');
  }
  chomp(my $id = $buffer);
  is_deeply app->minion->job($id)->info->{args}, [23, 'bar'], 'right arguments';
};

subtest 'Enqueue with options' => sub {
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-e', 'test', '-A', '3', '-p', '5', '-q', 'important', '-n', '{"test":123}');
  }
  chomp(my $id = $buffer);
  my $info = app->minion->job($id)->info;
  is $info->{attempts}, 3,           'right attempts';
  is $info->{priority}, 5,           'right priority';
  is $info->{queue},    'important', 'right queue';
  is_deeply $info->{notes}, {test => 123}, 'right notes';
};

subtest 'Enqueue with parents' => sub {
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-e', 'test');
  }
  chomp(my $p1 = $buffer);
  $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-e', 'test');
  }
  chomp(my $p2 = $buffer);
  $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-e', 'test', '-P', $p1, '-P', $p2, '-x', '1');
  }
  chomp(my $id = $buffer);
  my $info = app->minion->job($id)->info;
  is_deeply $info->{parents}, [$p1, $p2], 'right parents';
  is $info->{lax}, 1, 'right lax';
};

subtest 'Job info' => sub {
  my $id     = app->minion->enqueue('test');
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run($id);
  }
  like $buffer, qr/id:\s*$id/,         'right id';
  like $buffer, qr/task:\s*test/,      'right task';
  like $buffer, qr/state:\s*inactive/, 'right state';
};

subtest 'Job does not exist' => sub {
  eval { $job->run('999999999') };
  like $@, qr/Job does not exist/, 'right error';
};

subtest 'List jobs' => sub {
  app->minion->backend->reset({all => 1});
  my $id1    = app->minion->enqueue('test');
  my $id2    = app->minion->enqueue('add');
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run;
  }
  like $buffer, qr/$id1/, 'first job listed';
  like $buffer, qr/$id2/, 'second job listed';
};

subtest 'List jobs with filters' => sub {
  app->minion->backend->reset({all => 1});
  my $id1    = app->minion->enqueue('test', [], {queue => 'important'});
  my $id2    = app->minion->enqueue('add',  [], {queue => 'default'});
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-q', 'important');
  }
  like $buffer,   qr/$id1/, 'right job listed';
  unlike $buffer, qr/$id2/, 'other job not listed';
  $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-t', 'add');
  }
  unlike $buffer, qr/$id1/, 'right job not listed';
  like $buffer,   qr/$id2/, 'right job listed';
  $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-S', 'inactive');
  }
  like $buffer, qr/$id1/, 'right job listed';
  like $buffer, qr/$id2/, 'right job listed';
};

subtest 'List jobs with limit and offset' => sub {
  app->minion->backend->reset({all => 1});
  my $id1    = app->minion->enqueue('test');
  my $id2    = app->minion->enqueue('test');
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-l', '1');
  }
  like $buffer,   qr/$id2/, 'right job listed';
  unlike $buffer, qr/$id1/, 'older job not listed';
  $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-l', '1', '-o', '1');
  }
  like $buffer,   qr/$id1/, 'right job listed';
  unlike $buffer, qr/$id2/, 'newer job not listed';
};

subtest 'Retry job' => sub {
  subtest 'Finished job' => sub {
    app->minion->backend->reset({all => 1});
    my $worker = app->minion->worker->register;
    my $id     = app->minion->enqueue('test');
    $worker->dequeue(0)->finish;
    is app->minion->job($id)->info->{state}, 'finished', 'right state';
    $job->run('-R', $id);
    is app->minion->job($id)->info->{state},   'inactive', 'right state';
    is app->minion->job($id)->info->{retries}, 1,          'right retries';
    $worker->unregister;
  };

  subtest 'With options' => sub {
    app->minion->backend->reset({all => 1});
    my $worker = app->minion->worker->register;
    my $id     = app->minion->enqueue('test');
    $worker->dequeue(0)->finish;
    $job->run('-R', '-p', '7', '-q', 'important', $id);
    my $info = app->minion->job($id)->info;
    is $info->{state},    'inactive',  'right state';
    is $info->{priority}, 7,           'right priority';
    is $info->{queue},    'important', 'right queue';
    $worker->unregister;
  };

  subtest 'Active job' => sub {
    app->minion->backend->reset({all => 1});
    my $worker = app->minion->worker->register;
    my $id     = app->minion->enqueue('test');
    $worker->dequeue(0);
    is app->minion->job($id)->info->{state}, 'active', 'right state';
    $job->run('-R', $id);
    is app->minion->job($id)->info->{state}, 'inactive', 'right state';
    $worker->unregister;
  };
};

subtest 'Remove job' => sub {
  subtest 'Inactive job' => sub {
    my $id = app->minion->enqueue('test');
    $job->run('--remove', $id);
    is app->minion->job($id), undef, 'job removed';
  };

  subtest 'Active job' => sub {
    app->minion->backend->reset({all => 1});
    my $worker = app->minion->worker->register;
    my $id     = app->minion->enqueue('test');
    $worker->dequeue(0);
    eval { $job->run('--remove', $id) };
    like $@, qr/Job is active/, 'right error';
    $worker->unregister;
  };
};

subtest 'Remove failed jobs' => sub {
  app->minion->backend->reset({all => 1});
  my $worker = app->minion->worker->register;
  my $id1    = app->minion->enqueue('test');
  my $id2    = app->minion->enqueue('test');
  $worker->dequeue(0)->fail;
  $worker->dequeue(0)->fail;
  is app->minion->job($id1)->info->{state}, 'failed', 'right state';
  is app->minion->job($id2)->info->{state}, 'failed', 'right state';
  $job->run('--remove-failed');
  is app->minion->job($id1), undef, 'job removed';
  is app->minion->job($id2), undef, 'job removed';
  $worker->unregister;
};

subtest 'Retry failed jobs' => sub {
  app->minion->backend->reset({all => 1});
  my $worker = app->minion->worker->register;
  my $id1    = app->minion->enqueue('test');
  my $id2    = app->minion->enqueue('test');
  $worker->dequeue(0)->fail;
  $worker->dequeue(0)->fail;
  $job->run('--retry-failed');
  is app->minion->job($id1)->info->{state}, 'inactive', 'right state';
  is app->minion->job($id2)->info->{state}, 'inactive', 'right state';
  $worker->unregister;
};

subtest 'Stats' => sub {
  app->minion->backend->reset({all => 1});
  app->minion->enqueue('test');
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-s');
  }
  like $buffer, qr/inactive_jobs:\s*1/, 'right stats';
};

subtest 'History' => sub {
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-H');
  }
  like $buffer, qr/daily/, 'has history';
};

subtest 'List tasks' => sub {
  my $buffer = '';
  {
    open my $handle, '>', \$buffer;
    local *STDOUT = $handle;
    $job->run('-T');
  }
  like $buffer, qr/test/,        'right task';
  like $buffer, qr/add/,         'right task';
  like $buffer, qr/Minion::Job/, 'right class';
};

subtest 'Workers' => sub {
  subtest 'List workers' => sub {
    my $worker = app->minion->worker->register;
    my $buffer = '';
    {
      open my $handle, '>', \$buffer;
      local *STDOUT = $handle;
      $job->run('-w');
    }
    like $buffer, qr/@{[$worker->id]}/, 'worker listed';
    $worker->unregister;
  };

  subtest 'Worker info' => sub {
    my $worker = app->minion->worker->register;
    my $buffer = '';
    {
      open my $handle, '>', \$buffer;
      local *STDOUT = $handle;
      $job->run('-w', $worker->id);
    }
    like $buffer, qr/id:\s*@{[$worker->id]}/, 'right id';
    like $buffer, qr/pid:\s*$$/,              'right pid';
    $worker->unregister;
  };

  subtest 'Worker does not exist' => sub {
    eval { $job->run('-w', '999999999') };
    like $@, qr/Worker does not exist/, 'right error';
  };
};

subtest 'Locks' => sub {
  subtest 'List locks' => sub {
    app->minion->lock('test_lock', 3600);
    my $buffer = '';
    {
      open my $handle, '>', \$buffer;
      local *STDOUT = $handle;
      $job->run('-L');
    }
    like $buffer, qr/test_lock/, 'lock listed';
    $buffer = '';
    {
      open my $handle, '>', \$buffer;
      local *STDOUT = $handle;
      $job->run('-L', 'test_lock');
    }
    like $buffer, qr/test_lock/, 'right lock listed';
  };

  subtest 'Unlock' => sub {
    app->minion->lock('remove_me', 3600);
    $job->run('-U', 'remove_me');
    my $buffer = '';
    {
      open my $handle, '>', \$buffer;
      local *STDOUT = $handle;
      $job->run('-L', 'remove_me');
    }
    unlike $buffer, qr/remove_me/, 'lock removed';
  };
};

subtest 'Broadcast' => sub {
  my $worker = app->minion->worker->register;
  $job->run('-b', 'jobs', '-a', '[0]');
  my $received = app->minion->backend->receive($worker->id);
  is_deeply $received, [['jobs', 0]], 'right command';
  $worker->unregister;
};

subtest 'Foreground' => sub {
  subtest 'Inactive job' => sub {
    my $id = app->minion->enqueue('test');
    $job->run('-f', $id);
    is app->minion->job($id)->info->{state}, 'finished', 'right state';
  };

  subtest 'Active job' => sub {
    app->minion->backend->reset({all => 1});
    my $worker = app->minion->worker->register;
    my $id     = app->minion->enqueue('test');
    $worker->dequeue(0);
    is app->minion->job($id)->info->{state}, 'active', 'right state';
    $job->run('-f', $id);
    is app->minion->job($id)->info->{state}, 'finished', 'right state';
    $worker->unregister;
  };
};

# Clean up once we are done
$pg->db->query('DROP SCHEMA minion_command_job_test CASCADE');

done_testing();
