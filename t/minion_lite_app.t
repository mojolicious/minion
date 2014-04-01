use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mojolicious::Lite;
use Test::Mojo;

plugin Minion => {uri => $ENV{TEST_ONLINE}};

# Clean up before start
app->minion->prefix('minion_lite_app_test');
$_->options && $_->drop for app->minion->workers, app->minion->jobs;

my $count = app->minion->jobs->insert({count => 0});
app->minion->add_task(
  increment => sub {
    my $job = shift;
    my $doc = $job->app->minion->jobs->find_one($count);
    $doc->{count}++;
    $job->minion->jobs->save($doc);
  }
);

get '/increment' => sub {
  my $self = shift;
  $self->minion->enqueue('increment');
  $self->render(text => 'Incrementing soon!');
};

get '/count' => sub {
  my $self = shift;
  $self->render(text => $self->minion->jobs->find_one($count)->{count});
};

my $t = Test::Mojo->new;

# Perform jobs automatically
$t->app->minion->auto_perform(1);
$t->get_ok('/increment')->status_is(200)->content_is('Incrementing soon!');
$t->get_ok('/count')->status_is(200)->content_is('1');
$t->get_ok('/increment')->status_is(200)->content_is('Incrementing soon!');
$t->get_ok('/increment')->status_is(200)->content_is('Incrementing soon!');
$t->get_ok('/count')->status_is(200)->content_is('3');
$_->drop for app->minion->workers, app->minion->jobs;

done_testing();
