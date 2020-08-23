package LinkCheck;
use Mojo::Base 'Mojolicious';

sub startup {
  my $self = shift;

  # Configuration
  my $config = $self->plugin(Config => {file => 'linkcheck.conf'});
  $self->secrets($config->{secrets});

  # Job queue (requires a background worker process)
  #
  #   $ script/linkcheck minion worker
  #
  $self->plugin(Minion => {Pg => $config->{pg}});
  $self->plugin('Minion::Admin');
  $self->plugin('LinkCheck::Task::CheckLinks');

  # Controller
  my $r = $self->routes;
  $r->get('/' => sub { shift->redirect_to('index') });
  $r->get('/links')->to('links#index')->name('index');
  $r->post('/links')->to('links#check')->name('check');
  $r->get('/links/:id')->to('links#result')->name('result');
}

1;
