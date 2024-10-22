#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 40;
use IPncm_Connector;
use test_vars;


is(keys(%{$conn->{host_to_base_ipmon}}), 0, 'host map starts with no entries');
is(keys(%{$conn->{base_ipmon_to_host}}), 0, 'ipmon map starts with no entries');
$conn->_get_ipmon_map();
is(keys(%{$conn->{host_to_base_ipmon}}), 0, 'host map stays empty after empty call');
is(keys(%{$conn->{base_ipmon_to_host}}), 0, 'ipmon map stays empty after empty call');

$conn->_get_ipmon_map($host);
is(keys(%{$conn->{host_to_base_ipmon}}), 1, 'host map has entry after addition');
is($conn->{host_to_base_ipmon}->{$conn->_select_hostname($host)}, get_ipmon($host), 
		'host map entry is correct');
is(keys(%{$conn->{base_ipmon_to_host}}), 1, 'ipmon map has entry after addition');
is($conn->{base_ipmon_to_host}->{get_ipmon($host)}->[0], $host, 
		'ipmon map entry is correct');

$conn->_get_ipmon_map();
is(keys(%{$conn->{host_to_base_ipmon}}), 1, 'host map no change after null addition');
is(keys(%{$conn->{base_ipmon_to_host}}), 1, 'ipmon map no change after null addition');
like($conn->error(), qr/no valid hosts found/, 'error after null addition');

$conn->_get_ipmon_map('invalid');
is(keys(%{$conn->{host_to_base_ipmon}}), 1, 'host map no change after invalid addition');
is(keys(%{$conn->{base_ipmon_to_host}}), 1, 
		'ipmon map no change after invalid addition');
like($conn->error(), qr/invalid: not found/, 
		'error exists after invalid addition');

$conn->_get_ipmon_map($host);
is(keys(%{$conn->{host_to_base_ipmon}}), 1, 'host map no change after adding same host');
is(keys(%{$conn->{base_ipmon_to_host}}), 1, 
		'ipmon map no change after adding same host');

$conn = new IPncm_Connector();
isa_ok($conn, 'IPncm_Connector');

$conn->_get_ipmon_map(@hosts);
is(scalar(keys(%{$conn->{host_to_base_ipmon}})), scalar(@hosts), 
		'all added - host count correct');
my @ipmons = ();
foreach my $h (@hosts)  {
	push(@ipmons, get_ipmon($h)) if (!grep($_ eq get_ipmon($h), @ipmons));
}
is(scalar(keys(%{$conn->{base_ipmon_to_host}})), scalar(@ipmons), 
		'all added - ipmon count correct');
for (my $i = 0; $i < @hosts; $i++)  {
	is($conn->{host_to_base_ipmon}->{$conn->_select_hostname($hosts[$i])}, 
			get_ipmon($hosts[$i]), 
			$hosts[$i] . " / " . get_ipmon($hosts[$i]) . " in host map");
	ok(grep($_ eq $hosts[$i], @{$conn->{base_ipmon_to_host}->{get_ipmon($hosts[$i])}}), 
			$hosts[$i] . " / " . get_ipmon($hosts[$i]) . " in ipmon map");
}

$conn->_get_ipmon_map('\'); select 1; (\';');
like($conn->error(), qr/invalid characters found in host/,
	'invalid characters cause ignored host');
