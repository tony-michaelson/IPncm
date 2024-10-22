#!/usr/bin/perl

use strict;
use warnings;
use Cwd;
use File::Copy;
use File::Copy::Recursive qw(dircopy);
use File::Path qw(remove_tree);
use FindBin qw($Bin);
 
local $/=undef;

if (!-d "IPncm_Connector" || !-d "IPncm_Client" || !-e "bin/perl5-32.tar.gz" || 
		!-e "bin/perl5-64.tar.gz" || !-e "bin/perlbrew.tar.gz" || 
		!-e "current_version.txt")  {
	print STDERR "Not all required files found, aborting\n";
	exit(1);
}
my $ver = get_current_version();
my $cwd = getcwd;

if (!-e "tmp")  {
	mkdir("tmp");
}

#  Copy all files to temporary folder
`cp -r IPncm_Connector tmp`;
`cp -r IPncm_Client tmp`;
copy("bin/perl5-32.tar.gz", "tmp");
copy("bin/perl5-64.tar.gz", "tmp");
copy("bin/perlbrew.tar.gz", "tmp");

#  Copy libraries into IPncm_Connector and IPncm_Client
my $modules = "lib/*.pm";
for my $file (glob $modules)  {
	copy($file, "tmp/IPncm_Connector/lib");
	if ($file =~ 'Constants.new.pm')  {
		copy($file, "tmp/IPncm_Client/lib/Constants.pm");
	}  else {
		copy($file, "tmp/IPncm_Client/lib");
	}
}
chdir("$cwd/tmp");

chmod(0400, "IPncm_Connector/lib/Constants.new.pm", "IPncm_Client/lib/Constants.pm");

#  Update CURRENT_VERSION in all files
`grep -rl '<CURRENT_VERSION>' ./ | xargs sed -i 's/<CURRENT_VERSION>/$ver/g'`;

#  Remove all non-sample config files.
chdir("$cwd/tmp/IPncm_Connector/conf");
opendir(DOT, ".");
my @conf = grep(/\.conf$/ && ($_ ne "Sample.conf"), readdir(DOT));
closedir(DOT);
unlink(@conf);
chdir("$cwd/tmp");

#  Remove all .git files.
`find . -name .git -exec rm -rf {} \\;`;

#  Set up perl installations and add local versions of important libraries
`tar -zxf perl5-32.tar.gz`;
dircopy("../lib/Net", "perl5/perlbrew/perls/perl-5.18.0/lib/site_perl/5.18.0/Net");
if ($!)  {
	#fail("Can't copy into Perl32:  $!");
}
move("perl5", "perl5-32");
`tar -zxf perl5-64.tar.gz`;
dircopy("../lib/Net", "perl5/perlbrew/perls/perl-5.18.0/lib/site_perl/5.18.0/Net");
if ($!)  {
	fail("Can't copy into Perl64:  $!");
}
move("perl5", "perl5-64");
`tar -zxf perlbrew.tar.gz`;

#  Create IPncm_Client tar.gzs
move("perl5-32", "perl5");
`tar -czf IPncm_Client-32.tar.gz IPncm_Client perl5 .perlbrew`;
move("perl5", "perl5-32");
move("perl5-64", "perl5");
`tar -czf IPncm_Client-64.tar.gz IPncm_Client perl5 .perlbrew`;
move("perl5", "perl5-64");
copy("IPncm_Client-32.tar.gz", "IPncm_Connector/bin");
copy("IPncm_Client-64.tar.gz", "IPncm_Connector/bin");

move("perl5-32", "perl5");
`tar -czf IPncm_Connector-32.tar.gz IPncm_Connector perl5 .perlbrew`;
move("perl5", "perl5-32");
move("perl5-64", "perl5");
`tar -czf IPncm_Connector-64.tar.gz IPncm_Connector perl5 .perlbrew`;
move("perl5", "perl5-64");
copy("IPncm_Connector-32.tar.gz", "../bin");
copy("IPncm_Connector-64.tar.gz", "../bin");
cleanup();

my $major = 0;
my $minor = 0;
my $build = 0;
sub get_current_version  {
	if (!$major)  {
		open(F, "current_version.txt") || die ("Can't open version file!");
		my $file = <F>;
		close(F);
		if ($file =~ /(\d+)\.(\d+)\.(\d+)/)  {
			($major, $minor, $build) = ($1, $2, $3);
			$build++;
		}
		$file =~ s/\d+\.\d+\.\d+/$major.$minor.$build/;
		open(F, "> current_version.txt") || 
				die ("Can't open version file for writing!");
		print F $file;
		close(F);
	}
	return "$major.$minor.$build";
}

sub fail  {
	my ($msg) = @_;
	cleanup();
	die "Failed to complete build: $msg";
}

sub cleanup  {
	chdir($cwd);
	remove_tree("tmp");
}

