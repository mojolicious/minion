package Minion::Command::minion::schedule;
use Mojo::Base 'Mojolicious::Command';

use Mojo::JSON qw(decode_json);
use Mojo::Util qw(getopt tablify);

has description => 'Manage Minion schedules';
has usage       => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  my ($args, $options) = ([], {});
  getopt \@args,
    'A|attempts=i' => \$options->{attempts},
    'a|args=s'     => sub { $args = decode_json($_[1]) },
    'c|cron=s'     => \my $cron,
    'd|dispatch'   => \my $dispatch,
    'E|expire=i'   => \$options->{expire},
    'e|enqueue=s'  => \my $enqueue,
    'l|limit=i'    => \(my $limit             = 100),
    'n|notes=s'    => sub { $options->{notes} = decode_json($_[1]) },
    'o|offset=i'   => \(my $offset            = 0),
    'P|pause=s'    => \my $pause,
    'p|priority=i' => \$options->{priority},
    'q|queue=s'    => \$options->{queue},
    'R|remove=s'   => \my $remove,
    'r|resume=s'   => \my $resume,
    't|task=s'     => \my $task,
    'x|lax=s'      => \$options->{lax};

  my $minion = $self->app->minion;

  # Add or update a schedule
  if ($enqueue) {
    die "Cron expression is required (-c).\n" unless defined $cron;
    die "Task is required (-t).\n"            unless defined $task;
    return say $minion->schedule($enqueue, $cron, $task, $args, $options);
  }

  # Pause, resume or remove
  return $minion->pause_schedule($pause)   || die "Schedule does not exist.\n" if $pause;
  return $minion->resume_schedule($resume) || die "Schedule does not exist.\n" if $resume;
  return $minion->unschedule($remove)      || die "Schedule does not exist.\n" if $remove;

  # Manually dispatch any due schedules
  return print Minion::_dump($minion->dispatch_schedules) if $dispatch;

  # Schedule info
  my $name = shift @args;
  if (defined $name) {
    die "Schedule does not exist.\n"
      unless my $info = $minion->list_schedules(0, 1, {names => [$name]})->{schedules}[0];
    return print Minion::_dump(Minion::_datetime($info));
  }

  # List schedules
  $self->_list($offset, $limit);
}

sub _list {
  my ($self, $offset, $limit) = @_;
  my $schedules = $self->app->minion->list_schedules($offset, $limit)->{schedules};
  @$schedules = map { Minion::_datetime($_) } @$schedules;
  print tablify [map { [@$_{qw(id name task cron next_run paused)}] } @$schedules];
}

1;

=encoding utf8

=head1 NAME

Minion::Command::minion::schedule - Minion schedule command

=head1 SYNOPSIS

  Usage: APPLICATION minion schedule [OPTIONS] [NAME]

    ./myapp.pl minion schedule
    ./myapp.pl minion schedule daily
    ./myapp.pl minion schedule -e daily -c '0 4 * * *' -t cleanup
    ./myapp.pl minion schedule -e foo -c '*/5 * * * *' -t bar -a '[1, 2, 3]' -p 5 -q important
    ./myapp.pl minion schedule -e weekday_report -c '0 9 * * 1-5' -t report -A 3
    ./myapp.pl minion schedule -P daily
    ./myapp.pl minion schedule -r daily
    ./myapp.pl minion schedule -R daily
    ./myapp.pl minion schedule -d

  Options:
    -A, --attempts <number>     Number of times each enqueued job will be
                                attempted, defaults to 1
    -a, --args <JSON array>     Arguments for the new schedule in JSON format
    -c, --cron <expression>     Cron expression for new schedule
    -d, --dispatch              Manually dispatch any due schedules
    -E, --expire <seconds>      Each enqueued job is valid for this many seconds
                                before it expires
    -e, --enqueue <name>        Add or replace a schedule with this name
                                (requires -c and -t)
    -h, --help                  Show this summary of available options
        --home <path>           Path to home directory of your application,
                                defaults to the value of MOJO_HOME or
                                auto-detection
    -l, --limit <number>        Number of schedules to show when listing them,
                                defaults to 100
    -m, --mode <name>           Operating mode for your application, defaults to
                                the value of MOJO_MODE/PLACK_ENV or
                                "development"
    -n, --notes <JSON>          Notes in JSON format for the new schedule
    -o, --offset <number>       Number of schedules to skip when listing them,
                                defaults to 0
    -P, --pause <name>          Pause a schedule
    -p, --priority <number>     Priority of each enqueued job
    -q, --queue <name>          Queue to put each enqueued job in, defaults to
                                "default"
    -R, --remove <name>         Remove a schedule
    -r, --resume <name>         Resume a paused schedule
    -t, --task <name>           Task name for the new schedule
    -x, --lax <bool>            Existing jobs each enqueued job depends on may
                                also have failed to allow for it to be processed

=head1 DESCRIPTION

L<Minion::Command::minion::schedule> manages L<Minion> schedules.

=head1 ATTRIBUTES

L<Minion::Command::minion::schedule> inherits all attributes from L<Mojolicious::Command> and implements the following
new ones.

=head2 description

  my $description = $schedule->description;
  $schedule       = $schedule->description('Foo');

Short description of this command, used for the command list.

=head2 usage

  my $usage = $schedule->usage;
  $schedule = $schedule->usage('Foo');

Usage information for this command, used for the help screen.

=head1 METHODS

L<Minion::Command::minion::schedule> inherits all methods from L<Mojolicious::Command> and implements the following new
ones.

=head2 run

  $schedule->run(@ARGV);

Run this command.

=head1 SEE ALSO

L<Minion>, L<Minion::Guide>, L<https://minion.pm>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
