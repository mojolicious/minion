package Mojolicious::Plugin::Minion::Admin;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::File 'path';

sub register {
  my ($self, $app) = @_;

  # Static files
  my $resources = path(__FILE__)->sibling('resources');
  push @{$app->static->paths}, $resources->child('public')->to_string;

  # Templates
  push @{$app->renderer->paths}, $resources->child('templates')->to_string;

  # Routes
  my $prefix = $app->routes->any('/minion');
  $prefix->get('/'      => \&_dashboard)->name('minion_dashboard');
  $prefix->get('/stats' => \&_stats)->name('minion_stats');
  $prefix->get('/jobs'  => \&_list_jobs)->name('minion_jobs');
  $prefix->post('/jobs' => \&_manage_jobs)->name('minion_manage_jobs');
  $prefix->get('/workers' => \&_list_workers)->name('minion_workers');

  return $prefix;
}

sub _dashboard {
  my $c = shift;
  $c->render('minion/dashboard');
}

sub _list_jobs {
  my $c = shift;

  my $validation = $c->validation;
  $validation->optional('id');
  $validation->optional('limit')->num;
  $validation->optional('offset')->num;
  $validation->optional('queue');
  $validation->optional('state')->in(qw(active failed finished inactive));
  $validation->optional('task');
  my $options = {};
  $options->{$_} = $validation->param($_) for qw(queue state task);
  $options->{ids} = $validation->every_param('id')
    if $validation->is_valid('id');
  my $limit  = $validation->param('limit')  || 10;
  my $offset = $validation->param('offset') || 0;

  my $results = $c->minion->backend->list_jobs($offset, $limit, $options);
  $c->render(
    'minion/jobs',
    jobs   => $results->{jobs},
    total  => $results->{total},
    limit  => $limit,
    offset => $offset
  );
}

sub _list_workers {
  my $c = shift;

  my $validation = $c->validation;
  $validation->optional('id');
  $validation->optional('limit')->num;
  $validation->optional('offset')->num;
  my $limit  = $validation->param('limit')  || 10;
  my $offset = $validation->param('offset') || 0;
  my $options = {};
  $options->{ids} = $validation->every_param('id')
    if $validation->is_valid('id');

  my $results = $c->minion->backend->list_workers($offset, $limit, $options);
  $c->render(
    'minion/workers',
    workers => $results->{workers},
    total   => $results->{total},
    limit   => $limit,
    offset  => $offset
  );
}

sub _manage_jobs {
  my $c = shift;

  my $validation = $c->validation;
  $validation->required('id');
  $validation->required('do')->in('remove', 'retry', 'stop');

  $c->redirect_to('minion_jobs') if $validation->has_error;

  my $minion = $c->minion;
  my $ids    = $validation->every_param('id');
  my $do     = $validation->param('do');
  if    ($do eq 'retry')  { $minion->job($_)->retry  for @$ids }
  elsif ($do eq 'remove') { $minion->job($_)->remove for @$ids }
  elsif ($do eq 'stop') { $minion->backend->broadcast(stop => [$_]) for @$ids }

  $c->redirect_to($c->url_for('minion_jobs')->query(id => $ids));
}

sub _stats {
  my $c = shift;
  $c->render(json => $c->minion->stats);
}

1;

=encoding utf8

=head1 NAME

Mojolicious::Plugin::Minion::Admin - Admin UI

=head1 SYNOPSIS

  # Mojolicious (administration interface under "/minion")
  $self->plugin('Minion::Admin');

  # Mojolicious::Lite (administration interface under "/minion")
  plugin 'Minion::Admin';

  # Secure access to the administration interface with Basic authentication
  my $admin = $self->plugin('Minion::Admin');
  my $under = $self->routes->under('/minion' =>sub {
    my $c = shift;
    return 1 if $c->req->url->to_abs->userinfo eq 'Bender:rocks';
    $c->res->headers->www_authenticate('Basic');
    $c->render(text => 'Authentication required!', status => 401);
  });
  my @children = @{$admin->remove->children};
  $under->add_child($_) for @children;

=head1 DESCRIPTION

L<Mojolicious::Plugin::Minion::Admin> is a L<Mojolicious> plugin providing an
administration interface for the L<Minion> job queue.

=head1 METHODS

L<Mojolicious::Plugin::Minion::Admin> inherits all methods from
L<Mojolicious::Plugin> and implements the following new ones.

=head2 register

  my $route = $plugin->register(Mojolicious->new);

Register plugin in L<Mojolicious> application.

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
