#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 33;
use IPncm_Connector;
use test_vars;

my $result = $conn->send_hosts('show version', 'invalid');
like($conn->error(), qr/not added to connector, aborting/, 
	'sending to non-added host');
ok(!defined($result), 'no result from send');

$conn->add(@hosts);
$result = $conn->send_hosts('show version', 'invalid');
like($conn->error(), qr/not added to connector, aborting/,
	'sending to non-added host after hosts added');
ok(!defined($result), 'no result from send after hosts added');

$result = $conn->send_hosts('show version', $host, 'invalid');
like($conn->error(), qr/not added to connector, aborting/,
	'sending to one valid, one invalid host');
ok(!defined($result), 'no result from send to one valid, one invalid');

$result = $conn->send_hosts(undef, $host);
like($conn->error(), qr/invalid script, aborting/,
	'sending undef script');
ok(!defined($result), 'no result from send to undef script');

$result = $conn->send_hosts("<perl><perl></perl></perl>", $host);
like($conn->error(), qr/invalid script, aborting/,
	'sending invalid script');
ok(!defined($result), 'no result from send to invalid script');

my $starttime = time;
$result = $conn->send_hosts('show version');
my $thread_time = time - $starttime;
is($conn->error(), '', 'no error after correct send');
foreach my $h (@hosts)  {
	if (defined($result->{$h}))  {
		like($result->{$h}, qr/$send_version_pattern/, "correct result from $h");
	}  else  {
		fail("result returned from $h");
	}
}

my $ipmon = $conn->_select_ipmon($hosts[0]);
my @bad_hosts = ('invalid1', 'invalid2', 'invalid3', 'invalid4', 'invalid5',
	'invalid6', 'invalid7', 'invalid8', 'invalid9', 'invalid10');
$conn = new IPncm_Connector();
foreach my $bad_host (@bad_hosts)  {
	$conn->{host_to_base_ipmon}->{$bad_host} = $ipmon;
	push(@{$conn->{base_ipmon_to_host}->{$ipmon}}, $bad_host);
}
my $start = time;
my $ouput = $conn->send_hosts('show version');
my $end = time;
my $err = $conn->error();
foreach my $bad_host (@bad_hosts)  {
	like($err, qr/$bad_host: (?:Can't connect|no connection info available)/, 
			"$bad_host in error");
}
ok($end - $start > 5, 'At least 5 seconds to connect due to retries');
ok($end - $start < 30, 'No more than 30 seconds to fail to connect due to ' . 
		'retries - actually ' . ($end - $start));
