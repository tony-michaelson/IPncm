#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Cwd;
use File::Path qw(make_path remove_tree);
use Test::More tests => 76;
use IPncm_Client;
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


my @arr = ("a1", "a3", "a6", "a19", "b20", "a4", "b21", "b22", "a8", "c27",
	"c26", "a2", "a0", "x1/0/1", "x1/0/2", "x1/0/3");
my @out = IPncm_Client::gen_int_ranges(@arr);
is($out[0], "a0 - 4, a6, a8, a19, b20 - 22", "first range");
is($out[1], "c26 - 27, x1/0/1 - 3", "second range");

@arr = ();
@out = IPncm_Client::gen_int_ranges(@arr);
is($#out, -1, "gen empty array");

@arr = ("1", "a5", "4", "2", undef, "");
@out = IPncm_Client::gen_int_ranges(@arr);
is($out[0], "1 - 2, 4, a5", "empty elements and prefixes");

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

my $cwd = getcwd;
my $test_dir = "/tmp/test-" . time;
my $prefix1 = 'output-' . time;
my $prefix2 = time . '-output';
make_path($test_dir);
`touch $test_dir/$prefix1-empty`;
`touch $test_dir/$prefix2-empty`;
`echo "PROCESSING COMPLETE" > $test_dir/$prefix1-host1.txt`;
`echo "PROCESSING COMPLETE" > $test_dir/$prefix2-host2.txt`;
`echo "PROCESSING COMPLETE" > $test_dir/$prefix1-host3.txt`;
`echo "PROCESSING COMPLETE" > $test_dir/$prefix1-host4.txt`;
`echo "PROCESSING COMPLETE" > $test_dir/$prefix2-host4.txt`;
`echo "PROCESSING COMPLETE" > $test_dir/$prefix1-host5.txt`;
`echo "PROCESSING COMPLETE" > $test_dir/$prefix2-host6.txt`;
`echo "host5 host6" >  $test_dir/$prefix1-errors.txt`;
`echo "host6 host7" >  $test_dir/$prefix2-errors.txt`;
$conn->{dir} = $test_dir;
$conn->{output_file} = $prefix1;
$conn->{host_map} = {};
$conn->add('empty', 'host1', 'host2', 'host3', 'host4', 'host5', 'host6', 
		'host7');
@out = $conn->get_completion_counts('empty');
is_deeply(\@out, [0, 0, 1], 'empty file');
@out = $conn->get_completion_counts('host1');
is_deeply(\@out, [1, 0, 1], 'completed file');
@out = $conn->get_completion_counts('host2');
is_deeply(\@out, [0, 0, 1], 'completed file with different prefix');
@out = $conn->get_completion_counts('host4');
is_deeply(\@out, [1, 0, 1], 'completed file with two prefixes');
@out = $conn->get_completion_counts('host5');
is_deeply(\@out, [1, 1, 1], 'completed file with error');
@out = $conn->get_completion_counts('host6');
is_deeply(\@out, [0, 1, 1], 'uncompleted file with error');
@out = $conn->get_completion_counts('host1', 'host2', 'host3');
is_deeply(\@out, [2, 0, 3], 'multiple files');
@out = $conn->get_completion_counts();
is_deeply(\@out, [4, 2, 8], 'all hosts');
remove_tree($test_dir);
@out = $conn->get_completion_counts();
is_deeply(\@out, [0, 0, 8], "directory doesn't exist");
