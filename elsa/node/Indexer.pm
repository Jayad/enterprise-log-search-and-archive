package Indexer;
use Moose;
use Data::Dumper;
use Date::Manip;
use DBI;
use Socket qw(inet_aton);
use Time::HiRes qw(sleep time);
use Fcntl qw(:flock);
use File::Temp;
use File::Find;
use Sys::Info; 
use Sys::Info::Constants qw( :device_cpu );
use Sys::MemInfo qw( freemem totalmem freeswap totalswap );
use Config::JSON;

use constant CRITICAL_LOW_MEMORY_LIMIT => 100 * 1024 * 1024;
our $Missing_table_error_limit = 4;
our $Timeout = 30;
our $Run = 1;
our $Sphinx_agent_query_timeout = 300;
our @Sphinx_extensions = qw( spp sph spi spl spm spa spk spd );
our $Index_retry_limit = 3;
our $Index_retry_time = 5;
our $Data_db_name = 'syslog_data';
our $Peer_id_multiplier = 2**40;

has 'locks' => (is => 'rw', isa => 'HashRef', required => 1, default => sub { {} });
has 'log' => ( is => 'ro', isa => 'Log::Log4perl::Logger', required => 1 );
has 'conf' => ( is => 'ro', isa => 'Config::JSON', required => 1 );
has 'db' => (is => 'rw', isa => 'Object', required => 0);
#has 'class_info' => (is => 'rw', isa => 'HashRef', required => 1);
has 'cpu_count' => (is => 'ro', isa => 'Int', required => 1, default => sub {
	# Find number of CPU's
	return Sys::Info->new->device('CPU')->count;
});

sub BUILDARGS {
	my $class = shift;
	my %params = @_;
	
	if ($params{config_file}){
		$params{conf} = Config::JSON->new($params{config_file});
		my $logdir = $params{conf}->get('logdir');
		my $debug_level = $params{conf}->get('debug_level');
		my $l4pconf = qq(
			log4perl.category.ELSA       = $debug_level, File
			log4perl.appender.File			 = Log::Log4perl::Appender::File
			log4perl.appender.File.filename  = $logdir/node.log
			log4perl.appender.File.syswrite = 1
			log4perl.appender.File.recreate = 1
			log4perl.appender.File.layout = Log::Log4perl::Layout::PatternLayout
			log4perl.appender.File.layout.ConversionPattern = * %p [%d] %F (%L) %M %P %m%n
			log4perl.filter.ScreenLevel               = Log::Log4perl::Filter::LevelRange
			log4perl.filter.ScreenLevel.LevelMin  = $debug_level
			log4perl.filter.ScreenLevel.LevelMax  = ERROR
			log4perl.filter.ScreenLevel.AcceptOnMatch = true
			log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
			log4perl.appender.Screen.Filter = ScreenLevel 
			log4perl.appender.Screen.stderr  = 1
			log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
			log4perl.appender.Screen.layout.ConversionPattern = * %p [%d] %F (%L) %M %P %m%n
		);
		Log::Log4perl::init( \$l4pconf ) or die("Unable to init logger\n");
		$params{log} = Log::Log4perl::get_logger("ELSA") or die("Unable to init logger\n");
	}
	
	if ($params{conf}){ # wrap this in a condition so that the right error message will be thrown if no conf
		my $dbh = DBI->connect(($params{conf}->get('database/dsn') or 'dbi:mysql:database=syslog;'), 
			$params{conf}->get('database/username'), 
			$params{conf}->get('database/password'), 
			{
				RaiseError => 1, 
				mysql_auto_reconnect => 1,
				mysql_local_infile => 1, # Needed by some MySQL implementations
			}
		) or die 'connection failed ' . $! . ' ' . $DBI::errstr;
		$params{db} = $dbh;
		
#		unless ($params{class_info}){
#			$params{class_info} = get_class_info($dbh);
#		}
	}
	
	return \%params;
}

sub BUILD {
	my $self = shift;
	$Data_db_name = $self->conf->get('database/data_db') ? $self->conf->get('database/data_db') : 'syslog_data';
	
	#$self->log->debug('db id: ' . $self->dbh_id);		
}

sub DEMOLISH {
	my $self = shift;
	$self->db->disconnect;
}

sub get_current_log_size {
	my $self = shift;
	
	my ($query, $sth);
	
	# Find current size of logs in database
	$query = "SELECT SUM(index_length+data_length) AS total_bytes\n" .
		"FROM INFORMATION_SCHEMA.tables\n" .
		"WHERE table_schema LIKE \"syslog\_%\"";
	$sth = $self->db->prepare($query);
	$sth->execute();
	my $row = $sth->fetchrow_hashref;
	my $db_size = $row->{total_bytes};
	$self->log->debug("Current size of logs in database is $db_size");
	
	# Find current size of Sphinx indexes
	my $index_size = 0;
	find(sub { $index_size += -s $File::Find::name; }, 
		$self->conf->get('sphinx/index_path'));
	$self->log->debug("Found index size of $index_size");
	
	return $db_size + $index_size;
}

sub _get_current_archive_size {
	my $self = shift;
	
	my ($query, $sth);
	
	# Find current size of logs in database
	$query = "SELECT SUM(index_length+data_length) AS total_bytes\n" .
		"FROM INFORMATION_SCHEMA.tables\n" .
		"WHERE table_schema=? AND table_name LIKE \"syslogs\_archive\_%\"";
	$sth = $self->db->prepare($query);
	$sth->execute($Data_db_name);
	my $row = $sth->fetchrow_hashref;
	my $db_size = $row->{total_bytes};
	$self->log->debug("Current size of archived logs in database is $db_size");
	
	return $db_size;
}

sub _get_current_index_size {
	my $self = shift;
	
	my ($query, $sth);
	
	# Find current size of logs in database
	$query = "SELECT SUM(index_length+data_length) AS total_bytes\n" .
		"FROM INFORMATION_SCHEMA.tables\n" .
		"WHERE table_schema=? AND table_name LIKE \"syslogs\_index\_%\"";
	$sth = $self->db->prepare($query);
	$sth->execute($Data_db_name);
	my $row = $sth->fetchrow_hashref;
	my $db_size = $row->{total_bytes};
	$self->log->debug("Current size of indexed logs in database is $db_size");
	
	# Find current size of Sphinx indexes
	my $index_size = 0;
	find(sub { $index_size += -s $File::Find::name; }, 
		$self->conf->get('sphinx/index_path'));
	$self->log->debug("Found index size of $index_size");
	
	return $db_size + $index_size;
}

# Generic log rotate command for external use
sub rotate_logs {
	my $self = shift;
	
	# Delete oldest logs as per our policy
	$self->_oversize_log_rotate();
	$self->_overtime_log_rotate();
	
	# Delete buffers that are finished
	my ($query, $sth);
	if ($self->conf->get('archive/percentage')){
		$query = 'SELECT filename FROM buffers WHERE archive_complete=1 AND index_complete=1';
	}
	else {
		$query = 'SELECT filename FROM buffers WHERE index_complete=1';
	}
	$sth = $self->db->prepare($query);
	$sth->execute();
	
	my @files;
	while (my $row = $sth->fetchrow_hashref){
		push @files, $row->{filename};
	}
	$query = 'DELETE FROM buffers WHERE filename=?';
	$sth = $self->db->prepare($query);
	
	foreach my $file (@files){
		unlink $file;
		$self->log->debug('Deleted ' . $file);
		$sth->execute($file);
	}
	
	# Consolidate indexes
	$self->_check_consolidate();
}

sub initial_validate_directory {
	my $self = shift;
	my ($query, $sth);
	
	# Delete any in-progress permanent indexes
	$query = 'DELETE FROM indexes WHERE last_id-first_id > ? AND NOT ISNULL(locked_by)';
	$sth = $self->db->prepare($query);
	$sth->execute($self->conf->get('sphinx/perm_index_size'));
	
	# Remove any locks
	$query = 'UPDATE indexes SET locked_by=NULL';
	$self->db->do($query);
	
	$query = 'UPDATE tables SET table_locked_by=NULL';
	$self->db->do($query);
	
	# Delete finished buffers
	if ($self->conf->get('archive/percentage') and $self->conf->get('sphinx/perm_index_size')){
		$query = 'DELETE FROM buffers WHERE NOT ISNULL(pid) AND index_complete=1 AND archive_complete=1';
		$self->db->do($query);
	}
	elsif ($self->conf->get('archive/percentage')){
		$query = 'DELETE FROM buffers WHERE NOT ISNULL(pid) AND archive_complete=1';
		$self->db->do($query);
	}
	elsif ($self->conf->get('sphinx/perm_index_size')){
		$query = 'DELETE FROM buffers WHERE NOT ISNULL(pid) AND index_complete=1';
		$self->db->do($query);
	}
	else {
		$self->log->warn('Not doing archiving or indexing for some reason!');
	}
		
	$query = 'UPDATE buffers SET pid=NULL WHERE NOT ISNULL(pid)';
	$self->db->do($query);
	
	# Find any buffer files that aren't in the directory
	opendir(DIR, $self->conf->get('buffer_dir'));
	my @files;
	while (my $short_file = readdir(DIR)){
		my $file = $self->conf->get('buffer_dir') . '/' . $short_file;
		next if $file =~ /\./;
		# Strip any double slashes
		$file =~ s/\/{2,}/\//g;
		push @files, $file;
	}
	closedir(DIR);
	
	# Remove any references in the database to buffers that no longer exist
	$query = 'SELECT filename FROM buffers';
	$sth = $self->db->prepare($query);
	$sth->execute();
	my @to_delete;
	while (my $row = $sth->fetchrow_hashref){
		unless (-f $row->{filename}){
			$self->log->error('File ' . $row->{filename} . ' not found');
			push @to_delete, $row->{filename};
		}
	}
	$query = 'DELETE FROM buffers WHERE filename=?';
	$sth = $self->db->prepare($query);
	foreach my $file (@to_delete){
		$sth->execute($file);
	}
	
	$query = 'SELECT pid FROM buffers WHERE filename=?';
	$sth = $self->db->prepare($query);
	$query = 'INSERT IGNORE INTO buffers (filename, pid) VALUES (?,?)';
	my $ins_sth = $self->db->prepare($query);
	$self->log->debug('files: ' . Dumper(\@files));
	foreach my $file (@files){
		$self->log->debug('considering file ' . $file);
		if (-z $file){
			$self->log->info('Deleting empty buffer ' . $file);
			unlink $file;
			next;
		}
		my $mtime = (stat $file)[9];
		next if ((CORE::time() - $mtime) < (2 * $self->conf->get('sphinx/index_interval') ) );
		$sth->execute($file);
		my $row = $sth->fetchrow_hashref;
		next if $row;
		eval {
			$ins_sth->execute($file, $$);
		};
		if ($@){
			my $e = $@;
			$self->log->warn('Unable to lock file ' . $file . ': ' . $e);
			next;
		}
		$self->log->debug('Found old file ' . $file . ' with mtime ' . scalar localtime($mtime));
	}
	$ins_sth->finish();
	
	$self->_validate_directory();
	
	$self->log->info('Loading ' . (scalar @files) . ' existing buffers...');
	$self->load_buffers();
	
	return 1;
}

sub _validate_directory {
	my $self = shift;
	my ($query, $sth);
	
	# DEFINITELY going to need a directory lock for this
	$self->_get_lock('directory');
	
	# Validate that all real tables are accounted for in the directory
	$query = 'INSERT INTO tables (table_name, start, end, min_id, max_id, table_type_id) VALUES (?,?,?,?,?,' .
		'(SELECT id FROM table_types WHERE table_type=?))';
	my $ins_tables_sth = $self->db->prepare($query);
	
	$query = "SELECT CONCAT(t1.table_schema, \".\", t1.table_name) AS real_table,\n" .
		"t2.table_name AS recorded_table\n" .
		"FROM INFORMATION_SCHEMA.TABLES t1\n" .
		"LEFT JOIN tables t2 ON (CONCAT(t1.table_schema, \".\", t1.table_name)=t2.table_name)\n" .
		"WHERE t1.table_schema=\"$Data_db_name\" HAVING ISNULL(recorded_table)";
	$sth = $self->db->prepare($query);
	$sth->execute();
	
	while (my $needed_row = $sth->fetchrow_hashref){
		my $full_table = $needed_row->{real_table};
		my $table_type = 'index';
		if ($full_table =~ /archive/){
			$table_type = 'archive';
		}
		$self->log->debug("Directory is missing table $full_table");
		
		my ($start, $end, $min, $max);
		if ($table_type eq 'index'){		
			# Find our start,end,min_id,max_id
			$query = sprintf("SELECT MIN(id) AS min_id, MAX(id) AS max_id FROM %s",
				$full_table);
			$sth = $self->db->prepare($query);
			$sth->execute();
			my $row = $sth->fetchrow_hashref;
			($min, $max) = ($row->{min_id}, $row->{max_id});
			$query = sprintf("SELECT FROM_UNIXTIME(timestamp) AS timestamp FROM %s WHERE id=?",
				$full_table);
			$sth = $self->db->prepare($query);
			$sth->execute($min);
			$row = $sth->fetchrow_hashref;
			$start = $row->{timestamp};
			$sth->execute($max);
			$row = $sth->fetchrow_hashref;
			$end = $row->{timestamp};
		}
		else { #archive
			$query = sprintf("SELECT MIN(id) AS min_id, MAX(id) AS max_id, " .
				"FROM_UNIXTIME(MIN(timestamp)) AS start, FROM_UNIXTIME(MAX(timestamp)) AS end FROM %s",
				$full_table);
			$sth = $self->db->prepare($query);
			$sth->execute();
			my $row = $sth->fetchrow_hashref;
			($min, $max, $start, $end) = ($row->{min_id}, $row->{max_id}, $row->{start}, $row->{end});
		}
		
		# Finally, insert into tables
		$self->log->debug("Adding $full_table with start $start, end $end, min $min, max $max");
		$ins_tables_sth->execute($full_table, $start, $end, $min, $max, $table_type);
	}
	$ins_tables_sth->finish();
	
	$query = 'DELETE FROM tables WHERE table_name=?';
	my $del_sth = $self->db->prepare($query);

	# Validate that all tables in the directory are real	
	#TODO We could probably do this in one big DELETE ... SELECT statement
	$query = "SELECT t1.table_name AS recorded_table,\n" .
		"CONCAT(t2.table_schema, \".\", t2.table_name) AS real_table\n" .
		"FROM tables t1\n" .
		"LEFT JOIN INFORMATION_SCHEMA.TABLES t2 ON (CONCAT(t2.table_schema, \".\", t2.table_name)=t1.table_name)\n" .
		"HAVING ISNULL(real_table)";
	$sth = $self->db->prepare($query);
	$sth->execute();
	while (my $row = $sth->fetchrow_hashref){
		$self->log->error("Found directory entry for non-existent table: " .
			$row->{recorded_table});
		$del_sth->execute($row->{recorded_table});
	}
	
	# Validate that no tables overlap
	$query = 'SELECT t1.id, t1.table_name, t1.min_id, t1.max_id, t2.min_id AS trim_to_max' . "\n" .
		'FROM tables t1, tables t2' . "\n" .
		'WHERE t1.table_type_id=(SELECT id FROM table_types WHERE table_type="index")' . "\n" .
		'AND t2.table_type_id=(SELECT id FROM table_types WHERE table_type="index")' . "\n" .
		'AND t1.table_name!=t2.table_name' . "\n" .
		'AND t1.max_id BETWEEN t2.min_id AND t2.max_id';
	$sth = $self->db->prepare($query);
	$sth->execute();
	while (my $row = $sth->fetchrow_hashref){
		$self->log->error('Found duplicate IDs from ' . $row->{trim_to_max} . ' to ' . $row->{max_id});
		
		# Delete the older of the duplicate ID's
		$query = sprintf('DELETE FROM %s WHERE id >= ?', $row->{table_name});
		my $sth = $self->db->prepare($query);
		$sth->execute($row->{trim_to_max});
		$sth->finish();
		
		# Update the directory
		$query = 'UPDATE tables SET max_id=? WHERE id=?';
		$sth = $self->db->prepare($query);
		$sth->execute(($row->{trim_to_max} - 1), $row->{id});
		$sth->finish();
	}
	
	# Validate that index tables still have an index pointing to them
	$query = 'SELECT table_name FROM v_directory WHERE table_type="index" AND ISNULL(id)';
	$sth = $self->db->prepare($query);
	$sth->execute();
	
	while (my $row = $sth->fetchrow_hashref){
		$self->log->error("Found index directory entry for unindexed table: " .
			$row->{table_name});
		$del_sth->execute($row->{table_name});
		$self->log->error('Dropping unindexed index table ' . $row->{table_name});
		$self->db->do('DROP TABLE ' . $row->{table_name});
	}
	
	$del_sth->finish();
	
	# Explicitly index the dummy index entries for non-existent indexes
	$query = 'SELECT id, type FROM indexes';
	$sth = $self->db->prepare($query);
	$sth->execute();
	my %existing;
	while (my $row = $sth->fetchrow_hashref){
		$existing{ $self->_get_index_name($row->{type}, $row->{id}) } = 1;
	}
	
	for (my $i = 1 ; $i <= $self->conf->get('num_indexes'); $i++){
		foreach my $type qw(temporary permanent){
			my $index_name = $self->_get_index_name($type, $i);
			unless ($existing{ $index_name }){
				$self->log->debug('Wiping via index ' . $index_name);
				$self->_sphinx_index( $index_name );
			}
		}
	}
	
	$self->log->trace('Finished wiping indexes');

	# Find tables which are not referred to by any index
	$query = 'SELECT t1.table_name AS full_table FROM tables t1 ' .
		'LEFT JOIN v_directory t2 ON (t1.id=t2.table_id) ' .
		'WHERE ISNULL(t2.table_id)';
	$sth = $self->db->prepare($query);
	$sth->execute();

	$query = 'DELETE FROM tables WHERE table_name=?';
	$del_sth = $self->db->prepare($query);
	while (my $row = $sth->fetchrow_hashref){
		$self->log->info('Dropping unindexed table ' . $row->{full_table});
		$self->db->do('DROP TABLE ' . $row->{full_table});
		$del_sth->execute($row->{full_table});
	}
	
	$self->_release_lock('directory');
			
	return 1;
}

sub _oversize_log_rotate {
	my $self = shift;
	
	my ($query, $sth);
	
	my $archive_size_limit = $self->conf->get('log_size_limit') * $self->conf->get('archive/percentage') * .01;
	while ($self->_get_current_archive_size() > $archive_size_limit){
		$self->_get_lock('directory');
		
		# Get our latest entry
		$query = "SELECT id, first_id, last_id, type, table_type, table_name FROM v_directory\n" .
			"WHERE table_type=\"archive\" AND ISNULL(locked_by)\n" .
			"ORDER BY start ASC LIMIT 1";
		$sth = $self->db->prepare($query);
		$sth->execute();
		my $entry = $sth->fetchrow_hashref;
		
		my $full_table = $entry->{table_name};
		$self->log->info("Dropping table $full_table");
		$query = sprintf("DROP TABLE %s", $full_table);
		$self->db->do($query);
		$query = 'DELETE FROM tables WHERE table_name=?';
		$sth = $self->db->prepare($query);
		$sth->execute($full_table);
		$self->_release_lock('directory');
	}
	
	# Drop indexed data
	while ($self->_get_current_index_size() > ($self->conf->get('log_size_limit') - $archive_size_limit)){
		$self->_get_lock('directory');
		
		# Get our latest entry
		$query = "SELECT id, first_id, last_id, type, table_type, table_name FROM v_directory\n" .
			"WHERE table_type=\"index\" AND ISNULL(locked_by)\n" .
			"ORDER BY start ASC LIMIT 1";
		$sth = $self->db->prepare($query);
		$sth->execute();
		my $entry = $sth->fetchrow_hashref;
		
		$self->log->debug("Dropping old entries because current log size larger than " 
			. ($self->conf->get('log_size_limit') - $archive_size_limit));
		unless ($entry){
			$self->log->error("no entries, current log size: " . $self->_get_current_index_size());
			#$self->db->rollback();
			$self->_release_lock('directory');
			last;
		}
		
		$query = 'UPDATE indexes SET locked_by=? WHERE id=? AND type=?';
		$sth = $self->db->prepare($query);
		$sth->execute($$, $entry->{id}, $entry->{type});
		$self->_release_lock('directory');
		
		$self->log->info("Dropping index " . $entry->{id});
		# _drop_indexes drops the table as necessary
		$self->_drop_indexes($entry->{type}, [$entry->{id}]);
	}
			
	return 1;
}

sub _overtime_log_rotate {
	my $self = shift;
	
	my ($query, $sth);
	
	# Drop archive tables older than given number of days
	if ($self->conf->get('archive/days')){
		$self->_get_lock('directory');
			
		# Get our latest entry
		$query = "SELECT table_name, start, end FROM tables WHERE start < DATE_SUB(NOW(), INTERVAL ? DAY) ORDER BY start ASC";
		$sth = $self->db->prepare($query);
		$sth->execute($self->conf->get('archive/days'));
		
		while (my $row = $sth->fetchrow_hashref){
			my $full_table = $row->{table_name};
			$self->log->info("Dropping table $full_table");
			$query = sprintf("DROP TABLE %s", $full_table);
			$self->db->do($query);
			$query = 'DELETE FROM tables WHERE table_name=?';
			my $del_sth = $self->db->prepare($query);
			$del_sth->execute($full_table);
		}
		$self->_release_lock('directory');
	}

	
	# Drop indexed data older than given number of days
	if ($self->conf->get('sphinx/days')){
		$self->_get_lock('directory');
			
		# Get our latest entry
		$query = "SELECT id, first_id, last_id, type, table_type, table_name FROM v_directory\n" .
			"WHERE table_type=\"index\" AND ISNULL(locked_by) AND start < DATE_SUB(NOW(), INTERVAL ? DAY)\n" .
			"ORDER BY start ASC";
		$sth = $self->db->prepare($query);
		$sth->execute($self->conf->get('sphinx/days'));
		
		while (my $row = $sth->fetchrow_hashref){
			$self->log->info("Dropping index " . $row->{id});
			
			$query = 'UPDATE indexes SET locked_by=? WHERE id=? AND type=?';
			my $upd_sth = $self->db->prepare($query);
			$upd_sth->execute($$, $row->{id}, $row->{type});
			
			# _drop_indexes drops the table as necessary
			$self->_drop_indexes($row->{type}, [$row->{id}]);
		}
		$self->_release_lock('directory');
	}
			
	return 1;
}

sub _check_consolidate {
	my $self = shift;
	my ($query, $sth);
	
	$self->_get_lock('directory');
	# Check to see if we're low on temporary indexes and need to consolidate
	if ($self->_over_num_index_limit()){
		$self->log->warn('Over the temp index limit, engaging emergency consolidation');
		
		# Find out how many temp indexes we've got
		$query = "SELECT MIN(first_id) AS min_id, MAX(last_id) AS max_id,\n" .
			"MIN(start) AS start, MAX(end) AS end\n" .
			"FROM indexes WHERE ISNULL(locked_by) AND type=\"temporary\"";
		$sth = $self->db->prepare($query);
		$sth->execute();
		my $row = $sth->fetchrow_hashref;
		my ($min_id, $max_id) = (0,0);
		if ($row){
			$self->log->trace('got row: ' . Dumper($row));
			$min_id = $row->{min_id};
			$max_id = $row->{max_id};
			
			# We need to run the aggregate indexing to create permanent indexes from temp indexes	
			# Recurse and index the greater swath of records.  This will mean there will be indexes replaced.
			$self->consolidate_indexes({ first_id => $min_id, last_id => $max_id });
		}
	}
	
	# Check to see if we need to consolidate any tables
	$self->db->begin_work;
	$query = 'SELECT table_name, type, SUM(locked_by) AS locked, COUNT(DISTINCT id) AS num_indexes, ' . "\n"
		. 'min_id, max_id, max_id-min_id AS num_rows ' . "\n"
		. 'FROM v_directory' . "\n"
		. 'WHERE ISNULL(table_locked_by) AND table_type="index"' . "\n"
		. 'GROUP BY table_name' . "\n"
		. 'HAVING ISNULL(locked) AND num_rows > ? AND (num_indexes > 1 OR type="realtime") FOR UPDATE';
	$sth = $self->db->prepare($query);
	$sth->execute($self->conf->get('sphinx/perm_index_size'));
	
	my @to_consolidate;
	while (my $row = $sth->fetchrow_hashref){
		next if $row->{min_id} >= $row->{max_id};
		# Lock the table
		$query = 'UPDATE tables SET table_locked_by=? WHERE table_name=?';
		my $upd_sth = $self->db->prepare($query);
		$upd_sth->execute($$, $row->{table_name});
		$self->log->debug('Locked table ' . $row->{table_name});
		$self->log->debug('Locked table ' . Dumper($row));
		push @to_consolidate, { first_id => $row->{min_id}, last_id => $row->{max_id} };
	}
	$self->db->commit;
	$self->_release_lock('directory');
	
	foreach my $row (@to_consolidate){
		$self->consolidate_indexes($row);
	}
}

sub load_buffers {
	my ($self) = @_;
	
	my ($query, $sth);
		
	$query = 'SELECT id, filename FROM buffers WHERE ISNULL(pid) ORDER BY id ASC';
	$sth = $self->db->prepare($query);
	$sth->execute();
	$query = 'UPDATE buffers SET pid=? WHERE id=?';
	
	my @rows;
	while (my $row = $sth->fetchrow_hashref){
		push @rows, $row;
		my $sth = $self->db->prepare($query);
		$sth->execute($$, $row->{id});
		$sth->finish();
	}
	
	my ($first_id, $last_id, $multiple_loads);
	foreach my $row (@rows){	
		# Send to index load records
		if ($self->conf->get('sphinx/perm_index_size')){
			my $batch_ids  = $self->load_records({ file => $row->{filename} });
			$first_id ||= $batch_ids->{first_id};
			$last_id = $batch_ids->{last_id};
			if (scalar @rows == 1){
				# Standard case, just do the indexing
				$self->index_records($batch_ids);
			}
			elsif ($batch_ids->{first_id} - $last_id > 1){
				# Non-consecutive, must do an index for this batch
				$self->log->debug('non-consecutive ids: ' . $batch_ids->{first_id} . ' and ' . $last_id);
				$self->index_records($batch_ids);
				$first_id = $batch_ids->{first_id};
			}
			else {
				# Consecutive, keep loading, we will index at the end
				$multiple_loads++;
			}
		}
		
		# Send to archive
		if ($self->conf->get('archive/percentage')){
			$self->archive_records({ file => $row->{filename} })
		}
	}
	
	if ($multiple_loads and $self->conf->get('sphinx/perm_index_size')){
		$self->log->trace('Loading multiple buffers between ' . $first_id . ' and ' . $last_id);
		$self->index_records({ first_id => $first_id, last_id => $last_id });
	}
	
	$self->rotate_logs();
	
	return {};
}

sub load_records {
	my $self = shift;
	my $args = shift;
	
	die 'Invalid args: ' . Dumper($args)
		unless $args and ref($args) eq 'HASH';
	die 'Invalid args: ' . Dumper($args)
		unless $args->{file} and -f $args->{file};
	
	my $load_only = 0;
	if ($args->{load_only}){
		$load_only = 1;
	}
	$self->log->debug("args: " . Dumper($args));
	
	$self->_get_lock('directory') or die 'Unable to obtain lock';
		
	# Create table
	my $full_table = $self->_create_table($args);
	my ($db, $table) = split(/\./, $full_table);
	
	my ($query, $sth);
	
	# Update the database to show that this child is working on it
	$query = 'UPDATE buffers SET pid=? WHERE filename=?';
	$sth = $self->db->prepare($query);
	$sth->execute($$, $args->{file});
	
	$query = 'UPDATE tables SET table_locked_by=? WHERE table_name=?';
	$sth = $self->db->prepare($query);
	$sth->execute($$, $full_table);
	
	$self->_release_lock('directory');
	
	my $load_start = time();
	# CONCURRRENT allows the table to be open for reading whilst the LOAD DATA occurs so that queries won't stack up
	$query = sprintf('LOAD DATA CONCURRENT LOCAL INFILE "%s" INTO TABLE %s', $args->{file}, $full_table);
	$sth = $self->db->prepare($query);
	$sth->execute();
	my $records = $sth->rows();
	my $load_time = time() - $load_start;
	my $rps = $records / $load_time;

	$query = sprintf("SELECT MAX(id) AS max_id FROM %s", $full_table);
	$sth = $self->db->prepare($query);
	$sth->execute() or die $self->db->errstr;
	my $row = $sth->fetchrow_hashref;
	my $last_id = $row->{max_id};
	my $first_id = $row->{max_id} - $records + 1;
	
#	$self->log->debug("Found max_id of $row->{max_id}, should have $args->{last_id}");
	$self->log->info("Loaded $records records in $load_time seconds ($rps per second)");
	
	# Find out what our min/max timestamps are by getting the records at min/max id
	$query = sprintf('SELECT timestamp FROM %s WHERE id=?', $full_table);
	$sth = $self->db->prepare($query);
	$sth->execute($first_id);
	$row = $sth->fetchrow_hashref;
	my $start = 0;
	if ($row){
		$start = $row->{timestamp};
	}
	else {
		die 'Unable to get a start timestamp from table ' . $full_table . ' with row id ' . $first_id;
	}
	$sth->execute($last_id);
	$row = $sth->fetchrow_hashref;
	my $end = 0;
	if ($row){
		$end = $row->{timestamp};
	}
	else {
		die 'Unable to get an end timestamp from table ' . $full_table . ' with row id ' . $first_id;
	}
	
	$self->_get_lock('directory') or die 'Unable to obtain lock';
	
	# Update the directory with our new buffer start (if it is earlier than what's already there)
	$query = 'SELECT UNIX_TIMESTAMP(start) AS start, UNIX_TIMESTAMP(end) AS end FROM tables WHERE table_name=?';
	$sth = $self->db->prepare($query);
	$sth->execute($full_table);
	$row = $sth->fetchrow_hashref;
	if ($row->{start} > $start){
		$query = 'UPDATE tables SET start=FROM_UNIXTIME(?) WHERE table_name=?';
		$sth = $self->db->prepare($query);
		$sth->execute($start, $full_table);
		$self->log->debug('Updated table to have start ' . $start);
	}
	if ($row->{end} < $end){
		$query = 'UPDATE tables SET end=FROM_UNIXTIME(?) WHERE table_name=?';
		$sth = $self->db->prepare($query);
		$sth->execute($end, $full_table);
		$self->log->debug('Updated table to have end ' . $end)
	}
	$query = 'UPDATE tables SET max_id=?, table_locked_by=NULL WHERE table_name=?';
	$sth = $self->db->prepare($query);
	$sth->execute($last_id, $full_table);
	
	$self->log->debug('Updated table to have end ' . $end . ', max_id ' . $last_id . ' table_name ' . $full_table);
	
	# Mark load complete
	$query = 'UPDATE buffers SET index_complete=1 WHERE filename=?';
	$sth = $self->db->prepare($query);
	$sth->execute($args->{file});
	
	# Record the load stats
	$query = 'REPLACE INTO stats (type, bytes, count, time) VALUES("load", ?,?,?)';
	$sth = $self->db->prepare($query);
	$sth->execute((-s $args->{file}), $records, $load_time);
	
	$self->_release_lock('directory');
	
	return { first_id => $first_id, last_id => $last_id };
}

sub archive_records {
	my $self = shift;
	my $args = shift;
	
	die 'Invalid args: ' . Dumper($args)
		unless $args and ref($args) eq 'HASH';
	die 'Invalid args: ' . Dumper($args)
		unless $args->{file} and $args->{file};
		
	$args->{archive} = 1;
	
	$self->log->trace("args: " . Dumper($args));
		
	# Create table
	my $full_table = $self->_create_table($args);
	my ($db, $table) = split(/\./, $full_table);
	
	my ($query, $sth);
	
	# Re-verify that this file still exists (some other process may have swiped it out from under us)
	unless (-f $args->{file}){
		$self->log->error('File ' . $args->{file} . ' does not exist, not loading.');
		return 0;
	}
	
	my $load_start = time();
	$query = sprintf('LOAD DATA CONCURRENT LOCAL INFILE "%s" INTO TABLE %s', $args->{file}, $full_table);
	$sth = $self->db->prepare($query);
	$sth->execute();
	my $records = $sth->rows();
	my $load_time = time() - $load_start;
	my $rps = $records / $load_time;

	$query = sprintf('SELECT id FROM %s LIMIT 1', $full_table);
	$sth = $self->db->prepare($query);
	$sth->execute();
	my $row = $sth->fetchrow_hashref;
	my $first_id = $self->conf->get('id') ? $Peer_id_multiplier * $self->conf->get('id') : 0;
	if ($row){
		$first_id = $row->{id};
	}
	
	$query = 'SELECT table_rows FROM INFORMATION_SCHEMA.tables WHERE table_schema=? AND table_name=?';
	$sth = $self->db->prepare($query);
	$sth->execute($db, $table);
	$row = $sth->fetchrow_hashref;
	my $last_id = $first_id;
	if ($row){
		$last_id = $first_id + $row->{table_rows};
	}

#	$self->log->debug("Found max_id of $row->{max_id}, should have $args->{last_id}");
	$self->log->info("Loaded $records records in $load_time seconds ($rps per second)");
	#TODO find an efficient but correct way of finding this out
	my $end = CORE::time();
	
	# Update the directory with our new buffer start (if it is earlier than what's already there)
	$query = 'UPDATE tables SET end=FROM_UNIXTIME(?), max_id=? WHERE table_name=?';
	$sth = $self->db->prepare($query);
	$sth->execute($end, $last_id, $full_table);
	
	$self->log->debug('Updated table to have end ' . $end . ', max_id ' . $last_id . ' table_name ' . $full_table);
	
	# Mark archiving complete
	$query = 'UPDATE buffers SET archive_complete=1 WHERE filename=?';
	$sth = $self->db->prepare($query);
	$sth->execute($args->{file});
	
	# Record the load stats
	$query = 'REPLACE INTO stats (type, bytes, count, time) VALUES("archive", ?,?,?)';
	$sth = $self->db->prepare($query);
	$sth->execute((-s $args->{file}), $records, $load_time);
	
	return { first_id => $first_id, last_id => $last_id };
}

sub _get_max_id {
	my $self = shift;
	my $type = shift;
	my ($query, $sth, $row);
	
	# Find db's current max id
	#$query = 'SELECT MAX(max_id) AS max_id FROM tables t1 JOIN table_types t2 on (t1.table_type_id=t2.id) WHERE table_type=?';
	$query = 'SELECT AUTO_INCREMENT AS max_id FROM INFORMATION_SCHEMA.TABLES ' .
		'WHERE CONCAT(table_schema, ".", table_name)=' . 
			'(SELECT table_name FROM v_directory WHERE table_type=? ORDER BY table_id DESC LIMIT 1)';
	$sth = $self->db->prepare($query);
	$sth->execute($type);
	$row = $sth->fetchrow_hashref;
	my $max_id = $row->{max_id};
	$max_id = 0 unless $max_id;
	
	# Validate this is with the correct range for this node
	my $min_id = $self->conf->get('id') ? $Peer_id_multiplier * $self->conf->get('id') : 0;
	unless ($max_id > $min_id){
		$self->log->warn('Found max_id of ' . $max_id . ' which was smaller than min_id of ' . $min_id . ', setting to ' . $min_id);
		$max_id = $min_id;
	}
	
	return $max_id;
}

sub _get_table {
	my $self = shift;
	my $args = shift;
	die 'Invalid args: ' . Dumper($args) unless $args and ref($args) eq 'HASH';
	
	my $table_type = 'index';
	if ($args->{archive}){
		$table_type = 'archive';
	}
	$args->{table_type} = $table_type;
	
	my ($query, $sth, $row);
	
	$query = 'SELECT CONCAT(table_schema, ".", table_name) AS table_name, AUTO_INCREMENT AS max_id, table_rows FROM INFORMATION_SCHEMA.TABLES ' .
		'WHERE CONCAT(table_schema, ".", table_name)=' . 
			'(SELECT table_name FROM v_directory WHERE table_type=? ORDER BY table_id DESC LIMIT 1)'; 
#	$query = 'SELECT table_name, min_id, max_id' . "\n" .
#		'FROM tables' . "\n" .
#		'WHERE table_type_id=(SELECT id FROM table_types WHERE table_type=?)' . "\n" .
#		"ORDER BY tables.id DESC LIMIT 1";
#	$query = sprintf('SELECT table_name, min_id, max_id, table_locked_by, locked_by' . "\n" .
#		'FROM %1$s.tables' . "\n" .
#		'LEFT JOIN %1$s.indexes ON (tables.table_locked_by=indexes.locked_by)' . "\n" .
#		'WHERE table_type_id=(SELECT id FROM %1$s.table_types WHERE table_type=?)' . "\n" .
#		"ORDER BY tables.id DESC LIMIT 1", $Meta_db_name);
	$sth = $self->db->prepare($query);
	$sth->execute($table_type) or die $self->db->errstr;
	$row = $sth->fetchrow_hashref;
	if ($row){
		# Is it time for a new index?
		my $size = $self->conf->get('sphinx/perm_index_size');
		if ($table_type eq 'archive'){
			$size = $self->conf->get('archive/table_size');
		}
		# See if the table is too big
		#if (($row->{max_id} - $row->{min_id}) >= $size){
		if ($row->{table_rows} >= $size){
			my $new_id = $row->{max_id} + 1;
			$self->log->debug("suggesting new table with id $new_id because row was: " . Dumper($row) . ' and size was ' . $row->{table_rows});
			$args->{table_name} = sprintf("%s.syslogs_%s_%d", $Data_db_name, $table_type, $new_id);
			return $args;
		}
		else {
			$self->log->debug("using current table $row->{table_name}");
			$args->{table_name} = $row->{table_name};
			return $args;
		}
	}
	else {
		# This is the first table
		$args->{table_name} = sprintf("%s.syslogs_%s_%d", $Data_db_name, $table_type, 1);
		return $args;
	}
}

sub _create_table {
	my $self = shift;
	my $args = shift;
	die 'Invalid args: ' . Dumper($args)
		unless $args and ref($args) eq 'HASH';
			
	my ($query, $sth, $row);
			
	my $needed = {};
	my $start_time = 0;
	my $end_time = 0;
	
	# See if the tables already exist
	$args = $self->_get_table($args);
	my $needed_table = $args->{table_name};
	
	my ($db, $table) = split(/\./, $needed_table);
	# Get list of current tables for our db
	$query = "SELECT table_name FROM INFORMATION_SCHEMA.tables WHERE table_schema=? AND table_name=?";
	$sth = $self->db->prepare($query);
	$sth->execute($db, $table);
	$row = $sth->fetchrow_hashref;
	if ($row){
		# We don't need to create a table
		$self->log->trace("Table $needed_table exists");
		return $needed_table;
	}
		
	$self->log->debug("Creating table $needed_table");
	
	# Find the max id currently in the directory and use that to determine the autoinc value
	my $current_max_id = $self->_get_max_id($args->{table_type});
	eval {
		$query = "INSERT INTO tables (table_name, start, end, min_id, max_id, table_type_id)\n" .
			"VALUES( ?, FROM_UNIXTIME(?), FROM_UNIXTIME(?), ?, ?, (SELECT id FROM table_types WHERE table_type=?) )";
		$sth = $self->db->prepare($query);
		$sth->execute( $needed_table, ($args->{start} ? $args->{start} : CORE::time()), ($args->{end} ? $args->{end} : CORE::time()), $current_max_id + 1, $current_max_id + 1, $args->{table_type});
		my $id = $self->db->{mysql_insertid};
		#$self->log->debug(sprintf("Created table id %d with start %s, end %s, first_id %lu, last_id %lu", 
		#	$id, _epoch2iso($args->{start}), _epoch2iso($args->{end}), $args->{first_id}, $args->{last_id} ));	
		
		$query = "CREATE TABLE IF NOT EXISTS $needed_table LIKE syslogs_template";
		$self->log->debug("Creating table: $query");
		$self->db->do($query);
		
		$query = sprintf('ALTER TABLE %s AUTO_INCREMENT=%lu', $needed_table, $current_max_id + 1);
		if ($args->{archive}){
			$query .= ' ENGINE=ARCHIVE';
		}
		$self->db->do($query);
	};
	if ($@){
		my $e = $@;
		if ($e =~ /Duplicate entry/){
			# This is fine
			return $needed_table;
		}
		else {
			die($e); # whatever it is, it's not cool
		}
		
	}
	return $needed_table;
}

sub consolidate_indexes {
	my $self = shift;
	my $args = shift;
	die 'Invalid args: ' . Dumper($args)
		unless $args and ref($args) eq 'HASH';
		
	my ($query, $sth, $row);
	
	my ($first_id, $last_id, $table);
	
	$self->_get_lock('directory') or die 'Unable to obtain lock';
	
	$self->log->debug("Consolidating indexes with args " . Dumper($args));
	if ($args->{table}){
		$table = $args->{table};
		$self->log->debug('Consolidating table ' . $table);
		$query = 'SELECT min_id, max_id FROM tables WHERE table_name=?';
		$sth = $self->db->prepare($query);
		$sth->execute($table);
		$row = $sth->fetchrow_hashref;
		if ($row){
			$self->log->debug('Consolidating indexes from ' . $row->{min_id} . ' to ' . $row->{max_id});
			$first_id = $row->{min_id};
			$last_id = $row->{max_id};	
		}
		else {
			$self->_release_lock('directory');
			die 'Unable to find rows to index for table ' . $args->{table};
		}
	}
	elsif ($args->{first_id} and $args->{last_id}){
		$self->log->debug('Consolidating indexes from ' . $args->{first_id} . ' to ' . $args->{last_id});
		$first_id = $args->{first_id};
		$last_id = $args->{last_id};	
	}
	else {
		$self->_release_lock('directory');
		die 'Invalid args: ' . Dumper($args);
	}
	
	$query = 'SELECT COUNT(*) AS count FROM v_directory ' . "\n" .
			'WHERE table_type="index" AND min_id >= ? AND max_id <= ? and type!="realtime"';
	$sth = $self->db->prepare($query);
	$sth->execute($first_id, $last_id);
	$row = $sth->fetchrow_hashref;
	if ($row->{count} == 1){
		$self->log->warn('Attempting to consolidate table that is already being consolidated');
		$self->_release_lock('directory');
		return 0;
	}
	
	$query = 'SELECT table_name, table_locked_by FROM v_directory ' . "\n" .
			#'WHERE table_type="index" AND min_id >= ? AND max_id <= ?';
			'WHERE table_type="index" AND (? BETWEEN min_id AND max_id OR ? BETWEEN min_id AND max_id)';
	$sth = $self->db->prepare($query);
	$sth->execute($first_id, $last_id);
	$row = $sth->fetchrow_hashref;
	unless ($row){
		$self->log->warn('Rows not found');
		$self->_release_lock('directory');
		return 0;
	}
	$table = $row->{table_name};
	
	$self->_release_lock('directory');
	
	# Do the indexing
	my $replaced = $self->index_records({first_id => $first_id, last_id => $last_id});
	
#	$self->_get_lock('directory') or die 'Unable to obtain lock';
#	
#	# Unlock the table we're consolidating
#	$query = 'UPDATE tables SET table_locked_by=NULL WHERE table_name=?';
#	$sth = $self->db->prepare($query);
#	$sth->execute($table);
#	$self->log->debug('Unlocked table ' . $table);
#	
#	$self->_release_lock('directory');
		
	# Validate our directory after this to be sure there's nothing left astray
	$self->_validate_directory();
}

sub _get_lock {
	my $self = shift;
	my $lock_name = shift;
	my $lock_timeout = shift;
	$lock_timeout ||= 120;
	
	my $ok;
	my $lockfile = $self->conf->get('lockfile_dir') . '/' . $lock_name;
	eval {
		open($self->locks->{$lock_name}, $lockfile) or die('Unable to open ' . $lockfile . ': ' . $!);
		$ok = flock($self->locks->{$lock_name}, LOCK_EX);
	};
	if ($@){
		$self->log->error('locking error: ' . $@);
	}
	unless ($ok){
		return 0;
	}
	$self->log->trace('Locked ' . $lock_name);
	return 1;
}

sub _release_lock {
	my $self = shift;
	my $lock_name = shift;
	
	my $ok;
	my $lockfile = $self->conf->get('lockfile_dir') . '/' . $lock_name;
	eval {
		open($self->locks->{$lock_name}, $lockfile) or die('Unable to open ' . $lockfile . ': ' . $!);
		$ok = flock($self->locks->{$lock_name}, LOCK_UN);
		close($self->locks->{$lock_name});
	};
	if ($@){
		$self->log->error('locking error: ' . $@);
	}
	unless ($ok){
		die 'Unable to release lock';
	}
	$self->log->trace('Unlocked ' . $lock_name);
	return 1;
}

sub index_records {
	my $self = shift;
	my $args = shift;
	die 'Invalid args: ' . Dumper($args)
		unless $args and ref($args) eq 'HASH';
	die 'Invalid args: ' . Dumper($args)
		unless $args->{first_id};
	die 'Invalid args: ' . Dumper($args)
		unless $args->{last_id};
		
	$self->log->debug("Indexing with args " . Dumper($args));
	
	my ($query, $sth, $row);
	
	$self->_get_lock('directory') or die 'Unable to obtain lock';
	
	# Verify these records are unlocked
	$query = "SELECT locked_by\n" .
		"FROM v_directory\n" .
		"WHERE table_type=\"index\" AND (? BETWEEN first_id AND last_id\n" .
		"OR ? BETWEEN first_id AND last_id\n" .
		"OR (first_id > ? AND last_id < ?))\n" .
		"ORDER BY id ASC";
	$sth = $self->db->prepare($query);
	$sth->execute($args->{first_id}, $args->{last_id}, $args->{first_id}, $args->{last_id});
	while ($row = $sth->fetchrow_hashref){
		if ($row->{locked_by} and $row->{locked_by} != $$){
			$self->_release_lock('directory');
			die 'Cannot do this indexing because index or table is locked: ' . Dumper($row);
		}
	}
	
	# Check to see if this will replace any smaller indexes (this happens during index consolidation)
	$query = "SELECT id, first_id, last_id, start, end, type FROM v_directory\n" .
		"WHERE first_id >= ? and last_id <= ?";
	$sth = $self->db->prepare($query);
	$sth->execute($args->{first_id}, $args->{last_id});
	my %replaced;
	while (my $row = $sth->fetchrow_hashref){
		unless ($replaced{ $row->{type} }){
			$replaced{ $row->{type} } = {};
		}
		$replaced{ $row->{type} }->{ $row->{id} } = 1;
		$self->log->debug("Replacing " . $row->{type} . " index " . $row->{id});
	}
	
	# Check to see if ram limitations dictate that these should be small permanent tables since they consume no ram
	my $index_type = 'temporary';
	if ($self->_over_mem_limit()){
		$self->log->warn('Resources overlimit, using permanent index for this emergency');
		$index_type = 'permanent';
	}
	elsif (scalar keys %replaced or ($args->{last_id} - $args->{first_id}) > $self->conf->get('sphinx/perm_index_size')){
		$self->log->debug('Size dictates permanent index');
		$index_type = 'permanent';
	}
	
	my $next_index_id = $self->_get_next_index_id($index_type);
	
	# Lock these indexes to make sure a different process does not try to replace them
	$query = "UPDATE indexes SET locked_by=?\n" .
		"WHERE first_id >= ? and last_id <= ? AND ISNULL(locked_by)";
	$sth = $self->db->prepare($query);
	$sth->execute($$, $args->{first_id}, $args->{last_id});
	$self->log->trace('Locked indexes between ' . $args->{first_id} . ' and ' . $args->{last_id});
	
	# Find the table(s) we'll be indexing
	my $table;
	$query = "SELECT DISTINCT table_id AS id, table_name, IF(min_id < ?, ?, min_id) AS min_id,\n" .
		"IF(max_id > ?, ?, max_id) AS max_id\n" .
		"FROM v_directory\n" .
		"WHERE table_type=\"index\" AND (? BETWEEN min_id AND max_id\n" .
		"OR ? BETWEEN min_id AND max_id\n" .
		"OR (min_id > ? AND max_id < ?))\n" .
		"ORDER BY id ASC";
	$sth = $self->db->prepare($query);
	$sth->execute($args->{first_id}, $args->{first_id},
	 	$args->{last_id},$args->{last_id},
		$args->{first_id}, 
		$args->{last_id}, 
		$args->{first_id}, $args->{last_id});
	my @tables_needed;
	while ($row = $sth->fetchrow_hashref){
		push @tables_needed, $row;
	}
	$self->log->trace("Tables needed: " . Dumper(\@tables_needed));
	
	# There should be exactly one table
	if (scalar @tables_needed > 1){		
		# Recursively do each table in a separate run
		foreach my $row (@tables_needed){
			$self->index_records({ first_id => $row->{min_id}, last_id => $row->{max_id} });
		}
		
		return 1;
	}
	elsif (scalar @tables_needed == 1) {
		$table = $tables_needed[0]->{table_name};
		$self->log->debug("Indexing rows from table $table");
	}
	else {
		$query = 'UPDATE indexes SET locked_by=NULL WHERE locked_by=?';
		$sth = $self->db->prepare($query);
		$sth->execute($$);
		
		$query = 'SELECT * FROM tables';
		$sth = $self->db->prepare($query);
		$sth->execute();
		my $tmp_hash = $sth->fetchall_hashref('id');
		$self->_release_lock('directory');
		die "No tables found for first_id $args->{first_id} and last_id $args->{last_id}" .
		 ", tables in database: " . Dumper($tmp_hash);
	}
	
	my ($count, $start, $end);
	$count = ($args->{last_id} - $args->{first_id});
	# This will be much faster than finding the timestamps above since timestamp is not indexed
	$query = sprintf("SELECT timestamp FROM %s WHERE id=?", $table);
	$sth = $self->db->prepare($query);
	$sth->execute($args->{first_id});
	$row = $sth->fetchrow_hashref;
	$start = $row->{timestamp};
	$sth->execute($args->{last_id});
	$row = $sth->fetchrow_hashref;
	$end = $row->{timestamp};
	
	$self->log->debug("Data table info: $count, $start, $end");
	#unless ($count > 0){
	unless ($args->{last_id} >= $args->{first_id}){
		$self->_release_lock('directory');
		
		die "Unable to find rows we're about to index, only got $count rows " .
			"from table $table " .
			"with ids $args->{first_id} and $args->{last_id} a difference of " . ($args->{last_id} - $args->{first_id});
	}
	
	# Update the index table
	$query = "REPLACE INTO indexes (id, start, end, first_id, last_id, table_id, type, locked_by)\n" .
		"VALUES(?, ?, ?, ?, ?, (SELECT id FROM tables WHERE table_name=?), ?, ?)";
	$sth = $self->db->prepare($query);
	$sth->execute($next_index_id, $start, $end, $args->{first_id}, $args->{last_id}, 
		$table, $index_type, $$);
	$self->_release_lock('directory');
	
	$self->log->debug("Inserted into indexes: " . join(", ", $next_index_id, $start, $end, $args->{first_id}, $args->{last_id}, $table, $index_type, $$));
			
	# Now actually perform the indexing
	my $start_time = time();
	
	my $index_name = $self->_get_index_name($index_type, $next_index_id);
	
	my $stats = $self->_sphinx_index($index_name);

	# Delete the replaced indexes
	foreach my $type (keys %replaced){
		$self->log->debug("Dropping indexes " . join(", ", sort keys %{ $replaced{$type} }));
		$self->_drop_indexes($type, [ sort keys %{ $replaced{$type} } ]);
	}
	
	$self->_get_lock('directory') or die 'Unable to obtain lock';
		
	# Unlock the indexes we were working on
	$query = 'UPDATE indexes SET locked_by=NULL WHERE locked_by=?';
	$sth = $self->db->prepare($query);
	$sth->execute($$);
	$self->log->trace('Unlocked indexes between ' . $args->{first_id} . ' and ' . $args->{last_id});
	
	# Update the stats table
	if ($stats and ref($stats) and ref($stats) eq 'HASH'){
		$query = 'REPLACE INTO stats (type, bytes, count, time) VALUES ("index", ?,?,?)';
		$sth = $self->db->prepare($query);
		$sth->execute($stats->{bytes}, $stats->{docs}, (time() - $start_time));
	}
	
	$self->_release_lock('directory');
	
	return \%replaced;
}

sub _over_num_index_limit {
	my $self = shift;
	my ($query, $sth);
	# Find the percentage of indexes that are temporary
	$query = 'SELECT COUNT(*) AS count FROM indexes WHERE type="temporary" and ISNULL(locked_by)';
	$sth = $self->db->prepare($query);
	$sth->execute();
	my $row = $sth->fetchrow_hashref;
	my $num_temps = 0;
	if ($row){
		$num_temps = $row->{count};
	}
	my $percent_temp = int($num_temps / $self->conf->get('num_indexes') * 100);
	if ($percent_temp > $self->conf->get('sphinx/allowed_temp_percent') ){
		 $self->log->warn('percent of temporary indexes is ' . $percent_temp . ' which is greater than '
			. $self->conf->get('sphinx/allowed_temp_percent'));
		return 1;
	}
	return 0;
}

sub _over_mem_limit {
	my $self = shift;
	
	my ($query, $sth);
	
	# Find out how much memory we've got in comparison with how much Sphinx is using
	#my $total_used = $self->_get_mem_used_by_sphinx();
	my $total_mem = totalmem() + totalswap();
	my $total_free = freemem() + freeswap();
	
	my $index_sizes = $self->_get_sphinx_index_sizes();
	$query = "SELECT id, type\n" .
		"FROM indexes WHERE ISNULL(locked_by) AND type=\"temporary\"\n";
	$sth = $self->db->prepare($query);
	$sth->execute();
	my $total_temp_size = 0;
	while (my $row = $sth->fetchrow_hashref){
		my $index_name = $self->_get_index_name($row->{type}, $row->{id});
		$total_temp_size += $index_sizes->{$index_name};
	}
			
	# Check if we're over anything
	if ( (($total_temp_size / $total_mem) * 100) > $self->conf->get('sphinx/allowed_mem_percent')){
		$self->log->warn('Total mem used: ' . $total_temp_size . ' of ' . $total_mem 
			. ', which is greater than ' . $self->conf->get('sphinx/allowed_mem_percent') . ' allowed percent');
		return 1;
	}
	elsif ($total_free < CRITICAL_LOW_MEMORY_LIMIT){
		$self->log->warn('system only has ' . $total_free . ' memory available');
		return 1;
	}
	
	return 0;
}

sub _get_sphinx_index_sizes {
	my $self = shift;
	# Find the size of all .spa (attributes) and .spi (dictionary) files
	opendir(DIR, $self->conf->get('sphinx/index_path'));
	my $sizes = {};
	while (my $file = readdir(DIR)){
		if ($file =~ /\.sp(a|i)$/){
			my @stat = stat($self->conf->get('sphinx/index_path') . '/' . $file);
			my @tokens = split(/\./, $file);
			my $prefix = $tokens[0];
			$sizes->{$prefix} += $stat[7];
		}
	}
	return $sizes;
}

sub _sphinx_index {
	my $self = shift;
	my $index_name = shift;
	
	my $start_time = time();
	my $cmd = sprintf("%s --config %s --rotate %s 2>&1", 
		$self->conf->get('sphinx/indexer'), $self->conf->get('sphinx/config_file'), $index_name);
	my @output = qx/$cmd/;
	$self->log->debug('output: ' . join('', @output));
	my $collected = 0;
	my $bytes = 0;
	my $retries = 0;
	$self->log->trace('ran cmd: ' . $cmd);
	TRY_LOOP: while (!$collected){
		LINE_LOOP: foreach (@output){
			chomp;
			#if (/collected\s+(\d+)\s+docs/){ # in sphinx 0.9.9
			if (/^total (\d+) docs, (\d+) bytes$/){
				$collected = $1;
				$bytes = $2;
				last TRY_LOOP;
			}
			elsif (/FATAL: failed to lock/){
				$self->log->warn("Indexing error: $_, retrying in $Index_retry_time seconds");
				sleep $Index_retry_time;
				@output = qx/$cmd/;
				last LINE_LOOP;
			}
		}
		$retries++;
		if ($retries > $Index_retry_limit){
			$self->log->error("Hit retry limit of $Index_retry_limit");
			last TRY_LOOP;
		}
	}
	
	my $index_time = (time() - $start_time);
	unless ($collected){
		$self->log->error("Indexing didn't work for $index_name, output: " . Dumper(\@output));
	}
	
	$self->log->info(sprintf("Indexed %s with %d rows in %.5f seconds (%.5f rows/sec)", 
		$index_name, $collected, $index_time, $collected / (time() - $start_time), #Nah, this will never be zero, right?
	));
	return {
		docs => $collected,
		bytes => $bytes,
	};
}

sub _drop_indexes {
	my $self = shift;
	my $type = shift;
	my $ids = shift;
	
	die 'Invalid args: ' . Dumper($ids)
		unless $ids and ref($ids) eq 'ARRAY';
		
	my ($query, $sth);
	
	$self->_get_lock('directory') or die 'Unable to obtain lock';
	
	# Delete from database
	foreach my $id (@$ids){
		$self->log->debug("Deleting index $id from DB");
		
		$query = 'SELECT first_id, last_id, table_name FROM v_directory WHERE id=? AND type=?';
		$sth = $self->db->prepare($query);
		$sth->execute($id, $type);
		#$self->log->trace('executed');
		my $row = $sth->fetchrow_hashref;
		if ($row){
			my $full_table = $row->{table_name};
			$query = 'DELETE FROM indexes WHERE id=? AND locked_by=? AND type=?';
			$sth = $self->db->prepare($query);
			$sth->execute($id, $$, $type);
			#$self->log->trace('executed id ' . $id);
			unless ($sth->rows){
				$self->log->warn('id ' . $id . ' was not found or locked by a different pid');
				next;
			}
			
			# Drop the table if necessary.  This query returns nothing if no indexes refer to a given table.
			$self->log->debug("Checking if we need to drop $full_table");
			$query = 'SELECT * FROM v_directory WHERE table_name=? AND NOT ISNULL(id)';
			$sth = $self->db->prepare($query);
			$sth->execute($full_table);
			#$self->log->trace('executed full_table ' . $full_table);
			$row = $sth->fetchrow_hashref;
			if ($row){
				$self->log->debug('At least one entry still exists for table '. $full_table . ': ' . Dumper($row));
			}
			else {
				$self->log->info("Dropping table $full_table");
				$query = sprintf("DROP TABLE %s", $full_table);
				$self->db->do($query);
				$query = 'DELETE FROM tables WHERE table_name=?';
				$sth = $self->db->prepare($query);
				$sth->execute($full_table);
			}
		}
		else {
			$self->log->error("Unknown index $id");
		}
		
		$self->log->trace('committed');
		
		my $index_name = $self->_get_index_name($type, $id);
		if ($type eq 'realtime'){
			my $sphinx_dbh = DBI->connect('dbi:mysql:host=' . $self->conf->get('sphinx/host') . ';port=' . $self->conf->get('sphinx/mysql_port'), 
				undef, undef, 
				{
					RaiseError => 1, 
					mysql_auto_reconnect => 1,
					mysql_multi_statements => 1,
					mysql_bind_type_guessing => 1,
				}
			) or die 'sphinx connection failed ' . $! . ' ' . $DBI::errstr;
			$sphinx_dbh->do('TRUNCATE RTINDEX ' . $index_name);
		}
		else {
			$self->_sphinx_index($index_name);
		}
		$self->log->info('Dropped index id ' . $id . ' with name ' . $index_name);
	}
	
	$self->log->trace('about to release lock on directory');
	$self->_release_lock('directory');
		
	$self->log->debug("Finished deleting files");
		
	return 1; 
}

sub get_sphinx_conf {
	my $self = shift;
#	my $template = shift;
#	open(FH, $template) or die 'Error opening template: ' . $!;
#	my @lines;
#	while (<FH>){
#		chomp;
#		push @lines, $_;
#	}
#	close(FH);

	my $template_base = <<EOT
indexer {
        mem_limit = 256M
        write_buffer = 100M
}
searchd {
		listen_backlog = 1000
        client_timeout = 300000
        log = %1\$s/searchd.log
        max_children = 128
        max_filter_values = 4096
        max_filters = 256
        max_matches = 1000
        max_packet_size = 8M
        max_batch_queries = 1000
        subtree_docs_cache = 8M
        subtree_hits_cache = 16M
        pid_file = %7\$s
        preopen_indexes = 0
        query_log = %1\$s/query.log
        read_timeout = 5
        seamless_rotate = 1
        unlink_old = 1
        listen = 0.0.0.0:%8\$s:mysql41
        listen = 0.0.0.0:%9\$s
        expansion_limit = 10
        workers = threads
}
source permanent {
        sql_attr_timestamp = timestamp
        sql_attr_uint = minute
        sql_attr_uint = hour
        sql_attr_uint = day
        sql_attr_uint = host_id
        sql_attr_uint = program_id
        sql_attr_uint = class_id
        sql_attr_uint = attr_i0
        sql_attr_uint = attr_i1
        sql_attr_uint = attr_i2
        sql_attr_uint = attr_i3
        sql_attr_uint = attr_i4
        sql_attr_uint = attr_i5
        sql_attr_uint = attr_s0
        sql_attr_uint = attr_s1
        sql_attr_uint = attr_s2
        sql_attr_uint = attr_s3
        sql_attr_uint = attr_s4
        sql_attr_uint = attr_s5
        sql_db = %4\$s
        sql_user = %5\$s
        sql_host = localhost
        sql_pass = %6\$s
        sql_range_step = 10000
        sql_query = SELECT id, timestamp, CAST(TRUNCATE(timestamp/86400, 0) AS unsigned) AS day, CAST(TRUNCATE(timestamp/3600, 0) AS unsigned) AS hour, CAST(TRUNCATE(timestamp/60, 0) AS unsigned) AS minute, host_id, host_id AS host, program_id, class_id, msg, s0, s1, s2, s3, s4, s5, i0 AS attr_i0, i1 AS attr_i1, i2 AS attr_i2, i3 AS attr_i3, i4 AS attr_i4, i5 AS attr_i5 FROM syslog.init
        type = mysql
}
index permanent {
        charset_table = 0..9, A..Z->a..z, _, a..z, U+A8->U+B8, U+B8, U+C0..U+DF->U+E0..U+FF, U+E0..U+FF, U+2E, U+40, U+2D
        docinfo = inline
        ondisk_dict = 1
        min_stemming_len = 7
        mlock = 0
        path = %2\$s/permanent
        source = permanent
        stopwords = %3\$s
}

source temporary {
        sql_attr_timestamp = timestamp
        sql_attr_uint = minute
        sql_attr_uint = hour
        sql_attr_uint = day
        sql_attr_uint = host_id
        sql_attr_uint = program_id
        sql_attr_uint = class_id
        sql_attr_uint = attr_i0
        sql_attr_uint = attr_i1
        sql_attr_uint = attr_i2
        sql_attr_uint = attr_i3
        sql_attr_uint = attr_i4
        sql_attr_uint = attr_i5
        sql_attr_uint = attr_s0
        sql_attr_uint = attr_s1
        sql_attr_uint = attr_s2
        sql_attr_uint = attr_s3
        sql_attr_uint = attr_s4
        sql_attr_uint = attr_s5
        sql_db = %4\$s
        sql_user = %5\$s
        sql_host = localhost
        sql_pass = %6\$s
        sql_range_step = 100000
        sql_query = SELECT id, timestamp, CAST(TRUNCATE(timestamp/86400, 0) AS unsigned) AS day, CAST(TRUNCATE(timestamp/3600, 0) AS unsigned) AS hour, CAST(TRUNCATE(timestamp/60, 0) AS unsigned) AS minute, host_id, host_id AS host, program_id, class_id, msg, s0, s1, s2, s3, s4, s5, i0 AS attr_i0, i1 AS attr_i1, i2 AS attr_i2, i3 AS attr_i3, i4 AS attr_i4, i5 AS attr_i5 FROM syslog.init
        type = mysql
}
index temporary {
        charset_table = 0..9, A..Z->a..z, _, a..z, U+A8->U+B8, U+B8, U+C0..U+DF->U+E0..U+FF, U+E0..U+FF, U+2E, U+40, U+2D
        docinfo = extern
        ondisk_dict = 0
        min_stemming_len = 7
        mlock = 0
        path = %2\$s/temporary
        source = temporary
        stopwords = %3\$s
}

index real_1 {
		type = rt
		charset_table = 0..9, A..Z->a..z, _, a..z, U+A8->U+B8, U+B8, U+C0..U+DF->U+E0..U+FF, U+E0..U+FF, U+2E, U+40, U+2D
        dict = keywords
        enable_star = 1
        path = %2\$s/real_1
        stopwords = %3\$s
        rt_field = host
        rt_field = msg
        rt_field = s0
        rt_field = s1
        rt_field = s2
        rt_field = s3
        rt_field = s4
        rt_field = s5
        rt_attr_timestamp = timestamp
        rt_attr_uint = minute
        rt_attr_uint = hour
        rt_attr_uint = day
        rt_attr_uint = host_id
        rt_attr_uint = program_id
        rt_attr_uint = class_id
        rt_attr_uint = attr_i0
        rt_attr_uint = attr_i1
        rt_attr_uint = attr_i2
        rt_attr_uint = attr_i3
        rt_attr_uint = attr_i4
        rt_attr_uint = attr_i5
        rt_attr_uint = attr_s0
        rt_attr_uint = attr_s1
        rt_attr_uint = attr_s2
        rt_attr_uint = attr_s3
        rt_attr_uint = attr_s4
        rt_attr_uint = attr_s5
}

index real_2 {
		type = rt
		charset_table = 0..9, A..Z->a..z, _, a..z, U+A8->U+B8, U+B8, U+C0..U+DF->U+E0..U+FF, U+E0..U+FF, U+2E, U+40, U+2D
        dict = keywords
        enable_star = 1
        path = %2\$s/real_2
        stopwords = %3\$s
        rt_field = host
        rt_field = msg
        rt_field = s0
        rt_field = s1
        rt_field = s2
        rt_field = s3
        rt_field = s4
        rt_field = s5
        rt_attr_timestamp = timestamp
        rt_attr_uint = minute
        rt_attr_uint = hour
        rt_attr_uint = day
        rt_attr_uint = host_id
        rt_attr_uint = program_id
        rt_attr_uint = class_id
        rt_attr_uint = attr_i0
        rt_attr_uint = attr_i1
        rt_attr_uint = attr_i2
        rt_attr_uint = attr_i3
        rt_attr_uint = attr_i4
        rt_attr_uint = attr_i5
        rt_attr_uint = attr_s0
        rt_attr_uint = attr_s1
        rt_attr_uint = attr_s2
        rt_attr_uint = attr_s3
        rt_attr_uint = attr_s4
        rt_attr_uint = attr_s5
}
	
EOT
;

	my $template = sprintf($template_base, $self->conf->get('logdir'), $self->conf->get('sphinx/index_path'), 
		$self->conf->get('sphinx/stopwords_file'), $self->conf->get('database/db'), 
		$self->conf->get('database/username'), $self->conf->get('database/password'), 
		$self->conf->get('sphinx/pid_file'), 
		$self->conf->get('sphinx/mysql_port') ? $self->conf->get('sphinx/mysql_port') : 9306,
		$self->conf->get('sphinx/port') ? $self->conf->get('sphinx/port') : 9312);

	
	my $perm_template = <<EOT
source perm_%1\$d : permanent {
        sql_query_pre = SELECT table_name INTO \@src_table FROM v_directory WHERE id=%1\$d AND type="permanent"
        sql_query_pre = SELECT IF(NOT ISNULL(\@src_table), \@src_table, "init") INTO \@src_table FROM dual
        sql_query_pre = SELECT IF((SELECT first_id FROM v_directory WHERE id=%1\$d AND type="permanent"), (SELECT first_id FROM v_directory WHERE id=%1\$d AND type="permanent"), 1), IF((SELECT last_id FROM v_directory WHERE id=%1\$d AND type="permanent"), (SELECT last_id FROM v_directory WHERE id=%1\$d AND type="permanent"), 1) INTO \@first_id, \@last_id FROM dual
        sql_query_pre = SET \@sql = CONCAT("SELECT id, timestamp, CAST(TRUNCATE(timestamp/86400, 0) AS unsigned) AS day, CAST(TRUNCATE(timestamp/3600, 0) AS unsigned) AS hour, CAST(TRUNCATE(timestamp/60, 0) AS unsigned) AS minute, host_id, host_id AS host, program_id, class_id, msg, s0, s1, s2, s3, s4, s5, i0 AS attr_i0, i1 AS attr_i1, i2 AS attr_i2, i3 AS attr_i3, i4 AS attr_i4, i5 AS attr_i5, CRC32(s0) AS attr_s0, CRC32(s1) AS attr_s1, CRC32(s2) AS attr_s2, CRC32(s3) AS attr_s3, CRC32(s4) AS attr_s4, CRC32(s5) AS attr_s5 FROM ", \@src_table, " WHERE id >= ", \@first_id, " AND id <= ", \@last_id)
        sql_query_pre = PREPARE stmt FROM \@sql
        sql_query = EXECUTE stmt 
}
index perm_%1\$d : permanent {
        path = %2\$s/perm_%1\$d
        source = perm_%1\$d
}
EOT
;

	my $temp_template = <<EOT
source temp_%1\$d : temporary {
        sql_query_pre = SELECT table_name INTO \@src_table FROM v_directory WHERE id=%1\$d AND type="temporary"
        sql_query_pre = SELECT IF(NOT ISNULL(\@src_table), \@src_table, "init") INTO \@src_table FROM dual
        sql_query_pre = SELECT IF((SELECT first_id FROM v_directory WHERE id=%1\$d AND type="temporary"), (SELECT first_id FROM v_directory WHERE id=%1\$d AND type="temporary"), 1), IF((SELECT last_id FROM v_directory WHERE id=%1\$d AND type="temporary"), (SELECT last_id FROM v_directory WHERE id=%1\$d AND type="temporary"), 1) INTO \@first_id, \@last_id FROM dual
        sql_query_pre = SET \@sql = CONCAT("SELECT id, timestamp, CAST(TRUNCATE(timestamp/86400, 0) AS unsigned) AS day, CAST(TRUNCATE(timestamp/3600, 0) AS unsigned) AS hour, CAST(TRUNCATE(timestamp/60, 0) AS unsigned) AS minute, host_id, host_id AS host, program_id, class_id, msg, s0, s1, s2, s3, s4, s5, i0 AS attr_i0, i1 AS attr_i1, i2 AS attr_i2, i3 AS attr_i3, i4 AS attr_i4, i5 AS attr_i5, CRC32(s0) AS attr_s0, CRC32(s1) AS attr_s1, CRC32(s2) AS attr_s2, CRC32(s3) AS attr_s3, CRC32(s4) AS attr_s4, CRC32(s5) AS attr_s5 FROM ", \@src_table, " WHERE id >= ", \@first_id, " AND id <= ", \@last_id)
        sql_query_pre = PREPARE stmt FROM \@sql
        sql_query = EXECUTE stmt 
}
index temp_%1\$d : temporary {
        path =  %2\$s/temp_%1\$d
        source = temp_%1\$d
}
EOT
;

	for (my $i = 1; $i <= $self->conf->get('num_indexes'); $i++){
		$template .= sprintf($perm_template, $i, $self->conf->get('sphinx/index_path')) . "\n";
		$template .= sprintf($temp_template, $i, $self->conf->get('sphinx/index_path')) . "\n";
	}
	
	# Split all indexes into four evenly distributed groups
	my @index_groups;
	for (my $i = 1; $i <= 2; $i++){
		unshift @{ $index_groups[ $i % $self->cpu_count ] }, 
			$self->_get_index_name('realtime', $i);
	}
	for (my $i = 1; $i <= $self->conf->get('num_indexes'); $i++){
		unshift @{ $index_groups[ $i % $self->cpu_count ] }, 
			$self->_get_index_name('temporary', $i), $self->_get_index_name('permanent', $i);
	}
	
	my $sphinx_port = $self->conf->get('sphinx/agent_port') ? $self->conf->get('sphinx/agent_port') : 9312;
	my @local_index_arr;
	for (my $i = 0; $i < $self->cpu_count; $i++){
		if ($index_groups[$i] and @{ $index_groups[$i] }){
			push @local_index_arr, "localhost:$sphinx_port:" . join(',', @{ $index_groups[$i] });
		}
	}

	my $timeout = $Timeout * 1000;
	my $agent_timeout = $Sphinx_agent_query_timeout * 1000;

	$template .= 'index distributed_local {' . "\n" .
		"\t" . 'type = distributed' . "\n" .
		"\t" . 'agent_connect_timeout = ' . $timeout . "\n" .
		"\t" . 'agent_query_timeout = ' . $agent_timeout . "\n";
	
	foreach my $line (@local_index_arr){
		$template .= "\t" . 'agent = ' . $line . "\n";
	}
	
	$template .= '}' . "\n";
	
	return $template;
}

sub _get_next_index_id {
	my $self = shift;
	my $type = shift;
		
	my ($query, $sth);
	
	# Try to find an unused id
	$query = 'SELECT id, type, start, locked_by FROM indexes WHERE type=?';
	$sth = $self->db->prepare($query);
	$sth->execute($type);
	my $ids = $sth->fetchall_hashref('id') or return 1;
	my $num_indexes = $self->conf->get('num_indexes');
	if ($type eq 'realtime'){
		$num_indexes = 2;
	}
	for (my $i = 1; $i <= $num_indexes; $i++){
		unless ($ids->{$i}){
			return $i;
		}
	}
	
	# Since we were unable to find an unusued id, we'll have to find the oldest unlocked one
	foreach my $id (sort { $ids->{$a}->{start} <=> $ids->{$b}->{start} } keys %{$ids}){
		unless ($ids->{$id}->{locked_by}){
			$self->log->warn("Overwriting " . $ids->{$id}->{type} . " index $id");
			return $id;
		}
	}
		
	die 'All indexes were locked: ' . Dumper($ids);
}

sub _get_index_name {
	my $self = shift;
	my $type = shift;
	my $id = shift;
	if ($type eq 'permanent'){
		return sprintf('perm_%d', $id);
	}
	elsif ($type eq 'temporary'){
		return sprintf('temp_%d', $id);
	}
	elsif ($type eq 'realtime'){
		return sprintf('real_%d', $id);
	}
	else {
		die 'Unknown index type: ' . $type;
	}
}

sub _epoch2iso {
	my $epochdate = shift;
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($epochdate);
	my $date = sprintf("%04d-%02d-%02d %02d:%02d:%02d", 
		$year + 1900, $mon + 1, $mday, $hour, $min, $sec);
	return $date;
}

sub dbh_id {
	my $self = shift;
	my ($query, $sth);
	$query = 'SELECT CONNECTION_ID()';
	$sth = $self->db->prepare($query);
	$sth->execute;
	my $row = $sth->fetchrow_arrayref;
	return $row->[0];
}

sub get_current_index_info {
	my $self = shift;
	
	my $index_id = ($self->_get_max_id('index'));
	my ($query, $sth);
	$query = 'SELECT id, records FROM v_indexes WHERE type="realtime" ORDER BY id DESC LIMIT 1';
	$sth = $self->db->prepare($query);
	$sth->execute();
	my $row = $sth->fetchrow_hashref;
	my $realtime_index_id;
	my $do_init = 0;
	my $records = 0;
	if ($row){
		$records = $row->{records};
		if ($records > $self->conf->get('sphinx/perm_index_size')){
			$realtime_index_id = $self->_get_next_index_id('realtime');
		}
		else {
			$realtime_index_id = $row->{id};
		}
	}
	else {
		 $realtime_index_id = 1;
		 $do_init = 1;
	}
	
	return {
		index => {
			table => $self->_create_table({}),
			id => $index_id,
		},
		archive => {
			table => $self->_create_table({archive => 1}),
			id => ($self->_get_max_id('archive')),
		},
		realtime => {
			table => $self->_get_index_name('realtime', $realtime_index_id),
			id => $index_id,
			do_init => $do_init,
			records => $records,
		},
	};
}

sub add_programs {
	my $self = shift;
	my $to_add = shift;
	my ($query, $sth);
	$self->log->trace('Adding programs: ' . Dumper($to_add));
	$query = 'INSERT INTO programs (id, program) VALUES(?,?) ON DUPLICATE KEY UPDATE id=?';
	$sth = $self->db->prepare($query);
	$query = 'REPLACE INTO class_program_map (class_id, program_id) VALUES(?,?)';
	my $sth_map = $self->db->prepare($query);
	foreach my $program (keys %{ $to_add }){
		$sth->execute($to_add->{$program}->{id}, $program, $to_add->{$program}->{id});
		if ($sth->rows){ # this was not a duplicate, proceed with the class map insert
			$sth_map->execute($to_add->{$program}->{class_id}, $to_add->{$program}->{id});
		}
		else {
			$self->log->error('Duplicate CRC found for ' . $program . ' with CRC ' . $to_add->{$program}->{id});
		}
	}
}

__PACKAGE__->meta->make_immutable;

1;

__END__
