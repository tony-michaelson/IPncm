#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More tests => 53;
use IPncm_Client;
use test_vars;
use Cwd;
use Sys::Hostname;

$conn->add($host);
my $output = $conn->_send_host("exit\nshow version\nlogout", $host);
is($conn->error(), '', 'no error from valid commands');
like($output, qr/'exit' caused connection to close, re-opening/, 
		'exit caused connection to close and reopen for next command');
like($output, qr/$send_version_pattern/, 'output contains version info');
like($output, qr/'logout' caused connection to close\n/, 
		'logout caused connection to just close (no more commands)');

for (my $i = 0; $i < 10; $i++)  {
	$output = $conn->_send_host('conf t\nend\nshow version', $host);
	is($conn->error(), '', "no error from conf t command iteration $i");
	like($output, qr/$send_version_pattern/, 
			"correct output from conf t command iteration $i");
}

SKIP:  {
	skip "no qa device to test with on this ipmon", 29 unless defined($qa_host);
	my $ipmon = hostname;
	my $ip = `grep $ipmon /etc/hosts`;
	$ip =~ /([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/;
	$ip = $1;

	my $cwd = getcwd;
	$cwd =~ s#^/apps##;
	my $file = "test-" . int(rand(100000)) . ".txt";
	open(F, ">", $file);
	print F "This is a test\n";
	close(F);

	$conn->add($qa_host);
	$output = $conn->_send_host('show flash', $qa_host);
	is($conn->error(), '', 'no error from show flash');
	unlike($output, qr/$file/, 'file doesn\'t exist before copy');

	$output = $conn->_send_host("copy scp://BASE_USER\@$ip/$cwd/$file flash:", 
			$qa_host);
	is($conn->error(), '', 'no error from copy');

	$output = $conn->_send_host('show flash', $qa_host);
	is($conn->error(), '', 'no error from show flash');
	like($output, qr/$file/, 'file exists after copy');

	$output = $conn->_send_host("delete flash:$file", 
			$qa_host);
	is($conn->error(), '', 'no error from delete');
	$output = $conn->_send_host('show flash', $qa_host);
	is($conn->error(), '', 'no error from show flash');
	unlike($output, qr/$file/, 'file gone after delete');
	unlink($file);

	$output = $conn->_send_host('show flash', $qa_host);
	is($conn->error(), '', 'no error from show flash');
	unlike($output, qr/$file/, 'file doesn\'t exist before copy');


	$conn->_send_to_flash();
	like($conn->error(), qr/file contents parameter required/, 'sending nothing');
	$conn->_send_to_flash(undef, 'show version');
	like($conn->error(), qr/not added, aborting/, 'sending no hosts');

	my $filename = $conn->_send_to_flash(undef, 'test file', $qa_host);
	is($conn->error(), '', 'no error from file send');
	like($filename, qr/^config-/, 'correct output from file send');
	$output = $conn->_send_host('show flash', $qa_host);
	is($conn->error(), '', 'no error from file test command');
	like($output, qr/$filename/, 'file present in flash');

	$conn->_send_host("delete flash:$filename", $qa_host);
	is($conn->error(), '', 'no error from file deletion command');

	$filename = $conn->_send_to_flash(undef, "\n", $qa_host);
	is($conn->error(), '', 'no error from send_to_flash');
	like($filename, qr/^config-/, 'correct output from send_to_flash');
	$output = $conn->_send_host('show flash', $qa_host);
	is($conn->error(), '', 'no error from send_to_flash test command');
	like($output, qr/$filename/, 'file present in flash');

	$output = $conn->_send_to_run(undef, $filename, $qa_host, 1);
	is($conn->error(), '', 'no error from send_to_run');
	my $cur_cmd = '';
	my $cur_output = '';
	foreach my $line (split(/\n/, $output))  {
		if ($line =~ /^-- (.*) --$/)  {
			my $last = $cur_cmd;
			$cur_cmd = $1;
			if ($last =~ /delete .*\.backup/)  {  
				ok(($cur_output =~ /Error deleting flash.*No such file/) || 
						($cur_output !~ /\w/), 
						'no problem with backup deletion');
			}  elsif ($last =~ /copy run flash/)  {
				like($cur_output, qr/ bytes copied /, 'backup created');
			}  elsif ($last =~ /copy flash/) {
				like($cur_output, qr/ bytes copied /, 'config copied');
			}  elsif ($last =~ /delete/)  {
				fail('file deletion should not occur with keep file');
			}  elsif ($last =~ /copy run start/)  {
				like($cur_output, qr/Building configuration.*bytes copied /, 
						'run copied to start');
			}  elsif ($last =~ /\w/)	{ 
				fail("invalid command output - cmd == '$last', " . 
						"output == '$cur_output'");
			}
			$cur_output = '';
		}  else  {
			$cur_output .= $line;
		}		
	}

	$output = $conn->_send_host('show flash', $qa_host);
	is($conn->error(), '', 'no error from send_to_run test command');
	like($output, qr/$filename/, 'file present in flash');

	$conn->_send_to_run(undef, $filename, $qa_host, 0);
	$output = $conn->_send_host('show flash', $qa_host);
	is($conn->error(), '', 'no error from send_to_run test command 2');
	unlike($output, qr/$filename(?!\.backup)/, 
			'file no longer present in flash');
}

$conn->_clear_output();

