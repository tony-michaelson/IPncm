#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 14;
use IPncm_Client;
use test_vars;

is($conn->get_max_connections(), 50, 'initially set to default?');
is($conn->_sema_status(), 50, 'semaphore set to default');

$conn->set_max_connections(10);
is($conn->get_max_connections(), 10, 'decreasing');
is($conn->_sema_status(), 10, 'semaphore set to less value');

$conn->set_max_connections(25);
is($conn->get_max_connections(), 25, 'increasing');
is($conn->_sema_status(), 25, 'semaphore set to greater value');

$conn->set_max_connections(0);
is($conn->get_max_connections(), 25, 'changing to 0');
is($conn->_sema_status(), 25, 'semaphore unchanged');

$conn->set_max_connections('q');
is($conn->get_max_connections(), 25, 'changing to q');
is($conn->_sema_status(), 25, 'semaphore unchanged');

$conn->set_max_connections(-1);
is($conn->get_max_connections(), 25, 'changing to -1');
is($conn->_sema_status(), 25, 'semaphore unchanged');

$conn->set_max_connections();
is($conn->get_max_connections(), 25, 'calling with no value');
is($conn->_sema_status(), 25, 'semaphore unchanged');

