# Calvin::Parse -- Parses output from Calvin-style chatservers.
#
# Copyright 1996 by Russ Allbery <rra@cs.stanford.edu>
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.
# 
# This module owes its existence to Jon Lennox <jon@cs.columbia.edu>, who
# wrote the Calvin chatserver that this module is designed to connect to,
# wrote the original Perl Calvin bot that this module is based on, and
# provided hints, information, and suggestions throughout its development.
# Thanks, Jon, for making all of Calvin possible in the first place.

package Calvin::Parse;
require 5.002;

use strict;
use vars qw(@ISA $ID $VERSION);

require Exporter;
@ISA = qw(Exporter);

$ID          = '$Id$';
$VERSION     = (split (' ', $ID))[2];


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
