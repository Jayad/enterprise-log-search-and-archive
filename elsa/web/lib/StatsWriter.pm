package StatsWriter;
use Moose::Role;

has 'stat_objects' => (is => 'rw', isa => 'ArrayRef', required => 1, default => sub { [] });

after BUILD => sub {
	my $self = shift;
	
	$self->stats_plugins();
	
	foreach my $plugin_name ($self->stats_plugins()){
		my $plugin = $plugin_name->new(conf => $self->conf);
		push @{ $self->stat_objects }, $plugin;
	}
	
	return $self
};

#around BUILDARGS => sub {
#	my $orig = shift;
#	my $class = shift;
#	my %params = @_;
#		
#	if ($params{config_file}){
#		$params{conf} = new Config::JSON ( $params{config_file} ) or die("Unable to open config file");
#	}		
#	
#	
#	
#	return $class->$orig(%params);
#};

1;