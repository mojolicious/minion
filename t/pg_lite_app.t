use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;
use Mojo::IOLoop;
use Mojolicious::Lite;
use Test::Mojo;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

# Missing backend
eval { plugin Minion => {Something => 'fun'} };
like $@, qr/^Backend "Minion::Backend::Something" missing/, 'right error';

plugin Minion => {Pg => $ENV{TEST_ONLINE}};

if ($ENV{TEST_ONLINE}) {
    app->minion->backend->pg->db->query("CREATE TABLE __t_result (result integer)");
}

app->minion->add_task(
  increment => sub {
    my $job = shift;
    Mojo::IOLoop->next_tick(
      sub {
        my $ret = $job->minion->backend->pg->db->query("SELECT result FROM __t_result")->hash;
        if ($ret) {
            $job->minion->backend->pg->db->query("UPDATE __t_result SET result = ?", ++$ret->{result});
        }
        else {
            $job->minion->backend->pg->db->query("INSERT INTO __t_result (result) VALUES (1)");
        }
        Mojo::IOLoop->stop;
      }
    );
    Mojo::IOLoop->start;
  }
);

get '/increment' => sub {
  my $c = shift;
  $c->minion->enqueue('increment');
  $c->render(text => 'Incrementing soon!');
};

get '/count' => sub {
  my $c = shift;
  my $ret = $c->minion->backend->pg->db->query("SELECT result FROM __t_result")->hash;
  $c->render(text => $ret->{result});
};

my $t = Test::Mojo->new;

# Perform jobs automatically
$t->get_ok('/increment')->status_is(200)->content_is('Incrementing soon!');
$t->app->minion->perform_jobs;
$t->get_ok('/count')->status_is(200)->content_is('1');
$t->get_ok('/increment')->status_is(200)->content_is('Incrementing soon!');
$t->get_ok('/increment')->status_is(200)->content_is('Incrementing soon!');
Mojo::IOLoop->delay(sub { $t->app->minion->perform_jobs })->wait;
$t->get_ok('/count')->status_is(200)->content_is('3');

if ($ENV{TEST_ONLINE}) {
    app->minion->backend->pg->db->query("DROP TABLE __t_result");
}

done_testing();
