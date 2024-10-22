#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 12;
use IPncm_Connector;
use test_vars;

my $test_out = <<EOF;
---- device1 ----
-- cmd 1 --
output 1
---- device2 ----
-- cmd 2 --
output 2

---- device 3 ----
-- cmd 3 --
output 3
output 3
EOF

my $conn = new IPncm_Connector();
my %results = $conn->_process_ipmon_output($test_out);
is($conn->error(), '', "No error after valid process");
is(scalar(keys(%results)), 3, "3 sets of results");
like($results{device1}, qr/output 1\n/, "valid output 1");
unlike($results{device2}, qr/output 1/, "valid output 1 not in device2");
unlike($results{"device 3"}, qr/output 1/, "valid output 1 not in device3");
like($results{device2}, qr/output 2\n\n/, "valid output 1");
unlike($results{device1}, qr/output 2/, "valid output 2 not in device1");
unlike($results{"device 3"}, qr/output 2/, "valid output 2 not in device3");
like($results{"device 3"}, qr/output 3\noutput 3\n/, "valid output 1");
unlike($results{device1}, qr/output 3/, "valid output 3 not in device1");
unlike($results{device2}, qr/output 3/, "valid output 3 not in device2");

%results = $conn->_process_ipmon_output("Invalid input");
like($conn->error(), qr/unknown device: Invalid input/, 
		"logs invalid input as error");

