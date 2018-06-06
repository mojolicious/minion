use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

use Mojo::IOLoop;
use Mojolicious::Lite;
use Test::Mojo;

# Isolate tests
require Mojo::Pg;
my $pg = Mojo::Pg->new($ENV{TEST_ONLINE});
$pg->db->query('drop schema if exists minion_dev_server_test cascade');
$pg->db->query('create schema minion_dev_server_test');
plugin Minion => {Pg => $pg->search_path(['minion_dev_server_test'])};

# Development server
app->minion_dev_server({queues => ['test']});

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
  my $id = $c->minion->enqueue(
    add => [$c->param('first'), $c->param('second')] => {queue => 'test'});
  $c->render(text => $id);
};

get '/result' => sub {
  my $c = shift;
  $c->render(text => $c->minion->job($c->param('id'))->info->{result});
};

my $t = Test::Mojo->new;

# Perform jobs automatically
$t->get_ok('/add' => form => {first => 1, second => 2})->status_is(200);
Mojo::IOLoop->timer(2 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;
$t->get_ok('/result' => form => {id => $t->tx->res->text})->status_is(200)
  ->content_is('3');

# Clean up once we are done
$pg->db->query('drop schema minion_dev_server_test cascade');

done_testing();
