
# Minion [![Build Status](https://travis-ci.org/kraih/minion.svg?branch=master)](https://travis-ci.org/kraih/minion)

  A [Mango](https://github.com/kraih/mango) job queue for the
  [Mojolicious](http://mojolicio.us) real-time web framework.

```perl
use Mojolicious::Lite;

my $uri = 'mongodb://<user>:<pass>@<server>/<database>';
plugin Minion => {uri => $uri};

# Slow task
app->minion->add_task(slow_log => sub {
  my $job = shift;
  sleep 5;
  $job->app->log->debug('Something.');
  return undef;
});

# Slow task with result
app->minion->add_task(slow_add => sub {
  my ($job, $first, $second) = @_;
  sleep 5;
  return $first + $second;
});

# Perform job in a background worker process
get '/log' => sub {
  my $self = shift;
  $self->minion->enqueue('slow_log');
  $self->render(text => 'Something will be logged soon.');
};

# Perform job in a background worker process and wait for result
get '/add' => sub {
  my $self = shift;
  my $result = $self->minion->call(slow_add => [2, 2]);
  $self->render(text => "The result is $result.");
};

app->start;
```

  Just start a background worker process in addition to your web server.

    $ ./myapp.pl minion worker

## Installation

  All you need is a oneliner, it takes less than a minute.

    $ curl -L cpanmin.us | perl - -n Minion

  We recommend the use of a [Perlbrew](http://perlbrew.pl) environment.
