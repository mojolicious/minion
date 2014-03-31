use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mojolicious::Lite;
use Test::Mojo;

plugin Minion => {uri => $ENV{TEST_ONLINE}};

# Clean up before start
app->minion->prefix('minion_lite_app_test');
$_->options && $_->drop
  for app->minion->workers, app->minion->jobs, app->minion->notifications;

app->minion->add_task(
  add => sub {
    my ($job, $first, $second) = @_;
    return $first + $second;
  }
);

get '/add' => sub {
  my $self   = shift;
  my $first  = $self->param('first') // 1;
  my $second = $self->param('second') // 1;
  my $result = $self->minion->enqueue_and_wait('add' => [$first, $second]);
  $self->render(text => $result);
};

my $t = Test::Mojo->new;

# Perform jobs automatically
$t->app->minion->auto_perform(1);
$t->get_ok('/add')->status_is(200)->content_is('2');
$t->get_ok('/add?first=3&second=5')->status_is(200)->content_is('8');

# Clean up
$_->drop
  for app->minion->workers, app->minion->jobs, app->minion->notifications;

done_testing();
