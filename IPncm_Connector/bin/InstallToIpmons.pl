#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

#
#  InstallToIpmons.pl
#  
#  Given a customer config file, installs IPncm on all ipmons for that customer 
#  - copies over appropriate IPncm_Client.tar.gz file, uncompresses it, runs
#  prove against it, prints out test results.  
#

use strict;
use warnings;
use FindBin qw($Bin);
use Getopt::Long qw(:config no_ignore_case);
use Sys::Hostname;

use constant BASE_PATH => (-e "$Bin/lib/IPncm_Connector.pm" ? $Bin : 
		(-e "$Bin/../lib/IPncm_Connector.pm" ? "$Bin/.." : 
		"/home/BASE_USER/IPncm_Connector"));
use lib BASE_PATH . "/lib";
use Constants;
use IPncm_Connector;

my $loggable = 1;

my $no_test = 0;
my @clients = ();
my $conf_dir = BASE_PRODUTIL_PATH . "/conf";
my $bin_dir = BASE_PRODUTIL_PATH . "/bin";
my $log_dir = BASE_PRODUTIL_PATH . "/log";

my $uninstall = 0;
my @ipmons = ();

GetOptions('notest' => \$no_test, 'clients|cc=s' => \@clients,
		'conf_dir|cd=s' => \$conf_dir, 'bin_dir=s' => \$bin_dir,
		'uninstall=i' => \$uninstall, 'ipmons=s' => \@ipmons);

@clients = split(/[\;, \r\n]+/,join(',',@clients));
@clients = grep(/\w/, @clients);
push(@ipmons, @ARGV);
@ipmons = split(/[\;, \r\n]+/,join(',',@ipmons));
@ipmons = grep(/\w/, @ipmons);

my @invasive_test_devices = ();
my @noninvasive_test_devices = ();
my @produtils = (hostname);

my $conn = new IPncm_Connector();
$conn->{all_hosts} = 1;

log_output("\n------ gathering client information ------\n");
my $found = 0;
foreach my $client (@clients)  {	
	if (!$client || !$conn->add_client_config($client))  {
		log_output("$client configuration file not found - skipping");
	}  else {
		$found = 1;
	}
}

my $u = 'BASE_USER';

my %p = ();
foreach my $pr (@produtils)  {
	$pr =~ s/(?:\.Company.com|\.ip-soft.net)$//;
	$p{$pr} = 1;
}
@produtils = keys(%p);

if (!$found)  {
	die("No valid client files found");
}
if (!-e "$bin_dir/IPncm_Client-32.tar.gz" || 
		!-e "$bin_dir/IPncm_Client-64.tar.gz")  {
	die("Installer files not found");
}
if (!@ipmons)  {
	@ipmons = uniq(flatten(@{$conn->{ipmons}}));
	if (!@ipmons)  {
		die("No valid ipmons found");
	}
}
my $output = $conn->send_ipmons("uname -i", 1, 0, 0, @ipmons);
my @ipmon_32 = ();
my @ipmon_64 = ();
foreach my $ipmon (keys(%$output))  {
	if ($output->{$ipmon} =~ /i386/)  {
		push(@ipmon_32, $ipmon);
	}  elsif ($output->{$ipmon} =~ /_64/)  {
		push(@ipmon_64, $ipmon);
	}  else  {
		log_output("ERROR getting device type from $ipmon - skipping\n");
	}
}
my @valid_ipmons = @ipmon_32;
push(@valid_ipmons, @ipmon_64);
my $err = $conn->error();

if ($uninstall)  {
	log_output("\n------ uninstalling old version ------\n");
	log_output("IPmons being uninstalled from:  @valid_ipmons\n");
	$output = $conn->send_ipmons("rm -rf IPncm_Client perl5 perl5.old .perlbrew",
			1, 0, 0, @valid_ipmons);
	
	if ($uninstall > 1)  {
		log_output("\n------ uninstallation complete ------\n");
		exit(0);
	}
}

log_output("\n------ running client device tests ------\n");
$output = $conn->send_ipmons("head " . STATUS_FILE, 1, 0, 0, @ipmons);
$err = $conn->error();
foreach my $ipmon (keys(%$output))  {
	if (($output->{$ipmon} =~ /cannot open/) || ($err =~ /$ipmon.*cannot open/))  {
		if (($output->{$ipmon} =~ /No such file or directory/) || 
				($err =~ /$ipmon.*No such file or directory/))  {
			log_output("ERROR:  " . STATUS_FILE . " does not exist on $ipmon - " . 
					"please create it and make it readable to the $u user\n");
		}  else {
			log_output("ERROR:  " . STATUS_FILE . " is unreadable on $ipmon - " . 
					"please make it readable to the $u user\n");
		}
	}
}

$output = $conn->send_ipmons("head " . CLOGIN_FILE, 1, 0, 0, @ipmons);
$err = $conn->error();
foreach my $ipmon (keys(%$output))  {
	if (($output->{$ipmon} =~ /cannot open/) || ($err =~ /$ipmon.*cannot open/))  {
		if (($output->{$ipmon} =~ /No such file or directory/) || 
				($err =~ /$ipmon.*No such file or directory/))  {
			log_output("ERROR:  " . CLOGIN_FILE . " does not exist on $ipmon - " . 
					"please create it and make it readable to the $u user\n");
		}  else {
			log_output("ERROR:  " . CLOGIN_FILE . " is unreadable on $ipmon - " . 
					"please make it readable to the $u user\n");
		}
	}
}

my $b_u = "BASEUSER";
$b_u =~ s/EU/E_U/;

if (@ipmon_32)  {
	log_output("\n------ sending 32-bit clients ------\n");
	log_output("IPmons being sent to:  @ipmon_32\n");
	$conn->send_ipmons("$bin_dir/IPncm_Client-32.tar.gz", 1, 
			BASE_U_PATH, 0, @ipmon_32);
	$output = $conn->send_ipmons("tar -zxf IPncm_Client-32.tar.gz\nrm IPncm_Client-32.tar.gz\ncd IPncm_Client\ngrep -rl '$b_u' ./ | xargs sed -i 's/$b_u/$u/g'", 
			1, 0, 0, @ipmon_32);
}
if (@ipmon_64)  {
	log_output("\n------ sending 64-bit clients ------\n");
	log_output("IPmons being sent to:  @ipmon_64\n");
	$conn->send_ipmons("$bin_dir/IPncm_Client-64.tar.gz", 1, 
			BASE_U_PATH, 0, @ipmon_64);
	$output = $conn->send_ipmons("tar -zxf IPncm_Client-64.tar.gz\nrm IPncm_Client-64.tar.gz\ncd IPncm_Client\ngrep -rl '$b_u' ./ | xargs sed -i 's/$b_u/$u/g'", 
			1, 0, 0, @ipmon_64);
}

log_output("\n------ sending configuration file ------\n");
$conn->send_ipmons("echo 'Produtils:\n\t" . join("\n\t", @produtils) . 
		"\n' > " . BASE_CLIENT_PATH . "/conf/client.conf", 1, 0, 0, @valid_ipmons);

if ($no_test)  {
	log_output("\n------ skipping testing ------\n");
}  else {
	$conn->add(@invasive_test_devices);
	$conn->add(@noninvasive_test_devices);

	log_output("\n------ building test configurations ------\n");
	my %ipmon_to_qafile = ();
	my @test_ipmons = ();
	foreach my $ipmon (@ipmons)  {
		my @ipmon_set = ($ipmon);
		my $found_test = 0;
		foreach my $ipmons (@{$conn->{ipmons}})  {
			if (ref($ipmons))  {
				if (grep($ipmon eq $_, @{$ipmons}))  {
					push(@ipmon_set, @$ipmons);
				}
			}
		}
		@ipmon_set = uniq(flatten(@ipmon_set));
		my $file = "echo 'Invasive Test Devices:\n";
		my @hosts = ();
		foreach my $host (@invasive_test_devices)  {
			my $ip = $conn->_select_ipmon($host);
			if (defined($ip) && grep($ip eq $_, @ipmon_set))  {
				$file .= "\t$host\n";
				$found_test = 1;
			}
		}

		$file .= "\nNoninvasive Test Devices:\n";
		foreach my $host (@noninvasive_test_devices)  {
			my $ip = $conn->_select_ipmon($host);
			if (defined($ip) && grep($ip eq $_, @ipmon_set))  {
				$file .= "\t$host\n";
				$found_test = 1;
			}
		}
		$file .= "' > " . BASE_CLIENT_PATH . "/conf/test.conf";
		if ($found_test)  {
			$ipmon_to_qafile{$ipmon} = $file;
			push(@test_ipmons, $ipmon);
		}  else {
			log_output("No test devices found for $ipmon - skipping tests\n");
		}
	}

	if (@test_ipmons)  {
		$conn->send_ipmons(\%ipmon_to_qafile, 1, 0, 0, @test_ipmons);

		log_output("\n------ running client test suites ------\n");
		$output = $conn->send_ipmons("source ~/perl5/perlbrew/etc/bashrc\n" .
					"cd IPncm_Client\n" . 
					"prove 2>&1", 1, 0, 0, @test_ipmons);
		foreach my $ipmon (keys(%$output))  {
			log_output("---- $ipmon ----\n" . $output->{$ipmon} . "\n");
		}
	}

	log_output("---- produtil ----\n\n");
	log_output(`prove`);
}
log_output("\n------ installation complete ------\n");


#  flatten(@arr)
#  Function:  Flattens an array, making it into a simple one-dimensional array.
#  Parameters:  @arr - array of elements: the array to flatten.  Elements may 
#      be scalars or array references.
#  Returns:  array of scalar: the flattened array.
sub flatten {
  map { ref $_ ? flatten(@{$_}) : $_ } @_;
}


sub uniq {
    my %seen = ();
    my @r = ();
    foreach my $a (@_) {
        unless ($seen{$a}) {
            push @r, $a;
            $seen{$a} = 1;
        }
    }
    return @r;
}


sub parse_config_files  {
	my @files = @_;
	
	foreach my $config (@files)  {
		next if (!-e $config);
		open(FILE, $config) || next;
		my $type = '';
		my $cur_ipmon = "";
		while(<FILE>)  {
			next if (/^\s*$/ || /^\s*#/);
			if (/^(\w.*):/)  {
				$type = $1;
			}  elsif ($type eq "Invasive Test Devices")  {
				if (/^	(\w.*?)\s*$/)  {
					push(@invasive_test_devices, $1);
				}
			}  elsif ($type eq "Noninvasive Test Devices")  {
				if (/^	(\w.*?)\s*$/)  {
					push(@noninvasive_test_devices, $1);
				}
			}  elsif ($type eq "Produtils")  {
				if (/^	(\w.*?)\s*$/)  {
					push(@produtils, $1);
				}
			}
		}
	}
}

sub log_output  {
	my ($output) = @_;
	if ($loggable)  {
		open(F, ">> $log_dir/install-" . CUR_TIMESTAMP . ".log") || 
				((print "Can't write to log file!\n") && ($loggable = 0));
		if ($loggable)  {
			print F "$output\n";
			close(F);
		}
	}
	print "$output\n";
}
