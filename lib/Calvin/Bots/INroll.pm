package Calvin::Bots::INroll;
require 5.002;

#
# INroll -- A Calvin bot for In Nomine dice rolling.
#             Copyright 1996 by Russ Allbery <rra@cs.stanford.edu>
#
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

############################################################################
# Modules and declarations
############################################################################

use Calvin::Client;
use Calvin::Manager;
use Calvin::Parse qw (:constants);

# Comment out for systems compiled without support for crypt(), if you
#  have Crypt.pm.
#use Crypt;

use strict;

############################################################################
# Private methods.
############################################################################

# Set the channel to send rolls to.
sub set_rollchan {
    my $self = shift;
    my ($client, $user, $rollchan) = @_;
    if ($rollchan !~ /\D/) {
        $self->roll_channel($rollchan);
        $client->msg($user, "Rolls will go to channel $rollchan.");
    } else {
        $client->msg($user, "Invalid channel for rolls: $rollchan.");
    }
}

# Adds a modifier to the next roll.
sub do_gm_modroll {
    my $self = shift;
    my ($client, $user, $args) = @_;
    if ($args =~ /^([+-]\d+) (\S+)$/) {
        my $modifier = $1;
        my $passwd = $2;
        if ($self->passwd eq crypt($passwd, "jr")) {
            $self->gm_modifier($modifier);
            $client->msg ($user, "Next player will have $modifier.");
        } else { $client->msg ($user, "Bad password to shift.") }
    } else { $client->msg ($user, "Bad shift format: \"$args\".") }
}

# Do an In Nomine dice roll.
sub do_roll {
    my $self = shift;
    my ($client, $user) = @_;
    my ($d1, $d2, $d3, $total);
    my ($chan) = $self->roll_channel;

    # Roll dice, all three.
    $d1 = int ((rand (6)) + 1);
    $d2 = int ((rand (6)) + 1);
    $d3 = int ((rand (6)) + 1);
    $total = $d1 + $d2;

    if ($d1 == $d2 && $d2 == $d3 && ($d1 == 1 || $d1 == 6)) {
        if ($d1 == 6) {
            $client->public ($chan, "$user rolled Diabolical!  666!");
        } else {
            $client->public ($chan, "$user rolled Divine!  111!");
        }
    } else {
        $client->public ($chan, "$user rolled $total ($d1 $d2) <$d3>.");
    }
}

############################################################################
# Public methods.
############################################################################

# Performs any functions that need to be done once the object has been
#  attached to a Calvin::Client.
sub startup {
    my $self = shift;
    srand ($$ ^ time);
}

# Defines the channel that rolls will be sent to.
sub roll_channel {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{ROLL_CHANNEL} = shift }
    return $self->{ROLL_CHANNEL};
}

# Sets a roll modifier for the GM.
sub gm_modifier {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{GM_MODIFIER} = shift }
    return $self->{GM_MODIFIER};
}

# Sets the GM password.
sub passwd {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{PASSWD} = shift }
    return $self->{PASSWD};
}

# Creates a new Calvin::Bots::Standard object and sets all of the
#  commands to on.
sub new {
    my $class = shift;
    my ($client) = @_;

    my $self = {};
    bless ($self, $class);
    $self->roll_channel(4);
    $self->gm_modifier(0);
    $self->passwd('jrSTovKkViTQM');
    return $self;
}

# Send the help message.
sub return_commands {
    my $self = shift;
    my (@commands) = (
                      'roll',
                     );
    return @commands;
}

sub return_help {
    my $self = shift;
    my %help;
    %help = (
             'roll'    =>  [
                            'Syntax:  roll',
                            'Rolls the die!',
                           ],
             'rollchan' => [
                            'Syntax:  rollchan <channel>',
                            'Sets the channel we send rolls to.',
                           ],
            );
    return %help;
}


sub handle_line {
    my $self = shift;
    my ($manager, $client, $line, %result) = @_;

    # Ignore everything other than private messages to us, from
    # someone other than us, that don't begin with "- ".
    return 0 unless ($result{'code'} == C_WHIS);
    return 0 if ($result{'name'} eq $client->{nick});
    return 0 if ($result{'s1'} =~ /^- /);

    # Handle commands.
    if ($result{'s1'} =~ /^(f)?roll((\s+[+-]\d+)+)?/i) {
        my $fortune = $1 ? 1 : 0;
        my $pluses = $2;
        my @pluses = ($pluses =~ /([+-]\d+)/g) if $pluses;
        $self->do_roll ($client, $result{'name'}, $fortune, @pluses);
        return 1;
    } elsif ($result{'s1'} =~ /^shift (.*)/) {
        $self->do_gm_modroll ($client, $result{'name'}, $1);
        return 1;
    } elsif ($result{'s1'} =~ /^rollchan (.*)/) {
        $self->set_rollchan($1);
        return 1;
    } else {
        return 0;
    }
}

1;
