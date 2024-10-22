GETTING IPNCM TO WORK IN A NEW ENVIRONMENT
------------------------------------------

IPncm is a network configuration system, allowing many devices to be audited /
configured efficiently.  It has two main components:
		IPncm_Connector - contacts the various ipmons, located on produtil
		IPncm_Client - contacts the client devices, located on various ipmons


Requirements for setting up IPncm:
  - One central device that can access all the ipmons that will be contacted.
    We've been using produtil thus far, but as long as it is a device that 
	can reach all the ipmons (and that can be reached by an automation), it
	doesn't matter very much which one it is.  I will be referring to this 
	device as "produtil" for convenience.  An additional backup produtil device
	is also useful, though not required.
  - One or more ipmons that can access all the endpoint devices.  These ipmons
    do not have to be all ipmons for a customer, as long as all customer devices
	can be reached via those ipmons.  (For example, in one environment, 
	there are 50+ ipmons, but they are split up into two major groups and all
	devices within one group can be accessed from two monitoring ipmons within
	the group.  We use those two ipmons rather than all of them.)
  - A set of 10 devices for the customer to be used for testing.  The commands 
    being run for this form of testing are “show version” commands and the like
	– nothing invasive, so it should be safe.
  - Ideally, one test device to use for invasive testing – adding a blank line 
    to the configuration and that sort of thing.  Again, the tests shouldn’t be 
	destructive, but better safe than sorry.  If no devices are available for 
	invasive testing, this can be skipped.
  - Either of:
    a) The current IPncm version - this is available on 
	sshproxy01.ny1.Company.com in /home/akramer/IPncm_Connector-64.tar.gz .  This
	is the preferred mechanism.
    b) If you need to or would rather build the IPncm installation yourself, 
	access to the config_pusher git repository within redmine on 10.161.20.100.



BUILDING IPNCM
--------------

If you don't have access to the IPncm_Connector-64.tar.gz file, you'll need to
build the installation yourself.  First, to retrieve the code, from the 
git-enabled device, run the command:

git clone git@10.161.20.100:config_pusher IPncm

This will retrieve the repository locally in the current directory.  Once you
have done this, you'll need to ensure your local Perl version has the 
File::Copy::Recursive module installed.  If it does, run these commands:

cd IPncm
perl installation_builder.pl

installation_builder.pl should run for a while (1-5 minutes).  Once it 
completes, you should have in the IPncm/bin folder the IPncm_Connector-64.tar.gz
(as well as an IPncm_Connector-32.tar.gz file in case the produtil is 32-bit).


INSTALLING IPNCM
----------------

Installing IPncm is fairly straightforward:

  1) Copy IPncm-Connector-64.tar.gz onto the produtil device.
  2) On the produtil device, run "tar -xzf IPncm-Connector-64.tar.gz".
  2) cd IPncm_Connector
  4) ./bin/configure
  5) cd IPncm_Connector/conf
  6) cp Sample.conf <customerID>.conf   (Use whatever ID makes sense for your 
     customer.  No spaces in the ID.)
  7) Edit the newly created <customerID>.conf file.  Inside that file is all
     the information you will need on how to edit it - this is where you will
	 enter the information about the IPmons and test devices you gathered 
	 earlier.  Note that the information you edit requires tabs at the beginning
	 of the line, spaces are not legal characters.
  8) cd ..
  9) ./InstallToIpmons.pl -cc <customerID> 

At this point, the installer should run, printing out occasional updates on the 
process.  Most of it you can ignore.  The exceptions are any errors that occur
in the "running client device tests" section - these are warnings about the 
state of important files on the various IPmons that you may need to modify in
order for IPncm to work properly.

  8) Once it completes, run a final test:
     ./IPncm_Connector -cc <customerID> -h <host device> -s "show clock"
	 If it successfully prints the clock time for the given device, you're done!
	 
	 

