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

plugin 'Minion::Admin';

my $t = Test::Mojo->new;

# Dashboard
$t->get_ok('/minion')->status_is(200)->content_like(qr/Dashboard/);

# Stats
$t->get_ok('/minion/stats')->status_is(200)->json_is('/finished_jobs' => 1)
  ->json_is('/inactive_jobs' => 1)->json_is('/delayed_jobs' => 0);

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
is app->minion->job($finished)->info->{state}, 'finished', 'right state';
$t->post_ok('/minion/jobs' => form => {id => $finished, do => 'retry'})
  ->status_is(302)->header_like(Location => qr/id=$finished/);
is app->minion->job($finished)->info->{state}, 'inactive', 'right state';
$t->post_ok('/minion/jobs' => form => {id => $finished, do => 'remove'})
  ->status_is(302)->header_like(Location => qr/id=$finished/);
is app->minion->job($finished), undef, 'job has been removed';

# Clean up once we are done
$pg->db->query('drop schema minion_admin_test cascade');

done_testing();
