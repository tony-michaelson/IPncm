#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 4;
use IPncm_Client;
use test_vars;

$conn->add(@hosts);
ok(defined($conn->{host_map}->{$host}), "$host in host_map before removal");

$conn->remove($host);
ok(!defined($conn->{host_map}->{$host}), "$host not in host_map after removal");

$conn->remove();
ok(!%{$conn->{host_map}}, 'no hosts in host_map after all removed');

$conn->remove('invalid');
ok(!$conn->error(), 'no error after removing invalid host');
