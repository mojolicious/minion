use Mojo::Base -strict;

use Test::More;
use File::Spec::Functions 'catfile';
use File::Temp 'tempdir';
use Mojolicious::Lite;
use Storable qw(store retrieve);
use Test::Mojo;

my $tmpdir = tempdir CLEANUP => 1;
my $file = catfile $tmpdir, 'minion.data';

# Missing backend
eval { plugin Minion => {Something => 'fun'} };
like $@, qr/^Backend "Minion::Backend::Something" missing/, 'right error';

plugin Minion => {File => $file};

my $results = catfile $tmpdir, 'results.data';
store {count => 0}, $results;
app->minion->add_task(
  increment => sub {
    my $job    = shift;
    my $result = retrieve $results;
    $result->{count}++;
    store $result, $results;
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
    increment => sub { $self->render(text => 'Incrementing soon too!') });
};

get '/count' => sub {
  my $self = shift;
  $self->render(text => retrieve($results)->{count});
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

done_testing();
