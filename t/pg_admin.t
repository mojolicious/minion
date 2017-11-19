use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

use Mojolicious::Lite;
use Test::Mojo;

# Isolate tests
require Mojo::Pg;
my $pg = Mojo::Pg->new($ENV{TEST_ONLINE});
$pg->db->query('drop schema if exists minion_admin_test cascade');
$pg->db->query('create schema minion_admin_test');
plugin Minion => {Pg => $ENV{TEST_ONLINE}};
app->minion->backend->pg->search_path(['minion_admin_test']);

app->minion->add_task(test => sub { });
my $finished = app->minion->enqueue('test');
app->minion->perform_jobs;
my $inactive = app->minion->enqueue('test');
get '/home' => 'test_home';

plugin 'Minion::Admin';

my $t = Test::Mojo->new;

# Dashboard
$t->get_ok('/minion')->status_is(200)->content_like(qr/Dashboard/)
  ->element_exists('a[href=/]');

# Stats
$t->get_ok('/minion/stats')->status_is(200)->json_is('/active_jobs' => 0)
  ->json_is('/active_workers' => 0)->json_is('/delayed_jobs'  => 0)
  ->json_is('/enqueued_jobs'  => 2)->json_is('/failed_jobs'   => 0)
  ->json_is('/finished_jobs'  => 1)->json_is('/inactive_jobs' => 1)
  ->json_is('/inactive_workers' => 0)->json_has('/uptime');

# Jobs
$t->get_ok('/minion/jobs?state=inactive')->status_is(200)
  ->text_like('tbody td a' => qr/$inactive/)
  ->text_unlike('tbody td a' => qr/$finished/);
$t->get_ok('/minion/jobs?state=finished')->status_is(200)
  ->text_like('tbody td a' => qr/$finished/)
  ->text_unlike('tbody td a' => qr/$inactive/);

# Workers
$t->get_ok('/minion/workers')->status_is(200)->element_exists_not('tbody td a');
my $worker = app->minion->worker->register;
$t->get_ok('/minion/workers')->status_is(200)->element_exists('tbody td a')
  ->text_like('tbody td a' => qr/@{[$worker->id]}/);
$worker->unregister;
$t->get_ok('/minion/workers')->status_is(200)->element_exists_not('tbody td a');

# Manage jobs
$t->ua->max_redirects(5);
is app->minion->job($finished)->info->{state}, 'finished', 'right state';
$t->post_ok(
  '/minion/jobs?_method=PATCH' => form => {id => $finished, do => 'retry'})
  ->text_like('.alert-success', qr/All selected jobs retried/);
is $t->tx->previous->res->code, 302, 'right status';
like $t->tx->previous->res->headers->location, qr/id=$finished/,
  'right "Location" value';
is app->minion->job($finished)->info->{state}, 'inactive', 'right state';
$t->post_ok(
  '/minion/jobs?_method=PATCH' => form => {id => $finished, do => 'stop'})
  ->text_like('.alert-info', qr/Trying to stop all selected jobs/);
is $t->tx->previous->res->code, 302, 'right status';
like $t->tx->previous->res->headers->location, qr/id=$finished/,
  'right "Location" value';
$t->post_ok(
  '/minion/jobs?_method=PATCH' => form => {id => $finished, do => 'remove'})
  ->text_like('.alert-success', qr/All selected jobs removed/);
is $t->tx->previous->res->code, 302, 'right status';
like $t->tx->previous->res->headers->location, qr/id=$finished/,
  'right "Location" value';
is app->minion->job($finished), undef, 'job has been removed';

# Bundled static files
$t->get_ok('/minion/bootstrap/bootstrap.js')->status_is(200)
  ->content_type_is('application/javascript');
$t->get_ok('/minion/bootstrap/bootstrap.css')->status_is(200)
  ->content_type_is('text/css');
$t->get_ok('/minion/d3/d3.js')->status_is(200)
  ->content_type_is('application/javascript');
$t->get_ok('/minion/epoch/epoch.js')->status_is(200)
  ->content_type_is('application/javascript');
$t->get_ok('/minion/epoch/epoch.css')->status_is(200)
  ->content_type_is('text/css');
$t->get_ok('/minion/fontawesome/font-awesome.css')->status_is(200)
  ->content_type_is('text/css');
$t->get_ok('/minion/fonts/fontawesome-webfont.eot')->status_is(200);
$t->get_ok('/minion/fonts/fontawesome-webfont.svg')->status_is(200);
$t->get_ok('/minion/fonts/fontawesome-webfont.ttf')->status_is(200);
$t->get_ok('/minion/fonts/fontawesome-webfont.woff')->status_is(200);
$t->get_ok('/minion/fonts/fontawesome-webfont.woff2')->status_is(200);
$t->get_ok('/minion/moment/moment.js')->status_is(200)
  ->content_type_is('application/javascript');
$t->get_ok('/minion/app.js')->status_is(200)
  ->content_type_is('application/javascript');
$t->get_ok('/minion/app.css')->status_is(200)->content_type_is('text/css');
$t->get_ok('/minion/logo-black-2x.png')->status_is(200)
  ->content_type_is('image/png');
$t->get_ok('/minion/logo-black.png')->status_is(200)
  ->content_type_is('image/png');

# Different prefix and return route
plugin 'Minion::Admin' =>
  {route => app->routes->any('/also_minion'), return_to => 'test_home'};
$t->get_ok('/also_minion')->status_is(200)->content_like(qr/Dashboard/)
  ->element_exists('a[href=/home]');

# Clean up once we are done
$pg->db->query('drop schema minion_admin_test cascade');

done_testing();
