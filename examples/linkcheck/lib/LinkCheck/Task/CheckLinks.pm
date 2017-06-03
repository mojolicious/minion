package LinkCheck::Task::CheckLinks;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::URL;

sub register {
  my ($self, $app) = @_;
  $app->minion->add_task(check_links => \&_check_links);
}

sub _check_links {
  my ($job, $url) = @_;

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
