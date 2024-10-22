#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

#
#  IPncm_Client.pl
#  
#  Simple dispatcher - uses IPncm_Client.pm to send a command to a bunch of
#  devices connected to this ipmon, printing first errors in processing (if any)
#  and then the results.
#

use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case);
use Data::Dumper;
use File::Basename;
use FindBin qw($Bin);
use MIME::Base64;
use Sys::Hostname;

use constant BASE_PATH => (-e "$Bin/lib/IPncm_Client.pm" ? $Bin : 
		(-e "$Bin/../lib/IPncm_Client.pm" ? "$Bin/.." : 
		"/home/BASE_USER/IPncm_Client"));

use lib BASE_PATH . "/lib";
use Constants;
use IPncm_Client;

use constant CONFIG_FILE => BASE_CLIENT_PATH . '/conf/client.conf';

my $debug = 0;
my $max_conn = 50;
my $user = '';
my $pw = '';
my $script = '';
my @hosts = ();
my $dir = BASE_CLIENT_PATH . "/log";
my $keep = 0;
my $output_file = 'output-' . time;
my $completion = 0;
my $test = 0;
my $all_hosts = 0;
my $enable = 0;
my $csv_out = 0;
my $backup_config = 0;
my $client = '';
my $conf_dir = '';
my $host_os = '';
my $comment = '';
my $is_cue = 0;
my $script_file = '';
my $model_info = 0;

my $conn = new IPncm_Client();

GetOptions(
		'all_hosts' => \$all_hosts, 
		'backup_config' => \$backup_config, 
		'client|cc=s' => \$client, 
		'comment|co=s' => \$comment,
		'completion|c' => \$completion, 
		'conf_dir|cd=s' => \$conf_dir,
		'CSV_out' => \$csv_out, 
		'cue|cue' => \$is_cue,
		'Debug=i' => \$debug, 
		'dir=s' => \$dir, 
		'enable' => \$enable, 
		'filename=s' => \&process_config_file, 
		'hosts|h=s' => \@hosts,
		'host_os|os=s' => \$host_os,
		'keep' => \$keep,
		'max_connections=i' => \$max_conn, 
		'model_info' => \$model_info, 
		'output|o=s' => \$output_file,  
		'password|p=s' => \$pw, 
		'script|s=s' => \$script, 
		'script_file|S=s' => \$script_file, 
		'test' => \$test, 
		'username=s' => \$user, 
);

$conn->{dir} = $dir;
$conn->{output_file} = $output_file;
$conn->{keep} = $keep;
$conn->{always_enable} = $enable;
$conn->{backup_device_config} = $backup_config;
$conn->{default_device_type} = $host_os if ($host_os);
$conn->{is_cue} = 1 if ($is_cue);
$conn->debug($debug);

$script = $script ? $script : (shift || "");
push(@hosts, @ARGV);
@hosts = split(/[\;, \r\n]+/,join(',',@hosts));
@hosts = grep(/\w/, @hosts);
push(@hosts, process_host_file()) if ($all_hosts);
@hosts = map { lc($_) } @hosts;

my @produtils = process_client_config_file();
$conn->{produtils} = \@produtils;

if ($test)  {
	$script = 'show version';
}

if ($script_file)  {
	$script = do {
		local $/ = undef;
		open my $fh, "<", $script_file
			or usage("Could not open $script_file for reading: $!");
		<$fh>;
	};
}
if (!$completion && !$backup_config && !$script)  {
	usage("No script provided");
}  elsif  (!@hosts)  {
	usage("No hosts provided");
}
if (-e $dir && ((!-d $dir) || (!-w $dir)))  {
	usage("Invalid directory option.");
}
my $decode_script = $script;
$decode_script =~ s/[^!-~\s]//g;
$decode_script =~ s/\\0//g;
if ($decode_script =~ m#^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{4}|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)$#)  {
	$script = decode_base64($decode_script);
}
$script =~ s/(?:\r\n|\r)/\n/g;

if ($user || $pw)  {
	$conn->set_login($user, $pw, undef, PRIORITY_USER_CLIENT, 'cli');
}


if ($completion)  {
	$conn->{keep} = 1;
	my ($done, $err, $total) = $conn->get_completion_counts(@hosts);
	if (defined($done))  {
		print "Complete: $done, errored: $err, total: $total\n";
	}  else {
		print "Output folder doesn't exist\n";
	}
}  else {
	print "------ IPncm_Client v" . CURRENT_VERSION . " ------\n";
	my $thr = threads->create({'context' => 'list'},
		sub { 
			$0 = basename($0) . " -co 'send_hosts main'";
			$conn->add(@hosts);
			my $output = $conn->send_hosts($script);
			my $err = $conn->error();
			my %model_map = map { $_ => $conn->get_host_model($_) } @hosts;
			my %os_map = map { $_ => $conn->get_host_os($_) } @hosts;
			return ($output, $err, \%model_map, \%os_map);
		}
	);

	my $time = 0;
	while (!$thr->is_joinable()) {
		$time++;
		if (!($time % 15))  {
			print "------ HEARTBEAT ------\n";
		}
		sleep(1);
	}
	my ($output, $err, $model_map, $os_map) = $thr->join();
	if ($csv_out)  {
		my %err_hosts = ();
		@err_hosts{@hosts} = (0) x @hosts;
		foreach my $line (split(/[\n\r]/, $err))  {
			my ($time, $function, $device, $error) = split(/: /, $line, 4);
			if (defined($device) && defined($err_hosts{$device}) && 
					!$err_hosts{$device})  {
				$err_hosts{$device} = $error;
			}
		}

		my %queues = get_host_queues(@hosts); 
		my $ipmon = hostname;
		$ipmon =~ s/\.ip-soft\.net//;
		foreach my $h (sort(@hosts))  {
			my $err = $err_hosts{$h};
			my $model = $model_info ? '"' .
					(defined($model_map->{$h}) ? $model_map->{$h} : 
					"Unknown model") . '","' . 
					(defined($os_map->{$h}) ? $os_map->{$h} : 
					"Unknown OS") . '",' : "";
			$err = (defined($err) && $err) ? $err : "";
			$err =~ s/"/'/g;
			$err =~ s/ at [^ ]*\.pm .*//;
			my $output = $output->{$h} || "";
			$output =~ s/-- [^\n]* --\n//g;
			$output =~ s/------ [^\n]* ------\n//g;
			if (($output =~ /\w.*\n.*\w/s) || ($output !~ /\w/))  { 
				$output = ""; 
			}  else {
				$output =~ s/(?:\n|\r\n)//g;
				$output =~ s/^\s+//;
				$output =~ s/\s+$//;
			}
			my $queue = defined($queues{$h}) ? '"' . $queues{$h} . '"' : "";
			print "$h,$ipmon,$queue,$model" .
					($err ? "FAILURE" : "SUCCESS") . ',"' .
					$err . '",' . $output . "\n";
		}

	}  else {
		if ($err)  {
			print "---- ERRORS ----\n$err\n";
		}

		if (!$test)  {
			foreach my $host (keys %$output)  {
				my $model = defined($model_map->{$host}) ? $model_map->{$host}
						: "";
				my $os = defined($os_map->{$host}) ? $os_map->{$host}
						: "";
				my $host_out = defined($output->{$host}) ? $output->{$host}
						: "";
				print "---- $host ( $model | $os ) ----\n$host_out\n";
			}
		}
	}
}

sub usage  {
	print "ERROR:  $_[0]\n" if ($_[0]);
	print <<EOF;
Usage:  $0 (-s <script>|-c|-t|-f <input_file>) (-h <hostlist>|-a) [-C] 
	[-m <max_connections>] [-d <output_dir>] [-k] [-o <file_prefix>] 
	[-u <username> -p <password>] [-b] [-e] [-D <debug_level>]

The IPncm_Client allows for automatic contacting and running of scripts on 
a number of connected devices simultaneously.  It runs in a multi-threaded way, 
keeping connections open only as long as needed and contacting 50 devices per 
at the same time.  The code that can be run is a combination of command-line 
code and evaluated Perl code.

See README files on produtil device in IPncm_Connector/doc for 
details.

EOF
	exit(1);
}

sub log_err  {
	my ($errname, $err);
	print "Problem $errname!  $err\n";
}


#  process_config_file($opt_name, $opt_value)
#  Function:  Uses the values in the given configuration file to set the login
#    information and script(s) to be sent to the host(s).  Called from 
#    Getopt::Long::GetOptions().  The file format is:
#    Host: <host name 1/host pattern 1>
#    script line 1
#    script line 2...
#    Host: <host 2>
#    script line 3...
#    Host: <host login pattern 1>
#    Login:  <username>, <password 1>, <password 2>
#    Host: <host login pattern 2>...
#  Parameters:  $opt_name:  ignored.
#      $opt_value - string:  the filename of the file to process.
#  Returns:  N/A
sub process_config_file  {
	my ($opt_name, $opt_value) = @_;
	if (!$opt_value || (!-e $opt_value))  {
		return;
	}

	open(my $fh, $opt_value) || (log_err("opening $opt_value", $!) && return);
	my $cur_host = '';
	$script = {};
	my @values = ();
	while (my $line = <$fh>)  {
		chomp($line);
		if ($line =~ /^(?:Host|Login): (.*) \((.*)\) - (.*) == (.*)$/)  {
			my ($h, $p, $k, $v) = ($1, $2, $3, $4);
			$conn->{config}->set_value($k, $v, $h, $p);
		}  elsif ($line =~ /^Host: (.*)$/)  {
			$cur_host = $1;
		}  elsif ($line =~ /^Host List: (.*)$/)  {
			push(@hosts, $1);
		}  elsif ($cur_host)  {
			if ($line =~ /^Login: \((.*)\) ([^ ]*), ([^ ]*)(?:, ([^ ]*))?$/)  {
				my ($p, $u, $pw, $pw2) = ($1, $2, $3, $4);
				$conn->{config}->set_value('user', $u, $cur_host, $p);
				$conn->{config}->set_value('pw', $pw, $cur_host, $p);
				$conn->{config}->set_value('pw2', $pw2, $cur_host, $p) if (defined($pw2) && $pw2);
			}  else {
				$script->{$cur_host} .= $line . "\n";
			}
		}  else {
			print "Error with input!  '$line'\n";
		}
	}
	close($fh);
}

sub process_host_file  {
	open(F, STATUS_FILE) || 
			usage("Couldn't access status file: $!");
	my %hosts = ();
	while (<F>)  {
		if (/^\s*host_name\s*=\s*([^\s]*)\s*$/)  {
			my $h = lc($1);
			next if (!$h || ($h =~ /^ipmon/));
			$hosts{$h} = 1;
		}
	}
	close(F);
	return keys(%hosts);
}

sub process_client_config_file  {
	open(F, CONFIG_FILE) || 
			usage("Couldn't access config file: $!");
	my %produtils = ();
	my $type = "";
	while (<F>)  {
		next if (/^\s*$/ || /^\s*#/);
		if (/^(\w.*):/)  {
			$type = $1;
		}  elsif ($type eq "Produtils")  {
			if (/^\t(\w.*?)\s*$/)  {
				$produtils{$1} = 1;
			}
		}
	}
	close(F);
	return keys(%produtils);
}

sub get_host_queues  {
	my $this = shift;
	my @hosts = @_;
	
	my $cmd = "grep '_host;default_ipim_queue' " . 
			"/apps/Company/IPmon/etc/attributes.cfg | egrep '(" . 
			join("|", @hosts) . ")'";
	my $results = `$cmd`;
	
	my %output = ();
	while ($results =~ 
			m/^attribute\[([^\]]*)]=_host;default_ipim_queue;(.*)/mg)  {
		$output{$1} = $2;
	}
	
	return %output;
}
