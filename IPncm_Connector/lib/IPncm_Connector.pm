#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

package IPncm_Connector;

use forks;
use strict;
use warnings;
use Capture::Tiny 'capture_stderr';
use Crypt::CBC;
use Data::Dumper;
use Expect;
use Exporter;
use File::Basename;
use File::Path qw(make_path);
use FindBin qw($Bin);
use JSON;
use List::MoreUtils qw(uniq);
use LWP::UserAgent;
use MIME::Base64;
use Net::OpenSSH;
use Sys::Hostname;
use Thread::Semaphore;

use CLoginConfig;

use sort 'stable';

use vars qw($VERSION);
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(LOG_CONN LOG_SEND LOG_TIMING LOG_CISCO LOG_SSH LOG_ALL);
our %EXPORT_TAGS = (LOG => [qw(LOG_CONN LOG_SEND LOG_TIMING LOG_CISCO LOG_SSH 
		LOG_ALL)]);

use constant BASE_PATH => (-e "$Bin/lib/IPncm_Connector.pm" ? $Bin : 
		(-e "$Bin/../lib/IPncm_Connector.pm" ? "$Bin/.." : 
		"/home/BASE_USER/IPncm_Connector"));
use lib BASE_PATH . "/lib";
use Constants;

my $mode = (stat(BASE_PATH . "/lib/Constants.pm"))[2];
if (($mode & 07777) != 0400)  {
	die "ERROR!  Constants.pm does not have 0400 permissions! Aborting!";
}


use Constants;
$VERSION     = CURRENT_VERSION;

use constant CONFIG_PATH => BASE_PRODUTIL_PATH . '/saved_configs';
use constant CLIENT_CONFIG_PATH => BASE_PRODUTIL_PATH . '/conf';
use constant CMD_PATH => 'unbuffer ' . BASE_CLIENT_PATH . '/IPncm_Client.pl';

# Creates debug output from IPncm_Connector. 
my $_debug = 0;

# Error log variable
my @_errors :shared;
@_errors = ();

# Semaphore for threading.
my $_thread_sema :shared;
$_thread_sema = new Thread::Semaphore(DEFAULT_MAX_CONNECTIONS);

#  Hostname for logging
my $localhost = hostname;
$localhost =~ s/\.(?:(?:ip-soft|Company|ipcenter)\.(?:net|com))//;

#  Hash for storing success / failure for devices.
my %_success :shared;
%_success = ();


#  IPncm_Connector->debug($level)
#  Function:  Sets the debug log level for this module.
#  Parameters:  $level - int:  from the LOG_ constants above, selects what 
#      types of log information gets output - may be anded together.  Note that 
#      LOG_ERROR messages are always printed if the log level is any value.
#  Returns:  N/A
sub debug  {
	my $class = shift;
	$_debug = shift;
	$Net::OpenSSH::debug = ~0 if ($_debug & LOG_SSH);
}


#  IPncm_Connector->new(@hosts)
#  Function:  Creates a new IPncm_Connector, connects it to its ipmons 
#    (whatever those may be for the current environment), adds the given @hosts 
#    to it (though those may be added later with add()).
#  Parameters:  @hosts - array of strings: end devices to add to the connector.
#  Returns:  IPncm_Connector: The new IPncm_Connector object.
sub new  {
	my $this = shift;
	my $opts = ref($_[0]) eq 'HASH' ? shift : {};
	my @hosts = @_;

	my $class = ref($this) || $this;
	my $self = {
		ipmons => [],
		base_ipmon_to_contact_ipmon => {},
		qa_device_to_contact_ipmon => {},
		base_ipmon_to_host => {},
		host_transform_patterns => {},
		host_to_base_ipmon => {},
		host_details => {},
		host_ip_to_host_name => {},
		ipmon_to_backup_ipmon => {},
		all_ipmons => undef,
		broken_ipmons => [],
		configs => {},
		connections => {},
		pid => $$,

		all_hosts => 0,
		always_enable => 0,
		backup_device_config => 0,
		clients => [],
		dir => BASE_PRODUTIL_PATH . '/log',
		ipmon_creds => _get_ipmon_creds(),
		keep => 0,
		output_file => 'output-' . time,
		default_device_type => undef,
		ssh_key_path => undef,
		ssh_key_passphrase => undef,
		db_device => '',
	};
	@$self{keys(%$opts)} = @$opts{keys(%$opts)};
	bless $self, $class;

	$| = 1;
	$self->add(@hosts);
	return $self;
}


{
        package PaasRequestAgent;
        our @ISA = qw(LWP::UserAgent);
        sub get_basic_credentials
        {
                return ( IPncm_Connector::_get_ipmon_args(IPncm_Connector::PAAS_USER), 
						IPncm_Connector::_get_ipmon_args(IPncm_Connector::PAAS_PW));
        }
}


#  $IPncm_connector->_get_ipmon_creds()
#  Function:  Gets the IPmon connection credentials from the Paas version
#      of IPlocksmith. 
#  Returns:  array reference:  [username, password]
sub _get_ipmon_creds  {
	my $this = shift;
	
	print IP_USER . "\n";
	return [ IP_USER, IP_PW ];
	
	my $ua = PaasRequestAgent->new;
	
	my $resp = $ua->get(PAAS_API_URL . 'folders');
	my @folders = ();

	if ($resp->is_success) {
		my $json = decode_json($resp->decoded_content);
		if ($json->{data})  {
			foreach my $parent (@{$json->{data}})  {
				foreach my $child (@{$parent->{children}})  {
					if ($child->{typeName} eq "FolderDTO")  {
						push(@folders, $child->{id});
					}
				}
			}
		}
	}
	foreach my $folder (@folders)  {
		$resp = $ua->get(API_URL . "folders/$folder/elements");
		next if (!$resp->is_success);
		my $json = decode_json($resp->decoded_content);
		if ($json->{data})  {
			foreach my $data (@{$json->{data}})  {
				my $id = $data->{id};
				my $user = undef;
				foreach my $att (@{$data->{attributes}})  {
					if ($att->{name} eq "Username")  {
						$user = $att->{value};
						last;
					}
				}
				if ($user ne PAAS_USER)  { 
					next;
				}
				my $r2 = $ua->get(API_URL . "elements/$id/Password");
				my $pass = undef;
				if ($r2->is_success)  {
					my $j2 = decode_json($r2->decoded_content);
					$pass = exists($j2->{value}) ? $j2->{value} : undef;
				}
				if ($user && $pass)  {
					return [_set_ipmon_args($user), _set_ipmon_args($pass)];
				}
			}
		}
	}
	return [ IP_USER, IP_PW ];
}


#  $IPncm_connector->_select_ipmon()
#  Function:  Given a host, selects the ipmon to be used to contact that host.
#  Parameters:  string:  hostname of host
#  Returns:  string:  hostname of ipmon
sub _select_ipmon  {
	my $this = shift;
	my ($hostname) = @_;
	$hostname = $this->_select_hostname($hostname);
	return $this->{qa_device_to_contact_ipmon}->{$hostname}
			if (defined($this->{qa_device_to_contact_ipmon}->{$hostname}));
	foreach my $device (keys(%{$this->{qa_device_to_contact_ipmon}}))  {
		if ($device =~ /^\/(.*)\/$/)  {
			return $this->{qa_device_to_contact_ipmon}->{$device} if ($hostname =~ /$1/);
		}
	}
	if (defined($this->{host_to_base_ipmon}->{$hostname}) && 
			defined($this->{base_ipmon_to_contact_ipmon}->{$this->{host_to_base_ipmon}->{$hostname}}))  {
		return $this->{base_ipmon_to_contact_ipmon}->{$this->{host_to_base_ipmon}->{$hostname}};
	}
	foreach my $ipmon (keys(%{$this->{base_ipmon_to_contact_ipmon}}))  {
		if ($ipmon =~ /^\/(.*)\/$/)  {
			return $this->{base_ipmon_to_contact_ipmon}->{$ipmon} if ($hostname =~ /$1/);
		}
	}
	$this->_log('_select_ipmon', undef, $hostname, "unable to find appropriate ipmon for host, perhaps it is no longer being monitored?", 
			LOG_ERROR);
	return undef;
}


#  $IPncm_connector->_run_sql()
#  Function:  Given a SQL query, runs it against the DB and returns the results.
#    This may be on the local device or another one, depending on the db_device 
#    setting.
#  Parameters:  string:  SQL query to run.
#  Returns:  string:  Output of SQL
sub _run_sql  {
	my $this = shift;
	my $sql_query = shift;
	
	my $sql_cmd = "mysql -hipdb-s -ureadonly -pread0nly -sN -e \"$sql_query\" 2>&1";
	if ($this->{db_device})  {
		my $ssh = undef;
		my %opts = (
			user => _get_ipmon_args($this->{ipmon_creds}->[0]),
			password => _get_ipmon_args($this->{ipmon_creds}->[1]),
			timeout => 30,
		);
		if ($_debug & LOG_SSH)  {
			$opts{master_opts} = [-o => "StrictHostKeyChecking=no", -vv];
		}  else {
			$opts{master_opts} = [-o => "StrictHostKeyChecking=no"];
		}
		my $err = capture_stderr  {
			$ssh = Net::OpenSSH->new($this->{db_device}, %opts);
		};
		$err =~ s/WARNING - This device is the exclusive property of Company.*?USE AND CONSENT TO THE SAME.//gs;
		$err =~ s/\-*\s*W\s*A\s*R\s*N\s*I\s*N\s*G.*consent to monitoring for these purposes.//gs;
		if ($ssh->error())  {
			$err .= $ssh->error();
		}
		$err =~ s/\n\n+/\n/g;
		$err =~ s/^\n+//;
		if ($err =~ /\w/)  {
			$this->_log('run_sql', $this->{db_device}, undef,
				"continuing after error connecting when " . 
				"running SQL query: $err", 
				LOG_ERROR);
			$_thread_sema->up();
			return '';
		}  else {
			my @output = ();
			$err = capture_stderr  {
				@output = 
					$ssh->capture({timeout => 10}, "$sql_cmd");
			};
			$err .= $ssh->error if ($ssh->error);
			if ($err =~ /\w/)  {
				$this->_log('run_sql', $this->{db_device}, undef,
				"continuing after error running SQL query: " . 
				$ssh->error, LOG_ERROR);
			}
			$_thread_sema->up();
			return join("\n", grep(!/can be insecure/, @output));
		}
	}  else {
		return `$sql_cmd`;
	}
}


#  $IPncm_connector->_select_hostname()
#  Function:  Given a host, rewrites the hostname as needed.  (Used for 
#    customers which have multiple host patterns that need to be rewritten as 
#    one - ca.thd / thdca, for example.)
#  Parameters:  string:  hostname of host
#  Returns:  string:  hostname of ipmon
sub _select_hostname  {
	my $this = shift;
	my ($hostname) = @_;
	if (defined($this->{host_ip_to_host_name}->{$hostname}))  {
		$hostname = $this->{host_ip_to_host_name}->{$hostname};
	}
	while (my ($k, $v) = each(%{$this->{host_transform_patterns}}))  {
		$hostname =~ s/$k/$v/;
	}
	return $hostname;
}



#  $IPncm_connector->_get_all_ipmons()
#  Function:  Gets all ipmons that we want to be sending information to via
#    $this->{all_hosts}.
#  Parameters:  N/A
#  Returns:  array of string: names of all ipmons.
sub _get_all_ipmons  {
	my $this = shift;
	
	if (!defined($this->{all_ipmons}))  {
		my $query = "select aus.Address from auth.Services aus " .
				"where ServiceType = 1 and isActive = 1";
		if ($this->{clients})  {
			$query = "select aus.Address from auth.Services aus " .
					"join auth.CLIENT auc on (aus.ClientID = " .
					"auc.ClientID) where ServiceType = 1 and " . 
					"isActive = 1 and auc.ClientClientname in ('" .
					join("', '", @{$this->{clients}}) . "')";
		}
		my $output = $this->_run_sql($query);
		my @ipmons = ();
		foreach my $line (split(/\n/, $output))  {
			$line = lc($line);
			next unless ($line =~ /ipmon/);
			chomp($line);
			push(@ipmons, $line);
		}
		$this->{all_ipmons} = \@ipmons;
	}
	
	return @{$this->{all_ipmons}};
}


#  _flatten(@arr)
#  Function:  Flattens an array, making it into a simple one-dimensional array.
#  Parameters:  @arr - array of elements: the array to flatten.  Elements may 
#      be scalars or array references.
#  Returns:  array of scalar: the flattened array.
sub _flatten {
  map { ref $_ ? _flatten(@{$_}) : $_ } @_;
}


#  $IPncm_connector->_connect_ipmon()
#  Function:  Creates Net::OpenSSH connections to the given ipmon.  ipmons may 
#    have one or more backups - if the first one fails to connect, tries the 
#    second, etc.
#  Parameters:  $ipmon - string:  the name of the ipmon desired to connect to.
#  Returns:  string: the name of the contacted ipmon, or undef if the 
#    connection attempt failed for all backups (if any).
sub _connect_ipmon  {
	my $this = shift;
	my ($desired_ipmon) = @_;

	if (grep($desired_ipmon eq $_, @{$this->{broken_ipmons}}))  {
		$this->_log('connect', $desired_ipmon, undef, "ipmon is currently down", 
			LOG_ERROR);
		return;
	}
	
	my $start = time;
	my @ipmons = @{$this->{ipmons}};
	my @ipmon_set = ($desired_ipmon);
	my ($found_element) = (-1);
	my ($found_ipmon) = (undef);
	
	for my $i (0 .. $#ipmons)  {
		my @list = _flatten($ipmons[$i]);
		if (grep($desired_ipmon eq $_, @list))  {
			my $index = 0;
			$index++ until ($desired_ipmon eq $list[$index]);
			@ipmon_set = splice(@list, $index);
			$found_element = $i;
			last;
		}
	}
	
	$this->_log('connect', $desired_ipmon, undef, "Opening connection to ipmon", LOG_CONN);
	my $ipmon = "";
	foreach my $j (0 .. $#ipmon_set)  {
		$ipmon = $ipmon_set[$j];
		if (defined($this->{connections}->{$ipmon}))  {
			$this->{ipmons}->[$found_element] = $ipmon 
					if ($found_element != -1);
			$found_ipmon = $ipmon;
			last;
		}
		my %opts = (
			user => _get_ipmon_args($this->{ipmon_creds}->[0]),
			timeout => 60,
		);
		if ($_debug & LOG_SSH)  {
			$opts{master_opts} = [-o => "StrictHostKeyChecking=no", -vv];
		}  else {
			$opts{master_opts} = [-o => "StrictHostKeyChecking=no"];
		}
		if (defined($this->{ssh_key_passphrase}))  {
			if (defined($this->{ssh_key_path}))  {
				$opts{key_path} = $this->{ssh_key_path};
			}
			$opts{passphrase} = $this->{ssh_key_passphrase};
		}  else  {
			$opts{password} = _get_ipmon_args($this->{ipmon_creds}->[1]);
		}
		my $err = capture_stderr  {
			$this->{connections}->{$ipmon} = Net::OpenSSH->new($ipmon, %opts);
		};
		$err =~ s/WARNING - This device is the exclusive property of Company.*?USE AND CONSENT TO THE SAME.//gs;
		$err =~ s/\-*\s*W\s*A\s*R\s*N\s*I\s*N\s*G.*consent to monitoring for these purposes.//gs;
		$err =~ s/\n\n+/\n/g;
		$err =~ s/^\n+//;
		$this->_log('connect', $ipmon, undef, "error connecting, continuing:  $err", 
				LOG_CONN) if ($err);
		$err = '';
		if ($this->{connections}->{$ipmon}->error())  {
			$err = $this->{connections}->{$ipmon}->error();
		}
		$err =~ s/\n\n+/\n/g;
		$err =~ s/^\n+//;
		if ($err =~ /\w/)  {
			$this->_log('connect', $ipmon, undef, "error connecting: $err", LOG_ERROR);
			if ($j < $#ipmon_set) {
				$this->_log('connect', $ipmon, undef,
					"falling back to " . $ipmon_set[$j+1], LOG_ERROR);
				$this->{connections}->{$ipmon} = undef;
			}  else {
				$this->_log('connect', $ipmon, undef,
					"no fallback ipmon available, aborting execution", 
					LOG_ERROR);
				return undef;
			}
		}  else {
			$this->_log('connect', $ipmon, undef, "connection created", 
				LOG_CONN);
			$this->{ipmons}->[$found_element] = $ipmon 
					if ($found_element != -1);
			$found_ipmon = $ipmon;
			last;
		}
	}
	$this->_log('connect', $desired_ipmon, $ipmon, time - $start, LOG_TIMING);
	return $found_ipmon;
}


#  $IPncm_connector->add(@hosts)
#  Function:  Sets up the hosts to be contactable, determining which ipmons 
#    they map to and getting the login information from those ipmons.
#  Parameters:  @hosts - array of strings:  list of hosts to set up.
#  Returns:  N/A
sub add  {
	my $this = shift;
	my @hosts = @_;

	if (!@hosts)  {
		return;
	}  elsif ($hosts[0] eq 'all')  {
		my $output = $this->_run_sql("select h.host from " .
				"IPradar.host_lookup h left join auth.Services s on " .
				"(h.ipmon_host = s.Service) left join auth.CLIENT c on " .
				"(c.ClientID = s.ClientID) where c.ClientClientname in ('" .
				join("', '", @{$this->{clients}}) . "')");
		@hosts = ();
		foreach my $line (split(/\n/, $output))  {
			$line = lc($line);
			chomp($line);
			next unless ($line =~ /\w/);
			push(@hosts, $line);
		}
		
	}

	foreach my $host (@hosts)  {
		my $curhost = $this->_select_hostname($host);
		if (defined($curhost))  {
			$this->{host_to_base_ipmon}->{lc($curhost)} = undef;
		}  else {
			$this->_add_result($host, $localhost, 0, "invalid generated hostname");
		}
		
	}

	$this->_get_ipmon_map(@hosts);
	$this->_get_ipmon_configs();
}


#  $IPncm_connector->add_ipmons(@ipmons)
#  Function:  Sets up the ipmons to be contacted when $this->{all_hosts} is set.
#    This list is ignored if $this->{all_hosts} isn't set.  If 
#    $this->{all_hosts} is set and this function has not been called, all 
#    active ipmons are used. 
#  Parameters:  @ipmons - array of strings:  list of ipmons to set up.
#  Returns:  N/A
sub add_ipmons  {
	my $this = shift;
	my @ipmons = @_;

	if (!@ipmons)  {
		return;
	}

	if (!defined($this->{all_ipmons}))  {
		$this->{all_ipmons} = [];
	}
	
	foreach my $ipmon (@ipmons)  {
		$ipmon = lc($ipmon);
		if (!grep($_ eq $ipmon, @{$this->{all_ipmons}}))  {
			push(@{$this->{all_ipmons}}, $ipmon);
		}
	}
}

#  $IPncm_connector->add_client_config($client)
#  Function:  Sets up the ipmon or ipmons to be used to contact devices using
#    the given client's configuration file, and gets the IPlocksmith credentials
#    for that customer's configuration.  This will _need_ to be done before
#    any devices are added. 
#  Parameters:  $client - string:  name of client to add configuration file
#      for.  A client of "all" adds all configuration files.
#  Returns:  boolean: true for success, false for failure.
sub add_client_config  {
	my $this = shift;
	my ($client) = @_;

	return 0 if (!defined($client) || !$client);

	my @clients = ();
	if ($client eq "all")  {
		opendir(DIR, CLIENT_CONFIG_PATH);
		@clients = grep($_ ne "Sample.conf", grep(/\.conf$/, readdir(DIR)));
		@clients = map { s/\.conf//; $_; } @clients;
		closedir(DIR);
	}  else {
		if (-e CLIENT_CONFIG_PATH . "/" . $client . ".conf")  {
			push(@clients, $client);
		}
	}

	if (!@clients)  {
		$this->_log('add_client_config', $localhost, undef,
			"Unable to locate config file for '$client'", LOG_ERROR);
		return 0;
	}
	
	my %clients_to_ipmons = ();
	my $priority = PRIORITY_USER_CONNECTOR;
	foreach my $conf (@clients)  {
		open(my $fh, CLIENT_CONFIG_PATH . "/$conf.conf") || 
				($this->_log('add_client_config', $localhost, undef,
				"Unable to open config file '$conf.conf'", LOG_ERROR) && next);
		my $type = '';
		my $cur_ipmon = "";
		my @contact_ipmons = ();
		my $iplocksmith_name = $conf;
		my $u = '';
		my $p = '';
		my $client_set = 0;
		my $valid_spacer = '\t';
		while(my $line = <$fh>)  {
			next if (($line =~ /^\s*$/) || ($line =~ /^\s*#/));
			if (($line =~ /^        /) && ($valid_spacer eq '\t'))  {  
				$valid_spacer = '(?:\t|        )';
			}  elsif ($line =~ /^    /)  {
				$valid_spacer = '(?:\t|    )';
			}
			if ($line =~ /^(\w.*):/)  {
				$type = $1;
			}  elsif ($type eq "IPmons")  {
				if ($line =~ /^$valid_spacer(\w.*?)(?:\s*=>\s*(.*))?\s*$/)  {
					my ($ipmon_list, $backup_ipmon) = ($1, $2);
					$backup_ipmon = $backup_ipmon || "";
					$backup_ipmon =~ s/[\r\n]//g;
					my @ipmons = $this->_generate_ipmon_list($ipmon_list);
					$cur_ipmon = $ipmons[0];
					push(@contact_ipmons, $cur_ipmon);
					$this->{configs}->{$cur_ipmon} = new CLoginConfig() 
							if (!defined($this->{configs}->{$cur_ipmon}));
					foreach my $ipmon (@ipmons)  {
						if (!defined($this->{base_ipmon_to_contact_ipmon}->{$ipmon}))  {
							$this->{base_ipmon_to_contact_ipmon}->{$ipmon} = $cur_ipmon;
						}
						if ($backup_ipmon)  {
							$this->{ipmon_to_backup_ipmon}->{$ipmon} = $backup_ipmon;
						}
					}
					push(@{$this->{ipmons}}, \@ipmons);
					push(@{$this->{ipmons}}, $backup_ipmon)  if ($backup_ipmon);
				}  elsif ($cur_ipmon && ($line =~ /^$valid_spacer$valid_spacer(\w.*?)\s*$/))  {
					my $str = $1;
					foreach my $ipmon ($this->_generate_ipmon_list($str))  {
						if (!defined($this->{base_ipmon_to_contact_ipmon}->{$ipmon}))  {
							$this->{base_ipmon_to_contact_ipmon}->{$ipmon} = $cur_ipmon;
						}
					}
					foreach my $device ($this->_generate_device_list($str))  {
						if (!defined($this->{qa_device_to_contact_ipmon}->{$device}))  {
							$this->{qa_device_to_contact_ipmon}->{$device} = $cur_ipmon;
						}
					}
				}  else {
					$this->_log('add_client_config', $localhost, undef,
						"Invalid conf file construction  - ipmons", LOG_ERROR);
				}
			}  elsif ($type eq "Hostname Transformations")  {
				if ($line =~ /^\s+(\S.*?)\s*$/)  {
					my $patt = $1;
					if ($patt =~ /\s=>/)  {	
						my ($k, $v) = split(/ =>/, $patt, 2);
						$v =~ s/^\s*//;
						$this->{host_transform_patterns}->{$k} = $v;
					}  else {
						$this->_log('add_client_config', $localhost, undef,
							"Invalid conf file construction - transformation", LOG_ERROR);
					}
				}
			}  elsif ($type eq "Short Client Name")  {
				if ($line =~ /^\s+(\S.*?)\s*$/)  {
					push(@{$this->{clients}}, $1);
					$client_set++;
				}
			}  elsif ($type eq "IPlocksmith Name")  {
				if ($line =~ /^\s+(\S.*?)\s*$/)  {
					$iplocksmith_name = $1;
				}
			}  elsif ($type eq "Username")  {
				if ($line =~ /^\s+(\S.*?)\s*$/)  {
					$u = decode_base64($1);
				}
			}  elsif ($type eq "Password")  {
				if ($line =~ /^\s+(\S.*?)\s*$/)  {
					$p = decode_base64($1);
					if ($u && $p)  {
						foreach my $ipmon (@contact_ipmons)  {
							$this->set_login($ipmon, ".*", PRIORITY_USER_CONNECTOR, $u, 
									$p, $p, 'client_config');
						}
					}
				}
			}
		}
		if (!$client_set)  {
			push(@{$this->{clients}}, $conf);
		}	
		@contact_ipmons = uniq(@contact_ipmons);
		$clients_to_ipmons{$iplocksmith_name} = \@contact_ipmons;
		close($fh)
	}
	$this->_get_locksmith_creds(%clients_to_ipmons);
	return 1;
}


{
        package RequestAgent;
        our @ISA = qw(LWP::UserAgent);
        sub get_basic_credentials
        {
                return ( IPncm_Connector::_get_ipmon_args(IPncm_Connector::LOCK_USER), 
						IPncm_Connector::_get_ipmon_args(IPncm_Connector::LOCK_PW));
        }
}

# Contains the list of clients, as retrieved from IPlocksmith, in the format:
# ("client" => [clientID, ["list", "of", "folders"], isRetrieved])
my %_locksmith_clients = ();

#  $IPncm_connector->_get_locksmith_creds(%client_to_ipmon_map)
#  Function:  Gets the IPlocksmith credentials for the given clients. 
#  Parameters:  %client_to_ipmon_map - hash:  maps the name of client to add 
#      IPlocksmith credentials for to the list of contactable ipmons for that
#      client.
#  Returns:  N/A
sub _get_locksmith_creds  {
	my $this = shift;
	my %client_to_ipmon_map = @_;
	
	if (!%_locksmith_clients)  {
		$this->_get_locksmith_clients();
	}
	my $priority = PRIORITY_IPLOCKSMITH;
	
	my $ua = RequestAgent->new;
	foreach my $client (keys(%client_to_ipmon_map)) {
		next if (!defined($_locksmith_clients{$client}));
		my ($cust_id, $folders, $retrieved) = @{$_locksmith_clients{$client}};
		if (!$retrieved)  {
			foreach my $folder (@{$folders})  {
				my $resp = $ua->get(API_URL . "folders/$folder/elements");
				next if (!$resp->is_success);
				my $json = decode_json($resp->decoded_content);
				if ($json->{data})  {
					foreach my $data (@{$json->{data}})  {
						my $id = $data->{id};
						my $host = $data->{name};
						if ($host eq "default")  {
							$host = "*";
						}  else {
							$host = "*$host*";
						}		
						my $user = undef;
						foreach my $att (@{$data->{attributes}})  {
							if ($att->{name} eq "Username")  {
								$user = $att->{value};
								$user =~ s/\\(.)/$1/g if ($user);
								last;
							}
						}
						my $r2 = $ua->get(API_URL . "elements/$id/Password");
						my $pass = undef;
						if ($r2->is_success)  {
							my $j2 = decode_json($r2->decoded_content);
							$pass = exists($j2->{value}) ? $j2->{value} : undef;
							$pass =~ s/\\(.)/$1/g  if ($pass);
						}
						$r2 = $ua->get(API_URL . "elements/$id/EnablePassword");
						my $en_pass = undef;
						if ($r2->is_success)  {
							my $j2 = decode_json($r2->decoded_content);
							$en_pass = exists($j2->{value}) ? $j2->{value} : undef;
							$en_pass =~ s/\\(.)/$1/g  if ($en_pass);
						}
						foreach my $ipmon (@{$client_to_ipmon_map{$client}})  {
							$this->set_login($ipmon, $host, $priority--, $user, 
									$pass, $en_pass, 'locksmith');
						}
					}
				}
			}
			$_locksmith_clients{$client}->[2] = 1;
		}
	}
		
}


#  $IPncm_connector->_get_locksmith_clients()
#  Function:  Loads the %_locksmith_clients hash with the client list, 
#    in the format ("client" => (clientID, ["list", "of", "folders"])). 
sub _get_locksmith_clients  {
	my $this = shift;
	
	my $ua = RequestAgent->new;
	my $resp = $ua->get(API_URL . 'folders');

	if ($resp->is_success) {
		my $json = decode_json($resp->decoded_content);
		if ($json->{data})  {
			foreach my $parent (@{$json->{data}})  {
				my @folders = ();
				foreach my $child (@{$parent->{children}})  {
					if (defined($child->{typeName}) && 
							$child->{typeName} eq "FolderDTO")  {
						push(@folders, $child->{id});
					}
				}
				$_locksmith_clients{$parent->{name}} = 
						[ $parent->{id}, \@folders, 0 ];
			}
		}
	}
}


#  $IPncm_connector->_generate_ipmon_list($ipmon_str)
#  Function:  Given a string with a list of ipmons in it (of the form 
#    a1-a10,b34-b36...) returns an array of the elements 
#    (a1, a2, a3..., b34, b35, b36).
#  Parameters:  $ipmon_str - string:  string with list of ipmons.
#  Returns:  array of strings: array of individual ipmons.
sub _generate_ipmon_list  {
	my $this = shift;
	my ($ipmon_str) = @_;

	my @ret = ();
	foreach my $element (split(/[,; ]+/, $ipmon_str))  {
		next unless $element;
		next if ($element =~ /^device:/);
		if ($element =~ /(.*)\-\-(.*)/)  {  # %%%%%PS%%%%% is this a bug???
		# if ($element =~ /^([^-]+)-([^-]+)$/)  {  # %%%%%PS%%%%% looks like it should be this.
			my ($first, $last) = ($1, $2);
			my ($ffirst, $fnum, $flast) = (undef, undef, undef);
			my ($lfirst, $lnum, $llast) = (undef, undef, undef);
			if ($first =~ /(.*?)(\d+)(.*)/)  {
				($ffirst, $fnum, $flast) = ($1, $2, $3);
			}
			if ($last =~ /(.*?)(\d+)(.*)/)  {
				($lfirst, $lnum, $llast) = ($1, $2, $3);
			}
			if (!defined($fnum) || !defined($flast) ||
					!defined($lnum) || !defined($llast) ||
					($ffirst ne $lfirst) || ($flast ne $llast))  {
				push(@ret, $element);
			}  else  {
				for (my $i = $fnum; $i <= $lnum; $i++)  {
					my $name = sprintf("%s%0*d%s", $ffirst, length($fnum), 
							$i, $flast);
					push(@ret, $name);
				}
			}
		}  else {
			push(@ret, $element);
		}
	}
	return @ret;
}
my $_cipher = Crypt::CBC->new( 
	-key => decode_base64('VGhpcyBpcyBub3QgdGhlIGtleS4gTG9vayBhd2F5Lgo='),
	-cipher => 'Blowfish'
);


#  $IPncm_connector->_generate_device_list($device_str)
#  Function:  Given a string with a list of devices in it (of the form 
#    a1-a10,device:b3,device:b45,b34-b36...) returns an array of the device-type 
#    elements (b3, b45).
#  Parameters:  $device_str - string:  string with list of devices.
#  Returns:  array of strings: array of individual devices.
sub _generate_device_list  {
	my $this = shift;
	my ($device_str) = @_;

	my @ret = ();
	foreach my $element (split(/[,; ]+/, $device_str))  {
		next unless $element;
		next unless ($element =~ s/^device://);
		push(@ret, $element);
	}
	return @ret;
}


#  $IPncm_connector->remove(@hosts)
#  Function:  Removes the hosts from the host map, requiring them to be 
#    re-add()ed before they can be used.
#  Parameters:  @hosts - array of strings:  list of hosts to remove.
#  Returns:  N/A
sub remove  {
	my $this = shift;
	my @hosts = @_;

	if (!@hosts)  {
		@hosts = keys(%{$this->{host_to_base_ipmon}});
	}
	foreach my $host (@hosts)  {
		delete($this->{host_to_base_ipmon}->{$this->_select_hostname($host)});
	}
}


#  $IPncm_connector->_get_ipmon_map(@hosts)
#  Function:  Determines which ipmon each host maps to and stores that 
#    information for later use.  This information is attempted to be gotten 
#    from the database.  A QA host pattern may also be specified that will cause
#    the host(s) that match the pattern to use a pre-determined ipmon instead.
#    Hosts that are not in the database and which don't match the QA pattern 
#    will cause an error.
#  Parameters:  @hosts - array of strings:  list of hosts to map to ipmons.
#  Returns:  N/A
sub _get_ipmon_map  {
	my $this = shift;
	my @hosts = @_;
	if (!@hosts)  {
		@hosts = keys(%{$this->{host_to_base_ipmon}});
	}

	my $start = time;

	for (my $i = 0; $i <= $#hosts; $i++)  {
		if ($hosts[$i] =~ /[^a-zA-Z0-9\-_\.]/)  {
			$this->_log('add', $localhost, $hosts[$i],
					'invalid characters found in host', LOG_ERROR);
			delete($this->{host_to_base_ipmon}->{$hosts[$i]});
			splice(@hosts, $i, 1);
		}  else {
			if ($this->_select_hostname($hosts[$i]) ne $hosts[$i])  {
				push(@hosts, $this->_select_hostname($hosts[$i]));
			}
		}
	}

	if (!@hosts)  {
		$this->_log('add', $localhost, undef, 'no valid hosts found', LOG_ERROR);
		return;
	}
	
	my %service_locs = ();
	my $services = $this->_run_sql("select Service,Address from " .
			"auth.Services where IsActive='1' and ServiceType='1'");
	foreach my $line (split(/\n/, $services))  {
		$line = lc($line);
		my ($service, $loc) = split(/\t/, $line);
		$service_locs{$service} = $loc;
	}
	
	my @limited_hosts = @hosts;
	my %found = ();
	while (@limited_hosts)  {
		my $hosts = join("', '", splice(@limited_hosts, 0, 1000));
		my $output = $this->_run_sql("select host, ipmon_host, ip from " .
				"IPradar.host_lookup where host in ('$hosts') " .
				"or ip in ('$hosts') order by updated desc");
		foreach my $line (split(/\n/, $output))  {
			$line = lc($line);
			if ($line =~ /^([a-z0-9\-\.\_]*)\t([a-z0-9\-\.\_]*)\t([0-9\:\.]*)$/)  {
				my ($host, $mon, $ip) = ($this->_select_hostname($1), $2, $3);
				next if (defined($found{$host}));
				$this->{host_ip_to_host_name}->{$ip} = $host;
				delete($this->{host_to_base_ipmon}->{$ip});
				$mon = lc($mon);
				if (defined($service_locs{$mon}))  {
					$mon = $service_locs{$mon};
				}  else {
					$mon =~ s/(.+)-(ipmon\d+)/$2.$1/i if ($mon =~ /ipmon\d+$/);
					$mon =~ s/(ipmon\d+)-(.+)/$1.$2/ if ($mon =~ /^ipmon\d+/);
				}
				$this->{host_to_base_ipmon}->{$host} = $mon;
				if (!defined($this->{base_ipmon_to_host}->{$mon}))  {
					$this->{base_ipmon_to_host}->{$mon} = ();
				}
				push(@{$this->{base_ipmon_to_host}->{$mon}}, $host);
				$found{$host} = 1;
			}  elsif ($line !~ /can be insecure/)  {
				$this->_log('add', $localhost, undef, $line, LOG_ERROR);
			}
		}
	}
	foreach my $qahost (@hosts)  {
		$qahost = $this->_select_hostname($qahost);
		next if (defined($found{$qahost}));
		my $qamon = $this->_select_ipmon($qahost);
		if (defined($qamon))  {
			$this->{host_to_base_ipmon}->{$qahost} = $qamon;
			push(@{$this->{base_ipmon_to_host}->{$qamon}}, $qahost);
			$found{$qahost} = 1;
		}
	}
	foreach my $host (@hosts)  {
		$host = $this->_select_hostname($host);
		if (!defined($found{$host}))  {
			$this->_log('add', undef, $host, "host not found in the database", LOG_ERROR);
			$this->_add_result($host, $localhost, 0, 
					"unable to find appropriate ipmon");
			delete($this->{host_to_base_ipmon}->{$host});
		}
	}
	$this->_log('_get_ipmon', $localhost, undef, time - $start, LOG_TIMING);
}


#  $IPncm_connector->_get_ipmon_configs()
#  Function:  For each ipmon that a host is connected to, attempts to gather 
#    login information from that ipmon (from the ~rancid/.cloginrc configuration
#    file).  A failure at any given ipmon is not necessarily fatal, as much
#    login information is duplicated between ipmons - an error is logged and
#    the process continues.  A failure to connect to _any_ ipmon will cause a 
#    login failure when the connections to the hosts are actually used.
#  Parameters:  N/A
#  Returns:  N/A
sub _get_ipmon_configs  {
	my $this = shift;

	my $start = time;
	my @threads = ();

	foreach my $mon (keys(%{$this->{base_ipmon_to_host}}))  {
		next if (defined($mon) && 
				defined($this->{base_ipmon_to_contact_ipmon}->{$mon}) && 
				($this->{base_ipmon_to_contact_ipmon}->{$mon} eq $mon));
		$_thread_sema->down();
		push(@threads, threads->create(sub  {
			$0 = basename($0) . " -co '$mon config fetch'";
			my @output;
			my $ssh = undef;
			my %opts = (
				user => _get_ipmon_args($this->{ipmon_creds}->[0]),
				timeout => 30,
			);
			if ($_debug & LOG_SSH)  {
				$opts{master_opts} = [-o => "StrictHostKeyChecking=no", -vv];
			}  else {
				$opts{master_opts} = [-o => "StrictHostKeyChecking=no"];
			}
			if (defined($this->{ssh_key_passphrase}))  {
				if (defined($this->{ssh_key_path}))  {
					$opts{key_path} = $this->{ssh_key_path};
				}
				$opts{passphrase} = $this->{ssh_key_passphrase};
			}  else  {
				$opts{password} = _get_ipmon_args($this->{ipmon_creds}->[1]);
			}
			my $err = capture_stderr  {
				$ssh = Net::OpenSSH->new($mon, %opts);
			};
			$err =~ s/[\s\-]*W\s*A\s*R\s*N\s*I\s*N\s*G.*?(?:USE AND CONSENT TO THE SAME.|monitoring for these purposes.|infosec\/policies.html)//gs;
			if ($ssh->error())  {
				$err .= $ssh->error();
			}
			$err =~ s/\n\n+/\n/g;
			$err =~ s/^\n+//;
			if ($err =~ /\w/)  {
				$this->_log('add', $mon, undef,
					"continuing after error connecting when " . 
					"gathering configuration information: $err", 
					LOG_CONN);
				$_thread_sema->up();
				return ();
			}  else {
				$err = capture_stderr  {
					@output = 
						$ssh->capture({timeout => 10}, 
								'[ -a ~rancid/.cloginrc ] && cat ~rancid/.cloginrc || echo ""');
				};
				$err .= $ssh->error if ($ssh->error);
				if ($err =~ /\w/)  {
					$this->_log('add', $mon, undef,
					"continuing after error gathering configuration: " . 
					$ssh->error, LOG_CONN);
				}
				$_thread_sema->up();
				return ($mon, join("\n", @output));
			}
		}));
	}

	foreach my $thread (@threads)  {
		my ($ipmon, $output) = $thread->join();
		next unless $ipmon;
		my $contact_ipmon = $this->{base_ipmon_to_contact_ipmon}->{$ipmon} || "";
		if ($output && $contact_ipmon)  {
			$this->{configs}->{$contact_ipmon}->parse_config($output, PRIORITY_CLOGIN_HOSTS);
		}
	}
	$this->_log('_get_ipmon_configs', $localhost, undef, time - $start, LOG_TIMING);
}


#  $IPncm_connector->_map_hosts_to_ipmons(@hosts)
#  Function:  Maps the hosts to the ipmons used to contact those hosts.  If 
#    $this->{all_hosts} is set, returns all ipmons we want to contact.
#  Parameters:  @hosts - array of string: the hosts to be mapped.
#  Returns:  hash: map of ipmon to a reference to an array of the hosts that
#    use that ipmon.
sub _map_hosts_to_ipmons  {
	my $this = shift;
	my @hosts = @_;
	my %map = ();
	if ($this->{all_hosts})  {
		my @ipmons = $this->_get_all_ipmons();
		@map{@ipmons} = undef;
	}  else {
		foreach my $host (@hosts)  {
			my $ipmon = $this->_select_ipmon($host);
			if (defined($ipmon))  {
				push(@{$map{$ipmon}}, $host);
			}
		}
	}
	return %map;
}


#  $IPncm_connector->get_ipmon($host)
#  Function:  Returns the ipmon that the host is associated with.
#  Parameters:  $host - string: the host to return.
#  Returns:  string: the name of the ipmon.
sub get_ipmon  {
	my $this = shift;
	my ($host) = @_;
	return $this->{host_to_base_ipmon}->{$this->_select_hostname($host)};
}


#  $IPncm_connector->send_hosts($script, @hosts)
#  Function:  Sends the script to IPncm_Client.pl on the ipmons mapped to the 
#    hosts, and from there to the given hosts themselves for processing.
#  Parameters:  $script - hash reference or string: if a string, the script
#      to be sent.  If a hash reference, the hash keys are the hosts (or host
#      patterns - see POD for more details), and the hash values are the scripts 
#      to be sent to each of those hosts.  The script may be a combination of
#      simple commands separated by newlines and perl code to be eval'd 
#      surrounded by <perl>...</perl> tags.  See POD for specifics on the perl
#      code that may be executed.
#    @hosts - array of strings: the hosts to send the script(s) to.  A host 
#      without a script will cause an error.  A script without a host will not
#      be executed - the host list takes precedence.  If no hosts are specified,
#      the script will be sent to all hosts previously add()ed.
#  Returns:  hash: map of host names to the output from the script for that 
#    host.
sub send_hosts  {
	my $this = shift;
	my $script = shift;
	
	my @hosts = @_;
	if (!@hosts)  {
		@hosts = keys(%{$this->{host_to_base_ipmon}});
	}  else {
		foreach my $host (@hosts)  {
			if (!$this->is_added($host))  {
				$this->_log('send_hosts', $localhost, $host, "not " .
						"added to connector, aborting", 
						LOG_ERROR);
				return;
			}
			$host = $this->_select_hostname($host);
		}
	}
	if (!$this->is_valid_script($script))  {
		$this->_log('send_hosts', $localhost, undef, 'invalid script, aborting', LOG_ERROR);
		return;
	}
	
	$this->_log('send_hosts', $localhost, undef, 'preparing to send', LOG_SEND);
	foreach my $host (@hosts)  {
		delete($_success{$host});
	}
	
	my $start = time;
	my %map = $this->_map_hosts_to_ipmons(@hosts);
	my %responses = ();
	if (THREADED)  {
		my @threads = ();
		foreach my $ipmon (keys(%map))  {
			push(@threads, $this->_create_ipmon_thread($script, $ipmon, 
					@{$map{$ipmon}}));
		}
		if (DEBUG_THREADING)  {
			$this->_write_output("debug_threading.txt", 
					localtime . ": " . $this->{pid} . ": " . $this->{output_file} . 
					": finished thread creation\n", 1, BASE_PRODUTIL_PATH . "/log");
		}
		while (@threads)  {
			my $thread = shift(@threads);
			if (!$thread->is_joinable())  {
				push(@threads, $thread);
				sleep(1);
				next;
			}
			my ($ipmon, $output, $err) = $thread->join;  
			$ipmon = defined($ipmon) ? $ipmon : $localhost;
			if (DEBUG_THREADING)  {
				$this->_write_output("debug_threading.txt", 
						localtime . ": " . $this->{pid} . ": " . $this->{output_file} . 
						": joined thread $ipmon\n", 1, BASE_PRODUTIL_PATH . "/log");
			}
			my %err_host_map = ();
			foreach my $err (@_errors)  {
				push(@{$err_host_map{$err->[3]}}, $err);
			}
			if (defined($output))  {
				my %resp = $this->_process_ipmon_output($output);
				if (DEBUG_THREADING)  {
					$this->_write_output("debug_threading.txt", 
							localtime . ": " . $this->{pid} . ": " . $this->{output_file} . 
							": processing output for thread $ipmon\n", 1, BASE_PRODUTIL_PATH . "/log");
				}
				@responses{ keys(%resp) } = values(%resp);
				my @backup_hosts = ();
				foreach my $host (keys(%resp))  {
					if (!defined($this->{host_to_base_ipmon}->{$host}))  {
						$this->{host_to_base_ipmon}->{$host} = $ipmon;
					}
					my @host_errs = defined($err_host_map{$host}) ? @{$err_host_map{$host}} : (); 
					my $first_err = @host_errs ? $host_errs[0]->[4] : "";
					if (grep($_->[4] =~ / connect:/, @host_errs) && 
							defined($this->{ipmon_to_backup_ipmon}->{$ipmon}))  {
						push(@backup_hosts, $host);
						delete($resp{$host});
						$this->_log('send_hosts', $localhost, $host, 
								'falling back to backup ipmon ' . 
								$this->{ipmon_to_backup_ipmon}->{$ipmon}, 
								LOG_ERROR);
					}  else {
						$this->_add_result($host, $ipmon, undef, $first_err);
					}
				}
				if (@backup_hosts)  {
					push(@threads, $this->_create_ipmon_thread($script, 
							$this->{ipmon_to_backup_ipmon}->{$ipmon}, 
							@backup_hosts));
				}
				if (DEBUG_THREADING)  {
					$this->_write_output("debug_threading.txt", 
							localtime . ": " . $this->{pid} . ": " . $this->{output_file} . 
							": processed output for thread $ipmon\n", 1, BASE_PRODUTIL_PATH . "/log");
				}
			}  else {
				if (DEBUG_THREADING)  {
					$this->_write_output("debug_threading.txt", 
							localtime . ": " . $this->{pid} . ": " . $this->{output_file} . 
							": no output for thread $ipmon\n", 1, BASE_PRODUTIL_PATH . "/log");
				}
			}
			$this->_log('send_hosts', $ipmon, undef, $err, LOG_ERROR) if $err;
		}
		if (DEBUG_THREADING)  {
			$this->_write_output("debug_threading.txt", 
					localtime . ": " . $this->{pid} . ": " . $this->{output_file} . 
					": all threads joined\n", 1, BASE_PRODUTIL_PATH . "/log");
		}
	}  else {
		foreach my $ipmon (keys(%map))  {
			$this->_log('send_hosts', $ipmon, undef, "sending", LOG_SEND);
			my ($output, $err) = $this->_send_cmd($script, $ipmon, 
				@{$map{$ipmon}});
			if ($this->{backup_device_config})  {
				$this->_save_configs($ipmon);
			}
			if (defined($output))  {
				my %resp = $this->_process_ipmon_output($output);
				@responses{ keys(%resp) } = values(%resp);
				foreach my $host (keys(%resp))  {
					if (!defined($this->{host_to_base_ipmon}->{$host}))  {
						$this->{host_to_base_ipmon}->{$host} = $ipmon;
					}
				}
			}
			$this->_log('send_hosts', $ipmon, undef, $err, LOG_ERROR) if $err;
		}
	}

	my @missed_hosts = ();
	foreach my $host (@hosts)  {
		if (!grep($host eq $_, keys(%responses)) && 
				!grep($_->[2] eq $host, @_errors))  {
			push(@missed_hosts, $host);
		}
	}
	if (@missed_hosts)  {
		$this->_log('send_hosts', undef, join(", ", @missed_hosts), "No response from hosts", 
				LOG_ERROR);
	}
	
	
	$this->_log('send_hosts', $localhost, undef, time - $start, LOG_TIMING);
	return \%responses;
}


#  $IPncm_connector->_create_ipmon_thread($script, $ipmon, @hosts)
#  Function:  Creates the thread that sends the given script to the 
#    given IPmon and returns it.
#  Parameters:  $script - hash reference or string: if a string, the script
#      to be sent.  If a hash reference, the hash keys are the hosts (or host
#      patterns - see POD for more details), and the hash values are the scripts 
#      to be sent to each of those hosts.  The script may be a combination of
#      simple commands separated by newlines and perl code to be eval'd 
#      surrounded by <perl>...</perl> tags.  See POD for specifics on the perl
#      code that may be executed.
#    $ipmon - string:  the name of the IPmon to send the script to.
#    @hosts - array of strings: the hosts to send the script(s) to.  A host 
#      without a script will cause an error.  A script without a host will not
#      be executed - the host list takes precedence.  If no hosts are specified,
#      the script will be sent to all hosts previously add()ed.
#  Returns:  hash: map of host names to the output from the script for that 
#    host.
sub _create_ipmon_thread  {
	my $this = shift;
	my $script = shift;
	my $ipmon = shift;
	my @hosts = @_;
	
	if (DEBUG_THREADING)  {
		$this->_write_output("debug_threading.txt", 
				localtime . ": " . $this->{pid} . ": " . $this->{output_file} . 
				": starting $ipmon\n", 1, BASE_PRODUTIL_PATH . "/log");
	}
	$_thread_sema->down();
	return threads->new( sub  {  
		$0 = basename($0) . " -co '$ipmon script send'";
		$this->_log('send_hosts', $ipmon, undef, "sending", LOG_SEND);
		my ($output, $err) = $this->_send_cmd($script, $ipmon, 
			@hosts);
		if ($this->{backup_device_config})  {
			$this->_save_configs($ipmon);
		}
		$_thread_sema->up();
		if (DEBUG_THREADING)  {
			$this->_write_output("debug_threading.txt", 
					localtime . ": " . $this->{pid} . ": " . $this->{output_file} . 
					": finishing $ipmon thread\n", 1, BASE_PRODUTIL_PATH . "/log");
		}
		return ($ipmon, $output, $err);
	});
}


#  $IPncm_connector->send_ipmons($script, $direct, @devices)
#  Function:  Sends the script to the given ipmons.  The ipmons may be given 
#    directly, by giving a list of ipmons, or indirectly, in which case the
#    devices given are end devices, and the ipmons we want to send the script
#    to are the ones that correspond to the given hosts. 
#  Parameters:  $script - hash reference or string: if a string, the script
#      to be sent.  If a hash reference, the hash keys are the hosts/ipmons 
#      (or host patterns - see POD for more details), and the hash values are  
#      the scripts to be sent to each of those hosts.  The script should be 
#      a simple set of commands separated by newlines.
#    $direct - boolean:  if true, the given @host list is a list of ipmons.
#      If false, it's a list of hosts mapped to ipmons.  Defaults to true.
#    $path - string:  if false or undefined, the script is a command script.
#      If true, the script is treated as a filename and $path is the path to 
#      where it should be placed.  Defaults to false.
#    @devices - array of strings: the ipmons to send the script(s) to (either 
#      directly or indirectly).  If no devices are specified, the script 
#      will be sent to all ipmons associated with hosts previously add()ed.
#      If $this->{all_hosts} is set and no devices are specified, the script
#      will be sent to all ipmons.
#  Returns:  hash: map of ipmon names to the output from the script for that 
#    ipmon.
sub send_ipmons  {
	my $this = shift;
	my $script = shift;
	my $direct = shift;
	my $path = shift;
	my $root = shift;
	my @devices = @_;
	if (!@devices)  {
		@devices = $this->{all_hosts} ? $this->_get_all_ipmons() : 
				keys(%{$this->{base_ipmon_to_host}});
	}
	$direct = defined($direct) ? $direct : 1;
	$path = defined($path) ? $path : 0;
	my %device = ();
	if (!$direct)  {
		foreach my $device (@devices)  {
			if (!defined($this->{host_to_base_ipmon}->{$device}))  {
				$this->_log('send_ipmons', undef, $device, 
						'invalid host for indirect ipmon send', LOG_ERROR);
				return;
			}  else  {
				push(@{$device{$this->{host_to_base_ipmon}->{$device}}}, $device);
			}
		}
	}  else  {
		foreach my $device (@devices)  {
			$device{$device} = "";
		}
	}
	
	if (!$this->is_valid_script($script))  {
		$this->_log('send_ipmons', $localhost, undef, 'invalid script, aborting', LOG_ERROR);
		return;
	}
	
	$this->_log('send_ipmons', $localhost, undef, 'preparing to send', LOG_SEND);
	
	my $start = time;
	my %responses = ();
	if (THREADED)  {
		my @threads = ();
		foreach my $ipmon (keys(%device))  {
			my $sc = $this->_choose_script($script, $ipmon);
			my $device_list = $direct ? "" : join(" ", @{$device{$ipmon}});
			next unless ($sc);
			$sc =~ s/<HOST_LIST>/$device_list/g;

			$_thread_sema->down();
			push(@threads, threads->new( sub  {  
				$0 = basename($0) . " -co '$ipmon file send'";
				$this->_log('send_ipmons', $ipmon, undef, "sending", LOG_SEND);
				my ($output, $err);
				if ($path)  {
					$output = $this->_send_file_to_ipmon($sc, $ipmon, $path);
				}  else {
					($output, $err) = $this->_send_to_ipmon($sc, $ipmon, $root);
				}
				$_thread_sema->up();
				return ($ipmon, $output, $err);
			}));
		}
		while (@threads)  {  
			my $thread = shift(@threads);
			if (!$thread->is_joinable())  {
				push(@threads, $thread);
				sleep(1);
				next;
			}
			
			my ($ipmon, $output, $err) = $thread->join;  
			if (defined($output))  {
				$responses{$ipmon} = $output;
			}
			$this->_log('send_ipmons', $ipmon, undef, $err, LOG_ERROR) if $err;
		}
	}  else {
		foreach my $ipmon (keys(%device))  {
			my $sc = $this->_choose_script($script, $ipmon);
			my $device_list = join(" ", @{$device{$ipmon}});
			$sc =~ s/<HOST_LIST>/$device_list/g;

			$this->_log('send_ipmons', $ipmon, undef, "sending", LOG_SEND);
			my ($output, $err) = $this->_send_to_ipmon($sc, $ipmon, $root);
			if (defined($output))  {
				$responses{$ipmon} = $output;
			}
			$this->_log('send_ipmons', $ipmon, undef, $err, LOG_ERROR) if $err;
		}
	}

	my @missed_ipmons = ();
	foreach my $ipmon ($direct ? @devices : 
			map { $this->{host_to_base_ipmon}->{$_} } @devices)  {
		if (!defined($responses{$ipmon}) && 
				!grep($_->[2] eq $ipmon, @_errors))  {
			push(@missed_ipmons, $ipmon);
		}
	}
	if (@missed_ipmons)  {
		$this->_log('send_ipmons', join(", ", @missed_ipmons), undef, 
				"No response from ipmons", LOG_ERROR);
	}
	
	
	$this->_log('send_ipmons', $localhost, undef, time - $start, LOG_TIMING);
	return \%responses;
}


#  $IPncm_connector->cleanup_ipmons()
#  Function:  Copies all data collected on the various ipmons to the main
#      produtil device.   This step may take some time, as debug data may be 
#      quite large.  Once copied, output is deleted from the ipmons.  When this
#      is complete, the results CSV is updated (if desired).
sub cleanup_ipmons  {
	my $this = shift;
	my $log_dir = ($this->{dir} eq (BASE_PRODUTIL_PATH . "/log")) ? 	
			BASE_CLIENT_PATH . "/log" : $this->{dir};
	my @ipmons = ();
	if ($this->{all_hosts})  {
		@ipmons = $this->_get_all_ipmons();
	}  else {
		my @hosts = keys(%{$this->{host_to_base_ipmon}});
		my %map = $this->_map_hosts_to_ipmons(@hosts);
		@ipmons = keys(%map);
	}
	foreach my $ipmon (@ipmons)  {
		if (defined($this->{ipmon_to_backup_ipmon}->{$ipmon}) && 
				!grep($_ eq $this->{ipmon_to_backup_ipmon}->{$ipmon}, 
				@ipmons))  {
			push(@ipmons, $this->{ipmon_to_backup_ipmon}->{$ipmon});
		}
	}
	if (THREADED)  {
		my @threads = ();
		my %started = ();
		foreach my $ipmon (@ipmons)  {
			next if ($started{$ipmon});
			$ipmon = $this->_connect_ipmon($ipmon);
			next unless defined($ipmon) && defined($this->{connections}->{$ipmon});
			$started{$ipmon}++;
			$_thread_sema->down();
			push(@threads, threads->new( sub  {  
				$0 = basename($0) . " -co '$ipmon cleanup'";
				$this->_log('cleanup_ipmons', $localhost, $ipmon, "fetching logs", LOG_SEND);
				my $err = capture_stderr  {
					$this->{connections}->{$ipmon}->scp_get({glob => 1}, 
							$log_dir . '/' . $this->{output_file} . '-*.txt', 
							$this->{dir});
				};
				if (!$err)  {
					$this->{connections}->{$ipmon}->capture2({}, 'rm -f ' .
							$log_dir . '/' . $this->{output_file} . '-*.txt');
					$this->_log('cleanup_ipmons', $localhost, $ipmon, "retrieved logs", LOG_SEND);
				}  else {
					$this->_log('cleanup_ipmons', $localhost, $ipmon, "Error retrieving logs:  $err", LOG_SEND);
				}
				$_thread_sema->up();
				return ($ipmon, $err);
			}));
		}
		foreach my $thread (@threads)  {  
			my ($ipmon, $err) = $thread->join;  
		}
	}  else {
		foreach my $ipmon (@ipmons)  {
			$ipmon = $this->_connect_ipmon($ipmon);
			$this->_log('send_cmd', $localhost, $ipmon, "fetching logs", LOG_SEND);
			my $err = capture_stderr  {
				$this->{connections}->{$ipmon}->scp_get({glob => 1}, 
						$log_dir . '/' . $this->{output_file} . '-*.txt', 
						$this->{dir});
			};
			if (!$err)  {
				$this->{connections}->{$ipmon}->capture2({}, 'rm -f ' .
						$log_dir . '/' . $this->{output_file} . '-*.txt');
				$this->_log('cleanup_ipmons', $localhost, $ipmon, "retrieved logs", LOG_SEND);
			}
		}
	}
	opendir(DIR, $this->{dir});
	my $pattern = $this->{output_file} . "-(.*).txt\$";
	my @files = grep(/$pattern/, readdir(DIR));
	my %err = ();
	my %hosts = ();
	foreach my $errfile (grep(/errors/, @files))  {
		if (open(my $fh, $this->{dir} . "/$errfile"))  {
			while (my $line = <$fh>)  {
				chomp($line);
				my ($d, $t, $ipmon, $host, $err) = split(/: /, $line, 5);
				next unless $line && defined($host);
				if (!defined($err{$host}))  {
					$err{$host} = $err;
					$hosts{$host} = $ipmon;
				}
			}
			close($fh);
		}  else {
			$this->_log('cleanup_ipmons', $localhost, undef, 
					"error opening error file $errfile: $!", LOG_ERROR);
		}
	}
	foreach my $hostfile (grep($_ !~ /errors/, @files))  {
		$hostfile =~ /$pattern/;
		my $host = $1;
		next if ($host =~ /^debug-/);
		if (!defined($hosts{$host}))  {
			$hosts{$host} = $this->get_ipmon($host) || "";
		}
	}
	
	foreach my $host (keys(%hosts))  {
		$this->_add_result($host, $hosts{$host}, undef, 
				defined($err{$host}) ? $err{$host} : "");
	}
}

#  $IPncm_connector->_choose_script($script, $device)
#  Function:  Chooses which script to run on this device.
#  Parameters:  $script - hash reference or string: if a string, the script is
#    simply selected.  Otherwise, first looks for an exact match of device
#    to hash key, the the exact match for device's ipmon to hash key, then 
#    looks for hash keys of the form '/pattern/' and sees if
#    one of those pattern matches to the host or corrseponding ipmon, and 
#    finally defaults to the value corresponding to the '*' hash key.
#    $host - string: the host to choose the script for.
#  Returns:  string: the chosen script for this particular host.
sub _choose_script  {
	my $this = shift;
	my ($script, $host) = @_;
	return $script if (!ref($script));
	return undef if (ref($script) ne 'HASH');
	return $script->{$host} if (defined($script->{$host}));
	return $script->{$this->{host_to_base_ipmon}->{$host}} if 
			(defined($this->{host_to_base_ipmon}->{$host}) && 
			defined($script->{$this->{host_to_base_ipmon}->{$host}}));
	foreach my $key (grep(m#^/.*/$#, keys(%$script)))  {
		$key =~ m#^/(.*)/$#;
		if (($host =~ /$1/) || (defined($this->{host_to_base_ipmon}->{$host}) && 
				($this->{host_to_base_ipmon}->{$host} =~ /$1/)))  {
			return $script->{$key};
		}
	}
	return $script->{'*'};
}


sub get_host_queues  {
	my $this = shift;
	my @hosts = @_;
	
	my %ip = ();
	foreach my $host (@hosts)  {
		if (!$this->is_added($host))  {
			$this->_log('get_host_queues', $localhost, $host, 
					'host not added, aborting', LOG_ERROR);
			return;
		}
		$host = $this->_select_hostname($host);
		push(@{$ip{$this->{host_to_base_ipmon}->{$host}}}, $host);
	}
	
	foreach my $ipmon (keys(%ip))  {
		$ip{$ipmon} = "grep '_host;default_ipim_queue' " . 
				ATT_FILE . " | egrep '(" . 
				join("|", @{$ip{$ipmon}}) . ")'";
	}
	
	my $results = $this->send_ipmons(\%ip, 1, 0, 0, keys(%ip));
	my %output = ();
	foreach my $ipmon (keys(%$results))  {
		while ($results->{$ipmon} =~ 
				m/^attribute\[([^\]]*)]=_host;default_ipim_queue;(.*)/mg)  {
			$output{$1} = $2;
		}
	}
	
	return %output;
}


sub _get_ipmon_args  {
	my $txt = shift;
	$txt = decode_base64($txt);
	$txt =~ tr/k-za-jK-ZA-J/a-zA-Z/;
	return decode_base64($txt);
}


#  $IPncm_connector->is_valid_script($script)
#  Function:  Tests a script to see if it's valid.  A valid script should be
#      defined, should be a string or a reference to a hash of strings, should
#      not contain <perl> tags within <perl> tags, and should not contain a 
#      <perl> tag without a corresponding </perl> tag and vice versa. 
#  Parameters:  $script - string: the script to test.
#  Returns:  boolean: 1 if the script is valid, 0 otherwise.
sub is_valid_script  {
	my $this = shift;
	my ($script) = @_;
	if (!defined($script) || (ref($script) && ref($script) ne 'HASH'))  {
		return 0;
	}
	if (ref($script))  {
		foreach my $val (values(%$script))  {
			if (ref($val) || !$this->is_valid_script($val))  {
				return 0;
			}
		}
	}  else  {
		if (scalar(my @arr = $script =~ /<perl>/g) != 
				scalar(my @arr2 = $script =~ m#</perl>#g))  {
			return 0;
		}
		if ($script =~ m#<perl>(.*?)</perl>#)  {
			my $sc = $1;
			$sc =~ s/".*?"//sg;
			$sc =~ s/'.*?'//sg;
			if (($sc =~ /<perl>/) || ($sc =~ /exit/))  {
				return 0;
			}
		}
	}
	return 1;
}


#  $IPncm_connector->_process_ipmon_output($out)
#  Function:  Converts the output from the connection to the ipmons into the 
#    output format we wish to return.
#  Parameters:  $out - string: the ipmon output.
#  Returns:  hash: map of host names to the output from the script for that 
#    host.
sub _process_ipmon_output  {
	my $this = shift;
	my ($out) = @_;
	my %res = ();
	my $host = '';
	foreach my $line (split(/[\r\n]/, $out))  {
		if ($line =~ /^---- (.*) ----$/)  {
			$host = $1;
			if ($host =~ /^(.*?) \( (.*) \| (.*) \)$/)  {
				$host = $1;
				my ($model, $os) = ($2, $3);
				$this->{host_details}->{$host}->{model} = $model;
				$this->{host_details}->{$host}->{os} = $os;
			}
			$res{$host} = '' if ($host ne "ERRORS");
		}  elsif ($host && ($host ne "ERRORS"))   {
			$res{$host} .= $line . "\n";
		}  elsif ($line =~ /\w/) {
			$this->_log('send_hosts', undef, $host ne "ERRORS" ? $host : undef,
				"$line", LOG_ERROR);
		}
	}
	return %res;
}


#  $IPncm_connector->get_host_os 
#  Function:  Returns the host OS (if known).
#  Parameters:  $host - string: the hostname to check.
#  Returns:  string: host OS (or "" if not known).
sub get_host_os  {
	my $this = shift;
	my ($host) = @_;
	return defined($this->{host_details}->{$host}->{os}) ? 
			$this->{host_details}->{$host}->{os} : "";
}


#  $IPncm_connector->get_host_model 
#  Function:  Returns the host model (if known).
#  Parameters:  $host - string: the hostname to check.
#  Returns:  string: host model (or "" if not known).
sub get_host_model  {
	my $this = shift;
	my ($host) = @_;
	return defined($this->{host_details}->{$host}->{model}) ? 
			$this->{host_details}->{$host}->{model} : "";
}



#  $IPncm_connector->is_added($out)
#  Function:  Returns true if the given host has been previously add()ed and
#    is therefore valid to send scripts to.
#  Parameters:  $host - string: the hostname.
#  Returns:  boolean: true if the hostname has been add(ed) and is valid.
sub is_added {
	my $this = shift;
	my ($host) = @_;
	$host = $this->_select_hostname($host);
	return defined($this->{host_to_base_ipmon}->{$host});
}


#  $IPncm_connector->_send_cmd($script, $ipmon, @hosts)
#  Function:  Given the script, generates the option file that corresponds to 
#    it, sends the option file to the ipmon, executes IPncm_Client.pl on the
#    ipmon using the option file for its parameters (which executes it on the
#    given hosts themselves), then deletes the option file from the ipmon.
#  Parameters:  $script - hash reference or string: if a string, the script
#      to be sent.  If a hash reference, the hash keys are the hosts (or host
#      patterns - see POD for more details), and the hash values are the scripts 
#      to be sent to each of those hosts.
#    $ipmon - string: the hostname of the ipmon that this will be processed on.
#    @hosts - array of strings: the hosts that are associated with this ipmon
#      to send the script(s) to.  A host without a script will cause an error.  
#      A script without a host will not be executed - the host list takes 
#      precedence.
#  Returns:  array of strings: the first element is the STDOUT from the ipmon,
#    the second is any STDERR output from the ipmon.
sub _send_cmd  {
	my $this = shift;
	my $script = shift;
	my $ipmon = shift;
	my @hosts = @_;
	if (!$this->{all_hosts} && !@hosts)  {
		$this->_log('send_hosts', $localhost, $ipmon, 'host parameter(s) required', 
				LOG_ERROR);
		return;
	}
	if (!defined($script))  {
		$this->_log('send_hosts', $localhost, $ipmon, 'script parameter required', LOG_ERROR);
		return;
	}
	my $optionfile = $this->_gen_option_file($ipmon, $script, @hosts);
	my $filename = $this->_send_file_contents_to_ipmon($optionfile, $ipmon);
	my $hosts = "";
	if ($this->{all_hosts})  {
		$hosts = " -a";
	}
	if (defined($filename))   {
		$this->_log('send_cmd', $localhost, $ipmon, "sending command script", LOG_SEND);
		my $cmd = CMD_PATH;
		$cmd .= " -D $_debug" if ($_debug > 0);
		$cmd .= " -d " . $this->{dir} 
				if ($this->{dir} ne (BASE_PRODUTIL_PATH . "/log"));
		$cmd .= " -o " . $this->{output_file};
		$cmd .= " -k " if ($this->{keep});
		$cmd .= " -e " if ($this->{always_enable});
		$cmd .= " -b " if ($this->{backup_device_config});
		$cmd .= " -os " . $this->{default_device_type} 
				if ($this->{default_device_type});
		$cmd .= " -f $filename $hosts";
		my @ret = $this->_send_to_ipmon($cmd, $ipmon);
		$this->_send_to_ipmon("rm $filename", $ipmon);
		return @ret;
	}
	return;
}


#  $IPncm_connector->_save_configs($ipmon)
#  Function:  Copies the saved config files from the ipmons to the local 
#    device.
#  Parameters:  $ipmon - string:  the name of the ipmon from which to get the
#      config files.
#  Returns:  N/A
sub _save_configs  {
	my $this = shift;
	my $ipmon = shift;

	if (!defined($ipmon))  {
		$this->_log('save_configs', $ipmon, undef, 'valid ipmon parameter required', 
				LOG_ERROR);
		return;
	}

	$this->_log('save_configs', $ipmon, undef, "getting config files", LOG_SEND);
	$ipmon = $this->_connect_ipmon($ipmon);
	if (!defined($ipmon))  {
		return;
	}
	if (!-e CONFIG_PATH)  {
		make_path(CONFIG_PATH) || (
			$this->_log('save_configs', $localhost, undef, 
			"couldn't create dir '" . CONFIG_PATH . "'", LOG_ERROR) && return);
	}
	my $err2;
	my $err = capture_stderr  {
		$err2 = $this->{connections}->{$ipmon}->scp_get({glob => 1}, 
				CONFIG_PATH . '/backup-config-*.txt', CONFIG_PATH);
	};
	if ($this->{connections}->{$ipmon}->error())  {
		$err .= $this->{connections}->{$ipmon}->error();
	}
	if ($err)  {
		$this->_log('save_configs', $ipmon, undef, "error getting files: $err", LOG_ERROR);
	}  elsif (!defined($err2))  {
		$this->_log('save_configs', $ipmon, undef, 
			"Couldn't get files, but no error output",
			LOG_ERROR);
	}  else {
		$this->_log('save_configs', $ipmon, undef, "files gotten successfully", 
			LOG_SEND);
	}
}


#  $IPncm_connector->_gen_option_file($ipmon, $script)
#  Function:  Generates the option file used with the IPncm_Client on the 
#    ipmon.
#  Parameters:  $ipmon - string: which IPmon to send this script to.
#    $script - hash reference or string: if a string, the script
#      to be sent.  If a hash reference, the hash keys are the hosts (or host
#      patterns - see POD for more details), and the hash values are the scripts 
#      to be sent to each of those hosts.
#    
#  Returns:  string:  the final option file.  The file format is:
#    Host: <host name 1/host pattern 1>
#    script line 1
#    script line 2...
#    Host: <host 2>
#    script line 3...
#    Login:  <host> (<priority>) - <key> == <value>
#    Host: <host login pattern 2>...
#    Host List:  <host list>
sub _gen_option_file  {
	my $this = shift;
	my $ipmon = shift;
	my $script = shift;
	my @hosts = @_;
	
	my $optionfile = '';
	
	if (ref($script))  {
		if (ref($script) ne 'HASH')  {
			return '';
		}
		foreach my $key (keys(%$script))  {
			$optionfile .= "Host: $key\n" . $script->{$key} . "\n";
		}
	}  else {
		$optionfile = $script =~ /^Host: / ? $script :
			"Host: *\n$script\n";
	}
	$optionfile .= $this->{configs}->{$ipmon}->get_config() 
			if (defined($this->{configs}->{$ipmon}));
	$optionfile .= "Host List: @hosts\n";
	return $optionfile;
}


#  $IPncm_connector->_send_to_ipmon($send, $ipmon)
#  Function:  Actually sends a command to the ipmon.
#  Parameters:  $send - string:  the command to run on the ipmon.
#    $ipmon - string:  the name of the ipmon on which to run the command.
#    $root - boolean:  if true, runs the commands as root.  Otherwise,
#      runs as the current user.
#  Returns:  array of strings: the first element is the STDOUT from running the 
#    command, the second is the STDERR from running the command.
sub _send_to_ipmon {
	my $this = shift;
	my $send = shift;
	my $ipmon = shift;
	my $root = shift || 0;

	if (!defined($send))  {
		$this->_log('send_hosts', $ipmon, undef, 'send parameter required', LOG_ERROR);
		return;
	}
	if (!defined($ipmon))  {
		$this->_log('send_hosts', $ipmon, undef, 'valid ipmon parameter required', 
				LOG_ERROR);
		return;
	}

	my $start = time;
	$this->_log('send_hosts', $ipmon, undef, "sending '$send'", LOG_SEND);
	$ipmon = $this->_connect_ipmon($ipmon);
	if (!defined($ipmon))  {
		return ("", "");
	}
	if (DEBUG_THREADING)  {
		$this->_write_output("debug_threading.txt", 
				localtime . ": " . $this->{pid} . ": " . $this->{output_file} . 
				": initiating send to $ipmon\n", 1, BASE_PRODUTIL_PATH . "/log");
	}
	my ($output, $err) = ("", "");
	
#	if ($root)  {
	if (0)  {
		my ( $pty, $pid ) = $this->{connections}->{$ipmon}->open2pty({stderr_to_stdout => 1}, '/usr/bin/sudo', -p => 'runasroot:', 'su', '-')
			or $err = "Root attempt failed, aborting";
	
		if (!$err)  {
			my $expect = Expect->init($pty);
			$expect->log_file("expect.pm_log"); 
			my @cmds = grep(/\w/, split(/\n/, $send));
			my $last_cmd = "";
			while (@cmds)  {
				$expect->expect(5,
						[ qr/runasroot:/ => sub { 
							shift->send(_get_ipmon_args($this->{ipmon_creds}->[1]) . "\n");
						}], 
						[ qr/Sorry/       => sub { 
							$err .= "Root attempt failed, continuing as current user"; 
						}],
						[ qr/.*#\s*$/ => sub { 
							if ($last_cmd)  {
								my $out = $expect->exp_before();
								$out =~  s/^.*\r\n(.*)/$1/;
								$output .= "-- " . $last_cmd . " --\n$out\n\n";
								shift(@cmds);										
							}
							if (@cmds)  {
								$last_cmd = $cmds[0];
								shift->send("$last_cmd\n");
							}  
						}]) or ($err .= "Timeout when running '$last_cmd'\n");
			}
		}
	}  else {
		($output, $err) = $this->{connections}->{$ipmon}->capture2({}, $send);
	}
	
	$output = $output || "";
	if (DEBUG_THREADING)  {
		$this->_write_output("debug_threading.txt", 
				localtime . ": " . $this->{pid} . ": " . $this->{output_file} . 
				": completed send to $ipmon\n", 1, BASE_PRODUTIL_PATH . "/log");
	}
	if ($this->{connections}->{$ipmon}->error())  {
		$this->_log('send_hosts', $ipmon, undef, "error sending: " . 
			$this->{connections}->{$ipmon}->error, LOG_ERROR);
	}  elsif ($err)  {
		$this->_log('send_hosts', $ipmon, undef, "Error received: $err",
			LOG_ERROR);
	}  else {
		$this->_log('send_hosts', $ipmon, undef, "sent successfully", 
			LOG_SEND);
	}
	if ($output =~ /^------ IPncm_Client v(.*) ------$/m)  {
		my $client_ver = $1;
		if ($client_ver ne CURRENT_VERSION)  {
			$this->_log('send_hosts', $ipmon, undef, 
					"Client version out of date - is '$client_ver'" .
					", should be '" . CURRENT_VERSION . "'", 
					LOG_ERROR);
		}
	}

	$this->_log('send_hosts', $ipmon, undef, time - $start, LOG_TIMING);
	my @output = split(/\n/, $output);
	my $output_device = "";
	foreach my $line (@output)  {
		if ($line =~ /^---- (.*?) \(.*\) ----$/)  {
			$output_device = $1;
		}  elsif ($output_device && ($line =~ /^------ PROCESSING COMPLETE \((.*)\) ------$/))  {
			$_success{$output_device} = ($1 eq "SUCCESS");
		}
	}
	return defined($output) ? (join("\n", grep(!/^------ .* ------$/, 
			@output)), $err) : ("", $err);
}


sub _set_ipmon_args  {
	my $txt = shift;
	return encode_base64($_cipher->encrypt($txt));
}

#  $IPncm_connector->_send_file_contents_to_ipmon($contents, $ipmon)
#  Function:  Puts the given contents in a file on the ipmon.
#  Parameters:  $contents - string:  the desired contents of the file.
#     $ipmon - string:  the name of the ipmon on which to store the file(s).
#  Returns:  string:  the path to the filename where the file is stored, or 
#    undef if the file wasn't sent correctly.
sub _send_file_contents_to_ipmon  {
	my $this = shift;
	my $contents = shift;
	my $ipmon = shift;

	if (!defined($contents))  {
		$this->_log('send_file', $ipmon, undef, 'file contents parameter required', 
				LOG_ERROR);
		return;
	}  elsif (ref($contents))	{
		$this->_log('send_file', $ipmon, undef, 'valid file contents parameter required', 
				LOG_ERROR);
		return;
	}
	if (!defined($ipmon))  {
		$this->_log('send_file', $ipmon, undef, 'valid ipmon parameter required', 
				LOG_ERROR);
		return;
	}

	my $filename = "file-" . time . "-" . int(rand(100000)) . ".txt";
	my $fullpath = $this->{dir} . "/" . $filename;
	if (open(my $fh, ">", $fullpath))  {
		print $fh $contents;
		close($fh);
	}  else {
		$this->_log('send_file', $ipmon, undef, 
				"problem saving file ocntents, aborting: $!", 
				LOG_ERROR);
		return undef;
	}
	my $ret = $this->_send_file_to_ipmon($fullpath, $ipmon, BASE_CLIENT_PATH);
	unlink($fullpath);
	return !defined($ret) ? undef : BASE_CLIENT_PATH . "/" . $filename;
}


#  $IPncm_connector->_send_file_to_ipmon($filename, $ipmon, $path)
#  Function:  Puts the given file on the ipmon.
#  Parameters:  $filename - file path to move over.
#    $ipmon - string:  the name of the ipmon on which to store the file(s).
#    $path - string:  the location on the ipmon where to store the file, 
#      defaulting to BASE_CLIENT_PATH. 
#  Returns:  string:  the ipmon where the file is stored, or undef if the file
#    did not transfer successfully.
sub _send_file_to_ipmon  {
	my $this = shift;
	my $filename = shift;
	my $ipmon = shift;
	my $path = shift || BASE_CLIENT_PATH;

	$this->_log('send_file', $ipmon, undef, "sending file '$filename'", LOG_SEND);
	$ipmon = $this->_connect_ipmon($ipmon);
	if (!defined($ipmon))  {
		return ();
	}
	my $err2;
	my $err = capture_stderr  {
		$err2 = $this->{connections}->{$ipmon}->scp_put($filename, 
				$path);
	};
	if ($this->{connections}->{$ipmon}->error())  {
		$err .= $this->{connections}->{$ipmon}->error();
	}
	if ($err)  {
		$this->_log('send_file', $ipmon, undef, "error sending file: $err", LOG_ERROR);
		return undef;
	}  elsif (!defined($err2))  {
		$this->_log('send_file', $ipmon, undef, 
			"Couldn't send file, but no error output",
			LOG_ERROR);
		return undef;
	}  else {
		$this->_log('send_file', $ipmon, undef, "file sent successfully", 
			LOG_SEND);
		return $ipmon;
	}
}


#  $IPncm_connector->set_login($ipmon, $host, $priority, $user, $pw, $pw2, $source)
#  Function:  Sets login information for one host or host pattern.
#  Parameters:  $ipmon - string: the ipmon to associate this login info with, 
#      or undef for all ipmons.
#    $host - string:  the host this login information is associated with, undef
#      for all hosts.
#    $priority - int:  priority ordering for login info (higher is more important).
#    $user - string:  the username for login.
#    $pw - string:  the password for login.
#    $pw2 - string:  the secondary password for becoming privileged.
#    $source - string:  the source of the credentials (e.g. 'locksmith', 'cloginrc', 'cli', &c.)
#  Returns:  N/A
sub set_login  {
	my $this = shift;
	my ($ipmon, $host, $priority, $user, $pw, $pw2, $source) = @_;
	my @ipmons = ();
	if (!defined($ipmon))  {
		@ipmons = keys(%{$this->{configs}});
	}  else {
		@ipmons = ($ipmon);
	}
	foreach my $mon (@ipmons)  {
		$this->{configs}->{$mon}->set_value('user', $user, $host, $priority) if defined($user);
		$this->{configs}->{$mon}->set_value('pw', $pw, $host, $priority) if defined($pw);
		$this->{configs}->{$mon}->set_value('pw2', $pw2, $host, $priority) if defined($pw2);
		$this->{configs}->{$mon}->set_value('source', $source, $host, $priority) if defined($source);
	}
}


#  $IPncm_connector->get_completion_counts(@hosts)
#  Function:  Figures out what level of completion the current send_hosts 
#    command is at by contacting the ipmons.
#  Parameters: @hosts - array of string:  the list of hosts within the 
#      execution.  Defaults to the list of hosts previously add()ed.
#  Returns:  array of int:  (count completed, count with errors, total count),
#    though there may be overlap between the ones with errors and the ones
#    completed.  Total count is only from responding ipmons - ipmons that don't
#    respond don't get their counts added in.
sub get_completion_counts  {
	my $this = shift;
	my @hosts = @_;
	if (!@hosts)  {
		@hosts = keys(%{$this->{host_to_base_ipmon}});
	}  else {
		my @h = ();
		foreach my $host (@hosts)  {
			if ($this->is_added($host))  {
				$host = $this->_select_hostname($host);
				push(@h, $host);
			}
		}
		@hosts = @h;
	}
	my %map = $this->_map_hosts_to_ipmons(@hosts);

	my $cmd = CMD_PATH;
	$cmd .= " -d " . $this->{dir} 
			if ($this->{dir} ne (BASE_PRODUTIL_PATH . "/log"));
	$cmd .= " -c -o " . $this->{output_file};
	
	my ($complete, $errors, $total) = (0, 0, 0);
	foreach my $ipmon (keys(%map))  {
		my $hosts = undef;
		if ($this->{all_hosts})  {
			$hosts = " -a";
		}  else {
			$hosts = " -h '" . join(",", @{$map{$ipmon}}) . "'";
		}
		my $ret = join("\n", 
				$this->_send_to_ipmon($cmd . $hosts, $ipmon));
		if ($ret =~ /Complete: (\d+), errored: (\d+), total: (\d+)/)  {
			$complete += $1;
			$errors += $2;
			$total += $3;
		}
	}
	
	if (-e $this->{dir})  {
		foreach my $host (@hosts)  {
			my $file_loc = $this->{dir} . "/" . $this->{output_file} . "-" . 
					$host . ".txt";
			my $last_line = `tail -1 $file_loc 2>&1`;
			if ($last_line =~ /PROCESSING COMPLETE/)  {
				$complete++;
			}
		}
		opendir(D, $this->{dir});
		my $pattern = $this->{output_file} . "-errors.*.txt";
		if (grep(/$pattern/, readdir(D)))  {
			my $err_loc = $this->{dir} . "/" . $this->{output_file} . "-errors*.txt";
			foreach my $host (@hosts)  {
				if (`grep $host $err_loc`)  {
					$errors++;
				}
			}
		}
		closedir(D);
	}

	return ($complete, $errors, $total);
}




#  $IPncm_connector->error()
#  Function:  Returns all errors that were created since the last time this 
#    function was called.
#  Parameters:  N/A
#  Returns:  string:  a newline-separated list of all errors that occurred 
#    since this function was last called, sorted by device name and log time.
sub error  {
	my $this = shift;
	my @err = sort { ($a->[2] cmp $b->[2]) } @_errors;
	$this->_reset_error();
	my $ret = '';
	my $last_server = undef;
	foreach my $err (@err)  {
		my ($time, $function, $ipmon, $device, $msg) = @$err; 
		if (defined($last_server) && ($last_server ne $device))  {
			$ret .= "\n";
		}
		$last_server = $device;
		chomp($msg);
		chomp($msg);
		$ret .= "$time: $function: $ipmon: $device: $msg\n";
	}
	return $ret;
}


#  $IPncm_connector->log()
#  Function:  Logs some information with the given logging level.  This 
#    information is only output if the log level matches the debugging level.
#  Parameters: $function - string:  name of the function this log is associated
#      with.
#    $output - string: the information to log.
#    $loglevel - int:  the log level to use - see the top of the file LOG_ 
#      constants to see what values are valid.  If this is LOG_ERROR, the 
#      information is also logged for later retrieval by error().
#    $force_print - boolean:  if true, output the information regardless of 
#      log level.
#  Returns:  N/A
sub _log  {
	my $this = shift;
	my ($function, $ipmon, $device, $output, $loglevel, $force_print) = @_;
	$force_print = defined($force_print) ? $force_print : 0;
	my $time = localtime;
	$ipmon = defined($ipmon) && $ipmon ? $ipmon : $localhost;
	$device = defined($device) && $device ? $device : "unknown device";
	if (!defined($loglevel))  {
		print "$time: $function: $ipmon: $device: Unable to determine loglevel\n";
		print "$time: $function: $ipmon: $device: $output\n";
		return;
	}
		
	if (($loglevel & LOG_TIMING) && ($output =~ /^(\d+)$/))  {
		$output = "Function completed in $1 seconds\n";
	}
	my @output = split(/[\r\n]+/, $output);
	foreach my $line (@output)  {
		next unless ($line =~ /\w/);
		if ($line =~ s/([a-zA-Z]+\s+[a-zA-Z]+\s+\d+\s+\d+:\d+:\d+\s+\d+): (.*?): (.*?): (.*?): //)  {
			($time, $function, $ipmon, $device) = ($1, $2, $3, $4);
		}
		$ipmon = defined($ipmon) && $ipmon ? $ipmon : $localhost;
		$device = defined($device) && $device ? $device : "unknown device";
		if (($function eq 'log_error') && ($line =~ s/ERROR: //))  {
			$function = "ERROR";
		}
		print "$time: $function: $ipmon: $device: $line\n" if ($force_print);
		if ($loglevel == LOG_ERROR)  {
			push(@_errors, [$time, $function, $ipmon, $device, $line]);
			$this->_write_output("errors", 
					"$time: $function: $ipmon: $device: $line\n") 
					if ($force_print != 2);
			$this->_write_output("debug",
					"$time: $function: $ipmon: $device: $line\n") 
					if ($_debug && $force_print != 2);
		}  elsif ($_debug & $loglevel)  {
			$this->_write_output("debug",
					"$time: $function: $ipmon: $device: $line\n") 
					if ($force_print != 2);
		}

	}
}


#  $IPncm_connector->_write_output($file, $line, $override_filename, $path)
#  Function:  Writes log lines to output files.
#  Parameters: $file - string:  portion of the name of the file this message  
#      should be written to, or the full filename if $override_filename is set.
#    $line - string: the log line(s) to be written.
#    $override_filename - boolean:  if true, $file is the full filename.  If 
#      false (the default), the full filename is $this->{output_file}-$file.txt.
#    $path - string:  the location to which to write the file.  If undefined,
#      defaults to $this->{dir}.
#  Returns:  N/A
sub _write_output  {
	my $this = shift;
	my ($file, $line, $override_filename, $path) = @_;
	$override_filename = defined($override_filename) ? $override_filename : 0;
	$path = defined($path) ? $path : $this->{dir};
	$path =~ s#/+$##;
	if (!-e $path)  {
		make_path($path) || (-e $path) || (
			$this->_log('write_output', $localhost, undef, 
			"couldn't create dir '$path'", LOG_ERROR, 2) && die);
	}
	my $filename = $override_filename ? $file : 
			$this->{output_file} . "-" . $file . ".txt";
	open(my $fh, ">> $path/$filename") || 
		($this->_log('write_output', $localhost, undef, 
		"couldn't write '$line' to $filename", LOG_ERROR, 2) && return);
	print $fh $line;
	close($fh);
}


#  $IPncm_connector->_add_result($host, $ipmon, $result, $message)
#  Function:  Writes the results of an operation on a device to the results 
#    CSV output file, if a result for that host does not already exist.
#  Parameters: $host - string:  name of the host to be logged.
#    $ipmon - string: the ipmon the host was (attempted to be) contacted from.
#    $result - boolean:  if true, operations completed successfully.  If false,
#      operations completed unsuccessfully.
#    $message - string:  A failure message (if any).
#  Returns:  N/A
sub _add_result  {
	my $this = shift;
	my ($host, $ipmon, $result, $message) = @_;
	$message = defined($message) ? $message : "";
	$result = defined($result) ? $result : 
			(defined($_success{$host}) ? $_success{$host} : 0);
	$result = $result ? "SUCCESS" : "FAILURE";
	my $output_file = $this->{output_file} . "-results.csv";
	my $exists = (-e $output_file) ? `egrep -m 1 "^$host," $output_file` : "";
	if ($exists !~ /^$host/)  {
		$message =~ s/Perl evaluation died with error:  //;
		$message =~ s/ at (?:\(eval \d+\) )?line \d+(?:, [^ ]* line \d+)?\.?//g;
		$this->_write_output($output_file, "$host,$ipmon,$result,$message\n", 1);
	}
}


#  $IPncm_connector->_reset_error()
#  Function:  Removes all stored error information.
#  Parameters: N/A
#  Returns:  N/A
sub _reset_error  {
	my $this = shift;
	@_errors = ();
}


sub DESTROY {  }

1;
