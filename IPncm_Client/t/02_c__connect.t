#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 13;
use IPncm_Client;
use test_vars;

my $config = new CLoginConfig($conf);

my $conn = new IPncm_Client($host);
isa_ok($conn, 'IPncm_Client');

my $connection = $conn->_connect($host);
is($conn->error(), '', 'no error after correct connection');
isa_ok($connection, 'Net::Appliance::Session');

$conn = new IPncm_Client();
$connection = $conn->_connect("invalid");
like($conn->error(), qr/not added, aborting/, 
		'invalid host not connected - no config');
is($connection, undef, 'undef returned from invalid connection');

$conn->add($host);
my $user = $conn->{config}->get_value('user');
my $pw = $conn->{config}->get_value('pw');
$conn->{config}->set_value('user', 'invalid', '*');
my $t1 = time;
$connection = $conn->_connect($host);
my $t2 = time;
like($conn->error(), qr/Can't connect/, 'broken user fails correctly');
is($connection, undef, 'not connected with broken user');
ok($t2 - $t1 >= 5, 'At least 5 second timeout when failing to connect (for retries)');

$conn->{config}->set_value('user', $user, '*');
$conn->{config}->set_value('pw', 'invalid', '*');
$t1 = time;
$connection = $conn->_connect($host);
$t2 = time;
like($conn->error(), qr/Can't connect/, 'broken password fails correctly');
is($connection, undef, 'not connected with broken user');
ok($t2 - $t1 >= 5, 'At least 5 second timeout when failing to connect (for retries)');

$conn->{config}->set_value('pw', $pw, '*');
$connection = $conn->_connect($host);
is($conn->error(), '', 'no error after correct connection');
isa_ok($connection, 'Net::Appliance::Session');

$conn->_clear_output();