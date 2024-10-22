#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 12;
use IPncm_Connector qw(:LOG);
use test_vars;

$conn->add($host);
my $output = $conn->send_hosts('show version', $host);
is($conn->error(), '', 'no error from valid command');
like($output->{$host}, qr/$send_version_pattern/, 
		'correct output from proper command');

my $user = $conn->{config}->get_value('user');
my $pw = $conn->{config}->get_value('pw');
my $pw2 = $conn->{config}->get_value('pw2');

$conn->set_login('invalid');
is($conn->{config}->get_value('user'), 'invalid', 'change affects user');
is($conn->{config}->get_value('pw'), $pw, 'change not affects pw');
is($conn->{config}->get_value('pw2'), $pw2, 'change not affects pw2');

$output = $conn->send_hosts('show version', $host);
like($conn->error(), qr/login failed to remote host/, 'error after invalid user connection');
is($output->{$host}, "", 'no output after invalid user connection');

$conn->set_login($user, 'invalid');
is($conn->{config}->get_value('user'), $user, 'change affects user');
is($conn->{config}->get_value('pw'), 'invalid', 'change affects pw');
is($conn->{config}->get_value('pw2'), $pw2, 'change not affects pw2');

$output = $conn->send_hosts('show version', $host);
like($conn->error(), qr/login failed to remote host/, 'error after invalid user connection');
is($output->{$host}, "", 'no output after invalid user connection');

