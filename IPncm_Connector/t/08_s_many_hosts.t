#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More;
use IPncm_Connector;
use List::Util qw(shuffle);
use test_vars;

my @num_hosts = (20, 40, 60, 100, 200);
my $num_tests = 0;
foreach my $nh (@num_hosts)  {
	$num_tests += 1 + $nh;
}
plan tests => $num_tests;

foreach my $num_hosts (@num_hosts)  {

	SKIP:  {
		my @n_hosts = get_hosts($num_hosts / 2, $num_hosts);
		skip "not enough hosts to test with", (1 + $num_hosts) unless 
				(scalar(@n_hosts) == $num_hosts);
		$conn = new IPncm_Connector();

		my %time = ( start => time );
		$conn->add(@n_hosts);
		$time{after_add} = time;
		$time{add} = $time{after_add} - $time{start};

		my $result = $conn->send_hosts('show version');
		$time{after_send} = time;
		$time{send} = $time{after_send} - $time{after_add};
		is($conn->error(), '', 'no error after send more than limit'); 
		foreach my $h (@n_hosts)  {
			if (defined($result->{$h}))  {
				like($result->{$h}, qr/$send_version_pattern/, "correct result from $h");
			}  else {
				fail("result for $h defined"); 
			}
		}
		
		print <<EOF;
Time results ($num_hosts hosts):
	add: $time{add}
	send: $time{send}

EOF
	}
}

