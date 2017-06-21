package Calvin::Bots::Fengroll;
require 5.002;

#
# fengroll -- A Calvin bot for Feng Shui dice rolling.
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
#use Crypt;

use strict;

############################################################################
# Private methods.
############################################################################

# Send a quit message.
sub send_quit {
    my $self = shift;
    my ($client, $user) = @_;
    $client->raw_send ("\@quit Exiting at ${user}'s request\n");
}


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

# Increase a series of die rolls plus one, adding a new die if the last
#  roll is six.
sub increase_die {
    my $self = shift;
    my ($rolls) = @_;
    if ($$rolls[$#$rolls] < 6) { $$rolls[$#$rolls]++ }
    else                       { push (@$rolls, 1)   }
}

# Decrease a series of die rolls by one, removing the die if it's down
#  to one.
sub decrease_die {
    my $self = shift;
    my ($rolls) = @_;
    if ($$rolls[$#$rolls] > 1) { $$rolls[$#$rolls]-- }
    else                       { pop @$rolls         }
}

# If a die has its last roll a six, this tries to redistribute the roll
#  to end with something else so that it hasn't obviously been tampered
#  with.
sub redist_sixes {
    my $self = shift;
    my ($d1, $d2) = @_;
    if ($$d1[$#$d1] == 6) {
        if ($$d2[$#$d2] == 1) {
            push (@$d1, 1);
            $$d2[$#$d2]++;
        } else {
            $$d1[$#$d1]--;
            $$d2[$#$d2]--;
        }
    }
}

# Do a Feng Shui dice roll.
sub do_roll {
    my $self = shift;
    my ($client, $user, $fortune, @pluses) = @_;
    my (@d1, @d2, $reroll, $extra, $cmsg, $first_mod);
    my $except = 0;
    my $total = 0;
    
    # Roll dice.  If both are 6, it's an exceptional roll.  If any is
    #  6, keep rolling that die and adding it to the results for that
    #  roll until we get something other than a 6.
    push (@d1, int (rand (6)) + 1);
    push (@d2, int (rand (6)) + 1);
    if ($d1[$#d1] == 6 && $d2[$#d2] == 6) { $except += 1 }
    while ($d1[$#d1] == 6) {
        $extra = int (rand (6)) + 1;
        push (@d1, $extra);
    }
    while ($d2[$#d2] == 6) {
        $extra = int (rand (6)) + 1;
        push (@d2, $extra);
    }

    # Grab a modifier if there is one, and then set the modifier to 0.
    my $gm_modifier = $self->gm_modifier;
    $self->gm_modifier(0);

    # We want to make sure that a roll that isn't exceptional doesn't
    #  become so.  It won't matter to the note that it's exceptional,
    #  but it would make it more obvious that the rolls have been
    #  tampered with.  So if the first die's rolls have a six and
    #  we're modifying down (so that the second die might be increased
    #  to a 6), we roll a random number between 1 and 5 and keep
    #  subtracting from the first die until it either has one roll of
    #  that number or until we're done modifying.  We do the same thing
    #  if the second die has a first roll of six, we're modifying up,
    #  and it's not an exceptional roll.
    if ($d1[0] == 6 && $gm_modifier < 0 && !$except) {
        $first_mod = int (rand (5)) + 1;
        while ($gm_modifier != 0 && $d1[0] != $first_mod) {
            decrease_die(\@d1);
            $gm_modifier++;
        }
    } elsif ($d2[0] == 6 && $gm_modifier > 0 && !$except) {
        my $first_mod = int (rand (5)) + 1;
        while ($gm_modifier != 0 && $d2[0] != $first_mod) {
            decrease_die(\@d2);
            $gm_modifier--;
        }
    }   

    # If we have a modifier, we want to roll a random number to start
    #  applying to the first die's rolls, then apply the rest to the
    #  second die's rolls.  As a random number that I thought would
    #  work well, I've picked 0..(average of d1's rolls, d2's rolls,
    #  and the modifier).
    if ($gm_modifier) {
        my $temp_total = 0;
        map { $temp_total += $_ } @d1;
        map { $temp_total += $_ } @d2;
        $first_mod = int (rand ((((abs $gm_modifier) + $temp_total) / 3) + 1));
    }
    else {
        $first_mod = 0;
    }

    # Apply the random number, increasing or decreasing depending on
    #  whether the modifier is positive or negative.  If negative, we
    #  drop out when the rolls are down to only 1 on the first roll, or
    #  we have a 6 on the first roll and we're down to 1 on the second
    #  (to keep from screwing an exceptional roll.)
    while ($first_mod) {
        if ($gm_modifier > 0) {
            increase_die(\@d1);
            $gm_modifier--;
        } else {
            last if $#d1 == 0 && $d1[0] == 1;
            last if $#d1 == 1 && $d1[0] == 6 && $d1[1] == 1;
            decrease_die(\@d1);
            $gm_modifier++;
        }
        $first_mod--;
    }

    # Do the same with what's left of the modifier, save that for this,
    #  we increase rolls if the modifier is negative and decrease if
    #  positive.
    while ($gm_modifier != 0) {
        if ($gm_modifier < 0) {
            increase_die(\@d2);
            $gm_modifier++;
        } else {
            last if $#d2 == 0 && $d2[0] == 1;
            last if $#d2 == 1 && $d2[0] == 6 && $d2[1] == 1;
            decrease_die(\@d2);
            $gm_modifier--;
        }
    }

    # If we had a positive roll, we might not be done with distributing
    #  the modifier.  (We could have run out of rolls to decrease the
    #  second die by before we ran out of modifier.)  So we go back one
    #  more time to increase the first die if there's modifier left.
    while ($gm_modifier != 0) {
        if ($gm_modifier > 0) {
            increase_die(\@d1);
            $gm_modifier--;
        }
    }

    # And we might have ended up so that one group of dice rolls ends
    #  in a six, which wouldn't happen without a modifier.  So we
    #  redistribute to try fixing this, though it's still possible for
    #  this to happen, if the roll was right so that fixing one group
    #  messes up the other.
    redist_sixes(\@d1, \@d2);
    redist_sixes(\@d2, \@d1);
    
    map { $total += $_ } @d1;
    map { $total -= $_ } @d2;
    map { $total += $_ } @pluses;
    if ($fortune) {
	$fortune = int (rand (6)) + 1;
	$total += $fortune;
    }
    $total = "+$total" if ($total > 0);
    $total = " 0" if ($total == 0);
    $cmsg = $except ? ' (exceptional)' : '';
    if ($fortune) {
        $client->public ($self->roll_channel, "$user rolled $total$cmsg " .
                              "(+@d1, -@d2) (Fortune +$fortune) @pluses");
    } else {
        $client->public ($self->roll_channel, "$user rolled $total$cmsg " .
                              "(+@d1, -@d2) @pluses");
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
    if (@_) { $self->{ROLL_CHANNEL} = shift }
    return $self->{ROLL_CHANNEL};
}

# Defines the channel that rolls will be sent to.
sub gm_modifier {
    my $self = shift;
    if (@_) { $self->{GM_MODIFIER} = shift }
    return $self->{GM_MODIFIER};
}

# Defines the channel that rolls will be sent to.
sub passwd {
    my $self = shift;
    if (@_) { $self->{PASSWD} = shift }
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
                      'froll',
                      'quit',
                     );
    return @commands;
}

sub return_help {
    my $self = shift;
    my %help;
    %help = (
             'roll'  => ['Syntax:  roll [+-num] [+-num]...',
                         'Returns a \'Pong.\'',
                        ],
             'froll' => ['Syntax:  froll [+-num] [+-num]...',
                         'Changes the nick back to the default.',
                        ],
             'quit'  => ['Syntax:  quit',
                         'Disconnects the bot.',
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
    } elsif ($result{'s1'} =~ /^quit/) {
        $self->send_quit ($client, $result{'name'});
        $client->shutdown;
        exit;
    } else {
        return 0;
    }
}

1;
