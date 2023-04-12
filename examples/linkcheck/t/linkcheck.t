use Mojo::Base -strict;

use Test::More;

# This test requires a PostgreSQL connection string for an existing database
#
#   TEST_ONLINE=postgres://tester:testing@/test prove -l t/*.t
#
plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};

use Mojo::Pg;
use Mojo::URL;
use Test::Mojo;

# Isolate tests
my $url = Mojo::URL->new($ENV{TEST_ONLINE})->query([search_path => 'linkcheck_test']);
my $pg  = Mojo::Pg->new($url);
$pg->db->query('DROP SCHEMA IF EXISTS linkcheck_test CASCADE');
$pg->db->query('CREATE SCHEMA linkcheck_test');

# Override configuration for testing
my $t = Test::Mojo->new(LinkCheck => {pg => $url, secrets => ['test_s3cret']});
$t->ua->max_redirects(10);

# Enqueue a background job
$t->get_ok('/')->status_is(200)->text_is('title' => 'Check links')->element_exists('form input[type=url]');
$t->post_ok('/links' => form => {url => 'https://mojolicious.org'})->status_is(200)->text_is('title' => 'Result')
  ->text_is('p' => 'Waiting for result...')->element_exists_not('table');

# Perform the background job
$t->get_ok('/links/1')->status_is(200)->text_is('title' => 'Result')->text_is('p' => 'Waiting for result...')
  ->element_exists_not('table');
$t->app->minion->perform_jobs;
$t->get_ok('/links/1')->status_is(200)->text_is('title' => 'Result')->element_exists_not('p')->element_exists('table');

# Clean up once we are done
$pg->db->query('DROP SCHEMA linkcheck_test CASCADE');

done_testing();
