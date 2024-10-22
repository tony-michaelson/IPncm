#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

package IPncm_Client;

use forks;
use strict;
use warnings;
use sort 'stable';

use Capture::Tiny 'capture_stderr';
use Crypt::CBC;
use Data::Dumper;
use Exporter;
use File::Basename;
use File::Path qw(make_path);
use FindBin qw($Bin);
use MIME::Base64;
use MIME::Lite;
use Net::Appliance::Session;
use Net::OpenSSH;
use Scalar::Util 'blessed';
use Sys::Hostname;
use Thread::Semaphore;

use CLoginConfig;

use vars qw($VERSION);
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(LOG_CONN LOG_SEND LOG_TIMING LOG_CISCO LOG_ALL);
our %EXPORT_TAGS = (LOG => [qw(LOG_CONN LOG_SEND LOG_TIMING LOG_CISCO 
		LOG_ALL)]);

use constant BASE_PATH => (-e "$Bin/lib/IPncm_Client.pm" ? $Bin : 
		(-e "$Bin/../lib/IPncm_Client.pm" ? "$Bin/.." : 
		"/home/BASE_USER/IPncm_Client"));
use lib BASE_PATH . "/lib";
use Constants;

my $mode = (stat(BASE_PATH . "/lib/Constants.pm"))[2];
if (($mode & 07777) != 0400)  {
	die "ERROR!  Constants.pm does not have 0400 permissions! Aborting!";
}

$VERSION     = CURRENT_VERSION;

use constant PB_PATH => BASE_CLIENT_PATH . '/phrasebooks';
use constant CONFIG_PATH => BASE_CLIENT_PATH . '/saved_configs';
use constant RUNSCRIPT_PATH => BASE_CLIENT_PATH . '/RunScripts';
use lib RUNSCRIPT_PATH;

use constant SNMP_CACHE => BASE_CLIENT_PATH . '/log/snmp_cache.txt';
use constant SNMP_CACHE_LOCK => BASE_CLIENT_PATH . '/log/snmp_cache.lock';

# Creates debug output from IPncm_Client. 
my $_debug = 0;

# Semaphore for threading.
my $_thread_sema :shared;
$_thread_sema = new Thread::Semaphore(DEFAULT_MAX_CONNECTIONS);

# Semaphore for blocking client connections.
my $_blocker_sema :shared;
$_blocker_sema = new Thread::Semaphore();

my $_abort_execution :shared;
$_abort_execution = 0;

# Error log variable
my @_errors :shared;
@_errors = ();

my $local_ipmon = hostname;
$local_ipmon =~ s/\.(?:(?:ip-soft|Company|ipcenter)\.(?:net|com))//;

#  Hash for storing success / failure for devices.
my %_success :shared;
%_success = ();

#  IPncm_Client->debug($level)
#  Function:  Sets the debug log level for this module.
#  Parameters:  $level - int:  from the LOG_ constants above, selects what 
#      types of log information gets output - may be anded together.  Note that 
#      LOG_ERROR messages are always printed if the log level is any value.
#  Returns:  N/A
sub debug  {
	my $class = shift;
	$_debug = shift;
}

#  IPncm_Client->new(@hosts)
#  Function:  Creates a new IPncm_Client and adds the given @hosts 
#    to it (though those may be added later with add()).
#  Parameters:  @hosts - array of strings: end devices to add to the connector.
#  Returns:  IPncm_Client: The new IPncm_Client object.
sub new  {
	my $this = shift;
	my @hosts = @_;

	my $class = ref($this) || $this;
	my $self = {
		host_map => {},
		config => CLoginConfig->new(),
		dir => BASE_CLIENT_PATH . '/log',
		keep => 0,
		keep_connection_open => 0,
		output_file => 'output-' . time,
		broken_devices => ['netfxsgtw5.charlesriverlab', 'ns-1-westlake-baxter-com---one-baxter-way---critical.baxter', ],
		always_enable => 0,
		backup_device_config => 0,
		produtils => [],
		default_device_type => ($local_ipmon =~ /thd/ ? "thd" : "ios"),
		command_result => 0,
		is_cue => 0,
	};

	bless $self, $class;

	$self->_get_config();
	$self->add(@hosts);
	
	return $self;
}
		

#  $IPncm_client->set_max_connections($limit)
#  Function:  Sets the maximum number of simultaneous devices that may be 
#    accessed.  Each device has its own thread when being called.
#  Parameters:  $limit - int: maximum count.
#  Returns:  N/A
sub set_max_connections  {
	my $this = shift;
	my ($limit) = @_;
	if (!defined($limit) || ($limit !~ /^\d+$/) || ($limit <= 0) || 
			($$_thread_sema == $limit))  {
		return;
	}  elsif ($$_thread_sema > $limit)  {
		$_thread_sema->down_force($$_thread_sema - $limit)
	}  else  {
		$_thread_sema->up($limit - $$_thread_sema);
	}
}


#  $IPncm_client->get_max_connections()
#  Function:  Gets the current maximum number of simultaneous devices that may be 
#    accessed.
#  Parameters:  N/A
#  Returns:  int:  current maximum.
sub get_max_connections  {
	my $this = shift;
	return $$_thread_sema;
}


#  $IPncm_client->_get_config()
#  Function:  Gets the configuration from the local .cloginrc file and adds it 
#    to the login information configuration (see CLoginConfig).
#  Parameters:  N/A
#  Returns:  N/A
sub _get_config  {
	my $this = shift;

	local $/;
	my $fh = undef;
	if (!open($fh, CLOGIN_FILE))  { 
		$this->_log('get_config', undef, "Unable to open clogin file: $!", 
				LOG_CONN);
	}  else {
		my $config = <$fh>;
		close($fh);
		$this->{config}->parse_config($config, PRIORITY_CLOGIN_IPMON);
	}
}

my %connected :shared;
%connected = ();

#  $IPncm_client->send_hosts($script, @hosts)
#  Function:  Processes the script on the given hosts, creating a thread for
#    each host contacted (limited by $conn->set_max_connections(), defaulting
#    to 50).
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
		@hosts = keys(%{$this->{host_map}});
	}  else {
		foreach my $host (@hosts)  {
			$host = lc($host);
			if (!$this->is_added($host))  {
				$this->_log('send_hosts', $host, 
						"not added to connector, aborting", LOG_ERROR);
				return;
			}
		}
	}
	if (!$this->is_valid_script($script))  {
		$this->_log('send_hosts', undef, 'invalid script being sent, aborting', 
				LOG_ERROR);
		return;
	}
	
	$this->_log('send_hosts', $local_ipmon, 'preparing to send', LOG_SEND);
	my %responses = ();
	
	my $start = time;
	my %threads = ();
	
	foreach my $host (@hosts)  {
		$this->_log('send_hosts', $host, "waiting for semaphore", 
				LOG_SEND);
		my $host_script = $this->_choose_script($script, $host);
		if (!defined($host_script))  {
			$this->_log('send_hosts', $host, 'No script being sent', 
					LOG_ERROR);
			next;
		}
		$responses{$host} = '';
		$_thread_sema->down();
		delete($connected{$host});
		$threads{$host} = [ time, threads->new( sub  {  
			$0 = basename($0) . " -co '$host script execution'";
			$this->_log('send_hosts', $host, "sending", LOG_SEND);
			my $out = $this->_send_host($host_script, $host, 1);
			my @output = ($this->{host_map}->{$host}->{model}, $out);
			if (!$$_blocker_sema)  {
				$_blocker_sema->up();
			}
			$_thread_sema->up();
			return @output;
		})];
	}
	while (%threads)  {
		sleep 5;
		foreach my $host (keys(%threads))  {  
			my ($start_time, $thread) = @{$threads{$host}};
			if ($thread->is_joinable())  {
				delete($threads{$host});
				my ($model, $output) = $thread->join;  
				if (defined($model))  {
					$this->{host_map}->{$host}->{model} = $model;
					$responses{$host} = $output;
				}  else  {
					$this->_log('send_hosts', $host, 
							"thread terminated prematurely - " . (defined($output) ? 
							"output is '$output;" : "no output"), LOG_ERROR);
				}
			}  elsif (!defined($connected{$host}) &&
						(time - $start_time > CONNECTION_TIMEOUT_TIME))  {
				delete($threads{$host});
				$thread->detach();
				$this->_log('send_hosts', $host, 
						"Aborting due to connection timeout", LOG_ERROR);
			}
		}
		
	}

	$this->_clear_output();
	$this->_log('send_hosts', undef, time - $start, LOG_TIMING);
	return \%responses;
}


#  $IPncm_client->is_valid_script($script)
#  Function:  Tests a script to see if it's valid.  A valid script should be
#      defined, should be a string or a reference to a hash of strings, should
#      not contain <perl> tags within <perl> tags, and should not contain a 
#      <perl> tag without a corresponding </perl> tag and vice versa.   It 
#      also should not contain an "exit()" call.
#  Parameters:  $script - string: the script to test.
#  Returns:  boolean: 1 if the script is valid, 0 otherwise.
#  TODO:  Have valid return messages so we know where the problem is.
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


#  $IPncm_client->_choose_script($script, $host)
#  Function:  Chooses which script to run on this host.
#  Parameters:  $script - hash reference or string: if a string, the script is
#    simply selected.  Otherwise, first looks for an exact match of host
#    to hash key, then looks for hash keys of the form '/pattern/' and sees if
#    one of those pattern matches to the host, and finally defaults to the 
#    value corresponding to the '*' hash key.
#    $host - string: the host to choose the script for.
#  Returns:  string: the chosen script for this particular host.
sub _choose_script  {
	my $this = shift;
	my ($script, $host) = @_;
	my $ret = undef;
	if (ref($script))  {
		return undef if (ref($script) ne 'HASH');
		if (defined($script->{$host}))  {
			$ret = $script->{$host};
		}  else  {
			foreach my $key (grep(m#^/.*/$#, keys(%$script)))  {
				$key =~ m#^/(.*)/$#;
				if ($host =~ /$1/)  {
					$ret = $script->{$key};
					last;
				}
			}
			if (!defined($ret))  {
				$ret = $script->{'*'};
			}
		}
	}  else  {
		$ret = $script;
	}
	return $ret;
}


#  $IPncm_client->is_added($host)
#  Function:  Returns true if this host has been added to this connector.
#  Parameters:  $host - string: the hostname to check.
#  Returns:  boolean: has this hostname been added?
sub is_added {
	my $this = shift;
	my ($host) = @_;
	return defined($host) && defined($this->{host_map}->{$host});
}

#  $IPncm_client->is_cue($host)
#  Function:  Returns true if this host is a CUE-type host.
#  Parameters:  $host - string: the hostname to check.
#  Returns:  boolean: is this host CUE?
sub is_cue  {
	my $this = shift;
	my ($host) = @_;
	return $this->{is_cue} || (defined($this->{host_map}->{$host}->{is_cue}) && 
			$this->{host_map}->{$host}->{is_cue});
}

#  $IPncm_client->is_wlc($host)
#  Function:  Returns true if this host is a WLC-type host.
#  Parameters:  $host - string: the hostname to check.
#  Returns:  boolean: is this host WLC?
sub is_wlc  {
	my $this = shift;
	my ($host) = @_;
	return (defined($this->{host_map}->{$host}->{personality}) && 
			($this->{host_map}->{$host}->{personality} eq 'wlc')) || 
			($host =~ m/wlc/i);
}

#  $IPncm_client->is_unix($host)
#  Function:  Returns true if this host is *nix-based host.
#  Parameters:  $host - string: the hostname to check.
#  Returns:  boolean: is this host *nix?
sub is_unix  {
	my $this = shift;
	my ($host) = @_;
	return $this->{host_map}->{$host}->{personality} eq 'bash';
}


#  $IPncm_client->get_host_os 
#  Function:  Returns the host OS (if known).
#  Parameters:  $host - string: the hostname to check.
#  Returns:  string: host OS (or "" if not known).
sub get_host_os  {
	my $this = shift;
	my ($host) = @_;
	return defined($host) && defined($this->{host_map}->{$host}->{os}) ? 
			$this->{host_map}->{$host}->{os} : "";
}


#  $IPncm_client->get_host_model 
#  Function:  Returns the host model (if known).
#  Parameters:  $host - string: the hostname to check.
#  Returns:  string: host model (or "" if not known).
sub get_host_model  {
	my $this = shift;
	my ($host) = @_;
	return defined($host) && defined($this->{host_map}->{$host}->{model}) ? 
			$this->{host_map}->{$host}->{model} : "";
}


#  $IPncm_client->get_host_feature_set
#  Function:  Returns the host feature set (if known).
#  Parameters:  $host - string: the hostname to check.
#  Returns:  string: host feature set (or "" if not known).
sub get_host_feature_set  {
	my $this = shift;
	my ($host) = @_;
	return defined($host) && defined($this->{host_map}->{$host}->{feature_set}) ? 
			$this->{host_map}->{$host}->{feature_set} : "";
}


#  $IPncm_client->_connect($host)
#  Function:  Attempts to create a Net::Appliance::Session connection to this
#    host.  Retries up to 5 times with a 60-second timeout for each attempt.
#  Parameters:  $host - string: the hostname to connect to.
#  Returns:  Net::Appliance::Session: the connection object for the connection
#    to this host.
sub _connect  {
	my $this = shift;
	my ($host) = @_;
	if (!$this->is_added($host))  {
		$this->_log('connect', $host, "not added, aborting", LOG_ERROR);
		return;
	}

	if (grep($host eq $_, @{$this->{broken_devices}}))  {
		$this->_log('connect', $host, 
				"Can't connect: host uses incompatible connection mechanism", 
				LOG_ERROR);
		return;
	}

	$this->_log('connect', $host, "Opening connection", LOG_CONN);
	my $start = time;
	my $user = $this->{config}->get_value('user', $host);
	my $pw = $this->{config}->get_value('pw', $host);
	my $pw2 = $this->{config}->get_value('pw2', $host);
	my $credential_source = $this->{config}->get_value('source', $host);
	my $methods = $this->{config}->get_value('method', $host) || "ssh";
	if (!defined($user) || !defined($pw) || !defined($methods))  {
		$this->_log('connect', $host, 
				"no connection info available for this host, aborting", 
				LOG_ERROR);
		return;
	}
	$this->_log('connect', $host, "trying username '$user' from source '$credential_source'", LOG_CONN);
	my $always_enable = $this->{always_enable} || 
			(defined($this->{config}->get_value('autoenable', $host)) && 
			$this->{config}->get_value('autoenable', $host));
	if ((!defined($pw2) || !$pw2) && $always_enable)  {
		$pw2 = $pw;
	}

	my @method = split(/\s+/, $methods);

	my $retries = 5;
	my $err = '';
	my $conn = undef;
	while (!defined($conn) && $retries && defined($method[0]))  {
		try  {
			my $transport = $method[0] eq 'ssh' ? 'SSH' : 
					($method[0] eq 'telnet' ? 'Telnet' : undef);
			if (!defined($method[0]))  {
				shift(@method);
				next;
			}
			$conn = Net::Appliance::Session->new(
					host => $host, 
					personality => $this->{host_map}->{$host}->{personality},
					transport => $transport,
					do_paging => 0,
					add_library => PB_PATH,
					timeout => 60,
					connect_options => { opts => ($transport eq 'SSH' ? 
							['-o LogLevel=ERROR', 
							'-o ServerAliveInterval=60'] : []), },
			);
			if ($_debug & LOG_CISCO)  {
				$conn->set_global_log_at('debug');
			}
			$this->_log('connect', $host, "connection created", LOG_CONN);
			my $debug_fh = IO::File->new(
					($_debug & LOG_CISCO) ? 
					$this->_get_output_file("debug-$host"):
					"/dev/null", "a"
			);
			capture_stderr  {
				$conn->connect({
						username => $user,
						password => $pw,
						SHKC     => 0,
				});
				if ($conn->last_prompt =~ /Closing connection[.]{3}/)  {
					die($conn->last_prompt);
				}
				$this->_log('connect', $host, "authenticated", LOG_CONN);
				if (!$this->is_unix($host))  {
					if ($this->is_cue($host))  {
						$conn->macro('start_cue', {params => [$user, $pw]});
						$conn->nci->transport->ors("\r");
					}
					if (!$this->is_privileged($host, $conn) && 
							defined($pw2) && $pw2)  {
						if ($this->{host_map}->{$host}->{personality} eq 'h3c')  {
							# FOR THE RECORD:  This is only required because, for 
							# some reason, a) Net::Appliance::Session requires a
							# prompt change between privileged / unprivileged mode
							# or else it'll assume you're already in privileged 
							# mode, and b) HP devices don't change prompt.  BAH.
							$conn->macro('begin_privileged', {params => [$pw2]});
						}  else {
							$conn->begin_privileged({ password => $pw2 });
						}
					}
					$conn->do_paging(1);
					$conn->disable_paging();
					if (!$this->is_cue($host))  {
						$conn->cmd('term width 0');
					}
				}
			} stderr => $debug_fh;
			if ($err)  {
				$this->_log('connect', $host, $err, LOG_CONN);
			}
			if (!defined($this->{host_map}->{$host}->{model}))  {
				if (!$this->_set_host_model($host, $conn))  {
					$conn = undef;
				}
			}
			if (defined($conn))  {
				$this->_log('connect', $host, "successful connection", 
						LOG_CONN);
				$connected{$host} = 1;
			}
			$err = '';
		}  catch  {
			$err = $_;
			$conn = undef;
			if (($err =~ /Connection refused/ || 
					$err =~ /write error: filehandle isn't open/) && 
					defined($method[1]))  {
				$this->_log('connect', $host, "failed to connect, trying via " . 
						$method[1], LOG_CONN);
				shift(@method);
				$err = '';
			}  elsif ($err =~ 
					/should be in privileged mode but prompt does not match/)  {
				$this->_log('connect', $host, 
						"permanent privilege failure, aborting", LOG_CONN);
				$retries = 0;
			}  elsif ($err =~ /prompt does not match/)  {
				$this->_log('connect', $host, 
						"authentication failure, aborting", LOG_CONN);
				$retries = 0;
			}  else {
				$this->_log('connect', $host, "failed to connect, retrying:" . 
						$err, LOG_CONN);
				$retries--;
				sleep(1);
			}
		}
	};
	$err =~ s/\n*[\s\.]*(propagated )?at \/home\/.*//s;
	if ($err)  {
		$this->_log('connect', $host, "Can't connect: $err", LOG_ERROR);
	}  elsif (!@method)  {
		$this->_log('connect', $host, 
				"Can't connect: no valid connection methods found", LOG_ERROR);
	}

	$this->_log('connect', $host, time - $start, LOG_TIMING);
	return $conn;
}



#  $IPncm_client->is_privileged($hostname, $conn, $personality)
#  Function:  Given a host connection and personality, attempts to determine 
#    whether the device is in privileged mode or not.  This is trickier than
#    one would hope.
#  Parameters:  $hostname - string: the hostname being tested.
#    $conn - Net::Appliance::Session: the connection to the device
#      being tested.
#  Returns:  boolean:  true if the device is currently privileged, false 
#    otherwise.
sub is_privileged  {
	my $this = shift;
	my ($hostname, $conn) = @_;
	if (!defined($hostname) || !$this->is_added($hostname) || !defined($conn))  {
		return undef;
	}
	
	return 1 if ($this->is_cue($hostname) || $this->is_wlc($hostname));
	
	my $personality = $this->{host_map}->{$hostname}->{personality} || "";
	return 1 if ($personality eq 'junos');
	
	my $priv = 0;
	if ($personality eq 'h3c')  {
		my $out = "";
		my $debug_fh = IO::File->new(
				($_debug & LOG_CISCO) ? 
				$this->_get_output_file("debug-$hostname"):
				"/dev/null", "a"
		);
		capture_stderr  {
			$out = $conn->cmd("display version", { timeout => TIMEOUT_TIME });
		}  stderr => $debug_fh;
		
		$priv = ($out =~ /H3C/);
	}  else {
		$priv = ($conn->last_prompt =~ /#\s*$/);
	}
	$this->_log('connect', $hostname, "Privileged mode is " . 
			($priv ? "enabled" : "disabled"), LOG_CONN);
	return $priv;
}



#  $IPncm_client->_set_host_model($hostname, $conn)
#  Function:  Given a host connection, attempts to determine the model of 
#    device being connected to (and feature set, if possible).
#  Parameters:  $hostname - string: the hostname being tested.
#    $conn - Net::Appliance::Session: the connection to the device 
#      being tested.
#  Returns:  int:  1 if successful, 0 if unsuccessful (which requires a reconnect)
sub _set_host_model  {
	my $this = shift;
	my ($hostname, $conn) = @_;
	
	if (!defined($hostname) || !$this->is_added($hostname) || !defined($conn))  {
		return;
	}
	$this->{host_map}->{$hostname}->{model} = "";
	$this->{host_map}->{$hostname}->{feature_set} = "";
			
	my $personality = $this->{host_map}->{$hostname}->{personality};
	my $debug_fh = IO::File->new(
			($_debug & LOG_CISCO) ? 
			$this->_get_output_file("debug-$hostname"):
			"/dev/null", "a"
	);
	if ($personality eq 'h3c')  {
		my $out = "";
		capture_stderr  {
			$out = $conn->cmd("display version", { timeout => TIMEOUT_TIME });
		}  stderr => $debug_fh;
		if ($out =~ /(.*?) with .*? Processor/)  {
			$this->{host_map}->{$hostname}->{model} = $1;
		}
	}  elsif ($personality eq 'bash')  {
		$this->{host_map}->{$hostname}->{model} = 'Bash';
	}  else {
		my $out = "";
		capture_stderr  {
			$out = $conn->cmd("show version", { timeout => TIMEOUT_TIME });
		}  stderr => $debug_fh;
		if (($personality ne 'asa') && ($out =~ /Cisco Adaptive Security Appliance/))  {
			$this->_log('connect', $hostname, 
					"Personality determined incorrectly, " .
					"resetting to asa", LOG_CONN);
			$this->{host_map}->{$hostname}->{personality} = 'asa';
			return 0;
		}
		if ($out =~ /(.*?) with .*? (?:bytes|[kg]B) of .*?memory/)  {
			$this->{host_map}->{$hostname}->{model} = $1;
		}
		my $image_file = "";
		if ($out =~ /([a-z0-9\-\.]*)\.bin/i)  {
			$image_file = $1;
		}  elsif ($out =~ /"flash\d?:\/(.*?)"/)  {
			$image_file = $1;
		}
		if ($image_file =~ /\-([^\-]*)\-/)  {
			$this->{host_map}->{$hostname}->{feature_set} = $1;
		} 
		if ($this->{host_map}->{$hostname}->{model} =~ /3850/)  {
			$this->{host_map}->{$hostname}->{feature_set} = "universalk9";
		}
	}
	
	return 1;
}



my $_cipher = Crypt::CBC->new( 
	-key => decode_base64('VGhpcyBpcyBub3QgdGhlIGtleS4gTG9vayBhd2F5Lgo='),
	-cipher => 'Blowfish'
);
my $_cur_this = undef;
my $_cur_hostname = undef;
my $_cur_conn = undef;

#  $IPncm_client->_send_host($send, $hostname, $use_cur_conn, $timeout, 
#      $print_header)
#  Function:  Connects to the host, sets the $_cur_conn variable to be the 
#    host connection object, then sends the script to that host and closes the
#    connection.  Intended to be used within its own thread.
#  Parameters:  $send - string: the script to run on the host, a combination
#      of commands and perl code to be eval'd (see POD documentation for 
#      details).
#    $host - string: the hostname to connect to.
#    $use_cur_conn - boolean: whether to set this connection as the main one,
#      where subroutines execute within, defaulting to true.
#    $timeout - int:  the amount of time in seconds  we expect this command to 
#      take, defaulting to TIMEOUT_TIME.
#    $print_header - boolean:  whether or not to print the header block for the 
#      command output, defaulting to true.
#  Returns:  string: the output of the command on the host.
sub _send_host  {
	my $this = shift;
	my ($send, $hostname, $use_cur_conn, $timeout, $print_header) = @_;
	$use_cur_conn = defined($use_cur_conn) ? $use_cur_conn : 1;
	
	$_cur_this = $this;
	$this->_log('send_hosts', $hostname, 'initiating connection', LOG_SEND);
	my $conn = $this->_connect($hostname);
	if (!defined($conn))  {
		#  Errors have already been logged in _connect()
		return;
	}

	if ($use_cur_conn)  {
		$_cur_conn = $conn;
		$_cur_hostname = $hostname;
	}
	
	$this->_log('send_hosts', $hostname, 'initiating send', LOG_SEND);
	if ($this->{backup_device_config})  {
		if (!-e CONFIG_PATH)  {
			make_path(CONFIG_PATH) || (
				$this->_log('save_configs', $local_ipmon, 
				"couldn't create dir '" . CONFIG_PATH . "'", LOG_ERROR) && return);
		}
		if ($this->{host_map}->{$hostname}->{personality} eq 'h3c')  {
			my $output = $this->_send_connected_host($conn, 
				"display current-configuration", 
				$hostname, $timeout, $print_header);
			$output =~ s/.*display current-configuration --//s;
			if (open(my $fh, "> " . CONFIG_PATH . "/backup-config-$hostname.txt"))  {
				print $fh $output;
				close($fh);
			}  else  {
				$this->_log('send_host', $hostname, "Can't save configuration: $!", LOG_ERROR);
			}
		}  else  {
			$this->_send_connected_host($conn, 
				"copy running-config scp://" . _get_ipmon_args(IP_USER) . "\@<IPMON_IP>/" .
				CONFIG_PATH . "/backup-config-<HOSTNAME>.txt", 
				$hostname, $timeout, $print_header);
		}
	}

	my $ret = $this->_send_connected_host($conn, $send, $hostname, $timeout, 
			$print_header);
	$this->_log('send_hosts', $hostname, 'initiating cleanup', LOG_SEND);
	if ($use_cur_conn)  {
		$conn = $_cur_conn;
	}
	if (defined($conn) && !$this->{'keep_connection_open'})  {
		my $debug_fh = IO::File->new(
				($_debug & LOG_CISCO) ? 
				$this->_get_output_file("debug-$hostname"):
				"/dev/null", "a"
		);
		capture_stderr  {
			if ($this->is_cue($hostname))  {
				$conn->macro('end_cue');	
				$conn->nci->transport->ors("\n");
			}
			eval  {
				$conn->close();
			};
			if ($@)  {
				$this->_log('send_hosts', $hostname, 
						"Error closing connection: $@", LOG_SEND);
			}
		}  stderr => $debug_fh;
		$conn = undef;
	}
	if ($use_cur_conn)  {
		$_cur_conn = $_cur_this = $_cur_hostname = undef;
	}
	$this->_log('send_hosts', $hostname, 'send complete', LOG_SEND);
	my $success = !defined($_success{$hostname}) || $_success{$hostname} ? 
			"SUCCESS" : "FAILURE";
	$this->_write_output($hostname, "\n------ PROCESSING COMPLETE ($success) ------\n");
	$ret .= "\n------ PROCESSING COMPLETE ($success) ------\n";
	return $ret;
}

sub close_conn {
	my $this = shift;
	my $conn = $this->_connect($hostname);
	if (defined($conn))  {
		my $debug_fh = IO::File->new(
				($_debug & LOG_CISCO) ? 
				$this->_get_output_file("debug-$hostname"):
				"/dev/null", "a"
		);
		capture_stderr  {
			if ($this->is_cue($hostname))  {
				$conn->macro('end_cue');	
				$conn->nci->transport->ors("\n");
			}
			eval  {
				$conn->close();
			};
			if ($@)  {
				$this->_log('send_hosts', $hostname, 
						"Error closing connection: $@", LOG_SEND);
			}
		}  stderr => $debug_fh;
		$conn = undef;
		return "\n------ CONNECTION CLOSED ------\n";
	}
}

my $_top_perl_block = 0;
my $_last_executed_cmd = undef;
my @_cmd_patterns = (
	['^\s*dele?t?e? ', 'delete'],
	['^\s*copy (.*scp://)', 'copy_scp', _get_ipmon_args(IP_PW)],
	['^\s*copy ([^s])', 'copy_nonscp'],
	['^\s*save config', 'save_config'],
	['^\s*save(.*)', 'save'],
	['^\s*(?:reload|reload ([^c].*?))\s*$', 'reload', ''],
	['^\s*reset system', 'reset_system', ''],
	['^\s*802.11a disable network', '802_11a_disable'],
	['^\s*config 802.11a disable network', 'config_802_11a_disable'],
	['^\s*ssh -l (.*) (.*)$', 'ssh_l'],
	['^\s*end_ssl', 'end_ssl'],
	['^\s*software ', 'software_run'],
	['^\s*config wlan load-balance (.*)', 'config_wlan_load'],
	['^\s*config wlan band-select (.*)', 'config_wlan_band'],
	['^\s*ccn delete ', 'ccn_delete'],
	['^\s*(wr(?:ite)? ?.*)', 'wr_confirm'],
	['^\s*conf(?:ig)? country (.*)', 'conf_country'],
	['^\s*transfer download start', 'transfer_download_start'],
	['^\s*mkdir ', 'mkdir'],
	['^\s*no username ', 'no_username'],
);
my %_spec_macros = (
	'ssh_l' => ['quit', 'end_ssl'],
);
my @_multiline_cmds = (
	'^banner\s+motd\s+(.)',
	'^header\s+motd\s+(.)',
	'(\^C|\cC)',
);
my @_cmd_failure_patterns = (
	['.*', '(Invalid input detected.*|Incomplete command|Unknown command|Incorrect usage.*|Error opening.*|Error reading.*)'],
	['copy', '(Failure when receiving data from the peer|Error copying.*)'],
	['write', '(Authorization failed)'],
	['mac-address', '(Cannot change MAC address)'],
	['ccn copy', '(Given file does not exist|Server denied you to change to the given directory|Script maximum limit exceeded)'],
);
my $_reload_cmd_pattern = '^\s*(?:exit|reload|logout)\s*$';

#  $IPncm_client->_send_connected_host($conn, $send, $hostname, $timeout, 
#      $print_header, $suppress_errors)
#  Function:  Separates the script into pieces to be run directly on the host
#    (separated by newlines) and pieces to be eval'd (separated by 
#    <perl>...</perl> blocks), then executes the first type and eval's the 
#    second.  If a command matches a pattern in %_cmd_patterns, above, it will 
#    be run as a macro rather than a simple command - this is done to allow 
#    commands that require some sort of confirmation response to process 
#    correctly.  The macros may be specified in the local pb files in the 
#    location in the PB_PATH constant.  In the event that a command causes the
#    connection to close (such as an "exit" or a "reload"), if there are more
#    commands to run the connection is re-opened - otherwise, this fact is 
#    simply noted in the output.
#  Parameters:  $conn - Net::Appliance::Session: the object to use to connect
#      with.
#    $send - string: the script to run on the host, a combination
#      of commands and perl code to be eval'd (see POD documentation for 
#      details).
#    $hostname - string: the hostname to run the script on.
#    $timeout - int:  the amount of time in seconds  we expect this command to 
#      take, defaulting to TIMEOUT_TIME.
#    $print_header - boolean:  whether or not to print the header block for the 
#      command output, defaulting to true.
#    $suppress_errors - boolean:  if true, do not output error messages for failures
#      with the command, defaulting to false.
#  Returns:  string: the output of the command on the host.
sub _send_connected_host  {
	my $this = shift;
	my ($conn, $send, $hostname, $timeout, $print_header, $suppress_errors) = @_;
	if (!$this->is_added($hostname))  {
		$this->_log('send_hosts', $hostname, "not added, aborting", LOG_ERROR);
		return;
	}
	$timeout = (!defined($timeout) || $timeout !~ /^(\d+)/ || !int($1)) ? 
		TIMEOUT_TIME : $1;
	$print_header = (defined($print_header)) ? $print_header : 1;
	$suppress_errors = (defined($suppress_errors)) ? $suppress_errors : 0;
	
	my $start = time;
	my $return_output = '';
	my $user = $this->{config}->get_value('user', $hostname);
	my $pw = $this->{config}->get_value('pw', $hostname);
	
	$conn = $this->_connect($hostname) if (!defined($conn));
	$_cur_conn = $conn if (!defined($_cur_conn));
	my $using_cur_conn = (defined($_cur_conn) && ($conn == $_cur_conn));

	my $ip = $this->_get_ipaddr();
	$send =~ s/<IPMON_IP>/$ip/g;
	$send =~ s/<HOSTNAME>/$hostname/g;
	
	my @cmdblocks = split(/(\<\/?perl\>)/, $send);
	my $n = 0;
	my $cur_perl_block = 0;

	while (defined($conn) && @cmdblocks)  {
		my $cmdblock = shift(@cmdblocks);
		if (!$cmdblock || ($cmdblock !~ /\w/))  {
			next;
		}
		if ($cmdblock eq "<perl>")  {
			$_top_perl_block = 1;
			$cur_perl_block = 1;
		}  elsif ($cmdblock eq "</perl>")  {
			$_top_perl_block = 0;
			$cur_perl_block = 0;
		}  elsif ($cur_perl_block)  {
			$this->_log('send_hosts', $hostname, "executing '$cmdblock'", 
					LOG_SEND);
			$n++;
			my $cmd_output = "";
			$cmd_output .= "-- perl block $n --\n" if ($print_header);
			$cmd_output .= $this->_eval_block($cmdblock, $hostname) . "\n" ;
			$return_output .= $cmd_output;
			$this->_write_output($hostname, $cmd_output);
		}  else {
			my @cmds = split(/(?:\n|\\n|\r\n|\\r\\n)/, $cmdblock);
			my $fullcmd = '';
			my $multiline_cmd_delimiter = '';
			while (defined($conn) && @cmds)  {
				my $cmd = shift(@cmds);
				next if (!$cmd);
				if ($cmd =~ /^\s*wri?t?e?\s*era?s?e?\s*$/)  {
					$this->_log('send_hosts', $hostname, 
							"'write erase' command is disabled", 
							LOG_ERROR);
					next;
				}
				if ($fullcmd)  {
					if ($cmd =~ /$multiline_cmd_delimiter/)  {
						$cmd = $fullcmd . $cmd;
						$fullcmd = '';
					}  else  {
						$fullcmd .= $cmd . "\n";
						next;
					}
				}  else  {
					foreach my $patt (@_multiline_cmds)  {
						if ($cmd =~ /$patt/)  {
							my $delim = $1;
							if ($delim =~ /^\W$/)  {
								$delim = "\\$delim";
							}
							if ($cmd !~ /$delim.*$delim/)  {
								$fullcmd .= $cmd . "\n";
								$multiline_cmd_delimiter = $delim;
								last;
							}
						}
					}
					next if ($fullcmd);					
				}
					
				my $cmd_output = '';
				if ($print_header)  {
					$cmd_output .= '-- ' . $cmd . " --\n";
				}
				my $found = 0;
				my $err = "";
				
				eval  {
					my $debug_fh = IO::File->new(
							($_debug & LOG_CISCO) ? 
							$this->_get_output_file("debug-$hostname"):
							"/dev/null", "a"
					);
					foreach my $cmd_patt (@_cmd_patterns)  {
						my $patt = $cmd_patt->[0];

						if ($cmd =~ /$patt/i)  {
							my $macro = $cmd_patt->[1];
							my @opts = @{$cmd_patt}[2 .. $#{$cmd_patt}];
							my $tmpcmd = $cmd;
							$tmpcmd =~ s/$patt//i;
							$tmpcmd = $1 . $tmpcmd if (defined($1) && $1);
							push(@opts, $2) if (defined($2) && $2);
							unshift(@opts, $tmpcmd) if ($tmpcmd);
							foreach my $opt (@opts)  {
								$opt =~ s/\{\{user\}\}/$user/;
								$opt =~ s/\{\{pw\}\}/$pw/;
							}
							$this->_log('send_hosts', $hostname, 
									"sending '$cmd' as macro '$macro'", 
									LOG_SEND);
							capture_stderr  {
								eval  {
									$cmd_output .= $conn->macro($macro, 
										{params => \@opts, 
										timeout => $timeout });
								};
								$err = $@;
							} stderr => $debug_fh;
							if (defined($_spec_macros{$macro}))  {
								my ($spec_end_cmd, $spec_end_macro) = 
										@{$_spec_macros{$macro}};
								my $spec_found = 0;
								foreach my $cur_cmd (@cmds)  {
									if ($cur_cmd eq $spec_end_cmd)  {
										$cur_cmd = $spec_end_macro;
										$spec_found = 1;
										last;
									}
								}
								if (!$spec_found)  {
									push(@cmds, $spec_end_macro);
								}
							}
							$found = 1;
							last;
						}
					}
					if (!$found)  {
						$this->_log('send_hosts', $hostname, 
								"sending '$cmd'", LOG_SEND);
						capture_stderr  {
							eval  {
								$cmd_output .= $conn->cmd($cmd, 
										{ timeout => $timeout });
							};
							$err = $@;
						} stderr => $debug_fh;
					}
					$cmd_output =~ s/\e\[[\d;]*[a-zA-Z]//g;
					chomp($cmd_output);
					chomp($cmd_output);
					$this->{command_result} = SUCCESS;
					foreach my $failure_pattern (@_cmd_failure_patterns)  {
						my ($cmd_patt, $failure_patt) = @$failure_pattern;
						if (($cmd =~ /$cmd_patt/) && ($cmd_output =~ /$failure_patt/))  {
							my $out = $1;
							$out =~ s/[\r\n]/   /g;
							$this->{command_result} = FAIL;
							$this->_log('send_hosts', $hostname, 
									"Error with '$cmd': $out", 
									LOG_ERROR) if (!$suppress_errors);
							last;
						}
					}
					$cmd_output .= "\n\n";
				};
				$err .= $@  if ($@);
				if ($err)  {
					$this->{command_result} = FAIL;
					$this->_log('send_hosts', $hostname, 
							"Error while sending command '$cmd':  $err", 
							LOG_SEND);
					if (($err =~ /filehandle isn't open/) || ($err =~ /input\/output error/i))  {
						my $reload_cmd = '';
						if ($cmd =~ /$_reload_cmd_pattern/)  {
							$reload_cmd = $cmd;
						}  elsif (defined($_last_executed_cmd) && 
								($_last_executed_cmd =~ /$_reload_cmd_pattern/))  {
							$reload_cmd = $_last_executed_cmd;
							unshift(@cmds, $cmd);
						}  else {
							unshift(@cmds, $cmd);
						}
						if (@cmds)  {
							$cmd_output .= "\n'$reload_cmd' caused connection to close, " . 
									"re-opening\n\n" if ($reload_cmd);
							$conn = $this->_connect($hostname);
							$_last_executed_cmd = $reload_cmd;
						}  else {
							$cmd_output .= "\n'$reload_cmd' caused connection to close"
								if ($reload_cmd);
							$conn = undef;
							$_last_executed_cmd = undef;
						}
					}  elsif ($err =~ /read timed-out/)  {
						$this->{command_result} = TIME_OUT;
						$this->_log('send_hosts', $hostname, 
								"Command '$cmd' timed out after $timeout seconds, continuing", 
								LOG_ERROR) if (!$suppress_errors);
					}  else {
						$this->_log('send_hosts', $hostname, 
								"Can't send '$cmd', aborting: $err", 
								LOG_ERROR) if (!$suppress_errors);
						$_last_executed_cmd = undef;
						$conn = undef;
					}
				}  elsif (!$conn->last_prompt && ($cmd !~ /$_reload_cmd_pattern/))  {
					$this->{command_result} = FAIL;
					$this->_log('send_hosts', $hostname, 
							"No prompt after command '$cmd', re-opening and resending", 
							LOG_SEND);
					unshift(@cmds, $cmd);
					$conn = $this->_connect($hostname);
				}  else {
					$_last_executed_cmd = $cmd;
				}
				if ($cmd_output)  {
					$return_output .= $cmd_output;
					$this->_write_output($hostname, $cmd_output) 
							if (!$_top_perl_block);
				};
				if ($using_cur_conn)  {
					$_cur_conn = $conn;
				}
			}
		}
	}
	$this->_log('send', $hostname, time - $start, LOG_TIMING);
	if (defined($conn))  {
		$this->_log('send_hosts', $hostname, "all commands sent successfully", 
				LOG_SEND);
	}
	return $return_output;
}


#  $IPncm_client->_eval_block()
#  Function:  Eval's the given block of perl code.  Separated out to ensure 
#    no variables get stomped on by eval'd code.  Specifies a $hostname 
#    and $store_id variable (if appropriate) to be used in the eval'd block.
#  Parameters:  $eval - string:  the code to be eval'd.
#    $hostname - string:  the name of the host being contacted.
#  Returns:  string: anything written to STDOUT within the eval'd block.
sub _eval_block  {
	my $this = shift;
	my ($eval, $hostname) = @_;
	$hostname =~ /st?(\d+)/;
	my $store_id = defined($1) ? $1 : "";
	my $cmd_out = '';
	my $ipmon = $local_ipmon;
	my $host_os = $this->get_host_os($hostname) || "Unknown OS";
	my $host_model = $this->get_host_model($hostname) || "Unknown Model";
	my $host_feature_set = $this->get_host_feature_set($hostname) || "Unknown Feature Set";
	my $host_ip = $this->_get_ipaddr($hostname) || "Unknown IP Address";
	
	open(my $fh, '>', \$cmd_out) || die "Can't open CMD_OUT: $!";
	my $old = select($fh);
	eval $eval;
	if ($@)  {
		my $err = $@;
		if ($err)  {
			$this->_log('send_hosts', $hostname, "Perl evaluation died with error:  $err", LOG_ERROR);
		}
	}
	select($old);
	close($fh);
	return $cmd_out;
}


#  $IPncm_client->_send_to_flash($contents, $hostname)
#  Function:  Creates a file with the specified contents in the flash: 
#    location on the host.
#  Parameters:  $contents - string:  the contents of the file.
#    $hostname - string: the hostname to send the file to.
#  Returns:  string: the filename of the file on the host (in the format
#    "config-<year>-<month>-<day>.txt").
sub _send_to_flash {
	my $this = shift;
	my ($conn, $contents, $hostname) = @_;
	if (!defined($contents))  {
		$this->_log('send_file', $hostname, 
				'file contents parameter required, aborting', LOG_ERROR);
		return;
	}
	if (!$this->is_added($hostname))  {
		$this->_log('send_file', $hostname, "not added, aborting", LOG_ERROR);
		return;
	}

	my $start = time;
	my $fname = $this->{dir} . "/file-$hostname-" . time . "-" . 
			int(rand(100000)) . ".txt";
	if (open(my $fh, "> ", $fname))  {
		print $fh $contents;
		close($fh);
	}  else {
		$this->_log('send_file', $hostname, 
			"cannot save flash file, aborting: $!", LOG_ERROR);
		return;
	}

	my $ip = $this->_get_ipaddr();
	my @date = localtime(time);
	my $end_file = "config-" . ($date[5] + 1900) . "-" . ($date[4] + 1) .
			"-" . $date[3] . ".txt";
	my $u = _get_ipmon_args(IP_USER);
	my $cmd = <<EOF;
delete flash:$end_file
copy scp://$u\@$ip/$fname flash:$end_file
EOF

	my $output = $this->_send_connected_host($conn, $cmd, $hostname);
	unlink($fname);

	$this->_log('send_file', $hostname, "file sent successfully", 
			LOG_SEND);
	$this->_log('send_file', $hostname, time - $start, LOG_TIMING);
	return $end_file;
}

#  $IPncm_client->_get_ipaddr()
#  Function:  Finds the external IP address of the given device.
#  Parameters:  $hostname - string:  The host to search for the IP address of,
#    defaulting to this IPmon.
#  Returns:  string: the IP address of the device.
my %_ipaddr = ();
sub _get_ipaddr  {
	my $this = shift;
	my ($hostname) = @_;
	$hostname = $local_ipmon if (!defined($hostname) || !$hostname);
	
	return $_ipaddr{$hostname} if (defined($_ipaddr{$hostname}));
	open(my $fh, "/etc/hosts") || return undef;
	while (<$fh>)  {
		if (/$hostname/ && /([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/)  {
			$_ipaddr{$hostname} = $1;
			close($fh);
			return $_ipaddr{$hostname};
		}
	}
	close($fh);
	return undef;
}

#  $IPncm_client->add(@hosts)
#  Function:  Adds the hosts to this connector for later calls to send_hosts.
#  Parameters:  @hosts - array of strings:  the hostnames to add.
#  Returns:  N/A
sub add  {
	my $this = shift;
	my @hosts = @_;

	if (!@hosts)  {
		return;
	}

	foreach my $host (@hosts)  {
		$host = lc($host);
	}
	$this->_get_host_os_map(@hosts);
}

sub _get_host_os_map  {
	my $this = shift;
	my @hosts = @_;

	my $start = time;
	if (!-e STATUS_FILE)  {
		foreach my $host (@hosts)  {
			if (!defined($this->{host_map}->{$host}->{os}))  {
				$this->{host_map}->{$host}->{os} = "unknown";
			}
			if (!defined($this->{host_map}->{$host}->{personality} ))  {
				$this->_snmp_set($host, "unknown", 1);
			}
		}
		$this->_log('snmp_get', undef, time - $start, LOG_TIMING);
		return;
	}
	
	my $cmd = "egrep '(host_name|check_snmp|^servicestatus \{)' " . STATUS_FILE;
	my $cur_host = '';
	my %found_flags = ();
	my @threads = ();
	$this->_log('snmp_get', undef, "starting snmp processing", 
			LOG_CONN);
	$this->_get_snmp_cache(@hosts);
	
	foreach my $line (split(/[\r\n]/, `$cmd`)) {
		if ($line =~ /^servicestatus/)  {
			$cur_host = '';
		}  elsif ($line =~ /^\s*host_name\s*=\s*(.*?)\s*$/)  {
			my $h = lc($1);
			if (grep($h eq $_, @hosts) && !defined($this->{host_map}->{$h}))  {
				$cur_host = $h;
			}
		}  elsif ($cur_host && !defined($this->{host_map}->{$cur_host}) && 
				($line =~ /check_snmp[^-]*(.*)/) && 
				(!defined($found_flags{$cur_host})))  {
			my %flags = _parse_flags(split(/(?<!\\)!/, $1));
			my $host = $cur_host;
			$cur_host = '';
			next unless (defined($flags{'version'}));
			$flags{'community'} = 1 if (!$flags{'community'});

			if (defined($flags{'priv_protocol'}) && $flags{'priv_protocol'} =~ m/AES/i)  {
				$flags{'priv_protocol'} = 'AES'; #override AES128 or anything else added on
			}  else  {
				$flags{'priv_protocol'} = 'DES';
			}
			$this->_log('snmp_get', $host, "starting individual processing", 
					LOG_CONN);
			$_thread_sema->down();
			$found_flags{$host} = 1;
			push(@threads, threads->new( sub  {  
				$0 = basename($0) . " -co '$host snmp fetch'";
				$SIG{'KILL'} = sub { threads->exit(); };
				my $snmpget = '';
				my $err = '';
				my $snmp_cmd = '';
				if ($flags{version} eq "2c")  {
					$snmp_cmd = "snmpget -v2c -c" . $flags{community} . 
							" $host sysDescr.0";
				}  elsif (defined($flags{security_name}) && 
						defined($flags{auth_password}) && 
						defined($flags{security_level}) && 
						defined($flags{priv_password}) && 
						defined($flags{priv_protocol}))  {
					$snmp_cmd = "snmpget -v3 -u " . $flags{security_name} . 
							" -A " . $flags{auth_password} .
							" -l " . $flags{security_level} .
							" -X " . $flags{priv_password} .
							" -x " . $flags{priv_protocol} .
							" $host sysDescr.0";
				}
				$this->_log('snmp_get', $host, 
						"Running SNMP command: $snmp_cmd", LOG_CONN);
				$err = capture_stderr  {
					$snmpget = `$snmp_cmd`;
				};
				if ($err && ($err !~ m/no response from/i))  {
					$this->_log('snmp_get', $host, 
							"Error getting SNMP connection info, continuing:" . 
							"  $err", LOG_CONN);
				}  elsif ($snmpget) {
					$snmpget =~ s/.*STRING:\s*//;
					$snmpget =~ s/[\r\n].*//s;
					$this->_log('snmp_get', $host, "successful snmp retrieval - $snmpget", 
							LOG_CONN);
				}
				$_thread_sema->up();
				return ($host, $snmpget);
			}));
		}
	}
	while (@threads)  {
		my $thread = shift(@threads);
		if (!$thread->is_joinable())  {
			if (time - $start > TIMEOUT_TIME)  {
				$this->_log('snmp_get', undef, "aborting thread", LOG_CONN);
				$thread->kill('KILL')->detach();
				$_thread_sema->up();
			}  else {
				push(@threads, $thread);
				sleep(1);
			}
			next;
		}
		my ($host, $snmpget) = $thread->join();
		$this->_snmp_set($host, $snmpget, 1);
	}
	foreach my $host (@hosts)  {
		if (!defined($this->{host_map}->{$host}->{os}))  {
			$this->{host_map}->{$host}->{os} = "unknown";
		}
		if (!defined($this->{host_map}->{$host}->{personality} ))  {
			$this->_snmp_set($host, "unknown", 1);
		}
		if (!defined($this->{host_map}->{$host}->{is_cue} ))  {
			$this->{host_map}->{$host}->{is_cue} = ($host =~ /cue/) || 
					$this->{is_cue};
		}
	}
	$this->_log('snmp_get', undef, time - $start, LOG_TIMING);

}

sub _snmp_set {
	my ($this, $host, $snmpget, $set_cache) = @_;
	return if (!defined($host) || !defined($snmpget) || !$host || !$snmpget);
	$set_cache = defined($set_cache) && $set_cache;
	
	$this->{host_map}->{$host}->{os} = $snmpget;
	my $personality = $this->{default_device_type};
	if ($snmpget =~ /Cisco NX-OS/)  {
		$personality = $this->{default_device_type};  # TODO: make nxos pb
	}  elsif ($snmpget =~ /Cisco Adaptive Security Appliance/)  {
		$personality = 'asa';
	}  elsif ($snmpget =~ /H3C/)  {
		$personality = 'h3c';
	}  elsif (($snmpget =~ /Juniper/) || ($snmpget =~ /JN/))  {
		$personality = 'junos';
	}  elsif ($snmpget =~ /(?:Linux|Unix)/)  {
		$personality = 'bash';
	}  elsif (($snmpget =~ /Controller/) || ($this->is_wlc($host)))  {
		$personality = 'wlc';
	}
	$this->{host_map}->{$host}->{personality} = $personality;
	$this->_set_snmp_cache($host, $snmpget) if ($set_cache);
	if ($snmpget eq 'unknown')  {
		$this->_log('snmp_get', $host, "couldn't find type, using default of " . 
			$this->{host_map}->{$host}->{personality}, 
			LOG_CONN);
	}  else {
		$this->_log('snmp_get', $host, "found type to be '" . 
			$this->{host_map}->{$host}->{personality} . "'", LOG_CONN);
	}
}

sub _get_snmp_cache  {
	my $this = shift;
	my @hosts = @_;
	my %host_map = map { $_ => 1 } @hosts;
	open(my $fh, SNMP_CACHE) || return;
	while (my $line = <$fh>)  {
		chomp($line);
		my ($host, $time, $snmpget) = split(/,/, $line, 3);
		next unless (defined($host_map{$host}));
		if ($time > time - CACHE_TIME)  {
			$this->_snmp_set($host, $snmpget, 0);
		}
	}
	close($fh);
}


sub _set_snmp_cache  {
	my $this = shift;
	my ($host, $snmpget) = @_;
	my $lock = SNMP_CACHE_LOCK;
	my $fh = undef;
	while (-e $lock)  {
		sleep 1;
	}
	`touch $lock`;
	my $file = "";
	if (-e SNMP_CACHE)  {
		open($fh, SNMP_CACHE);
		while (my $line = <$fh>)  {
			my ($cache_host, $cache_time, $cache_snmpget) = split(/,/, $line, 3);
			if (($cache_time > time - CACHE_TIME) && ($cache_host ne $host))  {
				$file .= $line;
			}
		}
		close($fh);
	}
	my $time = time;
	$file .= "$host,$time,$snmpget\n";
	open($fh, "> " . SNMP_CACHE);
	print $fh $file;
	close($fh);
	unlink($lock);
}


sub _parse_flags  {
	my %string_map = ();
	while (@_)  {
		if ($_[0] =~ m/^--/)  {
			$_[0] =~ s/^--//;
			$string_map{$_[0]} = (!defined($_[1]) || ($_[1] =~ /^--/)) ? '' : 
					$_[1];
			$string_map{$_[0]} =~ s/\\(.)/$1/g;
			splice(@_,0,2);
		}  else {
			shift;
		}
	}
	return %string_map;
}

#  $IPncm_client->remove(@hosts)
#  Function:  Removes the hosts from this connector so that they can no longer
#    be access by later calls to send_hosts.
#  Parameters:  @hosts - array of strings:  the hostnames to remove.
#  Returns:  N/A
sub remove  {
	my $this = shift;
	my @hosts = @_;

	if (!@hosts)  {
		@hosts = keys(%{$this->{host_map}});
	}
	foreach my $host (@hosts)  {
		delete($this->{host_map}->{$host});
	}
}


#  $IPncm_client->_log($function, $output, $loglevel)
#  Function:  Logs some information with the given logging level.  This 
#    information is only output if the log level matches the debugging level.
#  Parameters: $function - string:  name of the function this log is associated
#      with.
#    $output - string: the information to log.
#    $loglevel - int:  the log level to use - see the top of the file LOG_ 
#      constants to see what values are valid.  If this is LOG_ERROR, the 
#      information is also logged for later retrieval by error().
#    $force_print - int:  if non-0, prints the output regardless of log level.
#      If 2, does not write to the filesystem.
#  Returns:  N/A
sub _log  {
	my $this = shift;
	my ($function, $device, $output, $loglevel, $force_print) = @_;
	$force_print = defined($force_print) ? $force_print : 0;
	my $time = localtime;
	$device = defined($device) && $device ? $device : "undefined device";
	$loglevel = defined($loglevel) ? $loglevel : LOG_ERROR;
	
	if (($loglevel & LOG_TIMING) && ($output =~ /^(\d+)$/))  {
		$output = "Function completed in $1 seconds\n";
	}
	my @output = split(/\n/, $output);
	foreach my $line (@output)  {
		next unless ($line =~ /\w/);
		print "$time: $function: $local_ipmon: $device: $line\n" if ($force_print);
		if ($loglevel == LOG_ERROR)  {
			push(@_errors, [$time, $function, $local_ipmon, $device, $line]);
			if (($device ne "undefined device") && (!defined($_success{$device})))  {
				$_success{$device} = 0;
			}
			$this->_write_output("errors-$local_ipmon", 
					"$time: $function: $local_ipmon: $device: $line\n") 
					if ($force_print != 2);
			$this->_write_output("debug-$local_ipmon",
					"$time: $function: $local_ipmon: $device: $line\n") 
					if ($_debug && $force_print != 2);
		}  elsif ($_debug & $loglevel)  {
			$this->_write_output("debug-$local_ipmon",
					"$time: $function: $local_ipmon: $device: $line\n") 
					if ($force_print != 2);
		}
	}
}


sub _get_ipmon_args  {
	my $txt = shift;
	$txt = decode_base64($txt);
	$txt =~ tr/k-za-jK-ZA-J/a-zA-Z/;
	return decode_base64($txt);
}


#  $IPncm_client->_write_output($file, $line)
#  Function:  Writes log lines to output files.
#  Parameters: $file - string:  portion of the name of the file this message  
#      should be written to.
#    $line - string: the log line(s) to be written.
#  Returns:  N/A
sub _write_output  {
	my $this = shift;
	my ($file, $line) = @_;
	my $filename = $this->_get_output_file($file);
	if (defined($filename))  {
		open(my $fh, ">> $filename") || 
			($this->_log('write_output', $local_ipmon, 
			"couldn't write '$line' to $filename", LOG_ERROR, 2) && return);
		print $fh $line;
		close($fh);
	}
}


#  $IPncm_client->_get_output_file($file)
#  Function:  Returns the full path we would like to log to.  As a side 
#    effect, creates the log directory if it doesn't exist.
#  Parameters: $file - string:  portion of the name of the file this message  
#      should be written to.
#  Returns:  string:  the full path to log to (or undef if an error).
sub _get_output_file  {
	my $this = shift;
	my ($file, $line) = @_;
	$this->{dir} =~ s#/+$##;
	if (!-e $this->{dir})  {
		make_path($this->{dir}) || (-e $this->{dir}) || (
			$this->_log('write_output', $local_ipmon, 
			"couldn't create dir '" . $this->{dir} . "'", LOG_ERROR, 2) && die);
	}
	return $this->{dir} . "/" . $this->{output_file} . "-" . $file . ".txt";
}



#  $IPncm_client->_clear_output()
#  Function:  Removes non-debug output files after completion (according to 
#      keep setting).
#  Parameters:  N/A
#  Returns:  N/A
sub _clear_output  {
	my $this = shift;
	if (!$this->{keep} && -e $this->{dir})  {
		chdir($this->{dir});
		opendir(D, ".");
		my $patt = $this->{output_file};
		my @files = grep($_ !~ /debug/, grep(/^$patt/, readdir(D)));
		unlink(@files);
		my $empty = scalar(grep { $_ ne "." && $_ ne ".." } readdir(D)) == 0;
		closedir(D);
		if ($empty)  {
			chdir('..');
			my $dir = $this->{dir};
			$dir =~ s#/+$##;
			$dir =~ s#.*/##;
			rmdir($dir);
		}
	}
}


#  $IPncm_client->get_completion_counts(@hosts)
#  Function:  Figures out what level of completion the current send_hosts 
#    command is at.
#  Parameters: @hosts - array of string:  the list of hosts within the 
#      execution.  Defaults to the list of hosts previously add()ed.
#  Returns:  array of int:  (count completed, count with errors, total count),
#    though there may be overlap between the ones with errors and the ones
#    completed.  Returns (0, 0, $total) if the output directory doesn't exist  
#    (which may happen before the script has started, or after it completes if  
#    the $this->{keep} variable is not true.
sub get_completion_counts  {
	my $this = shift;
	my @hosts = @_;
	if (!@hosts)  {
		@hosts = keys(%{$this->{host_map}});
	}
	my $total = scalar(@hosts);
	$this->{dir} =~ s#/+$##;
	if (!-e $this->{dir})  {
		return (0, 0, $total);
	}
	
	my $complete = 0;
	foreach my $host (@hosts)  {
		my $file_loc = $this->{dir} . "/" . $this->{output_file} . "-" . 
				$host . ".txt";
		my $last_line = `tail -1 $file_loc 2>&1`;
		if ($last_line =~ /PROCESSING COMPLETE/)  {
			$complete++;
		}
	}
	
	my $errors = 0;
	my $err_loc = $this->{dir} . "/" . $this->{output_file} . "-errors-$local_ipmon.txt";
	if (-e $err_loc)  {
		foreach my $host (@hosts)  {
			if (`grep $host $err_loc`)  {
				$errors++;
			}
		}
	}
	return ($complete, $errors, $total);
}


#  $IPncm_client->error()
#  Function:  Returns all errors that were created since the last time this 
#    function was called.
#  Parameters:  N/A
#    since this function was last called, sorted by device name and log time.
#  Returns:  string:  a newline-separated list of all errors that occurred 
sub error  {
	my $this = shift;
	my @err = sort { ($a->[2] cmp $b->[2]) } @_errors;
	$this->_reset_error();
	my $ret = '';
	my $last_server = undef;
	foreach my $err (@err)  {
		my ($time, $function, $ipmon, $device, $msg) = @$err; 

		if (defined($last_server) && ($last_server ne $msg))  {
			$ret .= "\n";
		}
		$last_server = $device;
		chomp($msg);
		chomp($msg);
		$ret .= "$time: $function: $ipmon: $device: $msg\n";
	}
	return $ret;
}


#  $IPncm_client->_reset_error()
#  Function:  Removes all stored error information.
#  Parameters: N/A
#  Returns:  N/A
sub _reset_error  {
	my $this = shift;
	@_errors = ();
}


#  $IPncm_client->_sema_status()
#  Function:  Returns the current value of the threading semaphore (i.e. the 
#    number of connections that may still be opened without closing some).
#  Parameters: N/A
#  Returns:  N/A
sub _sema_status  {
	my $this = shift;
	return $$_thread_sema;
}


#  $IPncm_client->set_login($user, $pw, $pw2, $host, $priority, $source)
#  Function:  Sets login information for one host or host pattern.
#  Parameters:  $user - string:  the username for login.
#    $pw - string:  the password for login.
#    $pw2 - string:  the secondary password for becoming privileged.
#    $host - string:  the host this login information is associated with.
#    $priority - int:  priority order of info (higher == higher priority).
#    $source - string:  the source of the credentials (e.g. 'locksmith', 'cloginrc', 'cli', &c.)
#  Returns:  N/A
sub set_login  {
	my $this = shift;
	my ($user, $pw, $pw2, $host, $priority, $source) = @_;
	$this->{config}->set_value('user', $user, $host, $priority) if defined($user);
	$this->{config}->set_value('pw', $pw, $host, $priority) if defined($pw);
	$this->{config}->set_value('pw2', $pw2, $host, $priority) if defined($pw2);
	$this->{config}->set_value('source', $source, $host, $priority) if defined($source);
}


#  $IPncm_client->_send_to_run($filename, $hostname, $keep_file)
#  Function:  Copies the current run configuration of the device to a backup
#    location on flash:, then copies the given file from flash: to run.
#  Parameters:  $filename - string:  the file to copy to run.
#    $hostname - string:  the hostname on which to copy the configuration.
#  Returns:  string: the output of the various commands being executed.
#    $keep_file - boolean:  keep the file in flash: afterwards?
#    $timeout - int:  timeout in seconds.
#  TODO:  ensure that the file exists within the flash: location before 
#    proceeding.
sub _send_to_run  {
	my $this = shift;
	my ($conn, $filename, $hostname, $keep_file, $timeout) = @_;
	$keep_file = defined($keep_file) ? $keep_file : 0;

	my $output = $this->_send_connected_host($conn, "show flash", $hostname, $timeout);
	my $backup = 0;
	if ($output =~ /$filename.backup/)  {
		for (my $i = 1; $i <= 3; $i++)  {
			$backup = $i;
			if ($output !~ /$filename.backup$i/)  {
				last;
			}
		}
	}
	$backup = ".backup" . ($backup ? $backup : "");
	my $cmd = '';
	$cmd .= 'delete flash:/' . $filename . $backup . "\n";
	$cmd .= 'copy run flash:/' . $filename . $backup . "\n";
	$cmd .= 'copy flash:/' . $filename . " run\n";
	$cmd .= 'delete flash:/' . $filename . "\n" if (!$keep_file);
	$cmd .= "write\n";
	
	return $this->_send_connected_host($conn, $cmd, $hostname, $timeout);
}

#
#  TO BE RUN WITHIN EVAL'D PERL
#

#  send_host($script, $hostname, $timeout, $print_header)
#  Function:  Calls _send_connected_host() for the given host.
#  Parameters:  $script - string:  the script to run.
#    $hostname - string: the device on which to run the script, defaulting to 
#      the current one.
#    $timeout - int:  the amount of time in seconds  we expect this command to 
#      take, defaulting to TIMEOUT_TIME.
#    $print_header - boolean:  whether or not to print the header block for the 
#      command output, defaulting to true.
#    $suppress_errors - boolean:  whether or not to log errors for this command
#      if they occur, defaulting to false.
#  Returns:  string: the output of _send_connected_host.
sub send_host  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	my ($script, $hostname, $timeout, $print_header, $suppress_errors) = @_;
	
	if (!defined($hostname) || (defined($_cur_hostname) && 
			$hostname eq $_cur_hostname))  {
		return defined($this) && defined($_cur_hostname) ? 
				$this->_send_connected_host($_cur_conn, $script, 
				$_cur_hostname, $timeout, $print_header, $suppress_errors) : undef;
	}  else {
		$hostname = lc($hostname);
		if (!$this->is_added($hostname))  {
			$this->add($hostname);
		}
		return defined($this) ? 
				$this->_send_host($script, $hostname, 0, $timeout, $print_header) : undef;
	}
}

#  send_to_flash($script)
#  Function:  Calls _send_to_flash() for the current host.
#  Parameters:  $contents - string:  the contents on the file to be created.
#  Returns:  string: the output of _send_to_flash.
sub send_to_flash  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	return defined($this) && defined($_cur_hostname) ? 
			$this->_send_to_flash($_cur_conn, $_[0], $_cur_hostname) : 
			undef;
}

#  send_to_run($script)
#  Function:  Calls _send_to_run() for the current host.
#  Parameters:  $filename - string:  the filename to send to run.
#    $keep_file - boolean: whether to keep the file after sending it to run.
#    $timeout - int:  timeout for sending the file to run.
#  Returns:  string: the output of _send_to_run.
sub send_to_run  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	my ($filename, $keep_file, $timeout) = @_;
	return defined($this) && defined($_cur_hostname) ? 
			$this->_send_to_run($_cur_conn, $filename, $_cur_hostname, 
			$keep_file, $timeout) : undef;
}

#  log_error($script)
#  Function:  Outputs the error message and saves it to later retrieval by 
#    error().
#  Parameters:  $error - string:  the error message to log.
#  Returns:  N/A
sub log_error  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	my ($error) = @_;
	if (defined($this))  { 
		$this->_log('log_error', $_cur_hostname, "ERROR: " . $error, 
				LOG_ERROR);
	}
	print localtime . ": ERROR: $error\n";
}


#  get_command_result()
#  Function:  For the last command executed, determines whether it ran successfully.
#  Returns:  int:  SUCCESS, FAIL, or TIME_OUT.
sub get_command_result  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	return $this->{command_result};
}


#  run_script($script_name, $param1...)
#  Function:  Runs a previously-defined script (for use in complex tasks 
#    that will be standard across-the-board, such as upgrades).
#  Parameters:  $script_name - string:  the name of the script to run.
#      Script must be a package in IPncm_Client::RunScripts, with a function
#      called run_script which accepts, as the first two values, the host 
#      connection and the hostname.
#    $param1...:  values to be passed to the script execution.
#  Returns:  output of the called script.
sub run_script  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	my $script_name = shift;
	if ($script_name eq 'Upgrade')  {
		return $this->run_upgrade(@_);
	}
	if (!defined($this) || !defined($_cur_hostname) || 
			!defined($script_name) || !$script_name || 
			($script_name =~ /[^a-zA-Z0-9\.\_\-\~\: ]/) || 
			(!-e RUNSCRIPT_PATH . "/$script_name.pm")) {
		log_error("invalid script");
		return;
	}  else {
		my $output = "";
		eval  "			
			use $script_name;
			\$output = $script_name->run(
					\$this, \$_cur_hostname, \@_);
		";
		log_error($@) if $@;
		return $output;
	}
}


my %_upgrade_scripts = (
	"Adaptive Security Appliance" => "Upgrade_ASA",
);
#  run_upgrade($upgrade_file, $run_config, $upgrade_version, $upgrade_size)
#  Function:  Attempts to determine what kind of upgrade script to run for the
#    current device, then runs that upgrade script.  Checks first in the 
#    %_upgrade_scripts array, then in the RUNSCRIPT_PATH folder.
#  Parameters:  $upgrade_file - string:  filename to use for the upgrade.
#      $run_config - boolean:  on true, actually upgrade the device.  On false,
#        just perform prepwork (such as copying the file over) and initial 
#        device tests.  Defaults to false.
#      $upgrade_version - string:  version to upgrade to, defaulting to a version
#        specified by $upgrade_file.
#      $upgrade_size - int:  size of upgrade file, used to determine if it came
#        over properly.  Defaults to size determined from $upgrade_file.
#  Returns:  output of upgrade script.
sub run_upgrade  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
			
	my $host_model = $this->get_host_model($_cur_hostname);
	if (!defined($host_model) || !$host_model)  {
		$this->log_error("Cannot determine host model for upgrading");
		return;
	}
	foreach my $key (keys(%_upgrade_scripts))  {
		if ($host_model =~ /$key/)  {
			return $this->run_script($_upgrade_scripts{$key}, @_);
		}	
	}
	
	opendir(DIR, RUNSCRIPT_PATH) || 
			($this->log_error("Cannot open upgrade script dir") && return);
	my @scripts = grep(/Upgrade_/, readdir(DIR));
	closedir(DIR);
	foreach my $script (@scripts)  {
		$script =~ /Upgrade_(.*)\.pm/;
		my $script_model = $1;
		if ($host_model =~ /$script_model/)  {
			return $this->run_script("Upgrade_$script_model", @_);
		}
	}
	
	log_error("Unable to find upgrade script that matches host model");
	return;
}


#  _odd_sort()
#  Function:  Sorting method to compare two strings terminated by numbers.
#    Used by gen_int_ranges, below.
sub _odd_sort  {
	return -1 if (!defined($a));
	return 1 if (!defined($b));

	$a =~ /^(.*)(\d+)$/;
	my ($a1, $a2) = (defined($1) ? $1 : "", defined($2) ? $2 : 0);

	$b =~ /^(.*)(\d+)$/;
	my ($b1, $b2) = (defined($1) ? $1 : "", defined($2) ? $2 : 0);
	return $a2 <=> $b2 if ($a1 eq $b1);
	return $a1 cmp $b1;
}


#  gen_int_ranges(@interfaces)
#  Function:  Given a list of interfaces, returns a list of interface ranges
#    combined into groups of 5 (which is the maximum that can be configured at
#    once).  Intended to be used by eval'd perl code.
#  Parameters:  @interfaces - array of string: the list of interface names to 
#    combine.
#  Returns:  array of string:  the list of combined interface ranges.
sub gen_int_ranges  {
	my @ints = @_;

	my $last_prefix = undef;
	my $first = undef;
	my $last = undef;
	my @ranges = ();
	foreach my $prefix (sort _odd_sort @ints)  {
		next if (!defined($prefix) || $prefix eq '');
		$prefix =~ s/([0-9]+)$//;
		my $num = $1;
		my $x = "x"; $x =~ /x/;  #  Clear regex capture buffer
		if (!defined($last_prefix) || !defined($first))  {
			$last_prefix = $prefix;
			$first = $last = $num;
		}  elsif ($last_prefix ne $prefix || !defined($num) || 
				$last + 1 != $num)  {
			push(@ranges, $last_prefix . (defined($first) ? $first . 
					($first != $last ? " - $last" : '') : ''));
			$last_prefix = $prefix;
			$first = $last = $num;
		}  else {
			$last++;
		}
	}
	if (defined($last_prefix))  {
		push(@ranges, $last_prefix . (defined($first) ? $first . 
				($first != $last ? " - $last" : '') : ''));
	}

	my @ret = ();
	while (@ranges)  {
		push(@ret, join(", ", splice(@ranges, 0, 5)));
	}
	return @ret;
}

#  normalize_interface($interface)
#  Function:  Given an interface, normalizes that interface into the standard
#    long form.  Intended to be used by eval'd perl code.
#  Parameters:  $interface - string: the interface name to normalize.
#  Returns:  string:  the normalized interface name.
sub normalize_interface  {
	my ($int) = @_;
	$int =~ s/^\s+//;
	$int =~ s/^\s$//;
	$int =~ /^([a-zA-Z\-]+)(.*)$/;
	my ($pre, $post) = ($1, $2);
	if ($pre =~ /^IS/)  {
		$pre = "ISM";
	}  elsif ($pre =~ /^Em/)  {
		$pre = "Embedded-Service-Engine";
	}  elsif ($pre =~ /^Se/)  {
		$pre = "Serial";
	}  elsif ($pre =~ /^Lo/)  {
		$pre = "Loopback";
	}  elsif ($pre =~ /^Po/)  {
		$pre = "Port-channel";
	}  elsif ($pre =~ /^Tu/)  {
		$pre = "Tunnel";
	}  elsif ($pre =~ /^Vl/)  {
		$pre = "Vlan";
	}  elsif ($pre =~ /^Fa/)  {
		$pre = "FastEthernet";
	}  elsif ($pre =~ /^Gi/)  {
		$pre = "GigabitEthernet";
	}  elsif ($pre =~ /^Te/)  {
		$pre = "TenGigabitEthernet";
	}  elsif ($pre =~ /^Et/)  {
		$pre = "Ethernet";
	}  elsif ($pre =~ /^Mu/)  {
		$pre = "Multilink";
	}
	return $pre . $post;
}


#  block_connections()
#  Function:  Blocks all device connections until the current thread completes.  
#    This only applies to threads that have called block_connections().
sub block_connections  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	$this->check_abort();
	$_blocker_sema->down();
	$this->check_abort();
}


#  check_abort()
#  Function:  Check if abort_execution() has been called.  If so, stop processing.
sub check_abort  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	if ($_abort_execution)  {
		die "Execution aborted in another thread.";
	}
}


#  abort_execution()
#  Function:  Immediately stop processing in the thread.  Informs other threads
#    that they, too, need to stop processing, though this will only work when 
#    check_abort() is called.
#  Parameters:  $msg - string:  The message to be output (if any).
sub abort_execution  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	$this->check_abort();
	my $msg = shift || "Execution aborted due to call to abort_execution().";
	$_abort_execution = 1;
	die $msg;
}


#  log_success($hostname)
#  Function:  Marks the execution on the device as successful, regardless of
#    any errors encountered.
#  Parameters:  $hostname - string:  The hostname to log as a success.  Defaults
#      to the current device.
sub log_success  {
	my $hostname = shift || $_cur_hostname;
	$_success{$hostname} = 1;
}


#  log_failure($hostname)
#  Function:  Marks the execution on the device as a failure, regardless of
#    any errors encountered.
#  Parameters:  $hostname - string:  The hostname to log as a failure.  Defaults
#      to the current device.
sub log_failure  {
	my $hostname = shift || $_cur_hostname;
	$_success{$hostname} = 0;
}


#  send_email($to, $subject, $body)
#  Function:  Sends email (from IP_USER@Company.com).
#  Parameters;  $to - string:  Email address to send to.
#      $subject - string:  Subject line of email.
#      $body - string:  Body of email.
#  Returns:  N/A.
sub send_email  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	my ($to, $subject, $body) = @_;
	my $msg = MIME::Lite->new(
		From => _get_ipmon_args(IP_USER) . "\@Company.com",
		To => $to,
		Subject => $subject,
		Type => "text",
		Data => $body
	) || $this->log_error(
			"Failure when creating email:  $!");

	$msg->send() || $this->log_error(
			"Failure when sending email:  $!");	
}

#  get_hosts()
#  Function:  Gets a list of the hosts this script is being run agains..
#  Parameters;  N/A.
#  Returns:  array of string:  list of host names.
sub get_hosts  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	return defined($this) ? keys($this->{host_map}) : ();
}

#  _produtil_connect()
#  Function:  Creates an OpenSSH connection to the given device.  Used for 
#    DB queries by db_select, below.
#  Parameters;  $produtil - string:  hostname of produtil device.
#  Returns:  Net::OpenSSH: Net::OpenSSH connection.
sub _produtil_connect  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	my $produtil = shift;
	
	my $conn = undef;
	my $err = capture_stderr  {
		$conn = Net::OpenSSH->new(
				$produtil,
				user => _get_ipmon_args(IP_USER),
				password => _get_ipmon_args(IP_PW),
				timeout => 60,
		);
	};
	$err =~ s/WARNING - This device is the exclusive property of Company.*?USE AND CONSENT TO THE SAME.//gs;
	$err =~ s/\n\n+/\n/g;
	$err =~ s/^\n+//;
		$this->log_error("error connecting, continuing: $err") if ($err);
	if ($conn->error())  {
		$err = $conn->error();
	}
	$err =~ s/\n\n+/\n/g;
	$err =~ s/^\n+//;
	if ($err =~ /\w/)  {
		$this->log_error("error connecting: $err");
		return undef;
	}  else {
		return $conn;
	}
}


#  db_select($query)
#  Function:  Runs a particular DB query within the produtil mysql DB 
#    and returns the results.
#  Parameters:  $query - string: the query to run.  Only select queries will be
#      accepted.
#  Returns:  array ref:  the results as an array of hashes, each hash being 
#      header => value.
sub db_select  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	my $query = shift;
	
	if ($query !~ /^\s*select\s/i)  {
		log_error("Unable to perform db_select:  only select queries permitted");
		return [];
	}
	my $conn = undef;
	foreach my $produtil (@{$this->{produtils}})  {
		$conn = $this->_produtil_connect($produtil);
		last if defined($conn);
	}
	if (defined($conn))  {
		my @results = ();
		my $send = "mysql -hipdb-s -ureadonly -pread0nly -e \"$query\"";
		my ($output, $err) = $conn->capture2({}, $send);
		my @lines = split(/(?:\r\n|\n)/, $output);
		my @headers = ();
		foreach my $line (@lines)  {
			my @l = split(/\t/, $line);
			if (!@headers)  {
				@headers = @l;
			}  else {
				my %line;
				@line{@headers} = @l;
				push(@results, \%line);
			}
		}
		return \@results;
	}  else {
		log_error("Unable to create connection to DB device");
	}
	return [];
}


#  check_ci_alerts()
#  Function:  Checks if there are any alerts open against this host.  If there
#    are, fail with an error.  Otherwise, continue processing normally.
sub check_ci_alerts  {
	my $this = blessed($_[0]) && $_[0]->isa('IPncm_Client') ? shift : 
			$_cur_this;
	my $query = <<END_QUERY;
SELECT
	COUNT(*) as 'Number of tickets open'
FROM
	IPcmdb.ci as ci
		LEFT JOIN
	IPradar.ipcmdb_ticket_mapping as cmdbtm ON cmdbtm.ci_id = ci.ci_id
		INNER JOIN
	IPradar.tickets as tick ON tick.ticket_id = cmdbtm.ticket_id
WHERE
	ci.name like '$_cur_hostname'
END_QUERY
         
	my $db_out = $this->db_select($query);
	my $open = defined($db_out->[0]->{'Number of tickets open'}) ?  
			$db_out->[0]->{'Number of tickets open'} : 0;
	if ($open)  {
		die "Aborting execution - IPmon alert tickets are open against this host";
	}
}


sub DESTROY {  }

1;

