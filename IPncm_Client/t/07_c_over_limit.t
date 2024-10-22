#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

use strict;
use warnings;
use Test::More;
use IPncm_Client;
use List::Util qw(shuffle);
use test_vars;

my @num_hosts = (10, 20, 30, 50, 100);
my $num_tests = 0;
foreach my $nh (@num_hosts)  {
	$num_tests += 2 + $nh;
}
plan tests => $num_tests;

foreach my $num_hosts (@num_hosts)  {
	SKIP:  {
		my $max_conn = int($num_hosts / 2);

		my @n_hosts = get_hosts($num_hosts);
		skip "not enough valid devices to test this number of hosts", 
				(2 + $num_hosts) unless (scalar(@n_hosts) == $num_hosts);
		
		$conn = new IPncm_Client();
		$conn->set_max_connections($max_conn);

		my %time = ( start => time );
		$conn->add(@n_hosts);
		$time{after_add} = time;
		$time{add} = $time{after_add} - $time{start};

		my $result = $conn->send_hosts('show version');
		$time{after_thread} = time;
		$time{thread} = $time{after_thread} - $time{after_add};
		is($conn->error(), '', 'no error after send more than limit');
		is(scalar(keys(%{$conn->{connections}})), 0, 'no connections after send');
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
	send: $time{thread}
	
EOF
	}
}

