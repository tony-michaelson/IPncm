#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 24;
use IPncm_Client;
use test_vars;

SKIP:  {
	my ($wlc_host) = get_hosts(0, 1);
	skip "no WLC device to test with on this ipmon", 9 unless defined($wlc_host);
	$conn->add($wlc_host);
	my $output = $conn->_send_host('show sysinfo', $wlc_host);
	is($conn->error(), '', 'no error after send 1 (wlc)');
	like($output, qr/Cisco Controller/, 'correct output from proper command (wlc)');
	unlike($output, qr/Timezone location/, 'output doesn\'t contain wrong text');

	$output = $conn->_send_host('show time', $wlc_host);
	is($conn->error(), '', 'no error after send 2 (wlc)');
	unlike($output, qr/Cisco Controller/, 
			'second command doesn\'t contain wrong text');
	like($output, qr/Timezone location/, 'correct output from second command in same connection (wlc)');

	$output = $conn->_send_host("show sysinfo\nshow time", $wlc_host);
	is($conn->error(), '', 'no error after send 3 (wlc)');
	like($output, qr/Cisco Controller/, 
			'correct output from first of two commands (wlc)');
	like($output, qr/Timezone location/, 
			'correct output from second of two commands (wlc)');
}

SKIP:  {
	my ($cue_host) = get_hosts(0, 0, 1);
	skip "no CUE device to test with on this ipmon", 8 unless defined($cue_host);
	$conn->add($cue_host);
	my $output = $conn->_send_host('show version', $cue_host);
	is($conn->error(), '', 'no error after send 1 (cue)');
	unlike($output, qr/$send_version_pattern/, 'not contain standard response');
	like($output, qr/CPU Model:/, 'contain cue response');

	$output = $conn->_send_host('show users', $cue_host);
	is($conn->error(), '', 'no error after send 2 (cue)');
	like($output, qr/total user/, 
			'correct cue output from second command in same connection (cue)');

	$output = $conn->_send_host("show version\nshow users", $cue_host);
	is($conn->error(), '', 'no error after send 3 (cue)');
	like($output, qr/CPU Model:/,
					'correct output from first of two commands (cue)');
	like($output, qr/total user/,
					'correct output from second of two commands (cue)');
}

SKIP:  {
	skip "no qa device to test with on this ipmon", 7 unless defined($qa_host);

	$conn->add($qa_host);
	my $output = $conn->_send_host('show version', $qa_host);
	is($conn->error(), '', 'no error after send 1 (no en)');
	like($output, qr/$send_version_pattern/, 'correct output from proper command (no en)');

	$output = $conn->_send_host('show ip int bri', $qa_host);
	is($conn->error(), '', 'no error after send 2 (no en)');
	like($output, qr/$show_ip_pattern/, 'correct output from second command in same connection (no en)');

	$output = $conn->_send_host("show version\nshow ip int bri", $qa_host);
	is($conn->error(), '', 'no error after send 3 (no en)');
	like($output, qr/$send_version_pattern/,
					'correct output from first of two commands (no en)');
	like($output, qr/$show_ip_pattern/,
					'correct output from second of two commands (no en)');
}

$conn->_clear_output();
