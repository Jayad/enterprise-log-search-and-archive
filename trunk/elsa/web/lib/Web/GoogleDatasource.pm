package Web::GoogleDatasource;
use Moose;
extends 'Web';
use Data::Dumper;
use Plack::Request;
use Plack::Session;
use Encode;
use Scalar::Util;
use Data::Google::Visualization::DataSource;
use Data::Google::Visualization::DataTable;
use DateTime;

with 'Fields';

sub call {
	my ($self, $env) = @_;
    
	my $req = Plack::Request->new($env);
	my $args = $req->parameters->as_hashref;
	my $datasource = Data::Google::Visualization::DataSource->new({
	    tqx => $args->{tqx},
	    xda => ($req->header('X-DataSource-Auth') || undef)
	});
	my $res = $req->new_response(200); # new Plack::Response
	my $ret;
	my $query_args;
	eval {
		$self->session(Plack::Session->new($env));
		$res->content_type('text/plain');
		$res->header('Access-Control-Allow-Origin' => '*');
		
		$self->api->clear_warnings;
		
		
		if ($self->session->get('user')){
			$args->{user} = $self->api->get_stored_user($self->session->get('user'));
		}
		else {
			$args->{user} = $self->api->get_user($req->user);
		}		
	
		my $check_args = $self->api->json->decode($args->{q});
		if ($args->{user}->is_admin){
			$self->api->log->debug('$check_args: ' . Dumper($check_args));
			# Trust admin
			$query_args = $check_args;
		}
		else {
			$query_args = $self->api->_get_query($check_args) or die('Query not found'); # this is now from the database, so we can trust the input
		}
		$query_args->{auth} = $check_args->{auth};
		$query_args->{query_meta_params} = $check_args->{query_meta_params};
		$query_args->{user} = $args->{user};
		$query_args->{system} = 1;
		
		unless ($query_args->{uid} eq $args->{user}->uid or $args->{user}->is_admin){
			die('Invalid auth token') unless $self->api->_check_auth_token($query_args);
			$self->api->log->info('Running query created by ' . $query_args->{username} . ' on behalf of ' . $req->user);
			$query_args->{user} = $self->api->get_user(delete $query_args->{username});
		}
		
		$self->api->freshen_db;
		$ret = $self->api->query($query_args);
		unless ($ret){
			die($self->api->last_error);
		}
	
		my $datatable = Data::Google::Visualization::DataTable->new();
	
		if ($ret->has_groupby){
			#$self->api->log->debug('ret: ' . Dumper($ret));
			$self->api->log->debug('all_groupbys: ' . Dumper($ret->all_groupbys));
			$self->api->log->debug('groupby: ' . Dumper($ret->groupby));
			
			# First add columns
			my $value_id = 0;
			foreach my $groupby ($ret->all_groupbys){
				$self->api->log->debug('groupby: ' . Dumper($groupby));
				my $label = $ret->meta_params->{comment} ? $ret->meta_params->{comment} : 'count'; 
				if ($Fields::Time_values->{$groupby}){
					$datatable->add_columns({id => $groupby, label => $groupby, type => 'datetime'}, {id => 'value' . $value_id++, label => $label, type => 'number'});
				}
				else {
					if ($query_args->{query_meta_params}->{type} and $query_args->{query_meta_params}->{type} =~ /geo/i){
						$datatable->add_columns({id => $groupby, label => $groupby, type => 'string'}, {id => 'value' . $value_id++, label => $label, type => 'number'});
					}
					else {
						$datatable->add_columns({id => $groupby, label => $groupby, type => 'string'}, {id => 'value' . $value_id++, label => $label, type => 'number'});
					}
				}
			}
			
			# Then add rows
			foreach my $groupby ($ret->all_groupbys){
				my $label = $ret->meta_params->{comment} ? $ret->meta_params->{comment} : 'count'; 
				if ($Fields::Time_values->{$groupby}){
					my $tz = DateTime::TimeZone->new( name => "local");
					foreach my $row (@{ $ret->results->results->{$groupby} }){
						$self->api->log->debug('row: ' . Dumper($row));
						$datatable->add_rows([ { v => DateTime->from_epoch(epoch => $row->{'intval'}, time_zone => $tz) }, { v => $row->{_count} } ]);
					}
				}
				else {
					if ($query_args->{query_meta_params}->{type} and $query_args->{query_meta_params}->{type} =~ /geo/i){
						# See if we have lat/long
#						if ($ret->results->results->{$groupby}->[0] and $ret->results->results->{$groupby}->[0]->{_groupby} =~ /latitude/){
#							$datatable->add_columns({id => 'latitude', label => 'latitude', type => 'number'}, {id => 'longitude', label => 'longitude', type => 'number'}, {id => 'value', label => $label, type => 'number'});
#							foreach my $row (@{ $ret->results->results->{$groupby} }){
#								$self->api->log->debug('row: ' . Dumper($row));
#								$row->{_groupby} =~ /latitude=(\-?\d+)/;
#								my $lat = $1;
#								$row->{_groupby} =~ /longitude=(\-?\d+)/;
#								my $long = $1;
#								$datatable->add_rows([ { v => $lat }, { v => $long }, { v => $row->{_count} } ]);
#							}
#						}
#						else {
							# Hope for country code
							foreach my $row (@{ $ret->results->results->{$groupby} }){
								my $cc = $row->{_groupby};
								$self->api->log->debug('row: ' . Dumper($row));
								if ($row->{_groupby} =~ /cc=(\w{2})/i){
									$cc = $1;
								}
								$datatable->add_rows([ { v => $cc }, { v => $row->{_count} } ]);
							}
#						}
					}
					else {
						foreach my $row (@{ $ret->results->results->{$groupby} }){
							$self->api->log->debug('row: ' . Dumper($row));
							$datatable->add_rows([ { v => $row->{_groupby} }, { v => $row->{_count} } ]);
						}
					}
				}
			}
		}
		else {
			die('groupby required');
		}
		$datasource->datatable($datatable);
		
		if (ref($ret) and ref($ret) eq 'HASH'){
			if ($self->api->has_warnings){
				$self->api->log->debug('warnings: ' . Dumper($self->api->warnings));
				$datasource->add_message({type => 'warning', reason => 'data_truncated', message => join(' ', @{ $self->api->warnings })});
			}
		}
		elsif (ref($ret) and blessed($ret) and $ret->can('add_warning') and $self->api->has_warnings){
			$self->api->log->debug('warnings: ' . Dumper($self->api->warnings));
			$datasource->add_message({type => 'warning', reason => 'data_truncated', message => join(' ', @{ $self->api->warnings })});
		}
	};
	if ($@){
		my $e = $@;
		$self->api->log->error($e);
		$datasource->add_message({type => 'error', reason => 'access_denied', message => $e});
		my ($headers, $body) = $datasource->serialize;
		$res->headers(@$headers);
		$res->body([encode_utf8($body)]);
	}
	else {
		my ($headers, $body) = $datasource->serialize;
		$res->headers(@$headers);
		$res->body([encode_utf8($body)]);
		$self->api->log->debug('headers: ' . Dumper(@$headers));
		$self->api->log->debug('body: ' . Dumper($body));
	}
	
	$res->finalize();
}

1;