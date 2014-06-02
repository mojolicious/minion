use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mojolicious::Lite;
use Test::Mojo;

plugin Minion => {Mango => $ENV{TEST_ONLINE}};

# Clean up before start
app->minion->backend->prefix('minion_lite_app_test')->reset;

app->minion->add_task(
  add => sub {
    my ($job, $first, $second) = @_;
    $job->finish($first + $second);
  }
);

get '/add' => sub {
  my $self = shift;
  my $id = $self->minion->enqueue(add => [$self->param([qw(first second)])]);
  $self->render(text => $id);
};

get '/non_blocking_add' => sub {
  my $self = shift;
  $self->minion->enqueue(
    add => [$self->param([qw(first second)])] => sub {
      my ($minion, $err, $id) = @_;
      $self->render(text => $id);
    }
  );
};

get '/result' => sub {
  my $self = shift;
  $self->render(
    text => $self->minion->backend->job_info($self->param(['id']))->{result});
};

get '/non_blocking_result' => sub {
  my $self = shift;
  $self->minion->backend->job_info(
    $self->param(['id']) => sub {
      my ($backend, $err, $info) = @_;
      $self->render(text => $info->{result});
    }
  );
};

my $t = Test::Mojo->new;

# Perform jobs automatically
$t->app->minion->auto_perform(1);
$t->get_ok('/add' => form => {first => 5, second => 3})->status_is(200);
my $id = $t->tx->res->text;
$t->get_ok('/result' => form => {id => $id})->status_is(200)->content_is('8');

# Perform jobs automatically (non-blocking)
$t->get_ok('/non_blocking_add' => form => {first => 1, second => 1})
  ->status_is(200);
$id = $t->tx->res->text;
$t->get_ok('/non_blocking_result' => form => {id => $id})->status_is(200)
  ->content_is('2');
app->minion->backend->reset;

done_testing();
