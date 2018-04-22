package Calvin::Bots::URL_Store;
require 5.002;

# This module is designed to provide registration and channeling
# functions for a Calvin bot, using a similar method as calvinhelps.tf
# does in Tinyfugue.  The purpose is to channel a character without
# letting others know who the channeler is.
#
# This should not be used in the same script with other bots due to
# namespace conflict with the characters.  A prefix command for allowing
# that could be added, but this should not be bothered with right now.
# This bot isn't something general use enough to do so. ;)  But if it was,
# format could be "%chanbot channel mi Hi!".  Easy to fix, see?
#
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

############################################################################
# Modules and declarations
############################################################################

use Calvin::Client;
use Calvin::Manager;
use Calvin::Parse;

use strict qw (vars);
use vars qw(@url_list);

############################################################################
# Misc functions.
############################################################################

sub clean_nick {
    my ($self, $nick) = @_;
    if ($nick =~ /^(\w+)(_|\d)$/) { return $1    }
    else                         { return $nick }
}

############################################################################
# Private methods.
############################################################################

sub addurl_cmd {
    my ($self, $client, $url, $channel) = @_;

    if ($#{${$self->{URLS}}[$channel]} >= ($self->urls - 1)) {
        pop @{${$self->{URLS}}[$channel]};
    }
    unshift (@{${$self->{URLS}}[$channel]}, $url);
}

sub listurl_cmd {
    my ($self, $client, $user, $message) = @_;

    my ($numlines, $channel, @rest) = split(/ /, $message);

    $channel = 1 unless $channel;

    if ($#{${$self->{URLS}}[$channel]} >= ($self->max_urls - 1)) {
        shift @{${$self->{URLS}}[$channel]};
    }

	if ($numlines > ($#{${$self->{URLS}}[$channel]} + 1)) {
		$numlines = $#{${$self->{URLS}}[$channel]};
	} else {
		$numlines--;
	}

	if ($numlines < 0) {
		$client->msg ($user, "Sorry, I have no URLS from channel $channel.");

	} else {
		while ($numlines) {
			$client->msg ($user, "URL: ".${$self->{URLS}}[$channel][$numlines - 1]);
			$numlines--;
		}
	}
}


############################################################################
# Public methods.
############################################################################

sub max_urls {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{MAX_URLS} = shift }
    return $self->{MAX_URLS};
}

sub new {
    my $class = shift;
    my ($client) = @_;

    my $self = {};
    bless ($self, $class);
	$self->{URLS} = undef;
	$self->max_urls(30);
    return $self;
}

# Performs any functions that need to be done once the object has been
#  attached to a Calvin::Client.  There aren't any, but leave this
#  here for standardization of the bots.
sub startup {
    my $self = shift;
}

# Creates a hash with all the valid help requests and their help.  Note
#  that if you call this, then change one of the commands to off, it
#  will still have the help for that command available.  Don't do it.
#  Bad.  No cookie.
sub return_help {
    my $self = shift;
    my %help;
    %help = (
             'listurls' =>   ['Syntax:  listurls <num> [channel]',
                              'Lists the last <num> URLs quoted on optional [channel].',
                             ],
    );
    return %help;
}

sub return_commands {
    my $self = shift;
    my (@commands) = ('listurls');
    return @commands;
}

sub handle_line {
    my $self = shift;
    my ($manager, $client, $line, %result) = @_;
    my ($message, $command);

    if (($result{'code'} == C_NICK_CHANGE) &&
        ($result{'name'} eq $client->{nick})) {
        $client->{nick} = $result{'s1'};

	} elsif ($result{'code'} == C_PUBLIC || $result{'code'} == C_POSE
					|| $result{'code'} == C_PPOSE
					|| $result{'code'} == C_NARRATE
					|| $result{'code'} == C_ALIAS
					|| $result{'code'} == C_ALIAS_POSE
					|| $result{'code'} == C_ALIAS_PPOSE
					|| $result{'code'} == C_YELL
					|| $result{'code'} == C_YELL_POSE
					|| $result{'code'} == C_YELL_PPOSE
					|| $result{'code'} == C_YELL_NARR
					|| $result{'code'} == C_TOPIC_CHANGE) {

		$message = $result{'s1'};

		# Find any URLs in the line.
		if ($message =~ m#<(http://[^ ]+)>#
				|| $message =~ m#(http://[^ ]+)[.,)']?#) {

			addurl_cmd($client, $1, $result{'channel'});
		}

    } elsif ($result{'code'} == C_WHIS && !$result{'on_channels'}
                    && $result{'s1'} !~ /^- /) {

        $message = $result{'s1'};

        # Parse the message sent us.
        $message =~ s/\t/\s/;
        $message =~ s/\s+$//;
        ($command, $message) = split (/ +/, $message, 2);

        # If it's a command for our bot and we're allowing that command,
        # do the command.
        if      ($command =~ /^listurls$/i) {
            $self->listurl_cmd ($client, $result{'name'}, $message);
            return 1;
        }
    }
    return 0;
}

1;
