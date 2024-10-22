package Upgrade_ASA;

use strict;
use warnings;

no if $] >= 5.017011, warnings => 'experimental::smartmatch';

#
#  Script to perform upgrades for an ASA device.
#
#  Parameters:
#    $upgrade_version - string:  version number to upgrade to.
#    $run_config - boolean:  if true, run the configuration (rather than
#        just printing the new configuration).
#    $upgrade_file - string:  file name of new configuration (defaults to 
#        value determined from $version in %known_types).
#    $upgrade_size - int:  file size of new configuration (defaults to 
#        value determined from $version in %known_types).
#

my %known_types = (
	'asa911-162-smp-k8.bin' => [
		'9.1(1)162',
		223734376,
	], 
);

my @neighbors = ();
my @interfaces = ();
my @ip_int_bri = ();
my $ip_route = '';
my $max_valid = 0;


sub run  {
	my ($this, $conn, $hostname, $upgrade_file, $run_config, $upgrade_version, 
			$upgrade_size) = @_;
	
	if (!defined($upgrade_file))  {
		$conn->log_error("No given upgrade file");
		return;
	}
	$run_config = defined($run_config) ? $run_config : 0;
	$upgrade_version = defined($upgrade_version) ? $upgrade_version :
		(defined($known_types{$upgrade_file}->[0]) ? 
		$known_types{$upgrade_file}->[0] : undef);
	if (!defined($upgrade_version))  {
		$conn->log_error("Given upgrade file is incompatible with this device");
		return;
	}
	$upgrade_size = defined($upgrade_size) ? $upgrade_size :
		(defined($known_types{$upgrade_file}->[1]) ? 
		$known_types{$upgrade_file}->[1] : undef);
	if (!defined($upgrade_size))  {
		$conn->log_error("No given upgrade size");
		return;
	}
	
	if (run_pre_installation($this, $conn, $hostname, $upgrade_file, 
			$run_config, $upgrade_version, $upgrade_size) && $run_config)  {
		if (run_installation($this, $conn, $hostname, $upgrade_file, 
				$run_config, $upgrade_version, $upgrade_size))  {
			run_post_installation($this, $conn, $hostname, $upgrade_file, 
					$run_config, $upgrade_version, $upgrade_size);
		}
	}
}

sub run_pre_installation  {
	my ($this, $conn, $hostname, $upgrade_file, $run_config, $upgrade_version, 
			$upgrade_size) = @_;

	#  Test whether upgrade is necessary
	my $output = $conn->send_host("sh version | i System image file");
	print "$output\n";
	if ($output =~ /$upgrade_file/)  {
		print "Upgrade file is already system image file, no upgrade necessary\n";
		return 0;
	}
	
	my $continue = 1;
	$output = $conn->send_host("show flash");
	if ($output !~ /$upgrade_file/)  {
		$output =~ /(\d+) bytes available /;
		my $cur_space = $1;
		if ($cur_space <= $upgrade_size)  {
			while ($output =~ /(\S+\.bin)/g)  {
				$conn->send_host("delete flash:" . $1); 
			}
			$output = $conn->send_host("show flash");
			$output =~ /(\d+) bytes available /;
			$cur_space = $1;
		}
		if ($cur_space > $upgrade_size)  {
			print $conn->send_host("copy ftp://anonymous\@171.70.168.154/images/" .
					"$upgrade_file flash:$upgrade_file");
		}  else {
			$conn->log_error("ABORTING INSTALL - Not enough disk space to proceed");
			$continue = 0;
		}
	}
	
	$output = $conn->send_host("show run");
	print "$output\n";
	
	$output = $conn->send_host("show version");
	print "$output\n";

	$output = $conn->send_host("show vpn-sessiondb detail");
	print "$output\n";
		
	$output = $conn->send_host("dir flash:");
	print "$output\n";
	
	if ($output !~  /$upgrade_file/)  {
		$conn->log_error("ABORTING INSTALL - image not present after copy");
		$continue = 0;
	}
	
	$output = $conn->send_host("verify flash:" . $upgrade_file);
	print $output;
	if ($output =~ /fail/i)  {
	#TODO:  fail if verification fails.
			$conn->log_error("ABORTING INSTALL - file verification failed");
			$continue = 0;
	}
		
	return $continue;
}


sub run_installation  {
	my ($this, $conn, $hostname, $upgrade_file, $run_config, $upgrade_version, 
			$upgrade_size) = @_;
		
	# Run configuration
	my $range = $max_valid == 1 ? "1" : "1-$max_valid";
	my $config1 = <<EOF;
boot system disk0:/$upgrade_file
EOF

	my $config2 = <<EOF;
conf t
vpn load-balancing
no participate
exit
write mem
reload
EOF

	if ($run_config)  {
		#  Start blocking - only one device can perform the upgrade at a time.
		block_connections();

		print $conn->send_host($config1, undef, 900) . "\n";
	
		my $output = $conn->send_host("sh bootvar");
		if ($output !~ /$upgrade_file/)  {
			$conn->log_error("Upgrade file not in 'sh bootvar' after config change - aborting upgrade!");
			return 0;
		}
		
		print $output = $conn->send_host($config2, undef, 900) . "\n";
		if ($output =~ /aborted/)  {
			$conn->log_error("Upgrade aborted by device");
			return 0;
		}
		sleep(360);
	}  else {
		print "TEST MODE, OTHERWISE WOULD RUN:\n$config1\n$config2\n";
	}
	return 1;
}


sub run_post_installation  {
	my ($this, $conn, $hostname, $upgrade_file, $run_config, $upgrade_version, 
			$upgrade_size) = @_;

			
	# Post-config checks
	my $output = $conn->send_host("sh version");
	print "$output\n";
	
	if (($output !~ /$upgrade_version/) || 
			($output !~ /System image file is ".*:\/$upgrade_file\"/))  {
		$conn->log_error("System not upgraded to new version");
	}
	my @non_upgraded = ();
	
	$output = $conn->send_host("sh crypto accelerator load-balance");
	my $in_flag = 0;
	print "$output\n";
	foreach my $line (split(/\n/, $output))  {
		if ($line =~ /Crypto IPSEC Load Balancing Stats:/)  {
			$in_flag++;
		}  elsif ($in_flag)  {
			if ($line =~ /Commands Completed/)  {
				$in_flag = 0;
			}  elsif ($line =~ /^\s*(\d+)\s*.*Active:\s*(\d+)/)  {
				if (!$2)  {
					$conn->log_error("Engine $1 has no Active");
				}
			}
		}
	}
	
	my $config = <<EOF;
conf t
vpn load-balancing
participate
exit
write mem
EOF
	if ($run_config)  {
		print $conn->send_host($config);
	}  else {
		print "TEST MODE, OTHERWISE WOULD RUN:\n$config\n";
	}
	
	$output = $conn->send_host("sh vpn-sessiondb detail");
	print "$output\n";
	if ($output =~ /Total Active and Inactive\s*:\s*(\d+)/)  {
		if (!$1)  {
			$conn->log_error("Total Active and Inactive is 0");
		}
	}
	
	
}

1;
