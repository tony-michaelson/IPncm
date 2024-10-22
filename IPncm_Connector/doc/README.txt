IPncm_Connector Usage Documentation
=====================================

Functionality
-----------------------------

The IPncm_Connector allows for automatic contacting and running of scripts on 
a number of connected devices simultaneously.  It runs in a multi-threaded way, 
keeping connections open only as long as needed and contacting 50 devices per 
ipmon at the same time.  The code that can be run is a combination of 
command-line code and evaluated Perl code.  It is separated into two pieces:
IPncm_Connector, which is run on the produtil machine and which deals with 
contacting ipmons, and IPncm_Client, which is run on the ipmons and which 
deals with contacting end devices.


Usage from the command line
-----------------------------

IPncm_Connector itself is located on the produtil machine (though it contacts 
subcomponents, IPncm_Client, located on several IPMons).  It utilizes a 
version of Perl with a number of packages pre-installed.  This version is 
located in /home/BASE_USER/perl5, and is used by running "source 
~/perl5/perlbrew/etc/bashrc" from the command line.  Once this is done, it can 
be run from the command line by calling:

/home/BASE_USER/IPncm_Connector/IPncm_Connector.pl (-s <script>|-c|-t) 
	(-h <hostlist>|-a) [-C] [-d <output_dir>] [-k] 
	[-o <file_prefix>] [-u <username> -p <password>] [-b] [-e] [-m]  
	[-D <debug_level>]

Options:
	-s <script>
		This is the script to be run, consisting of a list of commands to be 
		run (separated by newlines) and perl code (in <perl>...</perl> blocks).  
		An example might be "show version\nshow ip int bri<perl>print 
		'specialized output';</perl>" - the output of which would be printing 
		the output of the "show version" command, then the output of the "show 
		ip int bri" command, then the phrase "specialized output". 
		Base64-encoded data is properly decoded before evaluation.  See the 
		sections below for more information about the types of Perl code that 
		can be run.
	[-c]
		Rather than running the script, checks for and prints completion stats
		for a currently running script.  This requires the same -o and -d 
		options as the other instance (and requires a -o option to be set, as 
		otherwise it defaults to the current timestamp, which is probably not
		what the other instance uses).
	[-t]
		Tests the connections to the given devices rather than running a script.
		Only prints out error information - devices without errors return 
		nothing.
	-h <device_list>
		A comma-separated list of devices to contact (or a list of ipmons to
		contact, if -a is set).
	-a
		Connect to all hosts.  If this is set, the -h list is used as a list of 
		ipmons to contact instead of hosts, and all hosts on just those ipmons
		are contacted. 
	[-C]
		If present, prints the output as a CSV file, with the syntax 
		"<hostname>, <ipmon>, <status>, <failure reason>" - the status is 
		either "SUCCESS" or "FAILURE", and the failure reason is the first line 
		of error output.
	[-d <dir>]
		The directory where output is stored (temporarily, if the -k option is 
		not provided).  Defaults to /home/BASE_USER/IPncm_Connector/tmp.
	[-k]
		If used, this option leaves the output directory and output files 
		intact after execution completes.  Otherwise, the output files and 
		output directory are removed at the end of execution.
	[-o <output_file>]
		Specifies a pattern for the name of the output files.  Output files 
		are called <output_file>-<hostname>.txt.  Defaults to 
		"output-<current_timestamp>", so new files will be called something 
		list "output-1379008409-ise.thd.txt".  The file containing errors will 
		be called "<output_file>-errors.txt".
	[-u <username>]
	[-p <password>]
		Together, specify the username and password to be used to contact the 
		devices.  If this is not specified, uses the information stored on the 
		ipmons to contact them.
	[-b]
		If set, attempts to backup the current running configuration on the 
		devices to the IPmon the device is connected to.  The configs are 
		stored in /home/BASE_USER/saved_configs/backup-config-<hostname>.txt.
	[-e]
		Turns on auto-enable, causing the system to always try to turn on 
		privileged mode for the devices, whether a password is set for them
		or not.
	[-m]
		Prints the device model and OS information as well as the device name.
	[-D <debug_level>]
		Adds additional debug output.  <debug_level> can consist of or'd 
		together numbers:
			1 - Connection information
			2 - Command sending information
			4 - Timing information (testing for how long it takes to process 
				particular functions)
			8 - SSH connection and Net::Appliance::Session debug information.

The output is presented in the following format:

---- device_1 ----
-- commmand_1 --
Command 1 output

-- command_2 --
Command 2 output

-- perl block 1 --
Output from the first perl block...


Commands and perl are run sequentially - if the script is 
"command_1\n<perl>...</perl>command_2", the output will be in the order 
command_1, then the first perl block, then command_2.


Usage from the workflow
-----------------------------

See README-workflow.txt.


Notes about Perl usage
-----------------------------

The perl that may be executed via the use of a <perl>...</perl> block is fairly 
broad.  It is executed via an eval statement within the code, and as the "use 
strict" and "use warnings" pragmas are pre-declared - write the code 
appropriately.  The code is executed from the perspective of a single device 
within the set of devices being contacted - there is currently no 
straightforward way of getting the output from another device from within a 
different one.  There are a number of sub-functions which may be called:
	send_host($command_block)
		This function runs the given command or commands (separated by 
		newlines, as before) on the device, returning the output in the 
		standard format.  Note that perl blocks may not be used inside this 
		function, and, in fact, doing so will cause substantial errors.
	send_to_flash($file_contents)
		This function stores a file within the flash memory of the device and 
		returns the filename given to it.  As of this point, there is no 
		ability to determine the filename selected - the format used is 
		"config-<year>-<month>-<day>.txt", as in "config-2013-9-12.txt".
	send_to_run($filename, $keep_file)
		To be used after send_to_flash returns a filename.  This command copies
		the existing run configuration to flash:$filename.backup, then copies 
		flash:$filename to run, then (if $keep_file is not true) deletes 
		flash:$filename.  It returns the output of the various command calls 
		used to do this.
	log_error($error)
		Logs an error message related to this host.
	gen_int_ranges(@interfaces)
		Given a list of interfaces, returns a list of interface ranges combined 
		into groups of 5 (which is the maximum that can be configured at once).
		For example, gen_int_ranges('GigabitEthernet1/0/1', 
		'GigabitEthernet1/0/2', 'GigabitEthernet1/0/3', 'GigabitEthernet1/0/5',
		'GigabitEthernet2/0/6') will return 'GigabitEthernet1/0/1 - 3, 
		GigabitEthernet1/0/5, GigabitEthernet2/0/6'.
	normalize_interface($interface)
		Given an interface, returns the interface normalized to long form.  
		"Lo0/1" becomes "Loopback0/1", "Gi0/1/1" becomes 
		"GigabitEthernet0/1/1", and so forth.

Also, there is a pre-defined variable, $hostname, which contains the hostname 
of the device being contacted.

Anything printed to STDOUT will be returned as part of the output of this perl 
block.

Thus, in order to, say, print how long the various systems had been up, a valid
perl block might be:

<perl>
	my $output = send_host("show version");
	$output =~ / uptime is (.*)/;
	print "$hostname has been turned on for:  $1\n";
</perl>


Current bugs and limitations
-----------------------------

- Commands that require some sort of confirmation before returning to the 
prompt (even just hitting return) will not function properly without internal 
modification (due to strangenesses within the Net::Appliance::Session module).  
Functions that require responses that currently work properly: delete, copy, 
save, reload, reset system, 902.11a disable network, ssh -l, software install.
Others must be added individually.

- There is currently a 150 second timeout for commands sent to a device - if 
the command produces no output within that time, it is marked as a failure. 
This number can be modified as desired.


