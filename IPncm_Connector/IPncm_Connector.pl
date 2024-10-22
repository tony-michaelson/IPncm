#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

#
#  IPncm_Connector.pl
#  
#  IPncm_Connector allows for automatic contacting and running of scripts on 
#  a number of connected devices simultaneously.  It runs in a multi-threaded 
#  way, keeping connections open only as long as needed and contacting 50 
#  devices per ipmon at the same time.  The code that can be run is a 
#  combination of command-line code and evaluated Perl code.  See usage() for 
#  more details.
#

use strict;
use warnings;
use Cwd;
use Data::Dumper;
use File::Basename;
use FindBin qw($Bin);
use Getopt::Long qw(:config no_ignore_case);
use MIME::Base64;

use constant BASE_PATH => (-e "$Bin/lib/IPncm_Connector.pm" ? $Bin : 
		(-e "$Bin/../lib/IPncm_Connector.pm" ? "$Bin/.." : 
		"/home/BASE_USER/IPncm_Connector"));

use lib BASE_PATH . "/lib";
use Constants;
use IPncm_Connector;

use constant PID_FILE => BASE_PRODUTIL_PATH . "/log/pid_log.txt";
use constant PID_LOCK => BASE_PRODUTIL_PATH . "/log/pid_log.lock";

my %request = ();
my @hosts = ();
my $script = '';
my $dir = BASE_PRODUTIL_PATH . "/log";
my $keep = 0;
my $output_file = 'output-' . time;
my $user = '';
my $pw = '';
my $debug = 0;
my $completion = 0;
my $test = 0;
my $all_hosts = 0;
my $csv_out = 0;
my $backup_config = 0;
my $enable = 0;
my $model_info = 0;
my $ipmon_user = '';
my $ipmon_pw = '';
my @clients = ();
my $conf_dir = '';
my $host_os = '';
my $cleanup = 0;
my $ssh_key_path = undef;
my $ssh_key_passphrase = undef;
my $db_device = '';
my $comment = '';
my $script_file = '';

my $conn = new IPncm_Connector();

GetOptions(
		'all_hosts' => \$all_hosts, 
		'backup_config' => \$backup_config, 
		'cleanup|cl' => \$cleanup,
		'client|cc=s' => \@clients,
		'comment|co=s' => \$comment,
		'completion|c' => \$completion, 
		'conf_dir|cd=s' => \$conf_dir, 
		'CSV_OUT' => \$csv_out,
		'db_device|db=s' => \$db_device,
		'Debug|D=i' => \$debug, 
		'dir|d=s' => \$dir, 
		'enable' => \$enable, 
		'filename=s' => \&process_file, 
		'hosts|h=s' => \@hosts,
		'host_os|os=s' => \$host_os,
		'ipmon_pw=s' => \$ipmon_pw, 
		'ipmon_user=s' => \$ipmon_user,
		'keep' => \$keep,
		'model_info' => \$model_info, 
		'output|o=s' => \$output_file, 
		'password=s' => \$pw, 
		'script|s=s' => \$script, 
		'script_file|S=s' => \$script_file,
		'ssh_key_path|sk=s' => \$ssh_key_path,
		'ssh_key_passphrase|sp=s' => \$ssh_key_passphrase,
		'test' => \$test, 
		'username=s' => \$user,
);

$conn->{dir} = $dir;
$conn->{output_file} = $output_file;
$conn->{keep} = $keep;
$conn->{all_hosts} = $all_hosts;
$conn->{backup_device_config} = $backup_config;
$conn->{always_enable} = $enable;
$conn->{ipmon_creds}->[0] = $conn->_set_ipmon_args($ipmon_user) if ($ipmon_user);
$conn->{ipmon_creds}->[1] = $conn->_set_ipmon_args($ipmon_pw) if ($ipmon_pw);
$conn->{default_device_type} = $host_os if ($host_os);
$conn->{ssh_key_path} = $ssh_key_path;
$conn->{ssh_key_passphrase} = $ssh_key_passphrase;
$conn->{db_device} = $db_device;

$conn->debug($debug) if ($debug > 0);
$cleanup = 1 if ($completion);

$script = $script ? $script : (shift || "");
push(@hosts, @ARGV);
@hosts = split(/[\;, \r\n]+/,join(',',@hosts));
@hosts = grep(/\w/, @hosts);
@hosts = map { lc($_) } @hosts;

@clients = split(/[\;, \r\n]+/,join(',',@clients));
@clients = grep(/\w/, @clients);

$conf_dir = $conf_dir ? $conf_dir : BASE_PRODUTIL_PATH . "/conf";

if (!@clients) {
	usage("No valid client provided.");
}  else {
	foreach my $client (@clients)  {
		if (!$conn->add_client_config($client))  {
			usage("Client $client is invalid");
		}
	}
}
		
if (!$all_hosts && !@hosts)  {
	usage("No hostnames provided.");
}
if ($script_file)  {
	$script = do {
		local $/ = undef;
		open my $fh, "<", $script_file
			or usage("Could not open $script_file for reading: $!");
		<$fh>;
	};
}
	
if ($test)  {
	$script = 'show version';
}
if (!$cleanup && !$backup_config && !$script)  {
	usage("No commands provided.");
}
my $decode_script = $script;
$decode_script =~ s/[^!-~\s]//g;
$decode_script =~ s/\\0//g;
if ($decode_script =~ m#^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{4}|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)$#)  {
	$script = decode_base64($decode_script);
}
$script =~ s/(?:\r\n|\r)/\n/g;
if (-e $dir && ((!-d $dir) || (!-w $dir)))  {
	usage("Invalid directory option.");
}

if (!-e $dir)  {
	mkdir($dir) || usage("Couldn't create directory");
}
my $old_dir = getcwd;
chdir($dir);

if (!$cleanup)  {
	log_pid($dir, $output_file, $all_hosts, @hosts);
}

my $cmd_out = {};

if ($all_hosts)  {
	$conn->add_ipmons(@hosts) if (@hosts);
	$conn->add('all');
}  else {
	$conn->add(@hosts);
}
if ($completion)  {
	$conn->{keep} = 1;
	my ($done, $err, $total) = $conn->get_completion_counts();
	if (defined($done))  {
		print "Complete: $done, errored: $err, total: $total\n";
	}  else {
		print "Completion details currently unavailable\n";
	}
}

if ($cleanup)  {
	my $script_name = basename($0);
	my $procs = `ps -efww | grep $script_name | grep perl`;
	my $running = 0;
	my @pids = get_pids(0, $dir, $output_file, $all_hosts, @hosts);
	my %not_running = map { $_ => 1 } get_pids(1);
	
	foreach my $proc (split(/\n/, $procs))  {
		my ($u, $pid1, $pid2, $rest) = split(/\s+/, $proc, 4);
		if (grep($pid1 == $_, @pids) || grep($pid2 == $_, @pids))  {
			$running = 1;
		}
		delete($not_running{$pid1});
		delete($not_running{$pid2});
	}
	rm_pids(keys(%not_running));
	
	if (!$running)  {
		print "No processes running, cleaning up...\n";
		$conn->cleanup_ipmons();
		print "Cleanup complete!\n";
	}
	exit(0);
}

eval  {
	if ($user || $pw)  {
		$conn->set_login(undef, undef, PRIORITY_USER_CONNECTOR, 
				$user, $pw, $pw, "cli");
	}
	$cmd_out = $conn->send_hosts($script);
};

if ($@)  {
	if (open(my $fh, ">> $output_file-errors.txt"))  {
		print $fh "FATAL ERRORS:\n$@\n\n";
		close($fh);
	}  else {
		log_err("saving error file $output_file-errors.txt!", $!);
	}
}

@hosts = keys(%$cmd_out);

$conn->cleanup_ipmons();
 
if (!$test && !$keep)  {
	foreach my $key (keys(%$cmd_out))  {
		if (open(my $fh, ">> $output_file-$key.txt"))  {
			print $fh $cmd_out->{$key};
			close($fh);
		}  else {
			log_err("saving output file $output_file-$key.txt!", $!);
		}
	}
}

if ($csv_out)  {
	my %err_hosts = ();
	@err_hosts{@hosts} = (0) x @hosts;
	if (-e "$output_file-errors.txt")  {
		if (open(my $fh, "$output_file-errors.txt"))  {
			while (<$fh>)  {
				chomp;  chomp;
				my ($time, $function, $ipmon, $device, $error) = split(/: /, $_, 5);
				if (defined($device) && defined($err_hosts{$device}) && 
						!$err_hosts{$device})  {
					$err_hosts{$device} = $error;
				}
			}
			close($fh);
		}  else {
			log_err("opening $output_file-errors.txt", $!);
		}
	}

	foreach my $h (sort(@hosts))  {
		my $ipmon = $conn->get_ipmon($h);
		$ipmon = defined($ipmon) ? $ipmon : "unknown ipmon";
		my $err = $err_hosts{$h};
		my $model = $model_info ? '"' . $conn->get_host_model($h) . '","' .
			$conn->get_host_os($h) . '",' : "";
		$err = (defined($err) && $err) ? $err : "";
		$err =~ s/"/'/g;
		$err =~ s/ at [^ ]*\.pm .*//;
		my $output = $cmd_out->{$h};
		$output =~ s/-- [^\n]* --\n//g;
		if (($output =~ /\w.*\n.*\w/s) || ($output !~ /\w/))  { 
			$output = ""; 
		}  else {
			$output =~ s/(?:\n|\r\n)//g;
			$output =~ s/^\s+//;
			$output =~ s/\s+$//;
		}
		print "$h,$ipmon,$model," .
				($err ? "FAILURE" : "SUCCESS") . ',"' .
				$err . ',' . $output . "\n";
	}

}  else {
	if (-e "$output_file-errors.txt")  {
		if (open(my $fh, "$output_file-errors.txt"))  {
			print "ERRORS:\n";
			while(<$fh>)  {  print;  }
			close($fh);
		}  else {
			log_err("opening errors file $output_file-errors.txt!", $!);
		}
	}

	if (!$test)  {
		foreach my $h (sort(@hosts))  {
			next if (!-e "$output_file-$h.txt");
			my $desc = $h . ($model_info ? ' ( ' . $conn->get_host_model($h) . 
					' / ' . $conn->get_host_os($h) . ' )' : '');
			print "---- $desc ----\n";
			if (open(my $fh, "$output_file-$h.txt"))  {
				while(my $line = <$fh>)  {  
					if ($line !~ /------ PROCESSING COMPLETE ------/)  { 
						print $line;  
					}
				}
				close($fh);
				print "\n";
			}  else {
				log_err("opening output file $output_file-$h.txt!", $!);
			}
			if (!$keep)  {
				unlink("$output_file-$h.txt");
			}
		}
	}
}

if (!$keep)  {
	unlink("$output_file-results.csv");
}

if (!$keep && is_folder_empty($dir))  {
	chdir($old_dir);
	rmdir($dir);
}
rm_pids($$);


sub usage  {
	my ($error) = @_;
	print $error . "\n\n" if (defined($error) && $error);
	print <<EOF;
Usage:  $0 (-s <script>|-S <script file>|-c|-t) (-h <hostlist>|-a) 
	-cc <client name> [-cd <client conf directory>][-C] [-k] 
	[-d <output_dir>] [-o <file_prefix>] [-u <username> -p <password>]  
	[-b] [-e] [-m] [-D <debug_level>] 

The IPncm_Connector allows for automatic contacting and running of scripts on 
a number of connected devices simultaneously.  It runs in a multi-threaded way, 
keeping connections open only as long as needed and contacting 50 devices per 
ipmon at the same time.  The code that can be run is a combination of 
command-line code and evaluated Perl code.

See README files on produtil device in IPncm_Connector/doc for 
details.

EOF
	exit(1);
}

#  process_file($opt_name, $opt_value)
#  Parses a file (whose name is $opt_value) for hosts / script.  
#  Obsolete, due to be rewritten or removed.
sub process_file  {
	my ($opt_name, $opt_value) = @_;
	my $cur_name = '';
	my $cur_block = '';
	if (!$opt_value || (!-e $opt_value))  {
		return;
	}

	open(my $fh, $opt_value) || (log_err("opening $opt_value", $!) && return);
	while (my $line = <$fh>)  {
		if ($line =~ /^\[(.*):(.*)\]$/)  {
			$request{$1} = $2;
		}  elsif ($line =~ /^\[(.*)_(start|end)\]$/)  {
			if ($2 eq 'start')  {
				$cur_name = $1;
			}  elsif ($cur_name ne '')  {
				$request{$cur_name} = $cur_block;
				$cur_name = $cur_block = '';
			}
		}  elsif ($cur_name)  {
			$cur_block .= $line;
		}  else {
			print "Error with input!  '$line'\n";
		}
	}
	close($fh);

	$script =~ s/[^!-~\s]//g;
	$script =~ s/(?:\r\n|\r)/\n/g;
	$script = decode_base64($request{conf_data});
	push(@hosts, split(/[, ]+/, $request{hostname_list}));
}


sub is_folder_empty {
	my $dirname = shift;
	opendir(my $dh, $dirname) or die "Not a directory";
	return scalar(grep { $_ ne "." && $_ ne ".." } readdir($dh)) == 0;
}


sub log_pid  {
	my ($dir, $output_file, $all_hosts, @hosts) = @_;
	open(F, ">> " . PID_FILE) || usage("Unable to open PID log file");
	print F "$$ # $dir # $output_file # $all_hosts # @hosts\n";
	close(F);
}

sub rm_pids  {
	my @pids = @_;
	lock_pid();
	open(F, PID_FILE)  || (unlock_pid() && return);
	my $file = "";
	while (my $line = <F>)  {
		my ($pid) = split(" # ", $line, 2);
		if (!grep($pid == $_, @pids))  {
			$file .= $line;
		}
	}
	close(F);
	open(F, "> " . PID_FILE) || (unlock_pid() && return);
	print F $file;
	close(F);
	unlock_pid();
}


sub log_err  {
	my ($errname, $err);
	print "Problem $errname!  $err\n";
}

sub get_pids  {
	my ($all_pids, $dir, $output_file, $all_hosts, @hosts) = @_;
	my @pids = ();
	if (-e PID_FILE)  {
		open(F, PID_FILE) || usage("Unable to open PID log file");
		my %hosts = map { $_ => 1 } @hosts;
		while (<F>)  {
			chomp;
			my ($pid, $d, $o, $a, $h) = split(" # ", $_, 5);
			my $found = 0;
			if ($all_pids)  {
				$found = 1;
			}  elsif (($d eq $dir) && ($o eq $output_file) && ($a eq $all_hosts))  {
				$found = 1;
				my @h = split(/[\;, \r\n]+/, $h);

				foreach my $h1 (@h)  {
					if (!defined($hosts{$h1}))  {
						$found = 0;
						last;
					}
				}
			}
			if ($found)  {
				push(@pids, $pid);
			}
		}
		close(F);
	}
	return @pids;
}

sub lock_pid  {
	while (-e PID_LOCK)  {
		sleep 1;
	}
	open(F, "> " . PID_LOCK);
	print F "\n";
	close(F);
}

sub unlock_pid  {
	unlink(PID_LOCK);
}
