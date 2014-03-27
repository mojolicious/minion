
# Minion [![Build Status](https://secure.travis-ci.org/kraih/minion.png)](http://travis-ci.org/kraih/minion)

  A [Mango](https://github.com/kraih/mango) job queue for the
  [Mojolicious](http://mojolicio.us) real-time web framework.

```perl
use Mojolicious::Lite;

my $uri = 'mongodb://<user>:<pass>@<server>/<database>';
plugin Minion => {uri => $uri};

# Very slow task
app->minion->add_task(slow_log => sub {
  my ($job, $msg) = @_;
  sleep 5;
  $job->worker->minion->app->log->debug(qq{Received message "$msg".});
});

# Perform job in a background process
get '/' => sub {
  my $self = shift;
  $self->minion->enqueue(slow_log => [$self->param('msg') // 'no message']);
  $self->render(text => 'Your message will be logged soon.');
};

app->start;
```

  Just start a background worker process in addition to your web server.

    $ ./myapp.pl minion worker

## Installation

  All you need is a oneliner, it takes less than a minute.

    $ curl -L cpanmin.us | perl - -n Minion

  We recommend the use of a [Perlbrew](http://perlbrew.pl) environment.
