#!/home/BASE_USER/perl5/perlbrew/perls/perl-5.18.0/bin/perl

package Constants;

use base qw(Exporter);
our @EXPORT = qw(CURRENT_VERSION LOG_ERROR LOG_CONN LOG_SEND LOG_TIMING 
	LOG_CISCO LOG_SSH LOG_ALL SUCCESS FAIL TIME_OUT  
	DEFAULT_MAX_CONNECTIONS TIMEOUT_TIME CONNECTION_TIMEOUT_TIME  
	BASE_U_PATH BASE_PRODUTIL_PATH BASE_CLIENT_PATH  STATUS_FILE 
	ATT_FILE CLOGIN_FILE API_URL IP_USER IP_PW LOCK_USER LOCK_PW 
	PAAS_API_URL PAAS_USER PAAS_PW THREADED DEBUG_THREADING   
	CACHE_TIME CUR_TIMESTAMP PRIORITY_USER_CONNECTOR 
	PRIORITY_USER_CLIENT PRIORITY_IPLOCKSMITH PRIORITY_CLOGIN_HOSTS 
	PRIORITY_CLOGIN_IPMON
	);

use constant CURRENT_VERSION => '<CURRENT_VERSION>';

use constant LOG_ERROR  => 0;  #  Always logged if debug level has any value.
use constant LOG_CONN   => 1;
use constant LOG_SEND   => 2;
use constant LOG_TIMING => 4;
use constant LOG_CISCO  => 8;
use constant LOG_SSH	=> 16;
use constant LOG_ALL => LOG_CONN | LOG_SEND | LOG_TIMING | LOG_CISCO | LOG_SSH;

use constant SUCCESS  => 0;
use constant FAIL     => 1;
use constant TIME_OUT => 2;

use constant DEFAULT_MAX_CONNECTIONS => 50;
use constant TIMEOUT_TIME => 150;
use constant CONNECTION_TIMEOUT_TIME => 150;

use constant BASE_U_PATH => '/home/BASE_USER';
use constant BASE_PRODUTIL_PATH => BASE_U_PATH . '/IPncm_Connector';
use constant BASE_CLIENT_PATH => BASE_U_PATH . '/IPncm_Client';

use constant STATUS_FILE => '/apps/Company/IPmon/var/status.dat';
use constant ATT_FILE => '/apps/Company/IPmon/etc/attributes.cfg';
use constant CLOGIN_FILE => -e '/apps/home/rancid/.cloginrc' ? 
		'/apps/home/rancid/.cloginrc' : '/apps/Company/rancid/.cloginrc';


use constant API_URL => 'https://api-specops.ipcenter.com/IPlocksmith/v1/';
use constant IP_USER => 'a0hMcm5IQmZtM0x2STI5Z20yQnZucT09Cg==';
use constant IP_PW => 'bU5GM0JFaEVtUWM9Cg==';
use constant LOCK_USER => 'ipautospecopsdev';
use constant LOCK_PW => 'p5wELTpk';
use constant PAAS_API_URL => 'https://api-paas.ipcenter.com/IPlocksmith/v1/';
use constant PAAS_USER => 'SUdkaUlHMXZtcT09Cg==';
use constant PAAS_PW => 'V0RGeUlIQnZTdXZBbWlTZQo=';

use constant THREADED => 1;

use constant DEBUG_THREADING => 0;

# number of seconds in 30 days
use constant CACHE_TIME => 60 * 60 * 24 * 30;

use constant CUR_TIMESTAMP => time;

#  Priority order of login file processing (with room for all cloginrc entries)
use constant PRIORITY_USER_CONNECTOR => 10000;
use constant PRIORITY_USER_CLIENT => 8000;
use constant PRIORITY_IPLOCKSMITH => 6000;
use constant PRIORITY_CLOGIN_HOSTS => 4000;
use constant PRIORITY_CLOGIN_IPMON => 2000;


1;
