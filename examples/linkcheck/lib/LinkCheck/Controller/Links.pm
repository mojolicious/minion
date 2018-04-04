package LinkCheck::Controller::Links;
use Mojo::Base 'Mojolicious::Controller';

sub check {
  my $self = shift;

  my $v = $self->validation;
  $v->required('url');
  return $self->render(action => 'index') if $v->has_error;

  my $id = $self->minion->enqueue(check_links => [$v->param('url')]);
  $self->redirect_to('result', id => $id);
}

sub index { }

sub result {
  my $self = shift;

  return $self->reply->not_found
    unless my $job = $self->minion->job($self->param('id'));

  $self->render(result => $job->info->{result});
}

1;
