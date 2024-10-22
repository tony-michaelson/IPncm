#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 48;
use IPncm_Connector;
use test_vars;

$conn->add(@hosts);
my $result = $conn->send_hosts('<perl>print "OUTPUT\n";</perl>');
is($conn->error(), '', 'no error after perl code');
foreach my $h (@hosts)  {
	like($result->{$h}, qr/OUTPUT/, "correct result from $h");
}

$result = $conn->send_hosts('<perl>my $res = send_host("show version");' .
	'$res =~ /(.*) uptime is/; print "$1\n";</perl>');
is($conn->error(), '', 'no error after perl execution');
foreach my $h (@hosts)  {
	my $short_host = $h;
	$short_host =~ s/\..*//;
	ok(defined($result->{$h}), "result returned from $h");
	like($result->{$h}, qr/$short_host/i, "correct result from $h");
	unlike($result->{$h}, qr/$send_version_pattern/, 
		"no incorrect result from perl execution");
}

my $multi_send = {
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

