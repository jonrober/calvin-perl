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
#
# "Passions, once in motion, move themselves." -- Unknown


############################################################################
# Modules and declarations
############################################################################

package Calvin::Manager;
require 5.002;

use Calvin::Client;

use strict;
use vars qw($ID $VERSION $ping_after);

$ID      = '$Id$';
$VERSION = (split (' ', $ID))[2];

# We ping all servers after this much time (in seconds) has passed.  Change
# it from your program if you wish.  Setting it to 0 would be bad.
$ping_after = 10;


############################################################################
# Basic methods
############################################################################

# Create a new Calvin manager object.  Note that you'll almost certainly
# want to ignore SIGPIPE if you're using this class, but we'll be polite and
# not do that for you.
sub new {
    my $class = shift;
    my $self = {
	client  => 0,		# Initialize fairness pointer.
	clients => [],		# Array of managed clients.
	dead    => [],		# Which clients are currently dead.
	queue   => []		# Queue of events.
    };
    bless ($self, $class);
    $self->enqueue (time + $ping_after, sub { $self->periodic });
    $self;
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
}

# Perform a select on all managed file handles until we get data on one of
# them, and then return the client object for which there is data.  To
# ensure fairness, we keep track of which client we returned last (as an
# index into the clients array) and increment it, and then start our search
# from there next time.  We take an optional timeout; if one isn't
# specified, we wait until we have a hit (potentially forever).  Note that
# we timeout our own select() at the time when the next event queue event is
# scheduled to run, and just stay in a loop until our timeout has expired.
sub select {
    my ($self, $delay) = @_;

    # Determine when we should time out and return to the caller.
    my $return = defined $delay ? time + $delay : undef;

    # Determine when the next event in the event queue is scheduled to run
    # (and run the queue while we're at it.
    my $next = $self->run_queue;

    # Our select timeout is determined by the smaller of our calling timeout
    # (determined above) and the time for the next queue event run.
    # Continue doing selects and timing out to do queue runs until our
    # calling timeout expires or we have a hit from select, but do the
    # select at least once no matter what happens.
    do {
	my $stop = (!defined $return) ? $next   :
	           (!defined $next)   ? $return :
		   ($next < $return)  ? $next   : $return;
	my $timeout = (defined $stop) ? $stop - time : undef;
	$timeout = 0 if (defined $timeout && $timeout < 0);

	# Perform the actual select.
	my $rin = $self->build_vector;
	my $rout;
	my $nbits = select ($rout = $rin, undef, undef, $timeout);

	# Now check the resulting vector.  If we have a hit, figure out
	# which client caused the hit and return it.  The mod arithmetic on
	# number is somewhat ugly.
	my $client;
	if ($nbits > 0) {
	    my $number = $self->{client};
	    until (vec ($rout, $self->{clients}[$number]->connected, 1)) {
		$number = ($number + 1) % @{$self->{clients}};
	    }
	    $client = $self->{clients}[$number];
	    $number = ($number + 1) % @{$self->{clients}};
	    $self->{client} = $number;
	}

	# Run the queue again, getting the time for the new next scheduled
	# event.
	$next = $self->run_queue;

	# New return the $client if we had a hit.
	return $client if defined $client;
    } until (defined $return && time >= $return);

    # We timed out without getting a hit from any client, so return undef.
    undef;
}


############################################################################
# Event queue methods
############################################################################

# Add an event to our event queue.  Each event is in the form of a timestamp
# (when it should happen) and a closure (what should happen).  We maintain
# the queue in sorted order by timestamp.  We just tack the new event on to
# the end and sort rather than messing with a binary insertion, since the
# time difference probably won't be that much.
sub enqueue {
    my ($self, $time, $action) = @_;
    push (@{$self->{queue}}, [$time, $action]);
    @{$self->{queue}} = sort { $$a[0] <=> $$b[0] } @{$self->{queue}};
}

# Run the queue by removing and executing every closure whose time has
# arrived.  The current time is passed to each closure as an argument, in
# case the closure wants to use it.
sub run_queue {
    my ($self) = @_;
    my $event;
    while (defined $self->{queue}[0] && $self->{queue}[0][0] <= time) {
	$event = shift @{$self->{queue}};
	&{$event->[1]} (time);
    }
    defined $self->{queue}[0] ? $self->{queue}[0][0] : undef;
}


############################################################################
# Private methods
############################################################################

# Perform any periodic maintenance we need to do on our clients, such as
# reseting nicks or pinging servers.  Currently, all we do is send a date
# command to each live server to ensure that we're still connected.  This is
# run from the event queue and adds itself back onto the queue after each
# execution.
sub periodic {
    my ($self) = @_;
    my $client;
    for $client (@{$self->{clients}}) {
	$client->date if $client->connected;
    }
    $self->enqueue (time + $ping_after, sub { $self->periodic });
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
    $vector;
}

# If we note the death of a client we didn't already know was dead, mark it
# as such (so as not to do this multiple times) and then add a reconnect
# attempt to the event queue.
sub note_death {
    my ($self, $number) = @_;
    unless ($self->{dead}[$number]) {
	$self->{dead}[$number] = 1;
	$self->enqueue (time + 1, sub { $self->reconnect ($number, 1) });
    }
}

# Attempt to reconnect each dead client whose reconnect time has passed,
# using exponential backoff to increase the reconnect time each time
# connection fails.  Takes the number of the dead client and the current
# backoff value as arguments.  This function is designed to be run from the
# event queue, and if reconnection fails will add itself back into the event
# queue with an exponentially increasing timeout (maximum of 1024 seconds or
# about 17 minutes).
sub reconnect {
    my ($self, $client, $backoff) = @_;
    if ($self->{clients}[$client]->connect) {
	$self->{dead}[$client] = undef;
    } else {
	$backoff *= 2;
	$backoff = 1024 if ($backoff > 1024);
	my $event = sub { $self->reconnect ($client, $backoff) };
	$self->enqueue (time + $backoff, $event);
    }
}


############################################################################
# Module return value
############################################################################

# Ensure we evaluate to true.
1;
