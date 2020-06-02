package MinionTest::FailTestTask;
use Mojo::Base 'Minion::Job';

sub run {
  my ($self, @args) = @_;
  my $task = $self->task;
  $self->fail("$task failed");
}

1;
