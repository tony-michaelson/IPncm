#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 85;
use IPncm_Connector;
use test_vars;

my $config = new CLoginConfig();
isa_ok($config, 'CLoginConfig');
is(scalar(@{$config->{values}}), 0, 'no config, has no values?');

$config->parse_config($conf);
ok(defined($config), 'config, is $config defined?');
is($config->get_value('user', '*'), 'defaultuser', '* - default user?');
is($config->get_value('user'), 'defaultuser', 'no host - default user?');
is($config->get_value('pw'), 'defaultpw1', 'no host - default pw?');
is($config->get_value('pw', '*'), 'defaultpw1', '* - default pw?');
is($config->get_value('pw2'), 'defaultpw2', 'no host - default pw2?');
is($config->get_value('pw2', '*'), 'defaultpw2', '* - default pw2?');

is($config->get_value('user', 'nopw'), 'npuser1', 'nopw - user?');
is($config->get_value('pw', 'nopw'), 'defaultpw1', 'nopw - pw1?');
is($config->get_value('pw2', 'nopw'), 'defaultpw2', 'nopw - pw2?');

is($config->get_value('user', 'nouser'), 'defaultuser', 'nouser - user?');
is($config->get_value('pw', 'nouser'), 'nupw1', 'nouser - pw1?');
is($config->get_value('pw2', 'nouser'), 'nupw2', 'nouser - pw2?');

is($config->get_value('user', 'nopw2'), 'defaultuser', 'nopw2 - user?');
is($config->get_value('pw', 'nopw2'), 'np2pw1', 'nopw2 - pw1?');
is($config->get_value('pw2', 'nopw2'), '', 'nopw2 - pw2?');

is($config->get_value('user', 'twouser'), 'tuuser1', 'twouser - user?');

is($config->get_value('pw', 'twopw'), 'tppw1', 'twopw - user?');
is($config->get_value('pw2', 'twopw'), 'tppw2', 'twopw - user?');

is($config->get_value('user', 'sshmethod'), 'smuser', 'sshmethod - user?');
is($config->get_value('pw', 'sshmethod'), 'smpw1', 'sshmethod - pw1?');
is($config->get_value('pw2', 'sshmethod'), 'smpw2', 'sshmethod - pw2?');

is($config->get_value('user', 'nonsshmethod'), 'defaultuser', 'nonssh - user?');
is($config->get_value('pw', 'nonsshmethod'), 'defaultpw1', 'nonssh - pw1?');
is($config->get_value('pw2', 'nonsshmethod'), 'defaultpw2', 'nonssh - pw2?');

is($config->get_value('user', 'mnonsshmethod'), 'defaultuser', 'mnonssh - user?');
is($config->get_value('pw', 'mnonsshmethod'), 'defaultpw1', 'mnonssh - pw1?');
is($config->get_value('pw2', 'mnonsshmethod'), 'defaultpw2', 'mnonssh - pw2?');

is($config->get_value('user', 'mixedmethod1'), 'mm1user', 'mixedmethod1 - user?');
is($config->get_value('user', 'mixedmethod2'), 'mm2user', 'mixedmethod2 - user?');
is($config->get_value('user', 'mixedmethod3'), 'mm3user', 'mixedmethod3 - user?');

is($config->get_value('user', 'mixed1'), 'm1user', 'mixed 1 - user?');
is($config->get_value('pw', 'mixed1'), 'm1pw1', 'mixed 1 - pw1?');
is($config->get_value('pw2', 'mixed1'), 'm1pw2', 'mixed 1 - pw2?');
is($config->get_value('user', 'mixed2'), 'm2user', 'mixed 2 - user?');
is($config->get_value('pw', 'mixed2'), 'm2pw1', 'mixed 2 - pw1?');
is($config->get_value('pw2', 'mixed2'), 'm2pw2', 'mixed 2 - pw2?');

is($config->get_value('user', 'pattern1'), 'p1user', 'pattern - first match returned');
is($config->get_value('user', 'pattern2'), 'puser', 'pattern - second match exists');
is($config->get_value('user', 'pattern1blah'), 'p1user', 'pattern - full pattern match');
is($config->get_value('user', '132pattern'), 'p2user', 'pattern - internal pattern match');
is($config->get_value('user', '2132pattern'), 'ppuser', 'pattern - requires full match');

$config->set_value('user', 'mixed3', 'mixed1');
is($config->get_value('user', 'mixed1'), 'mixed3', 'set_value - new value overrides old');

$config->set_value('user', 'newdefaultuser');
is($config->get_value('user'), 'newdefaultuser', 'set_value - no domain');

$config->set_value('pw', 'newpw1', 'testdomain');
is($config->get_value('pw'), 'defaultpw1', 'set_value - with domain, no change default');
is($config->get_value('pw', 'testdomain'), 'newpw1', 'set_value - with domain, change domain');

$config->set_value('pw', 'newpw2', 'testdomain');
is($config->get_value('pw', 'testdomain'), 'newpw2', 'set_value - new value overrides old set_value');


$conn->add(@hosts);
is($conn->error(), '', 'no error after adding hosts');
ok(defined($conn->{host_to_base_ipmon}->{$conn->_select_hostname($host)}), "$host in host_map before removal");

$conn->remove($host);
is($conn->error(), '', 'no error after removing host');
ok(!defined($conn->{host_to_base_ipmon}->{$conn->_select_hostname($host)}), "$host not in host_map after removal");

$conn->remove();
is($conn->error(), '', 'no error after removing all hosts');
ok(!%{$conn->{host_to_base_ipmon}}, 'no hosts in host_map after all removed');

$conn->remove('invalid');
is($conn->error(), '', 'no error after removing invalid host');
ok(!%{$conn->{host_to_base_ipmon}}, 'still no hosts in host_map');


is($conn->is_valid_script("show version"), 1, "standard script is valid");
is($conn->is_valid_script("<perl>1;</perl>"), 1, "perl script is valid");
is($conn->is_valid_script("show version\n<perl>1;</perl>"), 1, 
		"mixed script is valid");
is($conn->is_valid_script("<perl>1;</perl><perl>1;</perl>"), 1, 
		"multiple perl block script is valid");
is($conn->is_valid_script(
		"show version\n<perl>1;</perl>show version<perl>1;</perl>show version"
		), 1, "mixedmultiple perl block script is valid");
my %script = ('1' => 'show version', 2 => 'show version');
is($conn->is_valid_script(\%script), 1, "hash ref script is valid");

is($conn->is_valid_script(undef), 0, "undef script is invalid");
is($conn->is_valid_script(["show version"]), 0, "array ref script is invalid");
my $str = "show version";
is($conn->is_valid_script(\$str), 0, "string ref script is invalid");
%script = ('1' => 'show version', 2 => undef);
is($conn->is_valid_script(\%script), 0, 
		"hash ref script with undef value is invalid");
is($conn->is_valid_script("<perl>1;<perl>2;</perl>3;</perl>"), 0, 
		"perl script with internal '<perl>' tag is invalid");
is($conn->is_valid_script(qq(<perl>send_host("<perl>1;</perl>");</perl>)), 0, 
		"perl script with internal quoted '<perl>' tag is invalid");
%script = (
	'1' => { '1' => 'show version' },
);
is($conn->is_valid_script(\%script), 0, "hash ref inside hash ref is invalid");
is($conn->is_valid_script("<perl>"), 0, 
		"<perl> tag without </perl> tag is invalid");
is($conn->is_valid_script("</perl>"), 0, 
		"</perl> tag without <perl> tag is invalid");
is($conn->is_valid_script("<perl>1;</perl><perl>"), 0, 
		"too many <perl> tags is invalid");
is($conn->is_valid_script("<perl>1;</perl></perl>"), 0, 
		"too many </perl> tags is invalid");

is($conn->is_valid_script("<perl>exit(1);</perl>"), 0, 
		"exit() call is invalid");
is($conn->is_valid_script("<perl>print 'exit(1);';</perl>"), 1, 
		"exit() call in single quotes is valid");
is($conn->is_valid_script("<perl>print \"exit(1);\";</perl>"), 1, 
		"exit() call in double quotes is valid");
is($conn->is_valid_script("<perl>print 'exit(1);';exit(1);</perl>"), 0, 
		"exit() call after single quotes is invalid");
is($conn->is_valid_script("<perl>print \"exit(1);\";exit(1);</perl>"), 0, 
		"exit() call after double quotes is invalid");
is($conn->is_valid_script("<perl>print exit(1);'exit(1);';</perl>"), 0, 
		"exit() call before single quotes is invalid");
is($conn->is_valid_script("<perl>print exit(1);\"exit(1);\";</perl>"), 0, 
		"exit() call before double quotes is invalid");
is($conn->is_valid_script("<perl>print 'exit(1);';print 'exit(1)';</perl>"), 1, 
		"exit() call with multiple single quotes is valid");
is($conn->is_valid_script("<perl>print \"exit(1);\";print \"exit(1)\";</perl>"), 
		1, "exit() call with multiple double quotes is valid");
is($conn->is_valid_script("<perl>print 'exit(1)';exit(1);print 'exit(1);';</perl>"), 0, 
		"exit() call surrounded by single quoted items is invalid");
is($conn->is_valid_script("<perl>print \"exit(1)\";exit(1);print\"exit(1);\";</perl>"), 0, 
		"exit() call surrounded by double quoted items is invalid");
