#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 30;
use IPncm_Connector;
use test_vars;

$conn->add_config($conf);
my $optionfile = $conn->_gen_option_file("Host: host1\nscript 1\n");
like($optionfile, qr/Host: host1\nscript 1/, "has provided script");
unlike($optionfile, qr/Host: \*\nscript 1/, 
		"has only provided script");
like($optionfile, qr/Host: .* - user == defaultuser/,
		"has provided default user");
like($optionfile, qr/Host: .* - pw == defaultpw1/,
		"has provided default pw1");
like($optionfile, qr/Host: .* - pw2 == defaultpw2/,
		"has provided default pw2");
like($optionfile, qr/Host: nopw - user == npuser1/,
		"has provided nopw user");
unlike($optionfile, qr/Host: nopw - pw/,
		"has no provided nopw pw");
unlike($optionfile, qr/Host: nouser - user/,
		"has no provided nouser user");
like($optionfile, qr/Host: nouser - pw == nupw1/,
		"has provided nouser pw1");
like($optionfile, qr/Host: nouser - pw2 == nupw2/,
		"has provided nouser pw2");
unlike($optionfile, qr/Host: nopw2 - user/,
		"has no provided nopw2 user");
like($optionfile, qr/Host: nopw2 - pw == np2pw1/,
		"has provided nopw2 pw1");
like($optionfile, qr/Host: nopw2 - pw2/,
		"has provided nopw2 pw2");
like($optionfile, qr/Host: twouser - user == tuuser1\nHost: twouser - user == tuuser2/,
		"has provided twouser user in right order");
like($optionfile, qr/Host: twopw - pw == tppw1\nHost: twopw - pw2 == tppw2\nHost: twopw - pw == tppw3\nHost: twopw - pw2 == tppw4/,
		"has provided twopw pw in right order");
like($optionfile, qr/Host: sshmethod - user == smuser/,
		"has provided sshmethod user");
like($optionfile, qr/Host: sshmethod - pw == smpw1/,
		"has provided sshmethod pw1");
like($optionfile, qr/Host: sshmethod - pw2 == smpw2/,
		"has provided sshmethod pw2");
unlike($optionfile, 
		qr/Host: nonsshmethod/, 
		"has no provided login for nonsshmethod");
unlike($optionfile, 
		qr/Host: mnonsshmethod/, 
		"has no provided login for mnonsshmethod");
like($optionfile, qr/Host: mixedmethod1 - user == mm1user/,
		"has provided mixed method 1 user");
like($optionfile, qr/Host: mixedmethod2 - user == mm2user/,
		"has provided mixed method 2 user");
like($optionfile, qr/Host: mixedmethod3 - user == mm3user/,
		"has provided mixed method 3 user");

like($optionfile, qr/Host: mixed1 - user == m1user/,
		"has provided mixed1 user");
like($optionfile, qr/Host: mixed1 - pw == m1pw1/,
		"has provided mixed1 pw1");
like($optionfile, qr/Host: mixed1 - pw2 == m1pw2/,
		"has provided mixed1 pw2");
like($optionfile, qr/Host: mixed2 - user == m2user/,
		"has provided mixed2 user");
like($optionfile, qr/Host: mixed2 - pw == m2pw1/,
		"has provided mixed2 pw1");
like($optionfile, qr/Host: mixed2 - pw2 == m2pw2/,
		"has provided mixed2 pw2");

$optionfile = $conn->_gen_option_file("different script\n");
like($optionfile, qr/Host: \*\ndifferent script/, 
		"has provided script without host");
