package LinkCheck::Controller::Links;
use Mojo::Base 'Mojolicious::Controller';

sub check {
  my $self = shift;

  my $validation = $self->validation;
  $validation->required('url');
  return $self->render(action => 'index') if $validation->has_error;

  my $id = $self->minion->enqueue(check_links => [$validation->param('url')]);
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
