use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More tests => 19;

require_ok('Calvin::Client');
require_ok('Calvin::Config');
require_ok('Calvin::Manager');
require_ok('Calvin::Parse');

require_ok('Calvin::Bots::Cambot');
require_ok('Calvin::Bots::Characters');
require_ok('Calvin::Bots::Descbot');
require_ok('Calvin::Bots::Fengroll');
require_ok('Calvin::Bots::INroll');
require_ok('Calvin::Bots::Nagbot');
require_ok('Calvin::Bots::Passthrough');
require_ok('Calvin::Bots::Standard');
require_ok('Calvin::Bots::URL_Store');

require_ok('Calvin::Logs');
require_ok('Calvin::Logs::Characters::Tag');
require_ok('Calvin::Logs::Characters');
require_ok('Calvin::Logs::Logread');
require_ok('Calvin::Logs::Misc');
require_ok('Calvin::Logs::Split');
