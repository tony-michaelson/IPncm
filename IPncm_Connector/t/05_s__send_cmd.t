#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 27;
use IPncm_Connector;
use test_vars;

my ($ipmon1_1, $ipmon1_2, $ipmon2_1, $ipmon2_2) = get_hosts(4);
my $tries = 40;
my $continue = 1;
do {
	$continue = 1;
	my $conn1 = new IPncm_Connector();
	$conn1->_get_ipmon_map($ipmon1_1, $ipmon1_2, $ipmon2_1, $ipmon2_2);
	if ($conn1->{host_to_base_ipmon}->{$ipmon1_1} ne 
			$conn1->{host_to_base_ipmon}->{$ipmon1_2})  {
		$ipmon1_2 = get_hosts(1);
		$continue = 0;
	}
	if ($conn1->{host_to_base_ipmon}->{$ipmon1_1} eq 
			$conn1->{host_to_base_ipmon}->{$ipmon2_1})  {
		$ipmon2_1 = get_hosts(1);
		$continue = 0;
	}
	if ($conn1->{host_to_base_ipmon}->{$ipmon2_1} ne 
			$conn1->{host_to_base_ipmon}->{$ipmon2_2})  {
		$ipmon2_2 = get_hosts(1);
		$continue = 0;
	}
}  while (!$continue && $tries--);

SKIP:  {
	$conn = new IPncm_Connector($ipmon1_1, $ipmon2_1);
	add_config_files();
	skip "only one ipmon to test with", 27 unless 
			(get_ipmon($ipmon2_1) ne get_ipmon($ipmon1_1));

	my $ipmon1 = $conn->_select_ipmon($ipmon1_1);
	my $ipmon2 = $conn->_select_ipmon($ipmon2_1);

	$conn = new IPncm_Connector($ipmon1_1, $ipmon1_2);
	add_config_files();
	$conn->_send_cmd(undef, $ipmon1, $ipmon2_1);
	like($conn->error(), qr/script parameter required/, 'sending nothing');
	$conn->_send_cmd('show version', undef, $ipmon2_1);
	like($conn->error(), qr/ipmon parameter required/, 'sending no ipmon');
	$conn->_send_cmd('show version', $ipmon1);
	like($conn->error(), qr/host parameter\(s\) required/, 'sending no hosts');

	my %output = $conn->_process_ipmon_output(
			$conn->_send_cmd('show version', $ipmon1, $ipmon2_1));
	like($conn->error(), qr/$ipmon2_1: (?:Can't connect|no connection info available for this host)/, 'sending to incorrect host');

	%output = $conn->_process_ipmon_output(
			$conn->_send_cmd('show version', $ipmon1, $ipmon1_1));
	is($conn->error(), '', 'no error from valid command');
	like($output{$ipmon1_1}, qr/$send_version_pattern/, 
			'correct output from proper command');
	unlike($output{$ipmon1_1}, qr/$show_ip_pattern/, 
			'not contains wrong info from command');

	%output = $conn->_process_ipmon_output(
			$conn->_send_cmd('show version', $ipmon1, $ipmon1_1, $ipmon1_2));
	is($conn->error(), '', "no error from valid command to $ipmon1_1, $ipmon1_2 ($ipmon1)");
	like($output{$ipmon1_1}, qr/$send_version_pattern/, 
			'correct output from proper command to device 1');
	unlike($output{$ipmon1_1}, qr/$show_ip_pattern/, 
			'not contains wrong info from command to device 1');
	like($output{$ipmon1_2}, qr/$send_version_pattern/, 
			'correct output from proper command to device 2');
	unlike($output{$ipmon1_2}, qr/$show_ip_pattern/, 
			'not contains wrong info from command to device 2');

	%output = $conn->_process_ipmon_output(
			$conn->_send_cmd("show version\nshow ip int bri", $ipmon1, 
			$ipmon1_1));
	is($conn->error(), '', 'no error from two commands');
	like($output{$ipmon1_1}, qr/$send_version_pattern/, 
			'correct output from first of two commands');
	like($output{$ipmon1_1}, qr/$show_ip_pattern/, 
			'correct output from second of two commands');

	%output = $conn->_process_ipmon_output(
			$conn->_send_cmd("show version\n\n\nshow ip int bri", $ipmon1, 
			$ipmon1_1));
	is($conn->error(), '', 'no error from two commands with newlines');
	like($output{$ipmon1_1}, qr/$send_version_pattern/, 
			'correct output from first of two commands with newlines');
	like($output{$ipmon1_1}, qr/$show_ip_pattern/, 
			'correct output from second of two commands with newlines');

	%output = $conn->_process_ipmon_output(
			$conn->_send_cmd({$ipmon1_1 => 'show version', 
			$ipmon1_2 => 'show ip int bri'}, $ipmon1, $ipmon1_1, $ipmon1_2));
	is($conn->error(), '', "no error from different commands to $ipmon1_1, $ipmon1_2 ($ipmon1)");
	like($output{$ipmon1_1}, qr/$send_version_pattern/, 
			'correct output from command 1 to device 1');
	unlike($output{$ipmon1_1}, qr/$show_ip_pattern/, 
			'not contains command 2 output to device 1');
	unlike($output{$ipmon1_2}, qr/$send_version_pattern/, 
			'not contains command 1 output to device 2');
	like($output{$ipmon1_2}, qr/$show_ip_pattern/, 
			'correct output from command 2 to device 2');

	$conn->add($ipmon2_1);
	%output = $conn->_process_ipmon_output(
			$conn->_send_cmd('show version', $ipmon2, $ipmon2_1));
	is($conn->error(), '', "no error from valid command to $ipmon2_1 ($ipmon2)");
	like($output{$ipmon2_1}, qr/$send_version_pattern/, 
			'correct output from proper command to other ipmon');
	unlike($output{$ipmon2_1}, qr/$show_ip_pattern/, 
			'not contains wrong info from command to other ipmon');

	my $broken_conn;
	eval  {
			$broken_conn = new Net::OpenSSH('invalid', timeout => 1);
	};
	$conn->{connections}->{$ipmon1} = $broken_conn;
	$conn->{connections}->{$ipmon2} = $broken_conn;
	$conn->_send_cmd('show version', $ipmon1, $ipmon1_1);
	my $err = $conn->error();
	like($err, qr/$ipmon1: unknown device: error sending/, 'broken connection error');

}