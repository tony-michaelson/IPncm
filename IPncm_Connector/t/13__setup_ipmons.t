#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 1;
use IPncm_Connector qw(:LOG);
use test_vars;
use Sys::Hostname;

TODO:  {
	local $TODO = "Tests not written yet";
	fail('testing');
}
