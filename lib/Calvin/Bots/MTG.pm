# Calvin::Bots::MTG -- Mediates a Magic: The Gathering game.  -*- perl -*-
# $Id$
#
# Copyright 1999 by Russ Allbery <rra@stanford.edu>
#
# Due to possible copyright difficulties with Wizards of the Coast, please
# do not distribute this module without my explicit permission.  I am not
# making this script free software in the standard sense because of those
# problems.

############################################################################
# Modules and declarations
############################################################################

package Calvin::Bots::MTG;
require 5.003;

use Calvin::Client ();
use Calvin::Parse qw(:constants);

use strict;
use vars qw(%CARDS @COMMANDS %COMMANDS %HELP $ROOT $VERSION);

($VERSION = (split (' ', q$Revision$ ))[1]) =~ s/\.(\d)$/.0$1/;

# The root of the description tree for this module.
$ROOT = '/home/eagle/magic/cards';

# Our commands, for the bot interface.
@COMMANDS = qw(end init reload what);
%COMMANDS = map { $_ => 1 } @COMMANDS;

# Our help text, for the bot interface.
%HELP = (end      => ['Syntax:  end GAME',
                      'End the current game, destroying its data.'],
         init     => ['Syntax:  init <channel> <player> [<player> ...]',
                      'Start a new game with the given players.'],
         reload   => ['Syntax:  reload <card>',
                      'Reload the given card from disk.'],
         what     => ['Syntax:  what[>] <card>',
                      'Describes the powers of the given Magic card.']);


############################################################################
# Database routines
############################################################################

# Reduce a card name to its canonical form for lookup.
sub clean {
    my ($self, $card) = @_;
    $card = lc $card;
    for ($card) { s/\s+/_/g; s/\'//g; s/\s+$// }
    $card;
}

# A card description parser.  Given a card name, read it into a hash and
# return the anonymous hash.  The keys will be the field labels of the file.
sub load_card {
    my ($self, $name) = @_;
    my $file = $name;
    $file =~ s%^(.)%$1/$1%;
    open (DESC, "$ROOT/$file") or return undef;
    local $_;
    my %card;
    while (<DESC>) {
        next if /^\s*$/;
        chomp;
        s/^(.): //;
        my $label = $1;
        if ($label eq 'D') {
            push (@{$card{$label}}, $_);
        } else {
            $card{$label} = $_;
        }
    }
    close DESC;
    $CARDS{$name} = \%card;
    1;
}

# Return a text description for a given card.
sub description {
    my ($self, $card) = @_;
    my %d = %{$CARDS{$card}};
    return ("$d{N} ($d{A}): "
            . (!$d{C} || $d{T} eq $d{C} ? $d{T} : "$d{C} $d{T}")
            . ($d{M} ? ", $d{M}" : '')
            . ($d{P} ? ", $d{P}" : '') . '.'
            . ($d{I} ? " $d{I}" : '')
            . ($d{Q} ? " ($d{Q})" : ''));
}


############################################################################
# Commands
############################################################################

# End the current game.  Require the first argument be exactly "GAME" to
# prevent typos and mistakes.
sub cmd_end {
    my ($self, $client, $user, $rest) = @_;
    if (!$$self{CHANNEL}) {
        $client->msg ($user, 'No game is currently in progress');
    } elsif ($rest ne 'GAME') {
        $client->msg ($user, 'Use "end GAME" to end the current game');
    } else {
        $client->public ($$self{CHANNEL},
                         "Ending game at ${user}'s request");
        $client->leave ($$self{CHANNEL});
        delete $$self{PLAYERS};
        delete $$self{GAME};
        delete $$self{CHANNEL};
    }
}

# Initialize a new game with the given channel and space-separated set of
# players.
sub cmd_init {
    my ($self, $client, $user, $players) = @_;
    unless ($players) {
        $client->msg ($user, 'You can\'t start a game without players');
        return;
    }
    my ($channel, @players) = split (' ', $players);
    if ($channel !~ /^\d+$/) {
        $client->msg ($user, "Bad channel number $channel\n");
    } elsif (!@players) {
        $client->msg ($user, 'You can\'t start a game without players');
    } elsif ($$self{PLAYERS}) {
        $client->msg ($user, 'A game is currently in progress');
    } else {
        for (@players) {
            $$self{PLAYERS}{lc $_} = {
                artifacts => [],
                creatures => [],
                enchants  => [],
                graveyard => [],
                land      => [],
                deck      => 60,
                hand      => 7
            };
        }
        $$self{CHANNEL} = $channel;
        $client->join ($channel);
        my $pretty;
        if (@players > 2) {
            $pretty = join (', ', $players[0 .. $#players - 1]);
            $pretty .= ", and $players[-1]";
        } else {
            $pretty = join (' and ', @players);
        }
        my $count = ['with', 'between']->[$#players] || 'among';
        $client->public ($channel, "Starting a new game $count $pretty "
                         . "at ${user}'s request");
    }
}

# Reload a given card from disk by name.
sub cmd_reload {
    my ($self, $client, $user, $card) = @_;
    my $name = $self->clean ($card);
    if (!defined $CARDS{$name}) {
        $client->msg ($user, "$card not currently cached\n");
    } elsif ($self->load_card ($name)) {
        $client->msg ($user, "$card description reloaded\n");
    } else {
        $client->msg ($user, "Unable to find description for $card\n");
    }
}

# Return a formatted card description to a given user or channel.  We use
# the load_card method to load it if its not already in our cache.
sub cmd_what {
    my ($self, $client, $user, $card, $public) = @_;
    my $name = $self->clean ($card);
    if (!exists $CARDS{$name} && !$self->load_card ($name)) {
        $client->msg ($user, "No description for $card\n");
    } else {
        $client->msg (($public && $public eq '>' ? $$self{CHANNEL} : $user),
                      $self->description ($name));
    }
}


############################################################################
# Public methods
############################################################################

# Create a new MTG bot.
sub new {
    my $that = shift;
    my $class = ref $that || $that;
    bless ({}, $class);
}

# We don't use this.
sub startup { }

# Our help text.
sub return_help     { return %HELP     }
sub return_commands { return @COMMANDS }

# Takes a line and performs any necessary functions on it.  If the line is a
# command to the bot, return 1.  Return 0 otherwise.  Note that there can be
# things for which we do functions, but return 0.  These are lines such as
# signon messages, which more than one bot may wish to know about.
sub handle_line {
    my $self = shift;
    my ($manager, $client, $line, %p) = @_;

    $line =~ s/\s+$//;
    if ($p{code} != C_WHIS || $p{s1} =~ /^- / || $p{on_channels}) {
        return 0;
    }

    # Parse the message, pulling off the first word as the command, and then
    # dispatch the command to the appropriate place.
    my ($method, $public);
    my ($command, $rest) = split (' ', $p{s1}, 2);
    chomp $rest if $rest;
    $command = lc $command;
    if ($command =~ s/([<>])$//) {
        $public = $1;
    }
    if ($COMMANDS{$command}) {
        $method = 'cmd_' . $command;
    } else {
        my @choices = grep { /^$command/ } @COMMANDS;
        if (@choices == 1) {
            $method = 'cmd_' . $choices[0];
        } elsif (@choices > 1) {
            $client->msg ($p{name}, 'Ambiguous command $command in '
                          . join (', ', @choices));
            return 1;
        } else {
            return 0;
        }
    }
    $self->$method ($client, $p{name}, $rest, $public);
    1;
}