
![Screenshot](https://raw.github.com/mojolicious/minion/main/examples/admin.png?raw=true)

[![](https://github.com/mojolicious/minion/workflows/linux/badge.svg)](https://github.com/mojolicious/minion/actions)

A high performance job queue for the Perl programming language. Also available for [Node.js](https://github.com/mojolicious/minion.js).

Minion comes with support for multiple named queues, priorities, high priority fast lane, delayed jobs, job
dependencies, job progress, job results, retries with backoff, rate limiting, unique jobs, expiring jobs, statistics,
distributed workers, parallel processing, autoscaling, remote control, [Mojolicious](https://mojolicious.org) admin ui,
resource leak protection and multiple backends (such as [PostgreSQL](https://www.postgresql.org)).

Job queues allow you to process time and/or computationally intensive tasks in background processes, outside of the
request/response lifecycle of web applications. Among those tasks you'll commonly find image resizing, spam filtering,
HTTP downloads, building tarballs, warming caches and basically everything else you can imagine that's not super fast.

```perl
use Mojolicious::Lite -signatures;

plugin Minion => {Pg => 'postgresql://postgres@/test'};

# Slow task
app->minion->add_task(slow_log => sub ($job, $msg) {
  sleep 5;
  $job->app->log->debug(qq{Received message "$msg"});
});

# Perform job in a background worker process
get '/log' => sub ($c) {
  $c->minion->enqueue(slow_log => [$c->param('msg') // 'no message']);
  $c->render(text => 'Your message will be logged soon.');
};

app->start;
```

  Just start one or more background worker processes in addition to your web server.

    $ ./myapp.pl minion worker

## Installation

  All you need is a one-liner, it takes less than a minute.

    $ curl -L https://cpanmin.us | perl - -M https://cpan.metacpan.org -n Minion

  We recommend the use of a [Perlbrew](http://perlbrew.pl) environment.

## Want to know more?

  Take a look at our excellent [documentation](https://mojolicious.org/perldoc/Minion/Guide)!
