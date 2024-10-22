package Show_Version;

use strict;
use warnings;

#
#  Script to run and print  'show version' for testing purposes
#


sub run  {
	my $this = shift;
	my $conn = shift;
	my $hostname = shift;
	print $conn->send_host("show version");
	return 1;
}

1;
