package Web;
use Moose;
use base 'Plack::Component';
use Data::Dumper;
use Plack::Request;
use Plack::Session;
use JSON -convert_blessed_universally;
use YUI;
use Module::Pluggable require => 1, search_path => [ qw( Export Info ) ];

use API;

has 'log' => ( is => 'ro', isa => 'Log::Log4perl::Logger', required => 1 );
has 'conf' => ( is => 'ro', isa => 'Config::JSON', required => 1 );
has 'json' => (is => 'ro', isa => 'JSON', required => 1);
has 'mode' => (is => 'rw', isa => 'Str', required => 1, default => sub { return 'index' });
has 'session' => (is => 'rw', isa => 'Object', required => 0);
has 'api' => (is => 'rw', isa => 'Object', required => 1);

our %Modes = (
	index => 1,
	chart => 1,
	stats => 1,
	get_results => 1,
	admin => 1,
);

#sub BUILD {
#	my ($self, $params) = @_;
#			
#	return $self;
#}

sub call {
	my ($self, $env) = @_;
    $self->session(Plack::Session->new($env));
	my $req = Plack::Request->new($env);
	my $res = $req->new_response(200); # new Plack::Response
	$res->content_type('text/html');
	$res->header('Access-Control-Allow-Origin' => '*');
	
	my $body;
	my $method = $self->_extract_method($req->request_uri);
	$method ||= 'index';
	$self->log->debug('method: ' . $method);
	if (exists $Modes{ $method }){
		my $sub = $method;
		if ($Modes{ $method } == 1){
			my $user_info = $self->api->get_user_info($req->user);
			if ($user_info){
				$self->session->set('user_info', $user_info);
				$body = $self->$sub($req);
			}
			else {
				$res->status(401);
				$body = 'Unauthorized';
			}
		}
		elsif ($Modes{ $method } == 2){
			$body = $self->$sub($req);
		}
	}
	
	$res->body($body);
	$res->finalize();
}

sub _extract_method {
	my $self = shift;
	my $uri = shift;
	$self->log->debug('uri: ' . $uri);
	
	$uri =~ /\/([^\/\?]+)\??([^\/]*)$/;
	return $1;
}


sub index {
	my $self = shift;
	my $req = shift;
	return $self->_get_headers() . $self->_get_index_body();
}

sub _get_headers {
	my $self = shift;
#	my $dir = shift;
#	unless ($dir){
#		$dir = '';
#	}
	my $dir = $self->conf->get('email/base_url');
	$dir =~ s/^https?\:\/\/[^\/]+\//\//; # strip off the URL to make $dir the URI
	$dir = '';
	my $HTML = <<'EOHTML'
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
<head>
EOHTML
;

#	my $yui_css = YUI::css_link();
#	my $yui_js = YUI::js_link();
	my $yui = new YUI(%{ $self->conf->get('yui') });
	$HTML .= $yui->css();
	$HTML .= $yui->js();

	my $template = <<'EOHTML'
<style type="text/css">
/*margin and padding on body element
  can introduce errors in determining
  element position and are not recommended;
  we turn them off as a foundation for YUI
  CSS treatments. */
body {
	margin:0;
	padding:0;
}
</style>
<link rel="stylesheet" type="text/css" href=%3$s/inc/custom.css />
<script type="text/javascript" src="%3$s/inc/swfobject.js"></script>
<script type="text/javascript" src="%3$s/inc/chart.js" ></script>
<script type="text/javascript" src="%3$s/inc/utilities.js" ></script>
<script type="text/javascript" src="%3$s/inc/elsa.js" ></script>
<script type="text/javascript" src="%3$s/inc/main.js" ></script>
<script type="text/Javascript">
EOHTML
;

	if ($self->conf->get('javascript_debug_mode')){
		$template .= 'YAHOO.ELSA.viewMode = \'' . $self->conf->get('javascript_debug_mode') . '\';' . "\n";
	}
	$HTML .= sprintf($template, undef, undef, $dir);
	
	# Set the javascript var for admin here if necessary
	if ($self->session->get('user_info') and $self->session->get('user_info')->{is_admin}){
		$HTML .= 'YAHOO.ELSA.IsAdmin = true;' . "\n";
		
		# Set the URL for getPcap if applicable
		if ($self->conf->get('pcap_url')){
			$HTML .= 'YAHOO.ELSA.pcapUrl = "' . $self->conf->get('pcap_url') . '"' . "\n";
		}
	}
	
	$HTML .= <<'EOHTML'
YAHOO.util.Event.throwErrors = true; 
	/*
		Global object that should allow for the initial creation of the select dropdown
		If necessary, this might be devoured by 'classes' object
	*/
	
	classSelect = {
		values: {
			'0': 'New Class',
			'1': 'Test Class'
		},
		id: 'class',
		selected: ' ',
		onchange: 'loadClass(this.value);drawLabels();'
	};
	
	labelSearch = [];
	multipleInheritance = {};
	
</script>
<title>ELSA</title>
EOHTML
;
	return $HTML;

}


sub _get_index_body {
	my $HTML = <<'EOHTML'
<script>YAHOO.util.Event.addListener(window, "load", YAHOO.ELSA.main);</script>
</head>
<body class=" yui-skin-sam">
<div id="menu_bar"></div>
<div id="panel_root"></div>
<h1>Enterprise Log Search and Archive</h1>
<div id="query_form"></div>
<div id="logs">
	<div id="tabView">
	<ul class="yui-nav">
    </ul>
	    <div class="yui-content"></div>
    </div>
</div>

</body>
</html>
EOHTML
;

	return $HTML;
}

sub get_results {
	my $self = shift;
	my $req = shift;
	
	my $HTML = $self->_get_headers('..');
	
	if ($self->session->get('user_info') and $self->session->get('user_info')->{uid}){
		my $args = $req->query_parameters->as_hashref;
		$args->{uid} = $self->session->get('user_info')->{uid};
		
		#my $ret = $self->rpc('get_saved_result', $args);
		my $ret = $self->api->get_saved_result($args);
		if ($ret and ref($ret) eq 'HASH'){
			 $HTML .= '<script>var oGivenResults = ' . $self->json->encode($ret) . '</script>';
			 $HTML .= '<script>YAHOO.util.Event.addListener(window, "load", function(){YAHOO.ELSA.initLogger(); YAHOO.ELSA.Results.Given(oGivenResults)});</script>';
		}
		else {
			$self->_error('Unable to get results, got: ' . Dumper($ret));
			$HTML .= '<script>YAHOO.util.Event.addListener(window, "load", function(){YAHOO.ELSA.initLogger(); YAHOO.ELSA.Error("Unable to get results"); });</script>';
		}
	}
	else {
		$self->_error('Unauthorized');
		$HTML .= '<script>YAHOO.util.Event.addListener(window, "load", function(){YAHOO.ELSA.initLogger(); YAHOO.ELSA.Error("Unauthorized"); });</script>';
	}
	
	$HTML .= <<'EOHTML'
</head>
<body class=" yui-skin-sam">
<div id="panel_root"></div>
<div id="logs">
	<div id="tabView">
	<ul class="yui-nav">
    </ul>
	    <div class="yui-content">
	    </div>
    </div>
</div>
</body>
</html>
EOHTML
;

	return $HTML;
}

sub admin {
	my $self = shift;
	my $req = shift;
	
	my $args = $req->query_parameters->as_hashref;
	$args->{uid} = $self->session->get('user_info')->{uid};
	my $HTML = $self->_get_headers('..');
	
	$HTML .= <<'EOHTML'
<script type="text/javascript" src="inc/admin.js" ></script>
<script>YAHOO.util.Event.addListener(window, "load", YAHOO.ELSA.Admin.main)</script>
</head>
<body class=" yui-skin-sam">
<div id="panel_root"></div>
<div id="permissions"></div>
<div id="delete_exceptions_button_container"></div>
<div id="exceptions"></div>
<div id="logs">
	<div id="tabView">
	<ul class="yui-nav">
    </ul>
	    <div class="yui-content">
	    </div>
    </div>
</div>
</body>
</html>
EOHTML
;
	
	return $HTML;	
}

sub stats {
	my $self = shift;
	my $req = shift;
	
	my $args = $req->query_parameters->as_hashref;
	$args->{uid} = $self->session->get('user_info')->{uid};
	my $HTML = $self->_get_headers('..');
	
	$HTML .= <<'EOHTML'
<script type="text/javascript" src="inc/stats.js" ></script>
<script>YAHOO.util.Event.addListener(window, "load", YAHOO.ELSA.Stats.main)</script>
</head>
<body class=" yui-skin-sam">
<div id="panel_root"></div>
<div id="query_stats"></div>
<div id="load_stats"></div>
<div id="logs">
	<div id="tabView">
	<ul class="yui-nav">
    </ul>
	    <div class="yui-content">
	    </div>
    </div>
</div>
</body>
</html>
EOHTML
;
	
	return $HTML;	
}


sub export {
	my ($self, $args) = @_;
	
	if ( $args and ref($args) eq 'HASH' and $args->{data} and $args->{plugin} ) {
		my $decode;
		eval {
			$decode = $self->json->decode(uri_unescape($args->{data}));
			$self->log->debug( "Decoded data as : " . Dumper($decode) );
		};
		if ($@){
			$self->_error("invalid args, error: $@, args: " . Dumper($args));
			return;
		}
		
		my $results_obj;
		my $plugin_fqdn = 'Export::' . $args->{plugin};
		foreach my $plugin ($self->plugins()){
			if ($plugin eq $plugin_fqdn){
				$self->log->debug('loading plugin ' . $plugin);
				my $results_obj = $plugin->new($decode);
				$self->log->debug('results_obj:' . Dumper($results_obj));
			}
		}
		if ($results_obj){
			return { ret => $results_obj->results(), mime_type => $results_obj->get_mime_type() };
		}
		
		$self->log->error('Unable to build results object from args');
		$self->_error("failed to find plugin " . $args->{plugin} . ', only have plugins ' .
			join(', ', $self->plugins()) . ' ' . Dumper($args));
	}
	else {
		$self->_error('Invalid args: ' . Dumper($args));
	}
}



1;