use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

use Mojo::IOLoop;
use Mojolicious::Lite;
use Test::Mojo;

# Missing backend
eval { plugin Minion => {Something => 'fun'} };
like $@, qr/^Backend "Minion::Backend::Something" missing/, 'right error';

# Isolate tests
require Mojo::Pg;
my $pg = Mojo::Pg->new($ENV{TEST_ONLINE});
$pg->db->query('drop schema if exists minion_app_test cascade');
$pg->db->query('create schema minion_app_test');
plugin Minion => {Pg => $pg->search_path(['minion_app_test'])};

app->minion->add_task(
  add => sub {
    my ($job, $first, $second) = @_;
    Mojo::IOLoop->next_tick(sub {
      $job->finish($first + $second);
      Mojo::IOLoop->stop;
    });
    Mojo::IOLoop->start;
  }
);

get '/add' => sub {
  my $c  = shift;
  my $id = $c->minion->enqueue(add => [$c->param('first'), $c->param('second')] => {queue => 'test'});
  $c->render(text => $id);
};

get '/result' => sub {
  my $c = shift;
  $c->render(text => $c->minion->job($c->param('id'))->info->{result});
};

my $t = Test::Mojo->new;

subtest 'Perform jobs automatically' => sub {
  $t->get_ok('/add' => form => {first => 1, second => 2})->status_is(200);
  $t->app->minion->perform_jobs({queues => ['test']});
  $t->get_ok('/result' => form => {id    => $t->tx->res->text})->status_is(200)->content_is('3');
  $t->get_ok('/add'    => form => {first => 2, second => 3})->status_is(200);
  my $first = $t->tx->res->text;
  $t->get_ok('/add' => form => {first => 4, second => 5})->status_is(200);
  my $second = $t->tx->res->text;
  Mojo::IOLoop->delay(sub { $t->app->minion->perform_jobs({queues => ['test']}) })->wait;
  $t->get_ok('/result' => form => {id => $first})->status_is(200)->content_is('5');
  $t->get_ok('/result' => form => {id => $second})->status_is(200)->content_is('9');
};

# Clean up once we are done
$pg->db->query('drop schema minion_app_test cascade');

done_testing();
