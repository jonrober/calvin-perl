# Calvin::Client -- Perl module interface to Calvin-style chatservers.
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
#
# "The greatest good you can do for another is not just to share your riches
# but to reveal to him his own." -- Benjamin Disraeli


############################################################################
# Modules and declarations
############################################################################

package Calvin::Client;
require 5.002;

use Calvin::Parse;
use IO::Handle;
use Socket qw(inet_aton sockaddr_in PF_INET SOCK_STREAM);
use Fcntl qw(F_SETFL O_NONBLOCK);

use strict;
use vars qw(@ISA $ID $VERSION $BUFFER_SIZE $TIMEOUT);

@ISA = qw(Calvin::Parse);

 $ID          = '$Id$';
($VERSION     = (split (' ', $ID))[2]) =~ s/\.(\d)$/.0$1/;
 $BUFFER_SIZE = 256;
 $TIMEOUT     = 60;		# One minute timeout on read and write.


############################################################################
# Basic methods
############################################################################

# Create a new Calvin interface object.  We won't connect in the constructor
# just in case there's a reason to keep a disconnected Calvin::Client object
# around.
sub new {
    my $class = shift;
    my $self = {buffer => ""};
    bless ($self, $class);
    return $self;
}

# Connect to a Calvin chatserver.  If the fourth argument (the nick
# fallback), is a false but defined value, no fallback is used, and if the
# default nick is taken connection will fail.  If the client has already
# been initialized and we're reconnecting, connect can be called with no
# arguments, or with partial arguments to override the default values.
sub connect {
    my ($self, $host, $port, $nick, $fallback) = @_;

    # Initialize class variables for this connection.  The default fallback
    # function, used if one isn't supplied, just adds "1" to the end of the
    # nick or increments a trailing number if there already is one.
    $self->{host}     = $host if $host;
    $self->{port}     = $port if $port;
    $self->{nick}     = $nick if $nick;
    $self->{fallback} = $self->{fallback} || $fallback;
    unless (defined $self->{fallback}) {
	$self->{fallback} = sub { $_[0] =~ s/(\d*)$/"0$1" + 1/e }
    }

    # Throw an exception of the connection isn't fully defined.
    if (not defined $self->{host}) { die "No host defined" }
    if (not defined $self->{port}) { die "No port defined" }
    if (not defined $self->{nick}) { die "No nick defined" }
    
    # Open connection.
    $self->tcp_connect ($self->{host}, $self->{port}) or return undef;

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
	$self->raw_send ("$self->{nick}\n");

	# We should now see either the "nickname in use" message or the
	# welcoming "you are now known as" message.  If we see "nickname in
	# use", we need to call $fallback to change the nick and try again.
	# Otherwise if we don't have a fallback or if we lost our
	# connection, return undef.
	$buf = $self->read;
	if (!defined $buf) {
	    $self->shutdown;
	    return undef;
	} elsif ($buf != C_S_NICK) {
	    if ($self->{fallback}) {
		&{$self->{fallback}} ($self->{nick});
		redo;
	    } else {
		undef;
	    }
	} else {
	    # Always introduce ourselves to the server.
	    $self->hello;
	}
    }
}

# Shut down the connection and purge any unread data from the buffer.
# Should leave the object in a state where connect can be called again.
sub shutdown {
    my ($self) = @_;

    if ($self->{fh}) {
	close $self->{fh};
	delete $self->{fh};
    }
    $self->{buffer} = "";
}

# Read a line from the chatserver and try to parse it, returning a parsed
# array in the form documented in Calvin::Parse, or in scalar context, just
# return the message type.  The parse method is inherited from
# Calvin::Parse.
sub read {
    my ($self) = @_;

    # Grab a line of output.
    my $line;
    unless ($self->raw_read (\$line)) { return undef }

    # Try to parse it.
    my @result = $self->parse ($line);

    # Return whatever we got.
    return wantarray ? @result : @result[0];
}


############################################################################
# Basic commands
############################################################################

# Join a channel (and then immediately join 16 again, since a client
# shouldn't have a default channel to allow easier parsing of server
# messages).
sub join {
    my ($self, $channel) = @_;
    if ($channel !~ /^(1[0-5]|[0-9])$/) { return undef }
    $self->raw_send ("\@join $channel\n\@join 16\n");
}

# Leave a channel.
sub leave {
    my ($self, $channel) = @_;
    if ($channel !~ /^(1[0-5]|[0-9])$/) { return undef }
    $self->raw_send ("\@leave $channel\n");
}

# Send a @msg.  This is intended mainly for private messages, since the
# public method will check to make sure that the target is a channel.
sub msg {
    my ($self, $nick, $message) = @_;
    unless ($nick) { return undef }
    $self->raw_send ("\@msg $nick - $message\n");
}

# Send a public message to a channel.
sub public {
    my ($self, $channel, $message) = @_;
    if ($channel !~ /^(1[0-5]|[0-9])$/) { return undef }
    $self->raw_send ("\@msg $channel - $message\n");
}

# Send a date command.
sub date {
    my ($self) = @_;
    $self->raw_send ("\@date\n");
}

# Send a message to ourselves, so that we'll register with the server.
sub hello {
    my ($self) = @_;
    $self->msg ($self->{nick}, '');
}

# Send a quit command.  Note that this method doesn't also shut down the
# connection to the server.  This is so that the client can read the results
# of the quit command if it so chooses and because terminating the
# connection can cause the message to be lost.
sub quit {
    my ($self, $message) = @_;
    $self->raw_send ("\@quit $message\n");
}


############################################################################
# State information
############################################################################

# Return the file number of our socket if we're connected to a server, undef
# if not.  This is the access routine commonly used to get the file number
# of a client for use with select() or similar routines.
sub connected {
    my ($self) = @_;
    $self->{fh} ? $self->{fh}->fileno : undef;
}


############################################################################
# Raw I/O
############################################################################

# Read from the file descriptor into the passed buffer until encountering
# the passed delimiter.  If no delimiter is given, assume "\n".  The
# delimiter is NOT included in the returned data.
sub raw_read {
    my ($self, $buf, $delim) = @_;
    my $tmpbuf = '';

    # Check our passed parameters and choose a delimiter to look for.
    unless ($buf) { return undef }
    unless (defined $delim) { $delim = "\n" }

    # Make sure we're connected.
    unless ($self->{fh}) { return undef }

    # This algorithm reads data from the fh and stores any excess seen after
    # the delimiter in the buffer $self->{buffer}.  We therefore read that
    # first, and if we still haven't seen the delimiter, read $BUFFER_SIZE
    # characters from the fh.  Continue, storing information in $buf, until
    # we see the delimiter or we lose the connection.  Because our socket is
    # non-blocking, we need to select on our file number to make sure there
    # is data there waiting for us.
    while (index ($self->{buffer}, $delim) == -1) {
	my $rin = '';
	my $rout;
	vec ($rin, $self->{fh}->fileno, 1) = 1;
	my $nbits = select ($rout = $rin, undef, undef, $TIMEOUT);

	# Close down the socket if there was an error, and return undef in
	# case of either an error or a timeout.
	if ($nbits < 0) { $self->shutdown }
	if ($nbits < 1) { return undef }

	# Actually do the read.  If we don't get any data, we saw an end of
	# file, and we need to close down this connection.
	unless (sysread ($self->{fh}, $tmpbuf, $BUFFER_SIZE)) {
	    $self->shutdown;
	    return undef;
	}
	$self->{buffer} .= $tmpbuf;
    }

    # Split out the data we want to actually return and do so.
    ($tmpbuf, $self->{buffer}) = split ($delim, $self->{buffer}, 2);
    $$buf = $tmpbuf;
    1;
}

# Send raw data to the file descriptor
sub raw_send {
    my ($self, $message) = @_;
    unless ($self->{fh}) { return undef }

    # Handle both literal strings and passed references to strings.
    my $buf = ref $message ? $message : \$message;
    
    # It's possible for write(2) to return a fewer number of written bytes
    # than the size of the buffer being written.  To allow for that, we need
    # to keep writing until either the entire buffer has been written or we
    # get an error of some sort.  Because the socket is non-blocking, we
    # also need to select on it to make sure that it's ready for data.
    my $written;
    my $count = 0;
    do {
	my $win = '';
	my $wout;
	vec ($win, $self->{fh}->fileno, 1) = 1;
	my $nbits = select (undef, $wout = $win, undef, $TIMEOUT);
	if ($nbits < 1) { return undef }

	# Actually write out the data.
	$written = syswrite ($self->{fh}, $$buf, (length $$buf) - $count,
			     $count);
	unless ($written) {
	    $self->shutdown;
	    return undef;
	}
	$count += $written;
    } until ($count == length $$buf);
    1;
}


############################################################################
# Private methods
############################################################################

# Open a TCP connection.  We really should use LWP, but I'd prefer not to
# have these modules dependent on it, and this is easy enough to do
# ourselves.
sub tcp_connect {
    my ($self, $host, $port) = @_;
    unless (defined $host && defined $port) { return undef }

    # If the port isn't numeric, look it up.  If that fails, we fail.
    if ($port =~ /\D/)     { $port = getservbyname ($port, 'tcp') }
    unless (defined $port) { return undef }

    # Look up the IP address of the remote host, create a socket, and try to
    # connect.
    my $iaddr = inet_aton ($host)                  or return undef;
    my $paddr = sockaddr_in ($port, $iaddr);
    my $proto = getprotobyname ('tcp')             or return undef;
    my $socket = new IO::Handle;
    socket ($socket, PF_INET, SOCK_STREAM, $proto) or return undef;
    connect ($socket, $paddr)                      or return undef;

    # Set the socket to nonblocking.
    fcntl ($socket, F_SETFL, O_NONBLOCK)           or return undef;
    
    # Unbuffer the created file handle and save it in the object.
    $socket->autoflush;
    $self->{fh} = $socket;
    1;
}


############################################################################
# Module return value
############################################################################

# Ensure we evaluate to true.
1;
