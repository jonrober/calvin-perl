# Calvin::Parse -- Parse output from Calvin-style chatservers.  -*- perl -*-
# $Id$
#
# Copyright 1996, 1997 by Russ Allbery <rra@stanford.edu>
#
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.
#
# This module owes its existence to Jon Lennox <lennox@cs.columbia.edu>, who
# wrote the Calvin chatserver that this module is designed to connect to,
# wrote the original Perl Calvin bot that this module is based on, and
# provided hints, information, and suggestions throughout its development.
# Thanks, Jon, for making all of Calvin possible in the first place.
#
# "There are probably better ways to do that, but it would make the parser
# more complex.  I do, occasionally, struggle feebly against complexity...
# :-)" -- Larry Wall


############################################################################
# Modules and declarations
############################################################################

package Calvin::Parse;
require 5.002;

use strict;
use vars qw(@ISA @EXPORT %EXPORT_TAGS $VERSION);

use Exporter ();
@ISA         = qw(Exporter);
@EXPORT      = ();
%EXPORT_TAGS = (constants => [qw(C_PUBLIC C_POSE C_ROLL
                                 C_YELL C_YELL_POSE C_YELL_ROLL
                                 C_WHIS C_WHIS_POSE C_WHIS_ROLL
                                 C_CONNECT C_SIGNOFF C_JOIN C_LEAVE
                                 C_NICK C_TOPIC
                                 C_S_NICK C_S_TOPIC C_S_TIME
                                 C_S_LIST_HEAD C_S_LA_HEAD C_S_LIST
                                 C_E_NICK_USE C_E_NICK_LONG C_E_NICK_BAD
                                 C_E_USER_BAD
                                 C_UNKNOWN)]);
Exporter::export_ok_tags ('constants');

($VERSION = (split (' ', q$Revision$ ))[1]) =~ s/\.(\d)$/.0$1/;


############################################################################
# Constants
############################################################################

# Public channel messages.
sub C_PUBLIC         {    1 }   # Regular public channel messages.
sub C_POSE           {    2 }   # Public poses.
sub C_ROLL           {    3 }   # Public rolls.
sub C_YELL           {    4 }   # Regular yells.
sub C_YELL_POSE      {    5 }   # Yelled poses.
sub C_YELL_ROLL      {    6 }   # Yelled rolls.

# Private messages.
sub C_WHIS           {  100 }   # Private whispers.
sub C_WHIS_POSE      {  101 }   # Whispered poses.
sub C_WHIS_ROLL      {  102 }   # Whispered rolls.

# Server messages.
sub C_CONNECT        {  200 }   # Connected to the chatserver.
sub C_SIGNOFF        {  201 }   # Left the chatserver.
sub C_JOIN           {  202 }   # Joined channel.
sub C_LEAVE          {  203 }   # Left channel.
sub C_NICK           {  204 }   # Changed nick.
sub C_TOPIC          {  205 }   # Changed a channel topic.

# Error messages.
sub C_E_NICK_LONG    { 1000 }   # Nick too long.
sub C_E_NICK_USE     { 1001 }   # Nick already in use.
sub C_E_NICK_BAD     { 1002 }   # Invalid nick.
sub C_E_USER_BAD     { 1003 }   # Attempted operation on nonexistent user.

# Status messages.
sub C_S_NICK         { 2000 }   # Initial response to nick setting.
sub C_S_TOPIC        { 2001 }   # Current channel topic.
sub C_S_TIME         { 2002 }   # The current time.
sub C_S_LIST_HEAD    { 2003 }   # Header for a channel user list.
sub C_S_LA_HEAD      { 2004 }   # Header for chatserver user list.
sub C_S_LIST         { 2005 }   # Single user in a list.

# Unknown messages.
sub C_UNKNOWN        {    0 }   # Unknown message.


############################################################################
# Parsing
############################################################################

# Read a line from the chatserver and try to parse it, returning one of the
# following forms if successful:
#
#       C_PUBLIC, on_channel, channel, user, message
#       C_POSE, on_channel, channel, message
#       C_ROLL, on_channel, channel, user, roll
#       C_YELL, user, message
#       C_YELL_POSE, message
#       C_YELL_ROLL, user, roll
#
#       C_WHIS, direction, user, message
#       C_WHIS_POSE, 0, message
#       C_WHIS_POSE, 1, user, message
#       C_WHIS_ROLL, direction, user, roll
#
#       C_CONNECT, user, date, host
#       C_SIGNOFF, nick, reason, date
#       C_JOIN, user, channel, topic
#       C_LEAVE, user, channel, topic
#       C_NICK, olduser, newuser
#       C_TOPIC, user, channel, topic
#
#       C_E_NICK_BAD, nick
#       C_E_NICK_LONG, nick
#       C_E_NICK_USE, nick
#       C_E_USER_BAD, user
#
#       C_S_NICK, nick
#       C_S_TOPIC, channel, topic
#       C_S_TIME, time
#       C_S_LIST_HEAD, channel
#       C_S_LA_HEAD
#       C_S_LIST, user, idle, channels, host
#
#       C_UNKNOWN, message
#
sub parse {
    local ($_) = @_;
    my @r;
    sub set {
        @r = map { defined $_ ? $_ : () } ($_[0], $_[1], $1, $2, $3, $4);
    }

    # Strip off trailing line terminators, if any.
    s/[\r\n]+$//;

    # Try to parse it.
    if    (/^<(\d+): (\S+)> (.*)/)                   { set (C_PUBLIC,1)    }
    elsif (/^[(\d+): (\S+)] (.*)/)                   { set (C_PUBLIC,0)    }
    elsif (/^\* (\d+): (.*)/)                        { set (C_POSE,1)      }
    elsif (/^\* [(\d+): (.*)]$/)                     { set (C_POSE,0)      }
    elsif (/^\#\# (\d+): (\S+) \S+ (.*)/)            { set (C_ROLL,1)      }
    elsif (/^\#\# [(\d+): (\S+) \S+ (.*)]/)          { set (C_ROLL,0)      }
    elsif (/^[yell: (\S+)] (.*)/)                    { set (C_YELL)        }
    elsif (/^\* [yell: (.*)]$/)                      { set (C_YELL_POSE)   }
    elsif (/^\#\# [yell: (\S+) \S+ (.*)]/)           { set (C_YELL_ROLL)   }
    elsif (/^\*([^* ]|\S{2,})\* (.*)/)               { set (C_WHIS,0)      }
    elsif (/^-> \*(\S+)\* (.*)/)                     { set (C_WHIS,1)      }
    elsif (/^\*> (.*)/)                              { set (C_WHIS_POSE,0) }
    elsif (/^\* -> (\S+): (.*)/)                     { set (C_WHIS_POSE,1) }
    elsif (/^\#\#> (\S+) \S+ (.*)/)                  { set (C_WHIS_ROLL,0) }
    elsif (/^\#\# -> (\S+): \S+ \S+ (.*)/)           { set (C_WHIS_ROLL,1) }
    elsif (/^\*{3} Invalid nickname \"(.*)\".$/)     { set (C_E_NICK_BAD)  }
    elsif (/^\*{3} Nickname \"(\S+)\" too long/)     { set (C_E_NICK_LONG) }
    elsif (/^\*{3} Nickname \"(\S+)\" in use/)       { set (C_E_NICK_USE)  }
    elsif (/^\*{3} Unknown user (\S+)\./)            { set (C_E_USER_BAD)  }
    elsif (/^\*{3} You are now known as (\S+)\./)    { set (C_S_NICK)      }
    elsif (/^\*{3} Topic for channel (\d+): (.*)/)   { set (C_S_TOPIC)     }
    elsif (/^\*{3} It is currently (\S+)\./)         { set (C_S_TIME)      }
    elsif (/^\*{3} \S+ users on \S+ (\d) \[(.*)\]:/) { set (C_S_LIST_HEAD) }
    elsif (/^\*{3} \S+ users on the chatserver:/)    { set (C_S_LA_HEAD)   }
    elsif (/^\*{3} (\S+) connected at (.*) from (\S+)\./) { set(C_CONNECT) }
    elsif (/^\*{3} Signoff: (\S+) \((.*)\) at (.*)\./)    { set(C_SIGNOFF) }
    elsif (/^\*{3} (\S+) has joined \S+ (\d+) \[(.*)\]\./){ set(C_JOIN)    }
    elsif (/^\*{3} (\S+) has left \S+ (\d+) \[(.*)\]\./)  { set(C_LEAVE)   }
    elsif (/^\*{3} (\S+) is now known as (\S+)\./)        { set(C_NICK)    }
    elsif (/^\*{3} (\S+) .+? topic on \S+ (\d+) to (.*)/) { set(C_TOPIC)   }
    elsif (/^\*{3} (\S+)\s+\[idle\s+(\S+)\] <ch. ((?:\d+ ?)+)> (\S+)/)
                                                     { set (C_S_LIST)      }
    else                                             { set (C_UNKNOWN, $_) }

    # Return the status code in a scalar context, everything in an array
    # context.
    wantarray ? @r : $r[0];
}


############################################################################
# Module return value
############################################################################

# Ensure we evaluate to true.
1;
