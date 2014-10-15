
# Minion [![Build Status](https://travis-ci.org/kraih/minion.svg?branch=master)](https://travis-ci.org/kraih/minion)

  A job queue for the [Mojolicious](http://mojolicio.us) real-time web
  framework with support for multiple backends.

```perl
use Mojolicious::Lite;
use 5.20.0;
use experimental 'signatures';

plugin Minion => {File => '/Users/sri/minion.db'};

# Slow task
app->minion->add_task(slow_log => sub ($job, $msg) {
  sleep 5;
  $job->app->log->debug(qq{Received message "$msg".});
});

# Perform job in a background worker process
get '/log' => sub ($c) {
  $c->minion->enqueue(slow_log => [$c->param('msg') // 'no message']);
  $c->render(text => 'Your message will be logged soon.');
};

app->start;
```

  Just start one or more background worker processes in addition to your web
  server.

    $ ./myapp.pl minion worker

## Installation

  All you need is a oneliner, it takes less than a minute.

    $ curl -L cpanmin.us | perl - -n Minion

  And if you already have `cpanm` installed with a secure toolchain.

    $ cpanm --mirror https://cpan.metacpan.org --mirror-only --verify -n Minion

  We recommend the use of a [Perlbrew](http://perlbrew.pl) environment.
