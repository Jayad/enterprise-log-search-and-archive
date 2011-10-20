package Web::Query;
use Moose;
extends 'Web';
use Data::Dumper;
use Plack::Request;
use Plack::Session;

sub call {
	my ($self, $env) = @_;
    $self->session(Plack::Session->new($env));
	my $req = Plack::Request->new($env);
	$self->{_USERNAME} = $req->user ? $req->user : undef;
	my $res = $req->new_response(200); # new Plack::Response
	$res->content_type('text/plain');
	$res->header('Access-Control-Allow-Origin' => '*');
	
	my $method = $self->_extract_method($req->request_uri);
	$self->log->debug('method: ' . $method);
	#my $ret = $self->rpc($method, $req->parameters->as_hashref);
	my $args = $req->parameters->as_hashref;
	$args->{user_info} = $self->session->get('user_info');
	unless ($self->api->can($method)){
		$res->status(404);
		$res->body('not found');
		return $res->finalize();
	}
	my $ret = $self->api->$method($args);
	if (ref($ret) and $ret->{mime_type}){
		$res->content_type($ret->{mime_type});
		$res->body($ret->{ret});
		if ($ret->{filename}){
			$res->header(-attachment => $ret->{filename});
		}
	}
	else {
		$res->body($self->json->encode($ret));
	}
	$res->finalize();
}

1;