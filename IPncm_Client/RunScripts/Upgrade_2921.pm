package Upgrade_2921;

use strict;
use warnings;

no if $] >= 5.017011, warnings => 'experimental::smartmatch';

#
#  Script to perform upgrades for a 3850 device.
#
#  Parameters:
#    $upgrade_version - string:  version number to upgrade to.
#    $upgrade_mode - string:  if eq "deploy", run the configuration (rather than
#        just printing the new configuration).
#    $upgrade_file - string:  file name of new configuration (defaults to 
#        value determined from $version in %known_types).
#    $upgrade_size - int:  file size of new configuration (defaults to 
#        value determined from $version in %known_types).
#

my %known_types = (
	'c2900-universalk9-mz.SPA.153-3.M9.bin' => [
		'153-3.M9',
		96072760,
	], 
	'c2900-universalk9-mz.SPA.154-3.M7.bin' => [
		'154-3.M7',
		104392336,
	],
	'c2900-universalk9-mz.SPA.155-3.M5.bin' => [
		'155-3.M5',
		108967472,
	]
);

my @neighbors = ();
my $cdp_neighbors_txt = "";
my @interfaces = ();
my $interfaces_txt = "";
my @ip_int_bri = ();
my $ip_int_bri_txt = "";
my $env_all = "";
my $ip_route = '';
my $show_flash_pre = "";
my $reload_out = "";
my $copy_out = "IOS File Present, no action required.";
my $verify_out = "IOS File Present, no verification required.";

my $golden_config = <<EOF;
conf t
snmp-server community Company_vanguard RO
end
copy run start
EOF

sub fifo_log {
	my ($hostname, $cmd, $msg) = @_;
	my $fifo_file = "/tmp/ipncm_fifo";
	if (not -e $fifo_file) {
			`mkfifo $fifo_file`;
	}
	
	print "$msg\n"; # print to STDOUT for IPncm to capture from produtil
	$msg =~ s/\n/\\n/g;
	$msg =~ s/\r//g;
	$msg .= "\n" unless $msg =~ /\n$/;
	open(FIFO, "> $fifo_file") || die "$!";
	print FIFO "$hostname,$cmd=>$msg";
	close(FIFO);
	sleep(2);
}

sub line_filter {
	my ($input, $regex) = @_;
	my @output = ();
	foreach my $line (split(/\n/, $input)) {
		push(@output, "$line") if ($line =~ /$regex/);
	}
	return join("\n", @output);
}

sub run  {
	my ($this, $conn, $hostname, $upgrade_file, $upgrade_mode, $queue_email, $email_subject, $upgrade_version, 
			$upgrade_size) = @_;
	
	if (!defined($upgrade_file))  {
		fifo_log("$hostname", "exit", "No given upgrade file");
		$conn->log_error("No given upgrade file");
		return;
	}
	$upgrade_mode = defined($upgrade_mode) ? $upgrade_mode : 0;
	$upgrade_version = defined($upgrade_version) ? $upgrade_version :
		(defined($known_types{$upgrade_file}->[0]) ? 
		$known_types{$upgrade_file}->[0] : undef);
	if (!defined($upgrade_version))  {
		fifo_log("$hostname", "exit", "Unknown IOS Filename Requested");
		$conn->log_error("Given upgrade file is incompatible with this device");
		return;
	}
	$upgrade_size = defined($upgrade_size) ? $upgrade_size :
		(defined($known_types{$upgrade_file}->[1]) ? 
		$known_types{$upgrade_file}->[1] : undef);
	if (!defined($upgrade_size))  {
		fifo_log("$hostname", "exit", "No IOS File Size Provided");
		$conn->log_error("No given upgrade size");
		return;
	}
	
	if (run_pre_installation($this, $conn, $hostname, $upgrade_file, 
			$upgrade_mode, $queue_email, $email_subject, $upgrade_version, $upgrade_size) && $upgrade_mode)  {
		if (run_installation($this, $conn, $hostname, $upgrade_file, 
				$upgrade_mode, $queue_email, $email_subject, $upgrade_version, $upgrade_size))  {
			run_post_installation($this, $conn, $hostname, $upgrade_file, 
					$upgrade_mode, $queue_email, $email_subject, $upgrade_version, $upgrade_size);
		}
	}
}

sub run_pre_installation  {
	my ($this, $conn, $hostname, $upgrade_file, $upgrade_mode, $queue_email, $email_subject, $upgrade_version, 
			$upgrade_size) = @_;

	#  Test whether upgrade is necessary
	my $current_ios = $conn->send_host("sh version | in System image file");
	fifo_log("$hostname", "show version", "$current_ios");
	
	if ($current_ios =~ /$upgrade_file/) {
		fifo_log("$hostname", "exit", "Device Already Running Image: $upgrade_file");
		$conn->log_error("Device Already Running Image: $upgrade_file");
		return 0;
	}	

	my $continue = 1;
	my $verify_ios_flag = 0;
	$show_flash_pre = $conn->send_host("dir flash:");
	my $show_flash = $show_flash_pre;

	if ($show_flash !~ /$upgrade_file/)  {
		$show_flash =~ /(\d+) bytes (?:available|free)/;
		my $cur_space = $1;
		if ($cur_space <= $upgrade_size)  {
			while ($show_flash =~ /(\S+\.bin)/g)  {
				$conn->send_host("delete flash:" . $1); 
			}
			$show_flash = $conn->send_host("dir flash:");
			$show_flash =~ /(\d+) bytes (?:available|free)/;
			$cur_space = $1;
		}
		if ($cur_space > $upgrade_size)  {
			fifo_log("$hostname", "IOS image not present, initiating copy sequence."
				, "copy tftp://10.161.160.5/$upgrade_file flash:$upgrade_file");
			$copy_out = $conn->send_host("copy tftp://10.161.160.5/$upgrade_file flash:$upgrade_file");
			$verify_ios_flag = 1;
			fifo_log("$hostname", "copy tftp://10.161.160.5/$upgrade_file flash:$upgrade_file", $copy_out);
		}  else {
			fifo_log("$hostname", "exit", "ABORTING INSTALL - Not enough space on flash");
			$conn->log_error("ABORTING INSTALL - Not enough disk space to proceed");
			return 0;
		}
	}
	
	$show_flash = $conn->send_host("dir flash:");
	fifo_log("$hostname", "dir flash:", $show_flash);
	
	if ($show_flash !~  /$upgrade_file/)  {
		fifo_log("$hostname", "exit", "ABORTING INSTALL - image not present after copy");
		$conn->log_error("ABORTING INSTALL - image not present after copy");
		return 0;
	}
	
	if ($verify_ios_flag) {
		fifo_log("$hostname", "Performing IOS Image File Verification", "verify flash:$upgrade_file");
		$verify_out = $conn->send_host("verify flash:$upgrade_file");
		fifo_log("$hostname", "verify flash:$upgrade_file", $verify_out);
		if ($verify_out =~ /fail/i)  {
				fifo_log("$hostname", "error", "ABORTING INSTALL - IOS flash verification failed");
				$conn->log_error("ABORTING INSTALL - file verification failed");
				$continue = 0;
		}
	}
	
	my $output = $conn->send_host("sh cdp neighbor");
	my $found = 0;
	foreach my $neighbor (split(/\n/, $output))  {
		if ($neighbor =~ /^Device ID/)  {
			$found++;
			next;
		}
		if ($found && ($neighbor !~ /^\s/) && ($neighbor !~ /^Total/) && ($neighbor =~ /^\w/))  {
			my @line = split(/\s+/, $neighbor);
			push(@neighbors, $line[0]) if $line[0] =~ /\w/;
		}
	}
	$cdp_neighbors_txt = join(", ",@neighbors);
	fifo_log("$hostname", "sh cdp neighbors", "CDP Neighbors: $cdp_neighbors_txt");

	$output = $conn->send_host("sh interface description | ex down");
	foreach my $interface (split(/\n/, $output))  {
		next if (($interface =~ /^--/) || ($interface =~ /^Interface\s/));
		my @line = split(/\s+/, $interface);
		push(@interfaces, $line[0]) if (defined($line[0]) && $line[0]);
	}
	@interfaces = sort(@interfaces);
	$interfaces_txt = join(', ', @interfaces);
	fifo_log("$hostname", "sh interface description | ex down", "Up/Up Interfaces: $interfaces_txt");
	
	$output = $conn->send_host("sh ip int brief | ex down");
	foreach my $interface (split(/\n/, $output))  {
		next if (($interface =~ /^--/) || ($interface =~ /^Interface\s/));
		my @line = split(/\s+/, $interface);
		push(@ip_int_bri, $line[0]) if (defined($line[0]) && $line[0]);
	}
	@ip_int_bri = sort(@ip_int_bri);
	$ip_int_bri_txt = join(', ', @ip_int_bri);
	fifo_log("$hostname", "sh ip int brief | ex down", "IP int bri: $ip_int_bri_txt");

	$ip_route = $conn->send_host("sh ip route");
	fifo_log("$hostname", "sh ip route", $ip_route);
	
	$env_all = $conn->send_host("sh environment all");
	fifo_log("$hostname", "sh environment all", $env_all);
	
	return $continue;
}


sub run_installation  {
	my ($this, $conn, $hostname, $upgrade_file, $upgrade_mode, $queue_email, $email_subject, $upgrade_version, 
			$upgrade_size) = @_;

	# Run configuration
	my $config = <<EOF;
conf t
no boot system
boot system flash0:/$upgrade_file
end
copy run start
reload
EOF

	if ($upgrade_mode eq "deploy")  {
		$reload_out = $conn->send_host($config, undef, 900) . "\n";
		fifo_log("$hostname", "send config & reload", $reload_out);
		if ($reload_out =~ /aborted/)  {
			fifo_log("$hostname", "exit", "Upgrade aborted by device");
			$conn->log_error("Upgrade aborted by device");
			return 0;
		}
		fifo_log("$hostname", "wait: 380", "standing by ...");
		sleep(360);
	}  else {
		print "TEST MODE, OTHERWISE WOULD RUN:\n$config\n";
	}
	return 1;
}


sub run_post_installation  {
	my ($this, $conn, $hostname, $upgrade_file, $upgrade_mode, $queue_email, $email_subject, $upgrade_version, 
			$upgrade_size) = @_;

	# Post-config checks
	$conn->send_host("sh version"); # this is simply done to re-establish the SSH connection
	my $image_file = $conn->send_host("sh version | in System image file");
	my $show_uptime = $conn->send_host("show version | i uptime");
	fifo_log("$hostname", "device contact re-established!", $show_uptime);
	
	if ($image_file =~ /$upgrade_file/)  {
		fifo_log("$hostname", "device is running new code version!", $image_file);
	} else {
		fifo_log("$hostname", "exit", "Device was not upgraded to new version!\n$image_file");
		$conn->log_error("Device was not upgraded to new version: $image_file");
		return 0;
	}
	
	sleep(20);
	my $output = $conn->send_host("sh cdp neighbor");
	my @new_neighbors = ();
	my $found = 0;
	foreach my $neighbor (split(/\n/, $output))  {
		if ($neighbor =~ /^Device ID/)  {
			$found++;
			next;
		}
		if ($found && ($neighbor !~ /^\s/) && ($neighbor !~ /^Total/) && ($neighbor =~ /^\w/))  {
			my @line = split(/\s+/, $neighbor);
			push(@new_neighbors, $line[0]) if $line[0] =~ /\w/;
		}
	}
	my $new_neighbors_txt = join(", ",@new_neighbors);
	fifo_log("$hostname", "sh cdp neighbors", "CDP Neighbors: $new_neighbors_txt");
	if (!(@neighbors ~~ @new_neighbors))  {
		fifo_log("$hostname", "error", "CDP Neighbors changed after install");
		$conn->log_error("CDP Neighbors changed after install");
	}

	my @new_interfaces = ();
	$output = $conn->send_host("sh interface description | ex down");
	foreach my $interface (split(/\n/, $output))  {
		next if (($interface =~ /^--/) || ($interface =~ /^Interface\s/));
		my @line = split(/\s+/, $interface);
		push(@new_interfaces, $line[0]);
	}
	@new_interfaces = sort(@new_interfaces);
	my $new_interfaces_txt = join(', ', @new_interfaces);
	fifo_log("$hostname", "sh interface description | ex down", "Interfaces: $new_interfaces_txt");
	if (!(@interfaces ~~ @new_interfaces))  {
		fifo_log("$hostname", "error", "Interfaces changed after install");
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
	my $new_ip_int_bri_txt = join(', ', @new_ip_int_bri);
	fifo_log("$hostname", "sh ip int brief | ex down", "IP int bri: $new_ip_int_bri_txt");
	if (!(@ip_int_bri ~~ @new_ip_int_bri))  {
		fifo_log("$hostname", "error", "ip int brief changed after install");
		$conn->log_error("ip int brief changed after install");
	}
	
	my $ip_route_new = $conn->send_host("sh ip route");
	fifo_log("$hostname", "sh ip route", "$ip_route_new");
	
	my $show_flash_new = $conn->send_host("dir flash:");
	fifo_log("$hostname", "dir flash:", "$show_flash_new");
	
	my $env_all_new = $conn->send_host("sh environment all");
	fifo_log("$hostname", "sh environment all", "$env_all_new");
	
	fifo_log("$hostname", "IOS upgrade complete!", "");
	
	my $golden_config_out = $conn->send_host($golden_config, undef, 15) . "\n";
	fifo_log("$hostname", "APPLY GOLDEN CONFIG", $golden_config_out);
	my $snmp_test = `snmpget -v2c -c Company_vanguard $hostname sysDescr.0`;
	fifo_log("$hostname", "snmpget test", $snmp_test);
	
	# Text transformations
	$ip_route = line_filter($ip_route, qr/\d+\.\d+\.\d+\.\d+/);
	$ip_route_new = line_filter($ip_route_new, qr/\d+\.\d+\.\d+\.\d+/);
	$show_flash_pre = line_filter($show_flash_pre, qr/^\s*\d|bytes total/);
	$show_flash_new = line_filter($show_flash_new, qr/^\s*\d|bytes total/);
	$golden_config_out = line_filter($golden_config_out, qr/\w/);
	$golden_config = line_filter($golden_config, qr/\w/);
	$snmp_test = line_filter($snmp_test, qr/\w/);
	$reload_out = line_filter($reload_out, qr/\w/);
	$verify_out = line_filter($verify_out, qr/\w/);
	$copy_out = line_filter($copy_out, qr/\w/);
	
	my $email_body = <<EOF;
$hostname has successfully been upgraded to ios: $upgrade_file.

==================================================
Pre Upgrade Information:
==================================================
CDP Neighbors:
=========================
$cdp_neighbors_txt
=========================

UP/UP Interfaces:
=========================
$ip_int_bri_txt
=========================

IP route:
=========================
$ip_route
=========================

Dir Flash:
=========================
$show_flash_pre
=========================

==================================================
Upgrade Information:
==================================================
IOS Copy:
=========================
$copy_out
=========================

IOS Verification:
=========================
$verify_out
=========================

Boot System & Reload:
=========================
$reload_out
=========================

==================================================
Post Upgrade Information:
==================================================
CDP Neighbors:
=========================
$new_neighbors_txt
=========================

UP/UP Interfaces:
=========================
$new_ip_int_bri_txt
=========================

IP route:
=========================
$ip_route_new
=========================

Dir Flash:
=========================
$show_flash_new
=========================

Show ENV All:
=========================
$env_all_new
==================================================

Regards,
IPautomata
EOF
	
	my $email_golden_config_body = <<EOF;
The golden configuration file has successfully been applied to: $hostname

==================================================
Golden Config:
==================================================
$golden_config
==================================================

==================================================
Golden Config Deployment:
==================================================
$golden_config_out
==================================================

==================================================
QA:
==================================================
SNMP Test:
$snmp_test
==================================================

Regards,
IPautomata
EOF
	
	$email_body =~ s/\r//g;
	my $tmp_fh = new File::Temp( UNLINK => 1 );
	print $tmp_fh $email_body;
	system("cat $tmp_fh | mail -s '$email_subject' -r 'ipautospecopsdev\@Company.com' $queue_email");
	
	sleep(2);
	$email_golden_config_body =~ s/\r//g;
	my $tmp2_fh = new File::Temp( UNLINK => 1 );
	print $tmp2_fh $email_golden_config_body;
	system("cat $tmp2_fh | mail -s '$email_subject' -r 'ipautospecopsdev\@Company.com' $queue_email");

	fifo_log("$hostname", "exit", "");
}

1;
