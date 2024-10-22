#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 32;
use IPncm_Connector qw(:LOG);
use test_vars;

SKIP:  {
	my ($wlc_host) = get_hosts(0, 0, 1);
	skip "no WLC device to test with", 13 unless defined($wlc_host);
	$conn->add($wlc_host);
	my $wlc_mon = $conn->_select_ipmon($wlc_host);

	is($conn->error(), '', 'no error after connection (wlc)');
	my ($output, $err) = $conn->_send_cmd('show sysinfo', $wlc_mon, $wlc_host);
	is($conn->error(), '', 'no error after send 1 (wlc)');
	is($err, '', 'no error returned from send after send 1 (wlc)');
	like($output, qr/Cisco Controller/, 'correct output from proper command (wlc)');
	unlike($output, qr/Timezone location/, 'output doesn\'t contain wrong text');

	($output, $err) = $conn->_send_cmd('show time', $wlc_mon, $wlc_host);
	is($conn->error(), '', 'no error after send 2 (wlc)');
	is($err, '', 'no error returned from send after send 2 (wlc)');
	unlike($output, qr/Cisco Controller/, 
			'second command doesn\'t contain wrong text');
	like($output, qr/Timezone location/, 'correct output from second command in same connection (wlc)');

	($output, $err) = $conn->_send_cmd("show sysinfo\nshow time", $wlc_mon, $wlc_host);
	is($conn->error(), '', 'no error after send 3 (wlc)');
	is($err, '', 'no error returned from send after send 3 (wlc)');
	like($output, qr/Cisco Controller/, 
			'correct output from first of two commands (wlc)');
	like($output, qr/Timezone location/, 
			'correct output from second of two commands (wlc)');
}

SKIP:  {
	my ($cue_host) = get_hosts(0, 0, 0, 1);
	skip "no CUE device to test with", 8 unless defined($cue_host);
	$conn->add($cue_host);
	my $cue_mon = $conn->_select_ipmon($cue_host);

	my ($output, $err) = $conn->_send_cmd('show version', $cue_mon, $cue_host);
	is($conn->error(), '', 'no error after send 1 (cue)');
	unlike($output, qr/$send_version_pattern/, 'not contain standard response');
	like($output, qr/CPU Model:/, 'contain cue response');

	($output, $err) = $conn->_send_cmd('show users', $cue_mon, $cue_host);
	is($conn->error(), '', 'no error after send 2 (cue)');
	like($output, qr/total user\(s\)/, 
			'correct cue output from second command in same connection (cue)');

	($output, $err) = $conn->_send_cmd("show version\nshow users", $cue_mon, $cue_host);
	is($conn->error(), '', 'no error after send 3 (cue)');
	like($output, qr/CPU Model:/,
					'correct output from first of two commands (cue)');
	like($output, qr/total user\(s\)/,
					'correct output from second of two commands (cue)');

}

SKIP:  {
	skip "no qa device to test with on this ipmon", 11 unless defined($qa_host);
	$conn->add($qa_host);
	my $qa_mon = $conn->_select_ipmon($qa_host);

	is($conn->error(), '', 'no error after connection (qa)');
	my ($output, $err) = $conn->_send_cmd('show version', $qa_mon, $qa_host);
	is($conn->error(), '', 'no error after send 1 (qa)');
	is($err, '', 'no error returned from send after send 1 (qa)');
	like($output, qr/$send_version_pattern/, 'correct output from proper command (qa)');

	($output, $err) = $conn->_send_cmd('show ip int bri', $qa_mon, $qa_host);
	is($conn->error(), '', 'no error after send 2 (qa)');
	is($err, '', 'no error returned from send after send 2 (qa)');
	like($output, qr/$show_ip_pattern/, 'correct output from second command in same connection (qa)');

	($output, $err) = $conn->_send_cmd("show version\nshow ip int bri", $qa_mon, $qa_host);
	is($conn->error(), '', 'no error after send 3 (qa)');
	is($err, '', 'no error returned from send after send 3 (qa)');
	like($output, qr/$send_version_pattern/,
					'correct output from first of two commands (qa)');
	like($output, qr/$show_ip_pattern/,
					'correct output from second of two commands (qa)');
}
