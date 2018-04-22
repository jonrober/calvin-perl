package Calvin::Bots::Standard;
require 5.002;

# This contains various functions useful in all Calvin::Bots.  At this
# point, that is limited only to ping, renick, time, and say.  The
# functions can be turned on and off through settings.
#
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

############################################################################
# Modules and declarations
############################################################################

use POSIX qw(strftime);
use Calvin::Client;
use Calvin::Manager;
use Calvin::Parse qw (:constants);

use strict;

############################################################################
# Private methods.
############################################################################

# Leaves a channel on a user command.
sub leave_cmd {
    my $self = shift;
    my ($client, $user, $channel, @args) = @_;
    my ($arg, $force);
    $force = 0;

    # Reads in any arguments sent to the bot.  "-force" forces a join,
    #  even if the bot thinks it is already on the requested channel.
    foreach $arg (@args) {
        if (($arg =~ /^-force$/i) || ($arg =~ /^-f$/i)) { $force = 1 }
    }

    # Check to make sure the bot is on the channel before trying to leave.
    if ((defined $self->on_channel($channel)) || $force) {

        # Make sure the channel sent is a valid number 0 and the high channel.
        if (($channel !~ /\D/) and ($channel >= 0) and
            ($channel <= $self->high_channel)) {

            # Remove the channel from the array of channels we're on
            #  and send a leave command to the server.
            $self->off_channel ($channel);
            $client->leave ($channel);
        } else {
            $client->msg ($user, "Sorry, $channel is an invalid channel.");
        }
    } else {
        $client->msg ($user, "Sorry, I'm not on channel $channel.");
    }
}

# Joins a channel on a user command.
sub join_cmd {
    my $self = shift;
    my ($client, $user, $channel, @args) = @_;
    my ($arg, $force);
    $force = 0;

    # Reads in any arguments sent to the bot.  "-force" forces a join,
    #  even if the bot thinks it is already on the requested channel.
    foreach $arg (@args) {
        if (($arg =~ /^-force$/i) || ($arg =~ /^-f$/i)) { $force = 1 }
    }

    # Make sure that we're not already on the channel.
    if ((!defined $self->on_channel($channel)) or $force) {

        # Make sure the requested channel is a valid channel.
        if ($channel !~ /\D/ and $channel >= 0 and
                     ($channel <= $self->high_channel)) {

            # Add the channel as joined in our array of channels we're on.
            #  Then send a join command to the server.
            $self->on_channel ($channel);
            $client->join ($channel);

        } else {
            $client->msg ($user, "Sorry, $channel is an invalid channel.");
        }
    } else {
        $client->msg ($user, "I'm already logging channel $channel.");
    }
}

# Performs a say command - redirects a message sent to the bot to a
#  certain channel.  Only real use is for fun, and you probably usually
#  want it disabled.
sub say_cmd {
    my ($self, $client, $user, $dest, @rest) = @_;
    if ((defined $dest) and ($dest !~ /\D/) and ($dest >= 0) and
        ($dest <= $self->high_channel)) {
        my $message = join(' ', @rest);
        $client->raw_send("\@$dest $message\n");
    } else { $client->msg ($user, "Invalid channel $dest.") }
}

# Replies to a ping.  Note that Nagbot also has a ping command, so if
#  we use nagbot, we want to disable this.  (Nagbot's ping will respond
#  the same as Standard's, if you send Nagbot's no options.)
sub ping_cmd {
    my ($self, $client, $user) = @_;
    $client->msg ($user, "Pong.");
}

# Attempts to change the nick back to its supposed value, after an
#  auto-increment has been forced in signon to prevent conflict.  Note
#  that we really have no way to tell what the original nick was, and
#  we're just assuming that the bot will never have a default nick
#  ending in a number.  If you do want to use, say, Cambot1997 as a
#  nick, disable this to prevent people from changing the nick to Cambot.
sub renick_cmd {
    my ($self, $client, $user) = @_;
    my $nick = $client->{nick};
    $client->msg ($user, "Attempting to change $nick back to original nick.");
    $nick =~ s/(\d+)$//;
    $client->raw_send ("\@nickname $nick\n");
}

# Returns a simple time string, like the @time command on the server.
sub time_cmd {
    my $self = shift;
    my ($client, $user) = @_;
    my $date_format = "%a %b %e %I:%M %p %Z";
    my $time = strftime($date_format, localtime());
    $client->msg ($user, "$time.");
}

# Send a quit message.
sub quit_cmd {
    my $self = shift;
    my ($client, $user) = @_;
    $client->quit ("Exiting at ${user}'s request.\n");
}


# When sent the name of a user, will open the current logfile from a
#  Cambot object and spam it all to the user's connection.  As yet
#  unimplemented, due to the difficulties in grabbing the Cambot object
#  from here.  I think that I'll have to add in a Bot_ID variable to each
#  Calvin::Bots object, then send the array of bots to each object when
#  they're called...  I'll get to it sooner or later and then get this
#  working.
# *Update*: Yes, this became recchan and readlog in Cambot.pm.  I didn't
#  mean for it to actually be useful, go fig.  I'm only leaving this here
#  because the idea how to do this would be useful later.
sub spam_cmd {
    my $self = shift;
    my ($client, $dest_user) = @_;
}

############################################################################
# Public methods.
############################################################################

# Creates a new Calvin::Bots::Standard object and sets all of the
#  commands to on.
sub new {
    my $class = shift;
    my ($client) = @_;

    my $self = {};
    bless ($self, $class);
    $self->{ON_CHANNELS} = undef;
    $self->ping_ok(1);
    $self->renick_ok(1);
    $self->say_ok(1);
    $self->time_ok(1);
    $self->high_channel (31);
    return $self;
}

# Set the highest channel on the server.  Should always be 31.  *Could* be
#  used to restrict the server to only channels lower than a certain channel.
#  It'd also be possible to use this and a few easy changes in the join and
#  leave to restrict the bot to a range of joinable channels, but we don't
#  need this and aren't likely to.  Just ignore this and don't really think
#  about it or change it or anything.  Good god, this is a lot of comments
#  for 5 measley lines.
sub high_channel {
    my $self = shift;
    if (@_) { $self->{HIGH_CHANNEL} = shift }
    return $self->{HIGH_CHANNEL};
}

# When sent a channel and tag, sets that channel to indicate the
#  channel has been joined.  When just sent a channel, returns one or
#  undef.
sub on_channel {
    my $self = shift;
    my ($channel) = @_;
    if (defined $channel) { ${$self->{ON_CHANNELS}}[$channel] = 1 }
    return ${$self->{ON_CHANNELS}}[$channel];
}

# Sets a channel to undef, indicating that we're not on the channel.
sub off_channel {
    my $self = shift;
    my ($channel) = @_;
    if (defined $channel) {
        ${$self->{ON_CHANNELS}}[$channel] = undef;
    }
}

# With an argument, sets the ping command on or off.  Returns the state
#  of the ping command.
sub ping_ok {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{Ping_OK} = shift }
    return $self->{Ping_OK};
}

# With an argument, sets the renick command on or off.  Returns the state
#  of the renick command.
sub renick_ok {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{Renick_OK} = shift }
    return $self->{Renick_OK};
}

# With an argument, sets the quit command on or off.  Returns the state
#  of the quit command.
sub quit_ok {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{Quit_OK} = shift }
    return $self->{Quit_OK};
}

# With an argument, sets the say command on or off.  Returns the state
#  of the say command.
sub say_ok {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{Say_OK} = shift }
    return $self->{Say_OK};
}

# With an argument, sets the ping.. er, the say... um, no... the time
#  command.  Yeah, that's it.  Sets the command on or off.  Returns the
#  state of the re-- er, time command.
sub time_ok {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{Time_OK} = shift }
    return $self->{Time_OK};
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
             'ping' =>   ['Syntax:  ping',
                          'Returns a \'Pong.\'',
                         ],
             'renick' => ['Syntax:  renick',
                          'Changes the nick back to the default.',
                         ],
             'say' =>    ['Syntax:  say <channel> <message>',
                          'Has the bot say a message on a certain channel.',
                         ],
             'time' =>   ['Syntax:  time',
                          'Aliases: date, clock',
                          'Tells the current time.',
                         ],
             'quit' =>   ['Syntax:  quit',
                          'Disconnects the bot.',
                         ],
    );
    if (!$self->ping_ok)   { delete $help{'ping'}   }
    if (!$self->say_ok)    { delete $help{'say'}    }
    if (!$self->renick_ok) { delete $help{'renick'} }
    if (!$self->time_ok)   { delete $help{'time'}   }
    if (!$self->quit_ok)   { delete $help{'quit'}   }
    return %help;
}

# Returns a list of all valid commands, for listing commands help is
#  given on.
sub return_commands {
    my $self = shift;
    my (@commands);
    if ($self->ping_ok)   { push (@commands, 'ping')   }
    if ($self->renick_ok) { push (@commands, 'renick') }
    if ($self->say_ok)    { push (@commands, 'say')    }
    if ($self->time_ok)   { push (@commands, 'time')   }
    if ($self->quit_ok)   { push (@commands, 'quit')   }
    return @commands;
}

# Takes a line and sees if there's anything the bot needs to do with
#  it.  Returns 1 if it is a command to this module, 0 otherwise.
sub handle_line {
    my $self = shift;
    my ($manager, $client, $line, %result) = @_;

    if (($result{'code'} == C_NICK_CHANGE) &&
        ($result{'s1'} eq $client->{nick})) {
        $client->{nick} = $result{'name'};

    # If we've signed off deliberately, kill this client.
    } elsif (($result{'code'} == C_SIGNOFF) &&
             ($result{'name'} eq $client->{nick}) &&
             ($result{'s1'} =~ /^Exiting( |:)/)) {

        $manager->kill_client($client);

        #        my $i = 0;
        #        my $fairness = $manager->{client};
        #        foreach (@{$manager->{clients}}) {
        #            if ($_ == $client) { last }
        #            $i++;
        #        }

        # If the fairness pointer points after the removed client, move it
        #  back one to have it point at the same client.  If the fairness
        #  pointer *is* the client and the client was the last element,
        #  move it back one.  Otherwise leave the pointer alone, though
        #  it'll be somewhat messed up if the pointer was at the client.
        #  Can't be helped.  Then zap the client from the arrays of clients
        #  and dead clients.
        #        if ($i < $fairness) {
        #            $manager->{client}--;
        #        } elsif ($i == $fairness && $i == $#{$manager->{clients}}) {
        #            $manager->{client}--;
        #        }
        #        splice(@{$manager->{clients}}, $i, 1);
        #        splice(@{$manager->{dead}},    $i, 1);

        # If we've killed all the clients, we don't really have any
        #  reason to be alive, so exit.  Think there's something wrong
        #  here, which is why the print to file.
        if (!@{$manager->{clients}}) {
            exit(0);
        }
        return 1;

    } elsif (($result{'code'} == C_WHIS) && (!$result{'on_channel'}) &&
             ($result{'s1'} !~ /^- /)) {

        my $message = $result{'s1'};
        my $user    = $result{'name'};

        # Parse the message sent us.
        $message =~ s/\t/ /;
        $message =~ s/\s+$//;
        my ($command, $type, @rest) = split (/ +/, $message);

        # If it's a command for our bot and we're allowing that command,
        # do the command.
        if (($command eq 'renick') && $self->renick_ok) {
            $self->renick_cmd ($client, $user);
            return 1;
        } elsif (($command eq 'say') && $self->say_ok) {
            $self->say_cmd ($client, $user, $type, @rest);
            return 1;
        } elsif (($command eq 'ping') && $self->ping_ok) {
            $self->ping_cmd ($client, $user);
            return 1;
        } elsif ( (($command eq 'clock') || ($command eq 'time') ||
                   ($command eq 'date')) && $self->time_ok) {
            $self->time_cmd ($client, $user);
            return 1;
        } elsif ($command eq 'go') {
            $self->leave_cmd ($client, $result{'name'}, $type, @rest);
            return 1;
        } elsif ($command eq 'come') {
            $self->join_cmd ($client, $result{'name'}, $type, @rest);
            return 1;
        } elsif (($command =~ /^quit$/i) && $self->quit_ok) {
            $self->quit_cmd ($client, $user);
            # No, we'll never actually need to return 1, since we're
            #  killing the bot in the previous sub.  It still fits
            #  with the idea of how things should work.  Mmm.  Perhaps
            #  we should instead have a way to set up new bots from
            #  uberbot.  Ones where we don't have to start a new script,
            #  but can load, say, a fengbot when needed on the fly.
            # Update: We now do this in uberbot itself, comment left for
            #  'membering how I came up with the idea.
            return 1;
        }
    }
    return 0;
}

1;
