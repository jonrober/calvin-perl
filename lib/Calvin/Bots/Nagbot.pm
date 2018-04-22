package Calvin::Bots::Nagbot;

# nagbot -- A calvin bot designed to issue reminders to a person.
#           Copyright 1997 by Jon Robertson <jonrober@eyrie.org>
#
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.
#
# Ideas and original framework taken from Russ Allbery's descbot.
#
# This bot is designed to take messages sent to it from a user, then return
# them at the user's signon, once at a certain time, or every X minutes.
# The messages are taken and sent by @msg, and are stored in a file until
# use.

############################################################################
# Modules and declarations
############################################################################

require 5.002;

use Calvin::Client;
use Calvin::Manager;
use Calvin::Parse qw (:constants);
use Date::Format;

use strict;

# We want a shared namespace for the nags, so that if we move servers,
#  the pings won't be lost.  %stat should probably be removed from here,
#  though.
use vars qw(%stat %nags);

############################################################################
# Operations on the message file.
############################################################################

# Adds a new command as the last line in the message file.
sub add_command {
    my $self = shift;
    my ($user, $command) = @_;
    push (@{$nags{$user}}, $command);
}

# Checks the message file for a certain numbered message from a
# specific user.  Returns either the position of the line we're looking
# for or -1 if it does not exist.
sub check_command {
    my $self = shift;
    my ($user, $checkfor) = @_;
    my @commands = @{$nags{$user}};
    my $i = 0;
    foreach my $msg (@commands) {
        return ($i) if ($msg =~ /^\w+ .*\Q$checkfor\E$/);
        ++$i;
    }
    return -1;
}

# Deletes one command line from the message file by popping the last
# line off and then writing that line over the line we want to delete,
# if we're not deleting the last line.
sub delete_command {
    my $self = shift;
    my ($user, $number) = @_;
    my @commands = @{$nags{$user}};
    if (($number < 0) || ($number > $#commands)) { return 0 }
    for (my $i = $number; $i < $#commands; $i++) {
        $commands[$i] = $commands[$i+1];
    }
    pop @commands;
    @{$nags{$user}} = @commands;
    return 1;
}

# Returns one line, the place number of which we know.
sub return_command {
    my $self = shift;
    my ($user, $place) = @_;
    return ($nags{$user}[$place]);
}

# This takes one user and scans the message file for any pending messages
# he has, returning them in the format of the message file.
sub all_commands {
    my $self = shift;
    my ($user) = @_;
    if (exists $nags{$user} && @{$nags{$user}}) { return @{$nags{$user}} }
    else                                        { return undef           }
}


############################################################################
# Commands to deal with the actual pingings.
############################################################################

# *Sabre* signon Remember to talk to Eag.              | Received
# sabre signon Remember to talk to Eag.                | Stored
# -> *Sabre* (1) Signon -> Remember to talk to Eag.    | Sent

# Takes a signon and sends the user who has just signed on any
# pending signon messages.
sub check_signon {
    my $self = shift;
    my ($client, $user) = @_;
    my ($position);
    my @messages = $self->all_commands ($user);
    my $i = 0;
    foreach my $message (@messages) {
        if (defined $message && $message =~ /^signon (.+)$/) {
            $message = $1;
            $position = $self->check_command ($user, $message);
            $client->msg ($user, "($position) Signon -> $message");
            $i++;
        }
    }
}

# Handle a set ping event, of either ping or alarm.
sub do_ping {
    my $self = shift;
    my ($manager, $client, $user, $message) = @_;
    my ($command, $position, $interval);

    $position = $self->check_command ($user, $message);

    # Check to see if it's still in the file.  If so, ping the user and
    # add it back to the queue.  If not, we can exit.
    if ($position > -1) {
        $command = $self->return_command ($user, $position);
        if ($command =~ /^ping (\d+) \Q$message\E$/) {

            my $lowcase = lc $user;
            # User has exceeded maximum bad pings for this client.
            if (lc $stat{$client}{$lowcase} > $self->maxbad) {
                $self->delete_command ($user, $position);
            } else {

            # Ping command - Send the ping and then put it back in the queue.
                $interval = $1;
                $client->msg ($user, "($position) Ping $interval -> $message");
                $manager->enqueue ($interval * 60 + time(), sub { $self->do_ping ($manager, $client, $user, $message) });
            }

        } elsif ($command =~ /^alarm .* \Q$message\E$/) {
            # Alarm command - We send the alarm and then delete the command.
            $client->msg ($user, "($position) Alarm -> $message");
            $self->delete_command ($user, $position);
        }
    }
}

############################################################################
# Misc functions.
############################################################################

# Set a user's bad message count to 0, adding him if he doesn't exist.
sub good_message {
    my $self = shift;
    my ($client, $user) = @_;
    $user = lc $user;
    $stat{$client}{$user} = 0;
}

# Increment's a user's bad message count, or sets it to 1 if he doesn't
# exist.
sub bad_message {
    my $self = shift;
    my ($client, $user) = @_;
    $user = lc $user;
    if (defined $stat{$client}{$user}) { $stat{$client}{$user}++   }
    else                               { $stat{$client}{$user} = 1 }
}

############################################################################
# User commands.
############################################################################

# *Van* !clear 1 3 4 5
#
# Clear a list of messages.
sub clear_message {
    my $self = shift;
    my ($client, $user, @args) = @_;
    my $nick = $client->{nick};
    my $status;
    if (@args) {
        foreach my $num (@args) {
            if ($num !~ /\D/) {
                $status = $self->delete_command ($user, $num);
                if ($status) { $client->msg ($user, "Deleted message $num") }
                else { $client->msg ($user, "Message $num not found"); }
            } else {
                $client->msg ($user, "Error: Use \"\%$nick clearmsg <Number> [Number] [Number]...\"");
            }
        }
    } else {
        $client->msg ($user, "Error: Use \"\%$nick clearmsg <Number> [Number] [Number]...\"");
    }
}


# *Sabre* !signon I need to do the Return of the AIF plotting.           | Received
# $h{'sabre'} = '2 signon I need to do the Return of the AIF plotting'; | Stored
# -> *Sabre* (1) Signon -> I need to do the Return of the AIF plotting. | Sent
#
# Parse and add a signon message.
sub signon_message {
    my $self = shift;
    my ($client, $user, @args) = @_;
    my $nick = $client->{nick};
    my $message = join (' ', @args);
    if ((defined $message) && ($message ne '')) {
        my $command = "signon $message";
        $self->add_command ($user, $command);
        $client->msg ($user, "Added signon message $message");
    } else {
        $client->msg ($user, "Error: Use \"\@msg nagbot !signon <Message>\"");
    }
}

# *Van* !ping 5 Remember to check the pizza.             | Received
# $h{'van'} = 'ping 5 Remember to check the pizza.';     | Stored
# -> *Van* (1) Ping 5 -> Remember to check the pizza.    | Sent
#
# Parse and add a ping message, then add it to the event queue.
sub ping_message {
    my $self = shift;
    my ($manager, $client, $user, $interval, @args) = @_;
    my $message = join (' ', @args);
    if (!@args && !defined $interval) {
        $client->msg ($user, "Pong.");
    } else {
        if (defined $message && $message ne '' && defined $interval
               && $interval ne '') {
            my $command = join (' ', 'ping', $interval, $message);
            $self->add_command ($user, $command);
            $manager->enqueue ($interval * 60 + time(), sub { $self->do_ping ($manager, $client, $user, $message) });
            $self->good_message($client, $user);
            $client->msg ($user, "Added ping message for every $interval minutes");
        } else {
            my $nick = $client->{nick};
            $client->msg ($user, "Error: Use \"\%$nick ping <Interval> <Message>\".");
        }
    }
}

# *Sabre* !alarm 3:32pm est Order dinner.                | Received
# $h{'sabre'} = '1 alarm 12:32pm pst Order dinner.';     | Stored
# -> *Sabre* (1) Alarm -> Order dinner.!                 | Sent
#
# Sets an alarm message for a certain user.
sub alarm_message {
    my $self = shift;
    my ($manager, $client, $user, @args) = @_;
    my ($pingtime, $err, $offset, $now, $diff, $number, $zone);
    my $done = 0;
    my $timeset = shift (@args);

    # Find the time for the alarm to go off.  Either "+0h0m" or "+0m" format.
    if ($timeset =~ /^\+((\d+)h)?(\d+)m$/) {
        if (defined $2) { $offset = (($2 * 60) + $3) * 60 }
        else            { $offset = $3 * 60               }
        $pingtime = $offset + time();

    # Time has been cruelly and viciously been sent in a bad format.
    } else { $done = 1 }

    # If the time format wasn't bad, add this message to the file and
    # the event queue.
    if (!$done) {
        my $message = join (' ', @args);

        # Fri Nov 14 04:28 AM EST
        my $date_format = "%a %b %e %I:%M %p %Z";
        my $time = time2str($date_format, $pingtime);

        # Add the command to the file and queue, and send the user the
        # added message.
        $self->add_command ($user, join (' ', 'alarm', $time, $message));
        $manager->enqueue ($pingtime, sub { $self->do_ping ($manager, $client, $user, $message) });
        $client->msg ($user, "Added alarm for $time.");
    } else { $client->msg ($user, "Error in !alarm: \"$timeset\" not valid.") }
}

# Lists all active messages for a user.
sub list_message {
    my $self = shift;
    my ($client, $user) = @_;
    my @messages = $self->all_commands ($user);
    $client->msg ($user, "Start listing");
    for (my $i = 0; $i <= $#messages; $i++) {
        $client->msg ($user, "($i) $messages[$i]");
    }
    $client->msg ($user, "Done listing");
}

############################################################################
# Main routine
############################################################################

sub new {
    my $class = shift;
    my ($client) = @_;

    my $self = {};
    bless ($self, $class);
    $self->maxbad(10);
    return $self;
}

# The maximum number of times we can get back a message that a user
#  we're messaging does not exist before we purge their ping messages.
#  Remember that if we're connected to multiple servers with one bot,
#  this number needs to be higher to account for the bad pings on the
#  backup server.  OTOH, we reset the number to zero each time a good
#  message goes through, so this isn't as bad as it might sound.
sub maxbad {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{MAXBAD} = shift }
    return $self->{MAXBAD};
}

sub startup {
    my $self = shift;
}

sub return_help {
    my $self = shift;
    my %help;
    %help = (
             'ping' =>     ['Syntax:  ping [<Interval> <Message>]',
                            'No arguments, pongs.  With arguments, sends a message every interval.',
                           ],
             'signon' =>   ['Syntax:  signon <Message>',
                            'Sends a message every time you sign on.',
                           ],
             'alarm' =>    ['Syntax:  alarm +<Hours>h<Minutes>m <Message>',
                            'Sets a message to be sent to you at a certain time.',
                           ],
             'listmsg' =>  ['Syntax:  listmsg',
                            'Lists all ping, alarm, and signon messages',
                            ],
             'clearmsg' => ['Syntax:  clearmsg <Number> [Number] [Number]...',
                            'Clears a ping, alarm, or signon message',
                           ],
            );
    return %help;
}


sub return_commands {
    my $self = shift;
    my (@commands) = ('clearmsg',
                      'listmsg',
                      'alarm',
                      'ping',
                      'signon',
                     );
    return @commands;
}


sub handle_line {
    my $self = shift;
    my ($manager, $client, $line, %result) = @_;

    if ($result{'code'} == C_CONNECT) {
        $self->check_signon ($client, $result{'name'});
        $self->good_message ($client, $result{'name'});
        return 0;

    # We got unknown user message to one of our /msg's.
    } elsif ($result{'code'} == C_E_USER_BAD) {
        $self->bad_message ($client, lc $result{'s1'});
        return 0;

    # Command message.  Reset the bad message count for the user to 0
    # and execute the command.
    } elsif (($result{'code'} == C_WHIS) && !$result{'on_channels'} &&
             ($result{'s1'} !~ /^- /)) {
        $self->good_message ($client, $result{'name'});

        my $message = $result{'s1'};
        $message =~ s/\s+$//;
        my ($command, @args) = split (/ +/,$message);
        if ($command eq 'clearmsg')   {
            $self->clear_message ($client, $result{'name'}, @args);
            return 1;
        }
        elsif ($command eq 'signon')  {
            $self->signon_message ($client, $result{'name'}, @args);
            return 1;
        }
        elsif ($command eq 'ping')    {
            $self->ping_message ($manager, $client, $result{'name'}, @args);
            return 1;
        }
        elsif ($command eq 'alarm')   {
            $self->alarm_message ($manager, $client, $result{'name'}, @args);
            return 1;
        }
        elsif ($command eq 'listmsg')    {
            $self->list_message ($client, $result{'name'});
            return 1;
        }
    }
    return 0;
}
