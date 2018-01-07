# Calvin::Parse -- Parse output from Calvin-style chatservers.  -*- perl -*-
# $Id$
#
# Copyright 1996, 1997 by Russ Allbery <rra@cpan.org>
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
%EXPORT_TAGS = (constants => [qw(C_PUBLIC C_POSE C_PPOSE C_ROLL C_NARRATE
                                 C_ALIAS C_ALIAS_POSE C_ALIAS_PPOSE
                                 C_YELL C_YELL_POSE C_YELL_PPOSE C_YELL_ROLL
                                 C_YELL_NARR
                                 C_WHIS C_WHIS_POSE C_WHIS_PPOSE C_WHIS_ROLL
                                 C_WHIS_NARR
                                 C_CONNECT C_SIGNOFF C_JOIN C_LEAVE
                                 C_NICK_CHANGE C_TOPIC_CHANGE
                                 C_S_NICK C_S_TOPIC C_S_TIME C_S_USERS
                                 C_S_LIST_HEAD C_S_LA_HEAD C_S_LIST
                                 C_E_NICK_USE C_E_NICK_LONG C_E_NICK_BAD
                                 C_E_USER_BAD
                                 C_UNKNOWN)]);
Exporter::export_ok_tags ('constants');

($VERSION = (split (' ', q$Revision: 0.4 $ ))[1]) =~ s/\.(\d)$/.0$1/;


############################################################################
# Constants
############################################################################

# Public channel messages.
sub C_PUBLIC         { 1021 }   # Regular public channel messages.
sub C_POSE           { 1022 }   # Public poses.
sub C_PPOSE          { 1023 }   # Public pposes.
sub C_ROLL           { 1024 }   # Public rolls.
sub C_NARRATE        { 1025 }   # Public narrate.
sub C_ALIAS          { 1026 }   # Public alias.
sub C_ALIAS_POSE     { 1027 }   # Public posed alias.
sub C_ALIAS_PPOSE    { 1028 }   # Public pposed alias.
sub C_YELL           { 1201 }   # Regular yells.
sub C_YELL_POSE      { 1202 }   # Yelled poses.
sub C_YELL_PPOSE     { 1203 }   # Yelled pposes.
sub C_YELL_ROLL      { 1204 }   # Yelled rolls.
sub C_YELL_NARR      { 1205 }   # Yelled narration.

# Private messages.
sub C_WHIS           { 1101 }   # Private whispers.
sub C_WHIS_POSE      { 1102 }   # Whispered poses.
sub C_WHIS_PPOSE     { 1103 }   # Whispered poses.
sub C_WHIS_ROLL      { 1104 }   # Whispered rolls.
sub C_WHIS_NARR      { 1105 }   # Whispered narration.

# Server messages.
sub C_CONNECT        { 2001 }   # Connected to the chatserver.
sub C_SIGNOFF        { 2002 }   # Left the chatserver.
sub C_LEAVE          { 2003 }   # Left channel.
sub C_JOIN           { 2004 }   # Joined channel.
sub C_TOPIC_CHANGE   { 2102 }   # Changed a channel topic.
sub C_NICK_CHANGE    { 3204 }   # Changed nick.

# Error messages.
sub C_E_USER_BAD     { 9101 }   # Attempted operation on nonexistent user.
sub C_E_NICK_USE     { 9306 }   # Nick already in use.
sub C_E_NICK_LONG    { 9307 }   # Nick too long.
sub C_E_NICK_BAD     { 9308 }   # Invalid nick.

# Status messages.
sub C_S_TOPIC        { 2101 }   # Current channel topic.
sub C_S_NICK         { 3203 }   # Initial response to nick setting.
sub C_S_LIST_HEAD    { 4101 }   # Header for a channel user list.
sub C_S_LA_HEAD      { 4102 }   # Header for chatserver user list.
sub C_S_LIST         { 4103 }   # Single user in a list.
sub C_S_USERS        { 4201 }   # @u listing.
sub C_S_TIME         { 4401 }   # The current time.

# Unknown messages.
sub C_UNKNOWN        {    0 }   # Unknown message.


############################################################################
# Parsing
############################################################################

# Read a line from the chatserver and try to parse it, returning one of the
# following forms if successful:
#
#       C_PUBLIC, on_channel, channel, user, message
#       C_POSE, on_channel, channel, user, message
#       C_PPOSE, on_channel, channel, user, message
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
#       C_NICK_CHANGE, olduser, newuser
#       C_TOPIC_CHANGE, user, channel, topic
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

sub set {
    my ($line, $code, $find, $on_channel) = @_;
    my (%fields);

    $fields{'code'} = $code;
    if (defined $on_channel) { $fields{'on_channel'} = $on_channel }

    if (defined $find) {
        if ($find =~ /c/) {
            $line =~ s/\|c(\d+)\|E/$1/;
            $fields{'channel'} = $1;
        }
        if ($find =~ /C/) {
            $line =~ s/\|C(.*?)\|E/$1/;
            $fields{'chans_on'} = $1;
        }
        if ($find =~ /n/) {
            $line =~ s/\|n(.*?)\|E/$1/;
            $fields{'name'} = $1;
        }
        if ($find =~ /d/) {
            $line =~ s/\|d(.*?)\|E/$1/;
            $fields{'date'} = $1;
        }
        if ($find =~ /t/) {
            $line =~ s/\|t(.*?)\|E/$1/;
            $fields{'topic'} = $1;
        }
        if ($find =~ /A/) {
            $line =~ s/\|A(\S+?)\|E/$1/;
            $fields{'address'} = $1;
        }
        if ($find =~ /i/) {
            $line =~ s/\|i(.*?)\|E/$1/;
            $fields{'idle'} = $1;
        }
        if ($find =~ /I/) {
            $line =~ s/\|I(.*?)\|E/$1/;
            $fields{'idle_chan'} = $1;
        }
        if ($find =~ /1/) {
            $line =~ s/\|1(.*?)\|E/$1/;
            $fields{'s1'} = $1;
        }
        if ($find =~ /2/) {
            $line =~ s/\|2(.*?)\|E/$1/;
            $fields{'s2'} = $1;
        }
    }
    $fields{'line'} = $line;

    foreach (keys %fields) {
        if (defined $fields{$_}) {
            $fields{$_} =~ s#\\1#\\#g;
            $fields{$_} =~ s#\\2#|#g;
        }
    }

    return (%fields);
}

sub parse {
    local ($_) = @_;

    # Strip off trailing line terminators, if any.
    s/[\r\n]+$//;

    my (%fields);

    # Try to parse it.
    if    (s/^1021 //) { %fields = &set ($_, C_PUBLIC,      'cn1', 1) }
    elsif (s/^1031 //) { %fields = &set ($_, C_PUBLIC,      'cn1', 0) }
    elsif (s/^1024 //) { %fields = &set ($_, C_ROLL,        'cn1', 1) }
    elsif (s/^1034 //) { %fields = &set ($_, C_ROLL,        'cn1', 0) }
    elsif (s/^1022 //) { %fields = &set ($_, C_POSE,        'cn1', 1) }
    elsif (s/^1032 //) { %fields = &set ($_, C_POSE,        'cn1', 0) }
    elsif (s/^1023 //) { %fields = &set ($_, C_PPOSE,       'cn1', 1) }
    elsif (s/^1033 //) { %fields = &set ($_, C_PPOSE,       'cn1', 0) }
    elsif (s/^1025 //) { %fields = &set ($_, C_NARRATE,     'cn1', 1) }
    elsif (s/^1035 //) { %fields = &set ($_, C_NARRATE,     'cn1', 0) }
    elsif (s/^1026 //) { %fields = &set ($_, C_ALIAS,       'cn12')   }
    elsif (s/^1027 //) { %fields = &set ($_, C_ALIAS_POSE,  'cn12')   }
    elsif (s/^1028 //) { %fields = &set ($_, C_ALIAS_PPOSE, 'cn12')   }
    elsif (s/^1201 //) { %fields = &set ($_, C_YELL,        'n1')     }
    elsif (s/^1202 //) { %fields = &set ($_, C_YELL_POSE,   'n1')     }
    elsif (s/^1203 //) { %fields = &set ($_, C_YELL_PPOSE,  'n1')     }
    elsif (s/^1204 //) { %fields = &set ($_, C_YELL_ROLL,   'n1')     }
    elsif (s/^1205 //) { %fields = &set ($_, C_YELL_NARR,   'n1')     }
    elsif (s/^1101 //) { %fields = &set ($_, C_WHIS,        'n1',  1) }
    elsif (s/^1111 //) { %fields = &set ($_, C_WHIS,        'n1',  0) }
    elsif (s/^1102 //) { %fields = &set ($_, C_WHIS_POSE,   'n12', 1) }
    elsif (s/^1112 //) { %fields = &set ($_, C_WHIS_POSE,   'n1',  0) }
    elsif (s/^1103 //) { %fields = &set ($_, C_WHIS_PPOSE,  'n12', 1) }
    elsif (s/^1113 //) { %fields = &set ($_, C_WHIS_PPOSE,  'n1',  0) }
    elsif (s/^1104 //) { %fields = &set ($_, C_WHIS_ROLL,   'n12', 1) }
    elsif (s/^1114 //) { %fields = &set ($_, C_WHIS_ROLL,   'n1',  0) }
    elsif (s/^1105 //) { %fields = &set ($_, C_WHIS_NARR,   'n12', 1) }
    elsif (s/^1115 //) { %fields = &set ($_, C_WHIS_NARR,   'n1',  0) }
    elsif (s/^2001 //) { %fields = &set ($_, C_CONNECT,     'ndA')    }
    elsif (s/^2002 //) { %fields = &set ($_, C_SIGNOFF,     'nd1')    }
    elsif (s/^2003 //) { %fields = &set ($_, C_LEAVE,       'nct')    }
    elsif (s/^2004 //) { %fields = &set ($_, C_JOIN,        'nct')    }
    elsif (s/^2101 //) { %fields = &set ($_, C_S_TOPIC,     'ct')     }
    elsif (s/^2102 //) { %fields = &set ($_, C_TOPIC_CHANGE,'nct')    }
    elsif (s/^3203 //) { %fields = &set ($_, C_S_NICK,      'n')      }
    elsif (s/^3204 //) { %fields = &set ($_, C_NICK_CHANGE, 'n1')     }
    elsif (s/^4101 //) { %fields = &set ($_, C_S_LIST_HEAD, 'ct')     }
    elsif (s/^4102 //) { %fields = &set ($_, C_S_LA_HEAD,   '')       }
    elsif (s/^4103 //) { %fields = &set ($_, C_S_LIST,      'niCA')   }
    elsif (s/^4201 //) { %fields = &set ($_, C_S_USERS,     'cI1')    }
    elsif (s/^4401 //) { %fields = &set ($_, C_S_TIME,      'd')      }
    elsif (s/^9101 //) { %fields = &set ($_, C_E_USER_BAD,  '1')      }
    elsif (s/^9306 //) { %fields = &set ($_, C_E_NICK_USE,  '1')      }
    elsif (s/^9307 //) { %fields = &set ($_, C_E_NICK_LONG, '1')      }
    elsif (s/^9308 //) { %fields = &set ($_, C_E_NICK_BAD,  '1')      }
    else               { %fields = &set ($_, C_UNKNOWN,     '')       }

    return (%fields);
}


############################################################################
# Module return value
############################################################################

# Ensure we evaluate to true.
1;
