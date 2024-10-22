package Upgrade_WLC;

use strict;
use warnings;

#
#  Script to perform upgrades for a WLC device.
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
	'7.4.110.0',
	'7.4.121.0',
);

my $sysinfo = '';
my $boot = '';
my $ap_count = '';
my $wlan_summary = '';
my $interface_summary = 0;


sub run  {
	my ($this, $conn, $hostname, $upgrade_version, $run_config) = @_;
	
	if (!defined($upgrade_version))  {
		$conn->log_error("No given upgrade version");
		return;
	}
	$run_config = defined($run_config) ? $run_config : 0;
	$conn->send_host("config paging disable");
	
	if (run_pre_installation($this, $conn, $hostname, $upgrade_version, 
			$run_config))  {
		if (run_installation($this, $conn, $hostname, $upgrade_version, 
			$run_config))  {
			run_post_installation($this, $conn, $hostname, $upgrade_version, 
				$run_config);
		}
	}
}

sub run_pre_installation  {
	my ($this, $conn, $hostname, $upgrade_version, $run_config) = @_;

	my $continue = 1;
	#  Test whether upgrade is necessary
	my $output = $conn->send_host("show boot");
	print "$output\n";
	
	if ($output =~ /$upgrade_version.*active/)  {
		print "No need to upgrade - active code is already $upgrade_version\n";
		return 0;
	}
	if ($output !~ /Primary Boot Image[\. ]*$upgrade_version/)  {
		$conn->log_error("ABORTING:  Primary boot image is not $upgrade_version");
		$continue = 0;
	}
	if ($output !~ /$upgrade_version.*default/)  {
		$conn->log_error("ABORTING:  $upgrade_version is not the default");
		$continue = 0;
	}
	
	$output = $conn->send_host("sh redundancy summary");
	print "$output\n";
	if ($output =~ /Redundancy Mode.*ENABLED/)  {
		$conn->log_error("ABORTING:  Device in redundancy mode");
		$continue = 0;
	}
	
	$sysinfo = $conn->send_host("sh sysinfo");
	print "$sysinfo\n";

	$boot = $conn->send_host("sh boot");
	print "$boot\n";

	$output = $conn->send_host("sh ap summary");
	print "$output\n";
	$ap_count = ($output =~ tr/\n//);

	$wlan_summary = $conn->send_host("sh wlan summary");
	print "$wlan_summary\n";

	$interface_summary = $conn->send_host("sh interface summary");
	print "$interface_summary\n";

	$output = $conn->send_host("sh network summary");
	print "$output\n";

	return $continue;
}


sub run_installation  {
	my ($this, $conn, $hostname, $upgrade_version, $run_config) = @_;
		
	# Run configuration
	my $config = <<EOF;
config network secureweb cipher-option rc4-preference enable
save config
reset system
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
	my ($this, $conn, $hostname, $upgrade_version, $run_config) = @_;

			
	# Post-config checks
	my $output = $conn->send_host("show boot");
	print "$output\n";
	
	if ($output !~ /$upgrade_version.*active/)  {
		$conn->log_error("$upgrade_version is not active code after installation!");
	}
	
	if ($run_config)  {
		my $config = <<EOF;
config wlan disable all
config wlan usertimeout 7200 1
config wlan usertimeout 7200 3
config wlan usertimeout 7200 4
config wlan usertimeout 7200 5
config wlan enable all
EOF
		print $conn->send_host($config, undef, 900) . "\n";
	}

	
	$output = $conn->send_host("sh sysinfo");
	print "$output\n";
	if ($output !~ /Product Version[\. ]*$upgrade_version/)  {
		$conn->log_error("$upgrade_version is not marked as product version after installation");
	}

	$output = $conn->send_host("sh ap summary");
	print "$output\n";
	if (($output =~ tr/\n//) != $ap_count)  {
		$conn->log_error("Number of APs has changed after installation");
	}

	$output = $conn->send_host("sh wlan summary");
	print "$output\n";
	if ($output ne $wlan_summary)  {
		$conn->log_error("WLAN summary has changed after installation");
	}

	$output = $conn->send_host("sh interface summary");
	print "$output\n";
	if ($output ne $interface_summary)  {
		$conn->log_error("Interface summary has changed after installation");
	}

	$output = $conn->send_host("sh lag summary");
	print "$output\n";
	if ($output !~ /enabled/i)  {
		$conn->log_error("LAG is disabled after installation");
	}

	$output = $conn->send_host("sh network summary");
	print "$output\n";
	if ($output !~ /Secure Web Mode RC4 Cipher Preference[\. ]*Enable/i)  {
		$conn->log_error("Secure Web Mode RC4 Cipher Preference is disabled after installation");
	}
}

1;
