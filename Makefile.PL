use 5.016;

use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  NAME         => 'Minion',
  VERSION_FROM => 'lib/Minion.pm',
  ABSTRACT     => 'Job queue',
  AUTHOR       => 'Sebastian Riedel <sri@cpan.org>',
  LICENSE      => 'artistic_2',
  META_MERGE   => {
    dynamic_config => 0,
    'meta-spec'    => {version   => 2},
    no_index       => {directory => ['t']},
    prereqs        => {runtime   => {requires => {perl => '5.016'}}},
    resources      => {
      bugtracker => {web => 'https://github.com/mojolicious/minion/issues'},
      homepage   => 'https://mojolicious.org',
      license    => ['http://www.opensource.org/licenses/artistic-license-2.0'],
      repository => {
        type => 'git',
        url  => 'https://github.com/mojolicious/minion.git',
        web  => 'https://github.com/mojolicious/minion',
      },
      x_IRC => {url => 'irc://chat.freenode.net/#mojo', web => 'https://webchat.freenode.net/#mojo'}
    },
  },
  PREREQ_PM => {Mojolicious => '9.0', 'YAML::XS' => 0},
  test      => {TESTS       => 't/*.t t/*/*.t'}
);
