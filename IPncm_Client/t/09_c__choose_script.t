#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 11;
use IPncm_Client;
use test_vars;

is($conn->_choose_script(undef, 'hostname'), undef, 
		'undef returns undef');
is($conn->_choose_script(['test'], 'hostname'), undef, 
		'wrong ref returns undef');
is($conn->_choose_script('normal', 'hostname'), 'normal', 
		'normal returns normal');
is($conn->_choose_script({'hostname' => 'normal'}, 'hostname'), 'normal', 
		'key returns normal');
is($conn->_choose_script({'invalid' => 'normal'}, 'hostname'), undef, 
		'no key returns undef');
is($conn->_choose_script({'hostname' => 'normal', '*' => 'default'}, 
		'hostname'), 'normal', 'key returns normal with default');
is($conn->_choose_script({'invalid' => 'normal', '*' => 'default'}, 
		'hostname'), 'default', 'no key returns default with default');
is($conn->_choose_script({'/hostname/' => 'normal', '*' => 'default'}, 
		'hostname'), 'normal', 'pattern returns normal with default');
is($conn->_choose_script({'/host/' => 'normal', '*' => 'default'}, 
		'hostname'), 'normal', 'part pattern returns normal with default');
is($conn->_choose_script({'host' => 'normal', '*' => 'default'}, 
		'hostname'), 'default', 
		'unmarked pattern returns default with default');
is($conn->_choose_script({'/nothost/' => 'normal', '*' => 'default'}, 
		'hostname'), 'default', 'wrong pattern returns normal with default');
