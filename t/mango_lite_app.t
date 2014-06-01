use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mojolicious::Lite;
use Test::Mojo;

plugin Minion => {Mango => $ENV{TEST_ONLINE}};

# Clean up before start
app->minion->backend->prefix('minion_lite_app_test')->reset;

my $count = app->minion->backend->jobs->insert({count => 0});
app->minion->add_task(
  increment => sub {
    my $job = shift;
    my $doc = $job->app->minion->backend->jobs->find_one($count);
    $doc->{count}++;
    $job->minion->backend->jobs->save($doc);
  }
);

get '/increment' => sub {
  my $self = shift;
  $self->minion->enqueue('increment');
  $self->render(text => 'Incrementing soon!');
};

get '/non_blocking_increment' => sub {
  my $self = shift;
  $self->minion->enqueue(
    increment => sub {
      $self->render(text => 'Incrementing soon too!');
    }
  );
};

get '/count' => sub {
  my $self = shift;
  $self->render(
    text => $self->minion->backend->jobs->find_one($count)->{count});
};

my $t = Test::Mojo->new;

# Perform jobs automatically
$t->app->minion->auto_perform(1);
$t->get_ok('/increment')->status_is(200)->content_is('Incrementing soon!');
$t->get_ok('/count')->status_is(200)->content_is('1');
$t->get_ok('/increment')->status_is(200)->content_is('Incrementing soon!');
$t->get_ok('/increment')->status_is(200)->content_is('Incrementing soon!');
$t->get_ok('/count')->status_is(200)->content_is('3');

# Perform jobs automatically (non-blocking)
$t->get_ok('/non_blocking_increment')->status_is(200)
  ->content_is('Incrementing soon too!');
$t->get_ok('/count')->status_is(200)->content_is('4');
$t->get_ok('/non_blocking_increment')->status_is(200)
  ->content_is('Incrementing soon too!');
$t->get_ok('/count')->status_is(200)->content_is('5');
app->minion->backend->reset;

done_testing();
