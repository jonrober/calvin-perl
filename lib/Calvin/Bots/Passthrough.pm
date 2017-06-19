package Calvin::Bots::Passthrough;
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
use vars qw (%charlist @on_channels);
# ['mi', 'Michael', 2, 'Van']

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

sub listchars_cmd {
    my ($self, $client, $user) = @_;
    my $userroot = $self->clean_nick($user);
    print "User: $userroot\n";
    my $found = 0;
    foreach my $key (keys %charlist) {
        my @charinfo = @{$charlist{$key}};
        if ($charinfo[2] eq $userroot) {
            $client->msg ($user, "Nick: $charinfo[0]  Name: $charinfo[1]  Channel: $charinfo[2].");
            $found = 1;
        }
    }
    if (!$found) { $client->msg ($user, "No characters found for '$userroot'.") }
}

sub addchar_cmd {
    my ($self, $client, $user, $message) = @_;
    my $userroot = $self->clean_nick($user);
    my ($nick, $name, $channel) = split (/ +/, $message);
    print "Nick: $nick  Name: $name  Channel: $channel  User: $user\n";

    if (exists $charlist{$nick}) {
        if (${$charlist{$nick}}[2] eq $userroot) {
            $client->msg ($user, "Deleted prefix $nick.");
            @{$charlist{$nick}} = ($name, $channel, $userroot);
            $client->msg ($user, "Added character $name with prefix $nick on channel $channel by $userroot.");
        } else {
            $client->msg ($user, "Character $nick already exists.");
        }
    } else {
        @{$charlist{$nick}} = ($name, $channel, $userroot);
        $client->msg ($user, "Added character $name with prefix $nick on channel $channel by $userroot.");
    }
}

sub delchar_cmd {
    my ($self, $client, $user, $message) = @_;
    my $userroot = $self->clean_nick($user);
    my ($nick) = split (/ +/, $message);
    print "Nick: $nick  User: $user\n";

    if (exists $charlist{$nick}) {
        if (${$charlist{$nick}}[2] eq $userroot) {
            delete $charlist{$nick};
            $client->msg ($user, "Deleted prefix $nick.");
        } else {
            $client->msg ($user, "Cannot delete prefix $nick: Does not belong to $userroot.");
        }
    } else {
        $client->msg ($user, "Cannot delete prefix $nick: Does not exist.");
    }
}

sub channel_cmd {
    my ($self, $client, $user, $nick, $message) = @_;
    my $userroot = $self->clean_nick($user);
    print "Nick: $nick  Message: $message  User: $user\n";

    if (exists $charlist{$nick}) {
        my @charinfo = @{$charlist{$nick}};
        if ($charinfo[2] eq $userroot) {
            my $name    = $charinfo[0];
            my $channel = $charinfo[1];
            if      ($message =~ /^(:|;)\1(.*)$/) {
                $client->raw_send ("%$channel [$name] $1$2\n");
            } elsif ($message =~ /^([:;])(?!\1)(?=[ a-z',]|....)\s*(.*)$/) {
                if ($1 eq ':') {
                    $client->raw_send ("%$channel [$name $2]\n");
                } else {
                    $client->raw_send ("%$channel [$name$2]\n");
                }
            } else {
                $client->raw_send ("%$channel [$name] $message\n");
            }
        } else {
            $client->msg ($user, "Cannot channel prefix $nick: Does not belong to $userroot.");
        }
    } else {
        $client->msg ($user, "Cannot channel prefix $nick: Does not exist.");
    }
}

sub join_cmd {
    my ($self, $client, $user, $args) = @_;
    my $quiet = 0;
    my $force = 0;

    my ($channel, @args) = split (/ +/, $args);
    foreach my $arg (@args) {
        if    (($arg =~ /^-quiet$/i) || ($arg =~ /^-q$/i)) { $quiet = 1 }
        elsif (($arg =~ /^-force$/i) || ($arg =~ /^-f$/i)) { $force = 1 }
    }

    if ((!$on_channels[$channel]) || $force) {
        if ($channel =~ /^(3[01]|[12]?[0-9])$/) {
            if (!$quiet) {
                $client->msg ($user, "Okay, I'll join $channel.");
            }
            $client->join ($channel);
            $on_channels[$channel] = $user;
        } else {
            $client->msg ($user, "Sorry, $channel is an invalid channel.");
        }
    } else {
        $client->msg ($user, "I'm already reflecting channel $channel.");
    }
}

sub leave_cmd {
    my ($self, $client, $user, $args) = @_;
    my $quiet = 0;
    my $force = 0;

    my ($channel, @args) = split (/ +/, $args);
    foreach my $arg (@args) {
        if    (($arg =~ /^-quiet$/i) || ($arg =~ /^-q$/i)) { $quiet = 1 }
        elsif (($arg =~ /^-force$/i) || ($arg =~ /^-f$/i)) { $force = 1 }
    }

    if ($on_channels[$channel] || $force) {
        if ($channel =~ /^(3[01]|[12]?[0-9])$/) {
            if (!$quiet) {
                $client->msg ($user, "Okay, I'll leave $channel.");
            }
            $client->leave ($channel);
            $on_channels[$channel] = '';
        } else {
            $client->msg ($user, "Sorry, $channel is an invalid channel.");
        }
    } else {
        $client->msg ($user, "Sorry, I'm not on channel $channel.");
    }
}


############################################################################
# Public methods.
############################################################################

#  commands to on.
sub new {
    my $class = shift;
    my ($client) = @_;

    my $self = {};
    bless ($self, $class);
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
             'addchar' =>   ['Syntax:  addchar prefix nickname channel',
                             'Adds a character, activated by messaging the prefix and a message.',
                            ],
             'delchar' =>   ['Syntax:  delchar prefix',
                             'Changes the nick back to the default.',
                            ],
             'listchars' => ['Syntax:  listchars',
                             'Lists all characters belonging to your nick.',
                            ],
    );
    return %help;
}

sub return_commands {
    my $self = shift;
    my (@commands) = ('addchar', 'delchar', 'listchars');
    return @commands;
}

sub handle_line {
    my $self = shift;
    my ($manager, $client, $line, %result) = @_;
    my ($message, $command);

    if (($result{'code'} == C_NICK_CHANGE) &&
        ($result{'name'} eq $client->{nick})) {
        $client->{nick} = $result{'s1'};

    } elsif ($result{'code'} == C_WHIS && !$result{'on_channels'}
                    && $result{'s1'} !~ /^- /) {

        $message = $result{'s1'};

        # Parse the message sent us.
        $message =~ s/\t/\s/;
        $message =~ s/\s+$//;
        ($command, $message) = split (/ +/, $message, 2);

        # If it's a command for our bot and we're allowing that command,
        # do the command.
        if      ($command =~ /^addchar$/i) {
            $self->addchar_cmd ($client, $result{'name'}, $message);
            return 1;
        } elsif ($command =~ /^delchar$/i) {
            $self->delchar_cmd ($client, $result{'name'}, $message);
            return 1;
        } elsif ($command =~ /^listchars$/i) {
            $self->listchars_cmd ($client, $result{'name'});
            return 1;
        } elsif ($command =~ /^join$/i) {
            $self->join_cmd ($client, $result{'name'}, $message);
            return 1;
        } elsif ($command =~ /^leave$/i) {
            $self->leave_cmd ($client, $result{'name'}, $message);
            return 1;
        } else {
            $self->channel_cmd ($client, $result{'name'}, $command, $message);
            return 1;
        }
    }
    return 0;
}

1;
