#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 4;
use IPncm_Connector;
use test_vars;

$conn->add(@hosts);

isa_ok($conn->{config}, 'CLoginConfig');
isnt($conn->{config}->get_value('user'), undef, 'defined default user name');
isnt($conn->{config}->get_value('user'), "", 'set default user name');

$conn = new IPncm_Connector();
$conn->{base_ipmon_to_host}->{invalid} = ();
$conn->_get_ipmon_configs();
like($conn->error(), qr/error connecting when gathering configuration information/, 
		'invalid device fails correctly');

