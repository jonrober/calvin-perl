# Calvin::Manager -- Perl module to manage multiple Calvin::Clients.
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

package Calvin::Manager;
require 5.002;

use Calvin::Client;

use lib '.';
use strict;
use vars qw($ID $VERSION $TIMEOUT);

$ID      = '$Id$';
$VERSION = (split (' ', $ID))[2];
$TIMEOUT = 600;				# Ten minute default timeout.


#############################  Basic Methods  ##############################

# Create a new Calvin manager object.  Note that you'll almost certainly
# want to ignore SIGPIPE if you're using this class, but we'll be polite and
# not do that for you.
sub new {
    my $class = shift;
    my $self = {
	client   => 0,		# Initialize fairness pointer.
	timer    => time,	# For periodic maintenance.
	clients  => [],		# Initialize anonymous arrays.
        deadtime => [],
        deadback => []
    };
    bless ($self, $class);
    return $self;
}

# Register a new Calvin::Client with the server.  We maintain an array which
# holds all of the clients we're managing.
sub register {
    my ($self, $client) = @_;

    unless (ref $client) { return undef }

    # Enter the new client into our array.  Note that the client may be dead
    # from the very start, in which case we also want to note its death.
    push (@{$self->{clients}}, $client);
    unless ($client->connected) {
	$self->note_death ($#{$self->{clients}});
    }

    1;
}

# Perform a select on all managed file handles until we get data on one of
# them, and then return the client object for which there is data.  To
# ensure fairness, we keep track of which client we returned last (as an
# index into the clients array) and increment it, and then start our search
# from there next time.  We take an optional timeout and fall back on the
# default if one is not provided.
sub select {
    my ($self, $timeout) = @_;

    # Determine our timeout.
    unless ($timeout) { $timeout = $TIMEOUT }

    # Perform the actual select.
    my $rin = $self->build_vector;
    my $rout;
    my $nbits = select ($rout = $rin, undef, undef, $timeout);

    # Now check the resulting vector.  If we have a hit, figure out which
    # client caused the hit and return it.  The mod arithmetic on number is
    # somewhat ugly.
    my $number = $self->{client};
    my $client;
    if ($nbits > 0) {
	until (vec ($rout, $self->{clients}[$number]->connected, 1)) {
	    $number = ($number + 1) % @{$self->{clients}};
	}
	$client = $self->{clients}[$number];
	$number = ($number + 1) % @{$self->{clients}};
	$self->{client} = $number;
    }

    # Check through our list of dead clients and see if we need to reconnect
    # any of them.
    $self->reconnect;

    # Check to see if we've passed our internal timeout period, and if so
    # perform periodic maintenance.  Note that because of the way timeouts
    # are handled, it's possible to go 2 * $TIMEOUT before running
    # periodic.
    if (time > $self->{timer} + $TIMEOUT) { $self->periodic }

    # Now return the $client we found or undef if we timed out.
    $client;
}


############################  Private Methods  #############################

# Perform any periodic maintenance we need to do on our clients, such as
# reseting nicks or pinging servers.  Currently, all we do is send a date
# command to each live server to ensure that we're still connected.
sub periodic {
    my ($self) = @_;
    my $client;
    for $client (@{$self->{clients}}) {
	$client->date if $client->connected;
    }
    $self->{timer} = time;
}

# Build an input vector for all of the live clients.  Takes an array of
# clients as input.
sub build_vector {
    my ($self, @clients) = @_;
    my $vector = '';
    my ($count, $fileno);
    for $count (0..$#{$self->{clients}}) {
	if ($fileno = $self->{clients}[$count]->connected) {
	    vec ($vector, $fileno, 1) = 1;
	} else {
	    $self->note_death ($count);
	}
    }
    return $vector;
}

# Add a client by number to the list of dead clients and add the associated
# time values.  We store two arrays for the dead clients, one which has the
# time to the next reconnect attempt, and one which stores the exponentially
# increasing backoff delay.
sub note_death {
    my ($self, $number) = @_;
    unless ($self->{deadtime}[$number]) {
	$self->{deadtime}[$number] = time + 1;
	$self->{deadback}[$number] = 1;
    }
}

# Attempt to reconnect each dead client whose reconnect time has passed,
# using exponential backoff to increase the reconnect time each time
# connection fails.
sub reconnect {
    my ($self) = @_;
    my ($count, $deadtime);
    for $count (0..$#{$self->{clients}}) {
	undef $deadtime;
	if ($self->{deadtime}[$count]) {
	    $deadtime = $self->{deadtime}[$count];
	}
	if ($deadtime && $deadtime < time) {
	    if ($self->{clients}[$count]->connect) {
		$self->{deadtime}[$count] = undef;
	    } else {
		my $backoff = ($self->{deadback}[$count] *= 2);
		$self->{deadtime}[$count] = $backoff + time;
	    }
	}
    }
}


##########################  Module Return Value  ###########################

# Ensure we evaluate to true.
1;
