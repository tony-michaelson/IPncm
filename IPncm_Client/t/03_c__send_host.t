#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 28;
use IPncm_Client;
use test_vars;

$conn->_send_host('show version', 'invalid');
like($conn->error(), qr/not added, aborting/, 
		'sending to invalid host');

$conn->add($host);
my $output = $conn->_send_host('show version', $host);
is($conn->error(), '', 'no error from command');
like($output, qr/$send_version_pattern/, 
		'correct output from proper command');
unlike($output, qr/$show_ip_pattern/, 
		'not contains wrong info from command');

$output = $conn->_send_host('show ip int bri', $host);
is($conn->error(), '', 'no error from second command');
unlike($output, qr/$send_version_pattern/, 
		'not contains wrong info from second command');
like($output, qr/$show_ip_pattern/, 
		'correct output from second command in same connection');

$output = $conn->_send_host("show version\nshow ip int bri", $host);
is($conn->error(), '', 'no error from two commands');
like($output, qr/$send_version_pattern/, 
		'correct output from first of two commands');
like($output, qr/$show_ip_pattern/, 
		'correct output from second of two commands');

$output = $conn->_send_host("show version\n\n\nshow ip int bri", $host);
is($conn->error(), '', 'no error from two commands with newlines');
like($output, qr/$send_version_pattern/, 
		'correct output from first of two commands with newlines');
like($output, qr/$show_ip_pattern/, 
		'correct output from second of two commands with newlines');

$output = $conn->_send_host("<perl>print \"OUTPUT\n\";</perl>", $host);
is($conn->error(), '', 'no error from perl execution');
like($output, qr/OUTPUT/, 
		'correct output from perl execution');
unlike($output, qr/$send_version_pattern/, 
		'no incorrect output from perl execution');

$output = $conn->_send_host("show version\n<perl>print \"OUTPUT1\n\";" . 
		"</perl>\nshow ip int bri\n<perl>print \"OUTPUT2\n\";</perl>", $host);
is($conn->error(), '', 'no error from mixed execution');
like($output, qr/$send_version_pattern/, 
		'correct output from first mixed execution');
like($output, qr/OUTPUT1/, 
		'correct output from second perl execution');
like($output, qr/$show_ip_pattern/, 
		'correct output from third mixed execution');
like($output, qr/OUTPUT2/, 
		'correct output from fourth perl execution');

$output = $conn->_send_host('<perl>my $out = send_host("show version");' . 
		'print ($out =~ /' . $send_version_pattern . '/ ? "YES" : "NO");</perl>', $host);
is($conn->error(), '', 'no error from perl function call');
like($output, qr/YES/, 
		'correct output from perl function call');
unlike($output, qr/$send_version_pattern/, 
		'no incorrect output from perl function call');

SKIP: {
	my ($wlc_host) = get_hosts(0, 1);
	skip "no WLC device to test with", 4 unless defined($wlc_host);
	$conn->add($wlc_host);
	$output = $conn->_send_host('<perl>my $out = send_host("show version", "' . 
			$wlc_host . '");' . 
			'print ($out =~ /Incorrect usage./ ? "YES" : "NO");</perl>', $host);
	is($conn->error(), '', 'no error from perl function call on WLC device');
	like($output, qr/YES/, 
			'correct output from perl function call on WLC device');
	$output = $conn->_send_host('show version', $host);
	is($conn->error(), '', 'no error from command to original device');
	like($output, qr/$send_version_pattern/, 
			'correct output from proper command on original device');
}

$conn->_clear_output();
