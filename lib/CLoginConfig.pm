package CLoginConfig;
#  Utility package to deal with processing connection login information from an 
#  ipmon.

#  CLoginConfig->new($conf, $priority)
#  Function:  Returns a new CLoginConfig object.
#  Parameters: $conf - string:  an initial config (probably from a .cloginrc 
#      file) - see parse_config() for the desired format.
#    $priority - int:  priority ordering of config, higher == higher priority
#  Returns:  CLoginConfig: the new CLoginConfig object.
sub new  {
	my $this = shift;
	my ($conf, $priority) = @_;

	my $class = ref($this) || $this;
	my $self = {
		values => {}
	};
	bless $self, $class;
	
	$self->parse_config($conf, $priority);
	return $self;
}

#  $config->parse_config($conf, $priority)
#  Function:  Adds the login configuration to this config object.
#  Parameters: $conf - string:  a config (probably from a .cloginrc 
#      file).  It should be in the format:
#      add <key> <hostname/pattern> <value1> <value2>
#      Where:
#    	<key>:  user, password, or method (other values are possible but
#    		 ignored).  user is the login user, password is the login password
#    		 (with the privileged-mode password as <value2>), and method is
#    		 method to be used to contact the host (currently only ssh and 
#    		 telnet are supported).
#    	<hostname/pattern>:  the host or host pattern this login information
#    		 line applies to.
#    	<value1>:  the value for this key.
#    	<value2>:  only used for password keys.
#    $priority - priority:  Priority order of this configuration (higher number 
#       == higher priority).  
#  Returns:  N/A
sub parse_config  {
	my $this = shift;
	my ($conf, $priority) = @_;
	if (!defined($conf) || !$conf)  {
		return;
	}
	$priority = defined($priority) ? $priority : 0;
	foreach my $line  (split(/\n/, $conf))  {
		chomp($line);
		$line =~ s#\\(.)#$1#g;
		if ($line =~ /^add ([a-zA-Z_]*)\s+(\S*)\s+(\S*)\s*(.*?)\s*$/)  {
			my $key = $1 || "";
			my $host = $2 || "";
			my $value = $3 || "";
			my $other = $4 || "";
			$host =~ s/(?<!\.)\*/.*/g;
			$value =~ s/^\{(.*)\}$/$1/;
			$other =~ s/^\{(.*)\}$/$1/;
			if ($key eq "user")  {
				$this->set_value('user', $value, $host, $priority--);
			}  elsif ($key eq "password")  {
				$this->set_value('pw', $value, $host, $priority--);
				$this->set_value('source', 'cloginrc', $host, $priority--);
				if ($other)  {
					$other =~ s/^ +//;
					$this->set_value('pw2', $other, $host, $priority--);
				}
			}  elsif ($key eq "method")  {
				$value = $value . ($other ? " " . $other : ""); 
				if ($value =~ /ssh/ || $value =~ /telnet/)  {
					$this->set_value('method', $value, $host, $priority--);
				}
			}
		}
	}
}


#  $config->get_value($key, $host)
#  Function:  Gets the value associated with this key for this host, using 
#      regular expressions to pick the first pattern that matches the host.
#  Parameters: $key - string:  the key for the value desired.  Currently stored
#      keys are:  user, pw, pw2.
#    $host - string:  the hostname to get the configuration from.  Defaults to
#      '*'.
#  Returns:  string:  the value for this key, or undef if it isn't found.
sub get_value  {
	my $this = shift;
	my ($key, $host) = @_;
	$host = "" if (!defined($host));
	foreach my $priority (sort {$b <=> $a} keys(%{$this->{values}}))  {
		foreach my $pattern (keys(%{$this->{values}->{$priority}}))  {
			if (defined($this->{values}->{$priority}->{$pattern}->{$key}) && 
					($host =~ /^$pattern$/))  {
				return $this->{values}->{$priority}->{$pattern}->{$key};
			}
		}
	}
	return undef;
}


#  $config->set_value($key, $val, $host, $priority)
#  Function:  Sets the value associated with this key for this host.
#  Parameters: $key - string:  the key for the value desired.
#    $value - string:  the value for the key desired.
#    $host - string:  the hostname to set the configuration for.  Defaults to
#      '*'.
#    $priority - int:  priority ordering of info, higher == more important.
#  Returns:  N/A
sub set_value  {
	my $this = shift;
	my ($key, $val, $host, $priority) = @_;
	if (!defined($host))  {
		$host = "*";
	}
	$host =~ s/(?<!\.)\*/.*/g;
	$this->{values}->{$priority}->{$host}->{$key} = $val;
}



#  $config->get_config()
#  Function:  Returns this configuration as a string.
#  Parameters: N/A
#  Returns:  N/A
sub get_config  {
	my $this = shift;
	my $str = "";
	foreach my $priority (sort {$b <=> $a} keys(%{$this->{values}}))  {
		foreach my $pattern (keys(%{$this->{values}->{$priority}}))  {
			foreach my $key (keys(%{$this->{values}->{$priority}->{$pattern}}))  {  
				my $value = $this->{values}->{$priority}->{$pattern}->{$key};
				$str .= "Login: $pattern ($priority) - $key == $value\n";
			}
		}
	}
	return $str;
}


sub DESTROY {  }

1;

