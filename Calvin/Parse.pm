# Calvin::Parse -- Parses output from Calvin-style chatservers.
#
# Copyright 1996 by Russ Allbery <rra@cs.stanford.edu>
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.
#
# This module owes its existence to Jon Lennox <lennox@cs.columbia.edu>, who
# wrote the Calvin chatserver that this module is designed to connect to,
# wrote the original Perl Calvin bot that this module is based on, and
# provided hints, information, and suggestions throughout its development.
# Thanks, Jon, for making all of Calvin possible in the first place.

package Calvin::Parse;
require 5.002;

use strict;
use vars qw(@ISA @EXPORT $ID $VERSION);

require Exporter;
@ISA = qw(Exporter);

$ID          = '$Id$';
$VERSION     = (split (' ', $ID))[2];

@EXPORT = qw(C_PUBLIC C_POSE C_ROLL C_YELL C_YELL_POSE C_YELL_ROLL
             C_WHIS C_WHIS_POSE C_WHIS_ROLL
             C_CONNECT C_JOIN C_LEAVE C_NICKCHANGE C_SIGNOFF
             C_E_NICK_USE C_E_NICK_LONG C_E_NICK_INVALID
             C_S_NICK
             C_UNKNOWN);


###############################  Constants  ################################

# Public channel messages.
sub C_PUBLIC         { 1 }	# Regular public channel messages.
sub C_POSE           { 2 }	# Public poses.
sub C_ROLL           { 3 }	# Public rolls.
sub C_YELL           { 4 }	# Regular yells.
sub C_YELL_POSE      { 5 }	# Yelled poses.
sub C_YELL_ROLL      { 6 }	# Yelled rolls.

# Private messages.
sub C_WHIS           { 100 }	# Private whispers.
sub C_WHIS_POSE      { 101 }	# Whispered poses.
sub C_WHIS_ROLL      { 102 }	# Whispered rolls.

# Server messages.
sub C_CONNECT        { 200 }	# Connected to the chatserver.
sub C_JOIN           { 201 }	# Joined channel.
sub C_LEAVE          { 202 }	# Left channel.
sub C_NICKCHANGE     { 203 }	# Changed nick.
sub C_SIGNOFF        { 204 }	# Left the chatserver.

# Error messages.
sub C_E_NICK_LONG    { 1000 }	# Nick too long.
sub C_E_NICK_USE     { 1001 }	# Nick already in use.
sub C_E_NICK_INVALID { 1002 }	# Invalid nick.

# Status messages.
sub C_S_NICK         { 2000 }	# Initial response to nick setting.

# Unknown messages.
sub C_UNKNOWN        { 0000 }	# Unknown message.


##############################  Main Routine  ##############################

# Read a line from the chatserver and try to parse it, returning one of the
# following forms if successful:
#
#	C_PUBLIC, channel, user, message, on_channel
#	C_POSE, channel, message, on_channel
#	C_ROLL, channel, user, roll, on_channel
#	C_YELL, user, message
#	C_YELL_POSE, message
#	C_YELL_ROLL, user, roll
#
#	C_WHIS, user, message
#	C_WHIS_POSE, message
#	C_WHIS_ROLL, user, roll
#
#	C_CONNECT, user, date, host
#	C_JOIN, user, channel, topic
#	C_LEAVE, user, channel, topic
#	C_NICKCHANGE, olduser, newuser
#	C_SIGNOFF, nick, reason, date
#
#       C_E_NICK_INVALID
#	C_E_NICK_LONG
#	C_E_NICK_USE
#
#       C_S_NICK
#
#	C_UNKNOWN, message
#
sub parse {
    my $self = shift;
    local ($_) = @_;
    my (@r);

    # Try to parse it.
    if    (/^<(\d+): (\S+)> (.*)/)          { @r = (C_PUBLIC, $1, $2, $3, 1) }
    elsif (/^[(\d+): (\S+)] (.*)/)          { @r = (C_PUBLIC, $1, $2, $3, 0) }
    elsif (/^\* (\d+): (.*)/)               { @r = (C_POSE, $1, $2, 1)       }
    elsif (/^\* [(\d+): (.*)]$/)            { @r = (C_POSE, $1, $2, 0)       }
    elsif (/^\#\# (\d+): (\S+) \S+ (.*)/)   { @r = (C_ROLL, $1, $2, $3, 1)   }
    elsif (/^\#\# [(\d+): (\S+) \S+ (.*)]/) { @r = (C_ROLL, $1, $2, $3, 0)   }
    elsif (/^[yell: (\S+)] (.*)/)           { @r = (C_YELL, $1, $2)          }
    elsif (/^\* [yell: (.*)]$/)             { @r = (C_YELL_POSE, $1)         }
    elsif (/^\#\# [yell: (\S+) \S+ (.*)]/)  { @r = (C_YELL_ROLL, $1, $2)     }
    elsif (/^\*([^* ]|\S{2,})\* (.*)/)      { @r = (C_WHIS, $1, $2)          }
    elsif (/^\*> (.*)/)                     { @r = (C_WHIS_POSE, $1)         }
    elsif (/^\#\#> (\S+) \S+ (.*)/)         { @r = (C_WHIS_ROLL, $1, $2)     }
    elsif (/^\*{3} Invalid nickname /)      { @r = (C_E_NICK_INVALID)        }
    elsif (/^\*{3} Nickname \S+ too long/)  { @r = (C_E_NICK_LONG)           }
    elsif (/^\*{3} Nickname \S+ in use/)    { @r = (C_E_NICK_USE)            }
    elsif (/^\*{3} You are now known as /)  { @r = (C_S_NICK)                }
    elsif (/^\*{3} (\S+) connected at (.*) from (\S+)\./)
                                            { @r = (C_CONNECT, $1, $2, $3)   }
    elsif (/^\*{3} (\S+) has joined channel (\d+) [(.*)]\./)
                                            { @r = (C_JOIN, $1, $2, $3)      }
    elsif (/^\*{3} (\S+) has left channel (\d+) [(.*)]\./)
                                            { @r = (C_LEAVE, $1, $2, $3)     }
    elsif (/^\*{3} (\S+) is now known as (\S+)\./)
                                            { @r = (C_NICKCHANGE, $1, $2)    }
    elsif (/^\*{3} Signoff: (\S+) \((.*)\) at (.*)\./)
                                            { @r = (C_SIGNOFF, $1, $2, $3)   }
    else                                    { @r = (C_UNKNOWN, $_)           }

    # Return whatever we got.
    return @r;
}
