# Calvin.pm -- Perl module interface to Calvin-style chatservers.
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

package Calvin;
require 5.002;

use FileHandle;
use Socket;

use strict;
use vars qw(@ISA @EXPORT $ID $VERSION $BUFFER_SIZE);

require Exporter;
@ISA = qw(Exporter);

$ID          = '$Id$';
$VERSION     = (split (' ', $ID))[2];
$BUFFER_SIZE = 256;

@EXPORT = qw(C_PUBLIC C_POSE C_ROLL C_YELL C_YELL_POSE C_YELL_ROLL
             C_WHIS C_WHIS_POSE C_WHIS_ROLL
             C_CONNECT C_JOIN C_LEAVE C_NICKCHANGE C_SIGNOFF
             C_E_NICK_USE C_E_NICK_LONG
             C_UNKNOWN);


#------------------------------  Constants  -------------------------------#

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
sub C_UNKNOWN        { 0 }	# Unknown message.


#----------------------------  Public Methods  ----------------------------#

# Create a new Calvin interface object.  In preparation of future revisions
# of this module which will allow for multiple connections to be handled by
# one object, we won't connect in the constructor.
sub new {
    my $class = shift;
    my $self = {};
    bless ($self, $class);
    $self->{'buffer'} = "";	# Kill warning messages.
    return $self;
}

# Connect to a Calvin chatserver.
sub connect {
    my ($self, $host, $port, $nick, $fallback) = @_;

    unless ($host && $port && $nick) { return undef }
    
    # Initialize class variables for this connection.
    $self->{'host'}     = $host;
    $self->{'port'}     = $port;
    $self->{'nick'}     = $nick;
    $self->{'fallback'} = $fallback if $fallback;
    
    # Open connection.
    unless ($self->tcp_connect ($host, $port)) { return undef }

    {
	# Now, we need to handle initial sign-on and setting the nick.  This
	# is the part of parsing that's rather ugly since the server doesn't
	# end the nick request line in a newline but uses a telnet code
	# instead.  We're looking for \xff\xf9.
	my $buf = "";
	unless ($self->raw_read (\$buf, "\xff\xf9")) {
	    $self->shutdown;
	    return undef;
	}

	# We now have a nick prompt.  Send the nick.
	$self->raw_send ("$self->{'nick'}\n");

	# We should now see either the "nickname in use" message or the
	# welcoming "you are now known as" message.  If we see "nickname in
	# use", we need to call $fallback to change the nick and try again.
	# Otherwise if we don't have a fallback or if we lost our
	# connection, return undef.  Finally, if we've succeeded, return 1.
	$buf = $self->read;
	if (!defined $buf) {
	    $self->shutdown;
	    return undef;
	} elsif ($buf != C_S_NICK) {
	    if ($self->{'fallback'}) {
		$self->{'nick'} = &{$self->{'fallback'}} ($self->{'nick'});
		redo;
	    } else {
		undef;
	    }
	} else {
	    1;
	}
    }
}

# Shut down the connection and purge any unread data from the buffer.
# Should leave the object in a state where connect can be called again.
sub shutdown {
    my ($self) = @_;

    if ($self->{'fh'}) {
	close $self->{'fh'};
	delete $self->{'fh'};
    }
    $self->{'buffer'} = "";
}

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
# That is in an array context.  In a scalar context, just returns the
# message type.
sub read {
    my ($self) = @_;
    my (@r);
    local ($_);

    # Grab a line of output.
    unless ($self->raw_read (\$_)) { return undef }

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
    return wantarray ? @r : @r[0];
}
    
# Read from the file descriptor into the passed buffer until encountering
# the passed delimiter.  If no delimiter is given, assume "\n".  The
# delimiter is NOT included in the returned data.
sub raw_read {
    my ($self, $buf, $delim) = @_;
    my ($status);
    my $tmpbuf = '';

    # Make sure our passed parameters are okay, and choose a delimiter to
    # look for.
    unless ($buf) { return undef  }
    unless (defined $delim) { $delim = "\n" }
    $delim = quotemeta $delim;

    # Make sure we're connected.
    unless ($self->{'fh'}) { return undef }

    # This algorithm reads data from the fh and stores any excess seen after
    # the delimiter in the buffer $self->{buffer}.  We therefore read that
    # first, and if we still haven't seen the delimiter, read $BUFFER_SIZE
    # characters from the fh.  Continue, storing information in $buf, until
    # we see the delimiter or we lose the connection.
    while ($self->{'buffer'} !~ /$delim/) {
	$status = sysread ($self->{'fh'}, $tmpbuf, $BUFFER_SIZE);
	unless (defined $status) {
	    $self->shutdown;
	    return undef;
	}
	$self->{'buffer'} .= $tmpbuf;
    }
    ($tmpbuf, $self->{'buffer'}) = split (/$delim/, $self->{'buffer'}, 2);
    $$buf = $tmpbuf;
    1;
}

# Send raw data to the file descriptor
sub raw_send {
    my ($self, $message) = @_;
    unless ($self->{'fh'}) { return undef }

    # Handle both literal strings and passed references to strings.
    my $buf = ref $message ? $message : \$message;
    
    # It's possible for write(2) to return a fewer number of written bytes
    # than the size of the buffer being written.  To allow for that, we need
    # to keep writing until either the entire buffer has been written or we
    # get an error of some sort.
    my $written;
    my $count = 0;
    do {
	$written = syswrite ($self->{'fh'}, $$buf, length ($$buf) - $count,
			     $count);
	unless (defined $written) {
	    $self->shutdown;
	    return undef;
	}
	$count += $written;
    } until ($count == length $$buf);
    1;
}


#---------------------------  Private Methods  ----------------------------#

# Open a TCP connection.
sub tcp_connect {
    my ($self, $host, $port) = @_;
    my ($iaddr, $paddr, $proto, $socket);
    unless ($host && $port) { return undef }

    # If the port isn't numeric, look it up.  If that fails, we fail.
    if ($port =~ /\D/) { $port = getservbyname ($port, 'tcp') }
    unless ($port)     { return undef }

    # Look up the IP address of the remote host, create a socket, and try to
    # connect.
    $iaddr = inet_aton ($host)                     or return undef;
    $paddr = sockaddr_in ($port, $iaddr);
    $proto = getprotobyname ('tcp');
    $socket = new FileHandle;
    socket ($socket, PF_INET, SOCK_STREAM, $proto) or return undef;
    connect ($socket, $paddr)                      or return undef;

    # Unbuffer the created file handle and save it in the object.
    $socket->autoflush;
    $self->{'fh'} = $socket;
    1;
}
