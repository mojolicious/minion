package LinkCheck::Task::CheckLinks;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::URL;

sub register ($self, $app, $config) {
  $app->minion->add_task(check_links => \&_check_links);
  $app->minion->add_task(foo         => sub {die});
}

sub _check_links ($job, $url) {
  my @results;
  my $ua  = $job->app->ua;
  my $res = $ua->get($url)->result;
  push @results, [$url, $res->code];

  for my $link ($res->dom->find('a[href]')->map(attr => 'href')->each) {
    my $abs = Mojo::URL->new($link)->to_abs(Mojo::URL->new($url));
    $res = $ua->head($abs)->result;
    push @results, [$link, $res->code];
  }

  $job->finish(\@results);
}

1;
