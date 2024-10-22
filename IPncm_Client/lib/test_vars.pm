package test_vars;

use Exporter;
use FindBin qw($Bin);
use List::Util qw(shuffle);
use IPncm_Client;
use Sys::Hostname;

use constant CONFIG_PATH => "$Bin/../conf";

@ISA = qw(Exporter);
use vars (@EXPORT);
@EXPORT = qw($conn @hosts $host $conf $qa_host get_hosts 
		$send_version_pattern $show_ip_pattern);

our $send_version_pattern = "(?:Cisco (?:IOS Software|Internetwork Operating System Software|NX-OS|Nexus Operating System|Adaptive Security Appliance)|Product model)";
our $show_ip_pattern = "(?:Interface|Incomplete command)";
our $conn = new IPncm_Client(); 

our $conf = <<EOF;
add method cue* {usercmd}

add usercmd_chat cue* {word} {pw1\r} {\#} {Service-module ISM 0/0 session\r} {Username:} {user1\r} {Password:} {pw1\r} {sleep} {} { } {\r}

add user nopw npuser1
add password nouser nupw1 nupw2
add password nopw2 np2pw1
add user twouser tuuser1
add user twouser tuuser2
add password twopw tppw1 tppw2
add password twopw tppw3 tppw4

add user sshmethod smuser
add password sshmethod smpw1 smpw2
add method sshmethod ssh

add user nonsshmethod nsmuser
add password nonsshmethod nsmpw1 nsmpw2
add method nonsshmethod deleteme

add method mnonsshmethod deleteme
add user mnonsshmethod nsmuser
add password mnonsshmethod nsmpw1 nsmpw2

add user mixed1 m1user
add user mixed2 m2user
add password mixed1 m1pw1 m1pw2
add password mixed2 m2pw1 m2pw2

add user pattern1* p1user
add user pattern* puser
add user 1*2pattern p2user
add user *pattern ppuser

add user * defaultuser
add password * defaultpw1 defaultpw2
add method * ssh
add autoenable * 0
EOF


my @invasive_test_devices = ();
my @noninvasive_test_devices = ();
sub parse_config_files  {
	opendir(DIR, CONFIG_PATH) || die("Can't access " . CONFIG_PATH);
	my @files = grep(/.conf$/ && ($_ ne "Sample.conf"), readdir(DIR));
	closedir(DIR);
	
	foreach my $config (@files)  {
		open(FILE, CONFIG_PATH . "/$config") || die("Can't open '$config'");
		my $type = '';
		my $cur_ipmon = "";
		while(<FILE>)  {
			next if (/^\s*$/ || /^\s*#/);
			if (/^(\w.*):/)  {
				$type = $1;
			}  elsif ($type eq "Invasive Test Devices")  {
				if (/^	(\w.*?)\s*$/)  {
					push(@invasive_test_devices, $1);
				}
			}  elsif ($type eq "Noninvasive Test Devices")  {
				if (/^	(\w.*?)\s*$/)  {
					push(@noninvasive_test_devices, $1);
				}
			}
		}
	}
}


sub get_hosts  {
	my ($numnorm, $numwlc, $numcue) = @_;
	my $ipmon = hostname;
	$ipmon =~ s/\.(?:ip-soft.net|ipcenter.com)//;
	$ipmon =~ /\.([^\.]+)$/;
	
	$numnorm = defined($numnorm) ? $numnorm : 5;
	$numwlc = defined($numwlc) ? $numwlc : 0;
	$numcue = defined($numcue) ? $numcue : 0;

	my @h = ();
	my @normal = ();
	my @wlc = ();
	my @cue = ();

	push(@normal, grep(($_ !~ /cue/) && ($_ !~ /wlc/), 
			@noninvasive_test_devices));
	push(@wlc, grep(/wlc/, @noninvasive_test_devices));
	push(@cue, grep(/cue/, @noninvasive_test_devices));
	@normal = shuffle(@normal);
	@wlc = shuffle(@wlc);
	@cue = shuffle(@cue);

	push(@h, @normal[0 .. $numnorm - 1]) 
			if ($numnorm && (scalar(@normal) >= $numnorm));
	push(@h, @wlc[0 .. $numwlc - 1])
			if ($numwlc && (scalar(@wlc) >= $numwlc));
	push(@h, @cue[0 .. $numcue - 1])
			if ($numcue && (scalar(@cue) >= $numcue));
	return shuffle(@h);
}

parse_config_files();
if (!@noninvasive_test_devices)  {
	die 'Unable to run tests - no test devices available';
}

our @hosts = get_hosts(5);
our $host = $hosts[rand @hosts];
our %hosts = ();

if (!@hosts || (scalar(@hosts) < 5))  {
	die 'Unable to run tests - insufficient hosts available';
}

our $qa_host = @invasive_test_devices ? 
		$invasive_test_devices[rand @invasive_test_devices] : undef;

1;
