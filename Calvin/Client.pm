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
use vars qw($ID $VERSION $BUFFER_SIZE);

$ID      = '$Id$';
$VERSION = (split (' ', $ID))[2];

$BUFFER_SIZE  = 256;		# Max size of the read buffer.

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
	$self->raw_send ("$nick\n");

	# We should now see either the "nickname in use" message or the
	# welcoming "you are now known as" message.  If we see "nickname in
	# use", we need to call $fallback to change the nick and try again.
	# Otherwise if we don't have a fallback or if we lost our
	# connection, return undef.  Finally, if we've succeeded, return 1.
	unless ($self->raw_read (\$buf)) {
	    $self->shutdown;
	    return undef;
	}
	if ($buf =~ /^\Q*** Nickname \E"$nick"\Q in use./) {
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

# Read from the file descriptor into the passed buffer until encountering
# the passed delimiter.  If no delimiter is given, assume "\n".  The
# delimiter is NOT included in the returned data.
sub raw_read {
    my ($self, $buf, $delim) = @_;
    my ($status);
    my $tmpbuf = '';

    # Make sure our passed parameters are okay, and choose a delimiter to
    # look for.
    unless ($buf)   { return undef  }
    unless ($delim) { $delim = "\n" }
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
