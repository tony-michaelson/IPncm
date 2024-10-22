Instructions For Using IPncm from the workflow
----------------------------------------------

1.  Before you start, make sure you have:
	a.  The list of devices you want to run the script on.  These must be hostnames, not IP addresses - IPncm looks in the database to determine which IPmon to use to contact the devices, and we save the hostnames in the database, not the IP addresses.
	b.  The script to run.  A script consists of a number of commands separated by newlines, as well as blocks of Perl code surrounded by <perl>...</perl> tags.  For example, a script that printed out the output of a "show ip int bri" command, then printed out "yes" if a further "show version" command returned any data and "no" otherwise, would look like:
show ip int bri
<perl>
	my $output = send_host("show version");
	if ($output)  {
		print "yes\n";
	}  else {
		print "no\n";
	}
</perl>
	c.  The base-64 encoded version of the run script saved to a file.  This should consist of just random uppercase and lowercase letters, numbers, and the + and = signs - no other characters.  Should you have multiple versions of the file, you will need to have base-64 encoded versions of each (for example, for a test version and a full version).  You DO NOT need one version of the file per device you will be running it on - you can contact as many devices as you like with one execution of a single script.  In order to generate a base-64 encoded file:  
		1)  Via a web browser, navigate to http://www.base64encode.org/.
		2)  Paste the script you want to run into the "Type (or paste) here..." box.
		3)  Hit "> ENCODE <".
		4)  Save the output to a different file.
	
2.  Go to IPCenter, to Service Operation => IPcm.

3.  From the "New Request for Change" menu select "<Customer> - IPncm" and push "Create".

4.  Fill in the required fields:
	- MAKE SURE to attach the base-64-encoded version of the script to the RFC, using "Upload new file" - "Choose File".
	- Name of Change, Category, Summary, Reason, and Cisco CR Number can be anything you like, they're mostly used to set things like subject lines and name of the created RFC.
	- Email Address is the address or addresses it sends notification emails to, usually your own.
	- Hosts is the list of devices (_not_ stores, specific devices, and IP addresses will not work) to run the script on.  They can be separated by spaces, commas, or semicolons (or some combination thereof).
	- Save individual files? controls whether the output is a bunch of files (one per host being connected to) or one big output file.  Most people seem to want the former, but just in case, the option is there.
	- Planned Start Date is when you want to run the script.  Planned End Date is completely ignored (in this version), but must be greater than the Planned Start Date - just add a minute.
	
5.  Press "Create", then "Submit for Approval", then "OK", then "Approve", then "OK".

6.  Go to the IPradar ticket created via the link on the page.  It will have a running log of the IPncm automaton execution.

7.  When the execution is complete, reload the page in order to ensure that the attached QA results show up on the page.  They should show up on the righthand side in the "Related IPim Ticket [Last Transaction]" box, under "Attachments", and be called something like "<RFC number>-qa.zip".  Click on it to download it and open it up.  It should contain a directory called "tmp", which contains a directory called "output-<RFC number>", which contains the output files - one file called "output-<long number>-<device name>.txt" for each device, and (possibly) one file called "output-<long number>-errors.txt" if there were execution errors for any of the devices.  (Most kinds of execution errors will also appear in the output files for the particular devices.)  These files will have Unix-type line endings, which Notepad doesn't work properly with - open these files in WordPad instead if you have problems.

