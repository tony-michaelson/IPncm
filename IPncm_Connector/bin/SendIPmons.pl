#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

#
#  SendIPmons.pl
#  
#  Sends a set of commands to one or more IPmons.  See usage for info.
#

use strict;
use warnings;
use Cwd;
use FindBin qw($Bin);
use MIME::Base64;

use constant BASE_PATH => (-e "$Bin/lib/IPncm_Connector.pm" ? $Bin : 
		(-e "$Bin/../lib/IPncm_Connector.pm" ? "$Bin/.." : 
		"/home/BASE_USER/IPncm_Connector"));
use lib BASE_PATH . "/lib";
use IPncm_Connector;

use Data::Dumper;
use Getopt::Long qw(:config no_ignore_case);

my %request = ();
my @hosts = ();
my $script = '';
my $dir = '/home/BASE_USER/IPncm_Connector/';
my $keep = 0;
my $output_file = 'output-' . time;
my $debug = 0;
my $csv_out = 0;
my $indirect = 0;
my $ipmon_user = '';
my $ipmon_pw = '';
my $x = 0;

my $conn = new IPncm_Connector();

GetOptions('filename=s' => \&process_file, 'hosts=s' => \@hosts,
		'script=s' => \$script, 'dir=s' => \$dir, 'keep' => \$keep,
		'output=s' => \$output_file, 'indirect|i' => \$indirect,
		'Debug=i' => \$debug, 'CSV_OUT' => \$csv_out,
		'ipmon_user=s' => \$ipmon_user, 'ipmon_pw=s' => \$ipmon_pw, 
		'x' => \$x);

$conn->{dir} = $dir;
$conn->{output_file} = $output_file;
$conn->{keep} = $keep;
$conn->{all_hosts} = 1;
$conn->{ipmon_creds}->[0] = $ipmon_user if ($ipmon_user);
$conn->{ipmon_creds}->[1] = $ipmon_pw if ($ipmon_pw);
$conn->debug($debug) if ($debug > 0);

$script = $script ? $script : (shift || "");
push(@hosts, @ARGV);
@hosts = split(/[\;, \r\n]+/,join(',',@hosts));
@hosts = grep(/\w/, @hosts);
@hosts = map { lc($_) } @hosts;

if (!@hosts)  {
	usage("No hostnames provided.");
}
if (!$script)  {
	usage("No commands provided.");
}
if ($script =~ m#^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{4}|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)$#)  {
	$script = decode_base64($script);
}

if (-e $dir && !-d $dir)  {
	usage("Invalid directory option.");
}

if (!-e $dir)  {
	mkdir($dir) || usage("Couldn't create directory");
}
my $old_dir = getcwd;
chdir($dir);

my $err = "";
my $cmd_out = {};

if (!$indirect)  {
	$conn->add_ipmons(@hosts);
}  else {
	$conn->add(@hosts);
}

eval  {
	$err .= $conn->error();
	if ($err =~ /\w/)  {
		open(F, "> $output_file-errors.txt");
		print F "ERRORS:\n$err\n\n";
		close(F);
	}

	$cmd_out = $conn->send_ipmons($script, !$indirect, 0, $x, @hosts);
	$err .= $conn->error();
	if ($err =~ /\w/)  {
		open(F, "> $output_file-errors.txt");
		print F "ERRORS:\n$err\n\n";
		close(F);
	}
};

if ($@)  {
	open(F, "> $output_file-errors.txt");
	print F "ERRORS:\n$@\n\n";
	close(F);
}

@hosts = keys(%$cmd_out);

foreach my $key (keys(%$cmd_out))  {
	open(F, ">> $output_file-$key.txt");
	print F $cmd_out->{$key};
	close(F);
}

if ($csv_out)  {
	my %err_hosts = ();
	@err_hosts{@hosts} = (0) x @hosts;
	if (-e "$output_file-errors.txt")  {
		open(F, "$output_file-errors.txt");
		while (<F>)  {
			chomp;  chomp;
			my ($time, $function, $device, $error) = split(/: /, $_, 4);
			if (defined($device) && defined($err_hosts{$device}) && 
					!$err_hosts{$device})  {
				$err_hosts{$device} = $error;
			}
		}
		close(F);
	}

	my %queues = $conn->get_host_queues(@hosts); 
	foreach my $h (sort(@hosts))  {
		my $ipmon = $conn->get_ipmon($h);
		$ipmon = defined($ipmon) ? $ipmon : "unknown ipmon";
		my $err = $err_hosts{$h};
		$err = (defined($err) && $err) ? $err : "";
		$err =~ s/"/'/g;
		$err =~ s/ at [^ ]*\.pm .*//;
		my $queue = defined($queues{$h}) ? '"' . $queues{$h} . '"' : "";
		print "$h,$ipmon,$queue," .
				($err ? "FAILURE" : "SUCCESS") . ',"' .
				$err . '"' . "\n";
	}

}  else {
	if (-e "$output_file-errors.txt")  {
		open(F, "$output_file-errors.txt");
		while(<F>)  {  print;  }
		close(F);
	}

	foreach my $h (sort(@hosts))  {
		next if (!-e "$output_file-$h.txt");
		my $desc = $h;
		print "---- $desc ----\n";
		open(F, "$output_file-$h.txt");
		while(<F>)  {  print;  }
		close(F);
		print "\n";
		if (!$keep)  {
			unlink("$output_file-$h.txt");
		}
	}
}

if (!$keep && is_folder_empty($dir))  {
	chdir($old_dir);
	rmdir($dir);
}


sub usage  {
	my ($error) = @_;
	print $error . "\n\n" if (defined($error) && $error);
	print <<EOF;
Usage:  $0 -s <script> -h <devices> [-i] [-C] [-d <output_dir>] [-k] 
	[-o <file_prefix>] [-D <debug_level>]
	

SendIpmons allows for automatic running of scripts on a number of IPmons. 

Options:
	-s <script>
		This is the script to be run, consisting of a list of commands 
		to be run (separated by newlines).  Base64-encoded data 
		is properly decoded before evaluation.  If "<HOST_LIST>" is present
		in the command, it is replaced with a space-separated list of the 
		devices used to contact that IPmon if the -i option is set, or an 
		empty string otherwise.
	-h <device_list>
		A comma-separated list of devices.  These devices can either be a list
		of ipmons, or (if the -i option is set) a list of hostnames (in which 
		case the ipmons that are being used to contact those hosts are used).
	[-i]
		If not set, the -h hostlist is considered to be a list of IPmons.  If
		set, the -h hostlist is considered to be a list of hosts and the IPmons
		that correspond to those hosts are used.
	[-C]
		If present, prints the output as a CSV file, with the syntax 
		"<hostname>, <ipmon>, <status>, <failure reason>" - the status is 
		either "SUCCESS" or "FAILURE", and the failure reason is the first line 
		of error output.
	[-d <dir>]
		The directory where output is stored (temporarily, if the -k option is 
		not provided).  Defaults to /home/BASE_USER/IPncm_Connector/tmp.
	[-k]
		If used, this option leaves the output directory and output files 
		intact after execution completes.  Otherwise, the output files and 
		output directory are removed at the end of execution.
	[-o <output_file>]
		Specifies a pattern for the name of the output files.  Output files 
		are called <output_file>-<hostname>.txt.  Defaults to 
		"output-<current_timestamp>", so new files will be called something 
		list "output-1379008409-ise.thd.txt".  The file containing errors will 
		be called "<output_file>-errors.txt".
	[-D <debug_level>]
		Adds additional debug output.  <debug_level> can consist of or'd 
		together numbers:
			1 - Connection information
			2 - Command sending information
			4 - Timing information (testing for how long it takes to process 
				particular functions)
			8 - SSH connection and Net::Appliance::Session debug information.


The output is presented in the following format:

---- device_1 ----
-- commmand_1 --
Command 1 output

-- command_2 --
Command 2 output

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

	open(F, $opt_value);
	while (my $line = <F>)  {
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
	close(F);

	$script = decode_base64($request{conf_data});
	push(@hosts, split(/[, ]+/, $request{hostname_list}));
}


sub is_folder_empty {
	my $dirname = shift;
	opendir(my $dh, $dirname) or die "Not a directory";
	return scalar(grep { $_ ne "." && $_ ne ".." } readdir($dh)) == 0;
}
