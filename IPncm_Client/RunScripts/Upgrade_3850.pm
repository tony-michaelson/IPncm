package Upgrade_3850;

use strict;
use warnings;

no if $] >= 5.017011, warnings => 'experimental::smartmatch';

#
#  Script to perform upgrades for a 3850 device.
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
	'cat3k_caa-universalk9.SPA.03.02.02.SE.150-1.EX2.bin' => [
		'03.02.02.SE',
		223734376,
	], 
	'cat3k_caa-universalk9.SPA.03.02.03.SE.150-1.EX3.bin' => [
		'03.02.03.SE',
		223743040,
	],
	'cat3k_caa-universalk9.SPA.03.03.01.SE.150-1.EZ1.bin' => [
		'03.03.01.SE',
		257193048,
	],
	'cat3k_caa-universalk9.SPA.03.03.02.SE.150-1.EZ2.bin' => [
		'03.03.02.SE',
		257243236,
	],
	'cat3k_caa-universalk9.SPA.03.03.03.SE.150-1.EZ3.bin' => [
		'03.03.03.SE',
		257399072,
	],
	'cat3k_caa-universalk9.SPA.03.03.04.SE.150-1.EZ4.bin' => [
		'03.03.04.SE',
		257642204,
	],
	'cat3k_caa-universalk9.SPA.03.06.02a.E.152-2a.E2.bin' => [
		'03.06.02a.E',
		0,
	],
	'cat3k_caa-universalk9.SSA.03.09.88.EXP.150-9.88.EXP.bin' => [
		'03.09.88.EXP',
		57589760,
	],
	'cat3k_caa-universalk9.SPA.03.07.01.E.152-3.E1.bin' =>  [
		'03.07.01.E',
		0,
	],
	'cat3k_caa-universalk9.SSA.03.06.03.E.CES.3.152-2.1.E3CES.bin' =>  [
		'03.06.03.E.CES.3',
		302883072,
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
	my $output = $conn->send_host("sh version | in INSTALL");
	print "$output\n";

	my @switches = ();
	foreach my $line (split(/\n/, $output))  {
		if ($line =~ (/^\s*\*?\s*(\d+)\s+\d+\s+\S+\s+(\S+)/))  {
			my ($sw, $version) = ($1, $2);
			if ($version ne $upgrade_version)  {
				push(@switches, $sw);
			}
		}
	}
	if (!@switches)  {
		print "All switches are at version $upgrade_version, no need to upgrade\n";
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
	
	$output = $conn->send_host("show switch detail");
	print "$output\n";

	$output = $conn->send_host("show switch");
	my @invalid = ();
	foreach my $line (split(/\n/, $output))  {
		if ($line =~ /^[\* ]*(\d+).*?(\S+)\s*$/)  {
			if (defined($2) && ($2 eq "Ready"))  {
				if ($1 > $max_valid)  {
					$max_valid = $1;
				}
			}  else {
				push(@invalid, $1);
			}
		}
	}
	if (@invalid)  {
		$conn->log_error("ABORTING INSTALL - switch(es) " . join(", ", @invalid) . 
				" not in Ready state");
		$continue = 0;
	}
	
	$output = $conn->send_host("show redundancy");
	print "$output\n";
	if ($output =~ /Hardware Mode = Duplex/)  { 
		if (($output !~ /Configured Redundancy Mode = SSO/) || 
				($output !~ /Operating Redundancy Mode = SSO/))  {
			$conn->log_error("ABORTING INSTALL - redundancy mode is not SSO");
			$continue = 0;
		}  elsif ($output !~ m/Peer Processor Information.*Current Software state = STANDBY HOT/s)  {
			$conn->log_error("ABORTING INSTALL - redundant switch not in STANDBY HOT state");
			$continue = 0;
		}
	}
	
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
	
	$output = $conn->send_host("sh cdp neighbor");
	my $found = 0;
	foreach my $neighbor (split(/\n/, $output))  {
		if ($neighbor =~ /^Device ID/)  {
			$found++;
			next;
		}
		if ($found && ($neighbor !~ /^\s/))  {
			my @line = split(/\s+/, $neighbor);
			push(@neighbors, $line[0]);
		}
	}			
	print "Neighbors:  @neighbors\n";

	$output = $conn->send_host("sh interface description | ex down");
	foreach my $interface (split(/\n/, $output))  {
		next if (($interface =~ /^--/) || ($interface =~ /^Interface\s/));
		my @line = split(/\s+/, $interface);
		push(@interfaces, $line[0]) if (defined($line[0]) && $line[0]);
	}
	@interfaces = sort(@interfaces);
	print "Interfaces:  @interfaces\n";
	
	$output = $conn->send_host("sh ip int brief | ex down");
	foreach my $interface (split(/\n/, $output))  {
		next if (($interface =~ /^--/) || ($interface =~ /^Interface\s/));
		my @line = split(/\s+/, $interface);
		push(@ip_int_bri, $line[0]) if (defined($line[0]) && $line[0]);
	}
	@ip_int_bri = sort(@ip_int_bri);
	print "IP int bri:  @ip_int_bri\n";
	
	$output = $conn->send_host("sh ip route 0.0.0.0");
	if ($output =~ /^\s+\*\s+(.*)/)  {
		$ip_route = $1;
	}
	print "Gateway: $ip_route\n";
	
	$output = $conn->send_host("sh environment all");
	print "$output\n";
	foreach my $line (split(/\n/, $output))  {
		if (($line !~ /^(?:SW\s*PID|\-)/) && ($line !~ /(?:Good|OK)/))  {
			$conn->log_error("ABORTING INSTALL - Environment issue:  $line\n");
			$continue = 0;
		}
	}
	
	return $continue;
}


sub run_installation  {
	my ($this, $conn, $hostname, $upgrade_file, $run_config, $upgrade_version, 
			$upgrade_size) = @_;
		
	# Run configuration
	my $range = $max_valid == 1 ? "1" : "1-$max_valid";
	my $config = <<EOF;
copy run start
software install file flash:$upgrade_file switch $range on-reboot
reload
EOF

	if ($run_config)  {
		my $output;
		print $output = $conn->send_host($config, undef, 900) . "\n";
		if ($output =~ /aborted/)  {
			$conn->log_error("Upgrade aborted by device");
			return 0;
		}
		sleep(360);
	}  else {
		print "TEST MODE, OTHERWISE WOULD RUN:\n$config\n";
	}
	return 1;
}


sub run_post_installation  {
	my ($this, $conn, $hostname, $upgrade_file, $run_config, $upgrade_version, 
			$upgrade_size) = @_;

			
	# Post-config checks
	my $output = $conn->send_host("sh version | in INSTALL");
	print "$output\n";
	
	my @non_upgraded = ();
	foreach my $line (split(/\n/, $output))  {
		if ($line =~ (/^\s*(\d+)\s+\d+\s+\S+\s+(\S+)/))  {
			my ($sw, $version) = ($1, $2);
			if ($version ne $upgrade_version)  {
				push(@non_upgraded, $sw);
			}
		}
	}
	if (@non_upgraded)  {
		$conn->log_error("Switch(es) " . join(",", @non_upgraded) . " were not " .
				"upgraded to new version");
	}
	
	$output = $conn->send_host("show switch detail");
	print "$output\n";

	$output = $conn->send_host("show switch");
	
	my $new_max_valid = 0;
	my @invalid = ();
	foreach my $line (split(/\n/, $output))  {
		if ($line =~ /^[\* ]*(\d+).*?(\S+)\s*$/)  {
			if ($1 > $new_max_valid)  {
				$new_max_valid = $1;
			}
			
			if (!defined($2) || ($2 ne "Ready"))  {
				push(@invalid, $1);
			}
		}
	}
	if ($new_max_valid != $max_valid)  {
		$conn->log_error("Were $max_valid switches before install, now " .
				$new_max_valid);
	}
	if (@invalid)  {
		$conn->log_error("Switch(es) " . join(", ", @invalid) . 
				" not in Ready state after install");
	}
	
	$output = $conn->send_host("sh cdp neighbor");
	my @new_neighbors = ();
	my $found = 0;
	foreach my $neighbor (split(/\n/, $output))  {
		if ($neighbor =~ /^Device ID/)  {
			$found++;
			next;
		}
		if ($found && ($neighbor !~ /^\s/))  {
			my @line = split(/\s+/, $neighbor);
			push(@new_neighbors, $line[0]);
		}
	}
	print "Neighbors:  @new_neighbors\n";
	if (!(@neighbors ~~ @new_neighbors))  {
		$conn->log_error("Neighbors changed after install");
	}

	my @new_interfaces = ();
	$output = $conn->send_host("sh interface description | ex down");
	foreach my $interface (split(/\n/, $output))  {
		next if (($interface =~ /^--/) || ($interface =~ /^Interface\s/));
		my @line = split(/\s+/, $interface);
		push(@new_interfaces, $line[0]);
	}
	@new_interfaces = sort(@new_interfaces);
	print "Interfaces:  @new_interfaces\n";
	if (!(@interfaces ~~ @new_interfaces))  {
		$conn->log_error("Interfaces changed after install");
	}
	
	my @new_ip_int_bri = ();
	$output = $conn->send_host("sh ip int brief | ex down");
	foreach my $interface (split(/\n/, $output))  {
		next if (($interface =~ /^--/) || ($interface =~ /^Interface\s/));
		my @line = split(/\s+/, $interface);
		push(@new_ip_int_bri, $line[0]);
	}
	@new_ip_int_bri = sort(@new_ip_int_bri);
	print "IP int bri:  @new_ip_int_bri\n";
	if (!(@ip_int_bri ~~ @new_ip_int_bri))  {
		$conn->log_error("ip int brief changed after install");
	}
	
	my $new_ip_route = '';
	$output = $conn->send_host("sh ip route 0.0.0.0");
	if ($output =~ /^\s+\*\s+(.*)/)  {
		$new_ip_route = $1;
	}
	print "Gateway: $new_ip_route\n";
	if ($ip_route ne $new_ip_route)  {
		$conn->log_error("IP route 0.0.0.0 changed after install");
	}
	
	$output = $conn->send_host("sh environment all");
	print "$output\n";
	foreach my $line (split(/\n/, $output))  {
		if (($line !~ /^(?:SW\s*PID|\-)/) && ($line !~ /(?:Good|OK)/))  {
			$conn->log_error("Environment issue:  $line\n");
		}
	}
}

1;
