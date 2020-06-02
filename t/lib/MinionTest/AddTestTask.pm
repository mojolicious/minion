package MinionTest::AddTestTask;
use Mojo::Base 'Minion::Job';

sub run {
  my ($self, @args) = @_;
  $self->finish('My result is ' . ($args[0] + $args[1]));
}

1;
