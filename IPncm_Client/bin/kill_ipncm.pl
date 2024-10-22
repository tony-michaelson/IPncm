#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

my $out = `ps -ef | grep IPncm_Client.pl`;
foreach my $line (split(/\n/, $out))  {
        my @line = split(/\s+/, $line);
        `kill -9 $line[1]`;
}

