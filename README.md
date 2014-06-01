
# Minion [![Build Status](https://travis-ci.org/kraih/minion.svg?branch=master)](https://travis-ci.org/kraih/minion)

  A job queue for the [Mojolicious](http://mojolicio.us) real-time web
  framework.

```perl
use Mojolicious::Lite;

my $uri = 'mongodb://<user>:<pass>@<server>/<database>';
plugin Minion => {uri => $uri};

# Slow task
app->minion->add_task(slow_log => sub {
  my ($job, $msg) = @_;
  sleep 5;
  $job->app->log->debug(qq{Received message "$msg".});
});

# Perform job in a background worker process
get '/log' => sub {
  my $self = shift;
  $self->minion->enqueue(slow_log => [$self->param('msg') // 'no message']);
  $self->render(text => 'Your message will be logged soon.');
};

app->start;
```

  Just start one or more background worker processes in addition to your web
  server.

    $ ./myapp.pl minion worker

## Installation

  All you need is a oneliner, it takes less than a minute.

    $ curl -L cpanmin.us | perl - -n Minion

  We recommend the use of a [Perlbrew](http://perlbrew.pl) environment.
