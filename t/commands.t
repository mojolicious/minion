use Mojo::Base -strict;

use Test::More;

subtest 'minion' => sub {
  require Minion::Command::minion;
  my $minion = Minion::Command::minion->new;
  ok $minion->description, 'has a description';
  like $minion->message,   qr/minion/, 'has a message';
  like $minion->hint,      qr/help/,   'has a hint';
};

subtest 'job' => sub {
  require Minion::Command::minion::job;
  my $job = Minion::Command::minion::job->new;
  ok $job->description, 'has a description';
  like $job->usage, qr/job/, 'has usage information';
};

subtest 'worker' => sub {
  require Minion::Command::minion::worker;
  my $worker = Minion::Command::minion::worker->new;
  ok $worker->description, 'has a description';
  like $worker->usage, qr/worker/, 'has usage information';
};

done_testing();
