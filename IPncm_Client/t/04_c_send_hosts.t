#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 47;
use IPncm_Client qw(:LOG);
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
like($conn->error(), qr/invalid script being sent, aborting/,
	'sending undef script');
ok(!defined($result), 'no result from send to undef script');

$result = $conn->send_hosts("<perl><perl></perl></perl>", $host);
like($conn->error(), qr/invalid script being sent, aborting/,
	'sending invalid script');
ok(!defined($result), 'no result from send to invalid script');

$result = $conn->send_hosts('show version');
is($conn->error(), '', 'no error after correct send');
foreach my $h (@hosts)  {
	ok(defined($result->{$h}), "result returned from $h");
	like($result->{$h}, qr/$send_version_pattern/, "correct result from $h");
}

my $multi_send = {
	$hosts[0] => "show version",
	$hosts[1] => "show ip int bri",
};
$result = $conn->send_hosts($multi_send, $hosts[0], $hosts[1]);
is($conn->error(), '', 'no error after correct multi-send');
like($result->{$hosts[0]}, qr/$send_version_pattern/, 
		"correct result from multi-send 1");
like($result->{$hosts[1]}, qr/$show_ip_pattern/, 
		"correct result from multi-send 2");
is($result->{$hosts[2]}, undef, "no host 3");

$result = $conn->send_hosts('<perl>my $res = send_host("show version");' .
	'if ($res =~ /(.*) uptime is/)  { print "$1\n"; } else {print "$hostname\n";}</perl>');
is($conn->error(), '', 'no error after perl execution');
foreach my $h (@hosts)  {
	my $short_host = $h;
	$short_host =~ s/\..*//;
	ok(defined($result->{$h}), "result returned from $h");
	like($result->{$h}, qr/$short_host/i, "correct result from $h");
	unlike($result->{$h}, qr/$send_version_pattern/, 
		"no incorrect result from perl execution");
}

$multi_send = {
	$hosts[0] => '<perl>print "HOST1\n";</perl>',
	$hosts[1] => '<perl>print "HOST2\n";</perl>',
};
$result = $conn->send_hosts($multi_send, $hosts[0], $hosts[1]);
is($conn->error(), '', 'no error after correct perl multi-send');
like($result->{$hosts[0]}, qr/HOST1/, 
		"correct result from perl multi-send 1");
like($result->{$hosts[1]}, qr/HOST2/, 
		"correct result from perl multi-send 2");

$multi_send = {
	$hosts[0] => '<perl>print send_host("show version");</perl>',
	$hosts[1] => '<perl>print send_host("show ip int bri");</perl>',
};
$result = $conn->send_hosts($multi_send, $hosts[0], $hosts[1]);
is($conn->error(), '', 'no error after correct multi-send perl function call');
like($result->{$hosts[0]}, qr/$send_version_pattern/, 
		"correct result from multi-send perl function 1");
like($result->{$hosts[1]}, qr/$show_ip_pattern/, 
		"correct result from multi-send perl function 2");

