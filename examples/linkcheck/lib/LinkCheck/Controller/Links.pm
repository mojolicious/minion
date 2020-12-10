package LinkCheck::Controller::Links;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub check ($self) {
  my $v = $self->validation;
  $v->required('url');
  return $self->render(action => 'index') if $v->has_error;

  my $id = $self->minion->enqueue(check_links => [$v->param('url')]);
  $self->redirect_to('result', id => $id);
}

sub index { }

sub result ($self) {
  return $self->reply->not_found unless my $job = $self->minion->job($self->param('id'));
  $self->render(result => $job->info->{result});
}

1;
