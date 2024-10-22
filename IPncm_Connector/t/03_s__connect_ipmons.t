#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Sys::Hostname;
use Test::More;
use IPncm_Connector;
use test_vars;

my @ipmons = @{$conn->{ipmons}};
foreach my $ipmon (@ipmons)  {
	if (ref($ipmon) eq 'ARRAY')  {
		$ipmon = $ipmon->[0];
	}
}

plan tests => 18 + (5 * @ipmons);

my $conn = new IPncm_Connector();
isa_ok($conn, 'IPncm_Connector');
is($conn->error(), '', 'No error after instantiation');
foreach my $ip (@ipmons)  {
	$ip = $conn->_connect_ipmon($ip);
	is($conn->error(), '', "No error after connection to $ip");
	isa_ok($conn->{connections}->{$ip}, 'Net::OpenSSH');
}

$conn->{connections} = {};
foreach my $ip (@ipmons)  {
	$ip = $conn->_connect_ipmon($ip);
	is($conn->error(), '', "No error after re-connection to $ip");
}

foreach my $ip (@ipmons)  {
	isa_ok($conn->{connections}->{$ip}, 'Net::OpenSSH');
	is($conn->{connections}->{$ip}->capture("echo $ip"), "$ip\n",
			"valid connection to $ip");
}

SKIP:  {
	skip "no broken ipmons to test with", 14 unless (scalar(@ipmons) > 1);
	
	$conn->{connections} = {};
	$conn->{ipmons} = [[$ipmons[0], $ipmons[1]]]; 
	my $ipm = $conn->_connect_ipmon($ipmons[0]);
	is($conn->error(), '', 'No error after reconnection with fallback');
	isa_ok($conn->{connections}->{$ipmons[0]}, 'Net::OpenSSH');
	is($conn->{connections}->{$ipmons[1]}, undef, 'second connection undefined');
	is($ipm, $ipmons[0], 'return proper value');

	$conn->{connections} = {};
	$conn->{ipmons} = [['invalid', $ipmons[1]]]; 
	$ipm = $conn->_connect_ipmon('invalid');
	my $err = $conn->error();
	like($err, qr/invalid: error connecting/, 'failed to connect');
	like($err, qr/falling back to $ipmons[1]/, 'falling back correctly');
	is($conn->{connections}->{'invalid'}, undef, 'invalid connection undefined');
	isa_ok($conn->{connections}->{$ipmons[1]}, 'Net::OpenSSH');
	is($ipm, $ipmons[1], 'return proper value when first fails');

	$conn->{connections} = {};
	$conn->{ipmons} = [['invalid1', 'invalid2']]; 
	$ipm = $conn->_connect_ipmon('invalid1');
	$err = $conn->error();
	like($err, qr/(?:Could not resolve hostname|Name or service not known)/, 'ipmon connection failure');
	like($err, qr/invalid1: error connecting/, 'failed to connect');
	like($err, qr/falling back to invalid2/, 'falling back correctly');
	like($err, qr/no fallback ipmon available, aborting execution/, 
			'failing correctly when no fallback');
	is($ipm, undef, 'return undef when fails');
}

SKIP: {
	skip "no broken ipmons to test with", 2 unless @{$conn->{broken_ipmons}};
	my $ipm = $conn->_connect_ipmon($conn->{broken_ipmons}->[0]);
	my $err = $conn->error();
	like($err, qr/ipmon is currently down/, 'known broken ipmon failure');
	is($ipm, undef, 'return undef with broken ipmon');
}
