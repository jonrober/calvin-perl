package Calvin::Bots::Cambot;
require 5.002;

# cambot -- A Calvin bot to lurk certain channels and save to a log.
#           Copyright 1997 by Jon Robertson <jonrober@eyrie.org>
#           From a tf script by Matthew Gerber
#
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.
#
# This bot is designed to record logs to a certain directory.  There
# are both channels that are loaded and joined on startup, and channels
# that the bot can never be dismissed from.

############################################################################
# Modules and declarations
############################################################################

use Calvin::Client;
use Calvin::Manager;
use Calvin::Parse qw (:constants);
use Date::Parse;
use IO::File;
use POSIX;
#use Crypt;

use strict;


############################################################################
# Logfile commands.
############################################################################

sub get_time {
    my $self = shift;
    #    return (strftime ("#%X %Z# ", localtime()));
    return '#'.time().'# ';
}

# Return the present year, month, day.  This is only used to determine
#  when to roll over logs.  Really, this could just return the day and
#  work fine.
sub get_today {
    my $self = shift;
    my ($sec, $min, $hour, $day, $month, $year) = localtime(time);
    return $year.$month.$day;
    #return $day.$hour.$min;
}

# Return the name of the present day's logfile.  The logfile will
#  be in the format YY-MM-DD-base.log, where `base' is a string
#  assigned in configuration.
sub get_logname {
    my $self = shift;
    my ($time) = @_;
    my ($sec, $min, $hour, $day, $month, $year) = localtime($time);
    $month++;
    $month = sprintf ("%02d", $month);
    $day   = sprintf ("%02d", $day);
    $year += 1900;
    my $base = $self->basename();
    my $logname = "$year-$month/$year-$month-$day-$base.log";
    #    my $logname = "$year-$month/$day-$hour-$min-$base.log";
    return $logname;
}

sub get_offsetname {
    my $self = shift;
    my ($time) = @_;
    my ($sec, $min, $hour, $day, $month, $year) = localtime($time);
    $month++;
    $month = sprintf ("%02d", $month);
    $day   = sprintf ("%02d", $day);
    $year += 1900;
    my $base = $self->basename();
    my $logname = "$year-$month/.offset-$year-$month-$day-$base.log";
    return $logname;
}

sub add_offset {
    my $self = shift;
    my ($line, $channel, $tag) = @_;

    if (length ($channel) == 1) { $channel .= ' ' }
    
    my $fh = $self->{FILE};
    my $pos = $fh->tell() - length ($line);

    my $offset_fh = $self->{OFFSET_FILE};
    $offset_fh->print ("$channel $tag $pos\n");
}

# Check to see if the directory exists, make it if not.
sub check_logdir {
    my ($self, $client, $logname) = @_;

    my $logdir;
    ($logdir) = $logname =~ /^((.+?\/)*)(.*)$/;
    ($logdir) = $logdir =~ /^(.*)\/$/;

    if (!(-e $logdir)) {
        mkdir ($logdir, 0750) or
            ($client->quit("Exiting: Cambot can't create directory: $!"));
    }
}

sub loglines_time {
    my $self = shift;
    my ($findchan, $time) = @_;
    my (@spamlines, @files, $start_time, $foundstart, $code, $channel,
                  $is_numeric);

    @spamlines = ();
    $foundstart = 0;
    $start_time = time() - $time * 60;

    # Check and see if the range of time falls into yesterday's log.
    #  Since we can't know *exactly* when rollover occurs (without
    #  keeping record?), we have to subtract 10 minutes from the interval. 
    if (strftime ("%e", localtime($start_time - 60 * 10)) !=
                 strftime ("%e", localtime(time()))) {
        my $fname = $self->logdir."/".$self->get_logname($start_time - 60 * 24);
        push (@files, $fname);
    }

    push (@files, $self->fname);
    foreach my $filename (@files) {
        $is_numeric = 0;
        open (SPAMFILE, $filename) or next;
        while (<SPAMFILE>) {
            my $line = $_;
            chomp $line;
            my $now = '';
            if ($line =~ s/^#(\d+)# //) { $now = $1 }
            else                        { next      }

            if ($line =~ /^% Numerics on\./) { $is_numeric = 1 }

            next unless $is_numeric;
            next unless ($line =~ /^10\d{2} / && $line =~ /\|c$findchan\|E/);

            $line = $self->clear_numerics($line);
            if ($foundstart) { push (@spamlines, $line) }
            elsif ($now >= $start_time) {
                push (@spamlines, $line);
                $foundstart = 1;
            }
        }
    }
    if (!$is_numeric && $#spamlines < 0) {
        push (@spamlines, "Readlog will not work: Logs are not numeric.");
    }
    return @spamlines;
}


sub loglines_lines {
    my $self = shift;
    my ($channel, $lines) = @_;
    my (@spamlines);

    @spamlines = $self->chan_lines($channel);
    while ($#spamlines >= $lines) { shift @spamlines }
    return @spamlines;
}

# Do a queue to delay sending an array of lines to a user by one line
#  per second.
sub queue_line {
    my $self = shift;
    my ($manager, $client, $user, @lines) = @_;
    my $grabline = shift @lines;
    $client->msg ($user, $grabline);
    if ($#lines >= 0) {
        $manager->enqueue (1 + time(), sub { $self->queue_line ($manager, $client, $user, @lines) });
    }
}

sub record_line {
    my $self = shift;
    my ($channel, $line) = @_;
    chomp $line;
    $self->chan_lines($channel, $line);
}

sub clear_numerics {
    my $self = shift;
    my ($line) = @_;

    # Remove numeric number and delimiters.
    $line =~ s/^\d{4} //;
    $line =~ s/\|.(.*?)\|E/$1/g;
    $line =~ s/\\1/\\/g;
    $line =~ s/\\2/|/g;
    return $line;
}



############################################################################
# Basic commands
############################################################################

# Leaves a channel on a user command.
sub leave_cmd {
    my $self = shift;
    my ($client, $user, $channel, @args) = @_;
    my ($tag, $now, $endmsg, $arg, $quiet, $force);

    $quiet = $force = 0;
    
    # Check to see if the "-quiet" or "-force" tags have been sent with
    #  the command.  "-quiet" tells the bot not to acknowledge the leave
    #  request.  "-force" forces a leave, even if the bot claims that it
    #  is not on the channel.  "-force" should never be needed unless
    #  something has really gone wrong.
    foreach $arg (@args) {
        if    (($arg =~ /^-quiet$/i) || ($arg =~ /^-q$/i)) { $quiet = 1 }
        elsif (($arg =~ /^-force$/i) || ($arg =~ /^-f$/i)) { $force = 1 }
    }

    # Check to make sure the bot is on the channel before trying to leave.
    if ((defined $self->on_channel($channel)) || $force) {

        # Make sure the channel sent is a valid number 0 and the high channel.
        if (($channel !~ /\D/) and ($channel >= 0) and
            ($channel <= $self->high_channel)) {

            if ($self->is_permanent($channel)) {
                $client->msg ($user, "I'm not supposed to leave channel $channel.");
            } else {
                if (!$quiet) {
                    $client->msg ($user, "Okay, I'll quit logging $channel.");
                }
                $tag = $self->on_channel ($channel);
                $now = localtime;

                # Send a message to the channel that we're leaving, then
                #  remove the channel from the array of channels we're on
                #  and send a leave command to the server.
                $endmsg = "Ending log of channel $channel [$tag] at $now by $user\'s request.";
                $self->off_channel ($channel);
                $client->public ($channel, $endmsg);
                $client->leave ($channel);
                $self->clear_lines($channel);
            }

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
    my ($arg, $now, $logmsg, $quiet, $force, $tag);
    $quiet = $force = 0;
    $tag = '';

    # Reads in any arguments sent to the bot.  "-quiet" as an argument keeps
    #  the bot from sending an acknowledge to the user who sent the command.
    #  "-force" forces a join, even if the bot thinks it is already on the
    #  requested channel.  Anything else is added together into a tag to be
    #  sent in a message to the joined channel.
    foreach $arg (@args) {
        if    (($arg =~ /^-quiet$/i) || ($arg =~ /^-q$/i)) { $quiet = 1 }
        elsif (($arg =~ /^-force$/i) || ($arg =~ /^-f$/i)) { $force = 1 }
        else  { $tag .= ' '.$arg }
    }

    # Take out any extra spaces from the tag, and give an error message
    #  if no tag was specified.
    $tag =~ s/^\s+//;
    if ($tag eq '') { 
        $client->msg ($user, "Sorry, you must specify a channel tag.");
    } else {

        # Make sure that we're not already on the channel.
        if ((!defined $self->on_channel($channel)) or $force) {

            # Make sure the requested channel is a valid channel.
            if ($channel !~ /\D/ and $channel >= 0 and
                         ($channel <= $self->high_channel)) {

                if (!$quiet) {
                    $client->msg ($user, "Okay, I'll log $channel.");
                }
                $now = localtime;
                $logmsg = "Starting to log channel $channel [$tag] at $now by $user\'s request.";

                # Add the channel as joined in our array of channels we're on.
                #  Then send a join command to the server, send a message to the
                #  joined channel, and display a @u and @list for the joined
                #  channel.
                $self->on_channel ($channel, $tag);
                $client->join ($channel);
                $client->public ($channel, $logmsg);
                $client->raw_send ("\@users $channel\n");
                $client->raw_send ("\@list $channel\n");

            } else {
                $client->msg ($user, "Sorry, $channel is an invalid channel.");
            }
        } else {
            $client->msg ($user, "I'm already logging channel $channel.");
        }
    }
}

# When given a channel and a time in minutes, returns all lines from
#  that channel in the timespan.
sub spam_log {
    my $self = shift;
    my ($manager, $client, $user, $type, @args) = @_;
    my ($channel, $span, $passwd) = @args;
    my (@lines);
    
    if ($self->recall_passwd ne '') {
        if (!defined $passwd) {
            $client->msg ($user, "Error: Password required.");
            return;
        } elsif (crypt($passwd, 'jr') ne $self->recall_passwd) {
            $client->msg ($user, "Error: Bad password.");
            return;
        }
    }

    if (!$self->enable_recall) {
        $client->msg ($user, "recchan and readlog not enabled.");
        return;
    }
    
    if (!defined $channel or !defined $span) {
        if ($type == 1) {
            $client->msg ($user, "Usage: \"readlog <channel> <time>\".");
        } elsif ($type == 2) {
            $client->msg ($user, "Usage: \"recall <channel> <lines>\".");
        }
        return 0;
    }

    if ($channel !~ /\D/ and $channel >= 0 and $channel <= $self->high_channel) {
        if ($type == 1) {
            if ($span !~ /\D/ and $span > 0 and $span < $self->max_readlog) {
                @lines = $self->loglines_time ($channel, $span);
            } else {
                $client->msg ($user, "Sorry, $span is an invalid time interval.");
                return 0;
            }
        } elsif ($type == 2) {
            if ($span !~ /\D/ and $span > 0 and $span <= $self->max_recchan) {
                @lines = $self->loglines_lines ($channel, $span);
            } else {
                $client->msg ($user, "Sorry, $span is an invalid number of lines.");
                return 0;
            }
        }
                
        if (@lines) {
            $manager->enqueue (1 + time(), sub { $self->queue_line ($manager, $client, $user, @lines) });
        } else {
            $client->msg ($user, "Sorry, I have no lines to spam.");
        }
    } else {
        $client->msg ($user, "Sorry, $channel is an invalid channel.");
    }        
}

# On request, show either the tag of a certain channel to a user in private
#  message, or show all channels the bot is on and their tags.
sub show_tag {
    my $self = shift;
    my ($client, $user, $channel, $passwd) = @_;
    my ($tag);

    if ($self->recall_passwd ne '') {
        if (!defined $passwd) {
            $client->msg ($user, "Error: Password required.");
            return;
        } elsif (crypt($passwd, 'jr') ne $self->recall_passwd) {
            $client->msg ($user, "Error: Bad password.");
            return;
        }
    }

    # See if the user has asked for the tag of a certain channel.
    if (($channel !~ /\D/) and ($channel >= 0) and
        ($channel <= $self->high_channel)) {
        if ($tag = $self->on_channel($channel)) {
            $client->msg ($user, "Channel $channel: [$tag].");
        } else {
            $client->msg ($user, "I'm not on channel $channel.");
        }

    # See if the user has asked for all joined channels and their tags.
    } elsif ($channel eq '*') {
        for my $key (0 .. $self->high_channel) {
            if ($tag = $self->on_channel($key)) {
                my $msg = sprintf ("Channel %2d: [%s].", $key, $tag);
                $client->msg ($user, $msg);
            }
        }

    # Otherwise, the user has asked for some weird channel.  Send error.
    } else { $client->msg ($user, "Invalid channel: $channel.") }
}

# Check to see if the time has passed on to the next day, and roll over to a
#  new log if so.
sub check_time {
    my $self = shift;
    my ($client) = @_;
    my ($key, $tag);
    my $new_day = $self->get_today();

    # Check to see if the date has changed since the last time it was checked.
    if ($new_day != $self->date) {
        $self->date ($new_day);
        my $now = localtime;
        my $logname = $self->logdir."/".$self->get_logname(time);
        $self->check_logdir($client, $logname);
        $self->fname($logname);
        
        # Create a temporary filehandle to write the opening message and tag
        #  spams.  This is so that calsplit won't have to do any happy
        #  loops waiting for the new file to be created when it reaches the
        #  closing message of the old -- the new file will exist before the
        #  old has the closing message written to.
        my $newfh = new IO::File $logname, "a", 644;
        my $newdate = '';
        if (defined $newfh) {
            $newfh->autoflush();
            if ($self->add_time) {
                $newdate = $self->get_time;
            }
            $newfh->print ("$newdate\% $client->{nick} opening logfile at $now.\n");
            if ($self->use_numerics) {
                $newfh->print ("$newdate\% Numerics on.\n");
            } else {
                $newfh->print ("$newdate\% Numerics off.\n");
            }
            
            # Write all existing tags to the beginning of the logfile.
            for my $i (0 .. $self->high_channel) {
                $tag = $self->on_channel($i);
                if ($tag) {
                    if ($self->add_time) {
                        $newdate = $self->get_time;
                    }
                    $newfh->print ("$newdate\% Channel $i: [$tag]\n")
                }
            }

            $newfh->close;
        } else {
            $client->quit("Exiting: Cambot could not open file $logname");
        }

        # Close the old file.
        my $fh = $self->{FILE};
        if ($self->add_time) {
            $newdate = $self->get_time;
        }
        $fh->print ("$newdate\% $client->{nick} closing logfile at $now.\n");
        $self->{FILE}->close;
        $fh->close;
        
        # Reopen the new file, then save it to the non-temp filehandle.
        $fh = new IO::File $logname, "a", 644;
        if (!defined $fh) {
            $client->quit("Exiting: Cambot could not open file $logname");
        }
        $fh->autoflush();
        $self->{FILE} = $fh;

        # Send @u's for all joined channels, for nick tracking.
        for (my $i = 0; $i <= $self->high_channel; $i++) {
            if (defined $self->on_channel($i)) { $client->raw_send("\@u $i\n") }
        }

        # Close the old offset file and open the new offset file.
        my $offset_fh = $self->{OFFSET_FILE};
        $offset_fh->close;
        my $offsetname = $self->logdir.'/'.$self->get_offsetname(time);
        $offset_fh = new IO::File $offsetname, "a", 644;
        if (!defined $offset_fh) {
            $client->quit("Exiting: Cambot could not open offset file $offsetname.\n");
        }
        $offset_fh->autoflush();
        $self->{OFFSET_FILE} = $offset_fh;
    }
    return;
}


# Does the startup sends for Cambot, namely sending the messages we want
#  in the log and then joining all autojoin channels.
sub on_connect {
    my $self = shift;
    my ($manager, $client) = @_;
    my ($channel);

    # We're on no channels, so clear things out in the array of channels we're
    #  on.
    $self->{ON_CHANNELS} = undef;

    # Send all the pretty messages we want in the logfile upon connecting.
    $client->raw_send ("\@motd\n");
    $client->raw_send ("\@users *\n");
    $client->raw_send ("\@listall\n");

    # Go through the channels we're to autojoin, joining each one.
    my @joinchans = $self->autojoin;
    for (my $chan = 0; $chan <= $self->high_channel; $chan++) {
        my $tag = $joinchans[$chan];
        if (defined $tag) {
            $self->join_cmd ($client, $client->{nick}, $chan, $tag, "-quiet");
        }
    }
}


# Open a log.  We only want to do it this way at startup.
sub openlog {
    my $self = shift;
    my ($client) = @_;
    
    # Get logfile name
    my $logname = $self->logdir."/".$self->get_logname(time);
    $self->check_logdir($client, $logname);
    $self->fname($logname);

    # Open logfile.
    my $fh = new IO::File $logname, "a", 644;
    if (!defined $fh) {
        $client->quit("Exiting: Cambot could not open logfile $logname.\n");
    }
    $fh->autoflush();
    my $now = localtime;
    my $newdate = '';
    if ($self->add_time) {
        $newdate = $self->get_time;
    }
    $fh->print ("$newdate\% $client->{nick} opening logfile at $now.\n");
    if ($self->use_numerics) { $fh->print ("$newdate\% Numerics on.\n")  }
    else                     { $fh->print ("$newdate\% Numerics off.\n") }

    $self->{FILE} = $fh;

    my $offsetname = $self->logdir.'/'.$self->get_offsetname(time);
    my $offset_fh = new IO::File $offsetname, "a", 644;
    if (!defined $offset_fh) {
        $client->quit("Exiting: Cambot could not open offset file $offsetname.\n");
    }
    $offset_fh->autoflush();
    $self->{OFFSET_FILE} = $offset_fh;
}

# Set the highest channel on the server.  Should always be 31.  *Could* be
#  used to restrict the server to only channels lower than a certain channel.
#  It'd also be possible to use this and a few easy changes in the join and
#  leave to restrict the bot to a range of joinable channels, but we don't
#  need this and aren't likely to.  Just ignore this and don't really think
#  about it or change it or anything.  Good god, this is a lot of comments
#  for 5 measley lines of code.
sub high_channel {
    my $self = shift;
    if (@_) { $self->{HIGH_CHANNEL} = shift }
    return $self->{HIGH_CHANNEL};
}

# Sets the date if one is sent.  Returns the date.  Used only in figuring out
#  when to roll over a log.
sub date {
    my $self = shift;
    if (@_) { $self->{DATE} = shift }
    return $self->{DATE};
}

############################################################################
# Methods to track channels we are on and their tags.
############################################################################

# When sent a channel and tag, sets the tag for that channel to indicate the
#  channel has been joined.  When just sent a channel, returns the tag or
#  undef.
sub on_channel {
    my $self = shift;
    my ($channel, $tag) = @_;
    if (defined $channel && defined $tag) {
        ${$self->{ON_CHANNELS}}[$channel] = $tag;
    }
    return ${$self->{ON_CHANNELS}}[$channel];
}

# Sets a channel tag to undef, indicating that we're not on the channel.
sub off_channel {
    my $self = shift;
    my ($channel) = @_;
    if (defined $channel) {
        ${$self->{ON_CHANNELS}}[$channel] = undef;
    }
}

############################################################################
# Outside methods.
############################################################################

# If a channel and tag are sent, adds them to the list of channels to
#  automatically join on connect.  Returns the list of all autojoin channels.
sub autojoin {
    my ($self, $channel, $tag) = @_;
    if (defined $channel and defined $tag) {
        ${$self->{AUTOJOIN}}[$channel] = $tag;
    }
    if (defined $self->{AUTOJOIN}) { return @{$self->{AUTOJOIN}} }
    else                           { return undef                }
}

# Sets the logdir if one is sent.  Returns the logging directory.
sub logdir {
    my $self = shift;
    if (@_) { $self->{LOGDIR} = shift }
    return $self->{LOGDIR};
}

# Sets the logdir if one is sent.  Returns the logging directory.
sub fname {
    my $self = shift;
    if (@_) { $self->{FNAME} = shift }
    return $self->{FNAME};
}

sub add_time {
    my $self = shift;
    if (@_) { $self->{ADD_TIME} = shift }
    return $self->{ADD_TIME};
}

sub max_recchan {
    my $self = shift;
    if (@_) { $self->{MAX_RECCHAN} = shift }
    return $self->{MAX_RECCHAN};
}

sub max_readlog {
    my $self = shift;
    if (@_) { $self->{MAX_READLOG} = shift }
    return $self->{MAX_READLOG};
}

sub enable_recall {
    my $self = shift;
    if (@_) { $self->{ENABLE_RECALL} = shift }
    return $self->{ENABLE_RECALL};
}

sub use_numerics {
    my $self = shift;
    if (@_) { $self->{USE_NUMERICS} = shift }
    return $self->{USE_NUMERICS};
}

sub recall_passwd {
    my $self = shift;
    if (@_) { $self->{RECALL_PASSWD} = shift }
    return $self->{RECALL_PASSWD};
}

# Sets the base name of the logfile if one is sent.  Returns the base name.
sub basename {
    my $self = shift;
    if (@_) { $self->{BASENAME} = shift }
    return $self->{BASENAME};
}

# Sets the list of channels not to leave if it is sent.  Returns the list of
#  channels not to leave.  Oh, I dunno.  See a trend?
sub perm_channels {
    my $self = shift;
    foreach (@_) { ${$self->{PERM_CHANNELS}}[$_] = 1 }

    if (defined $self->{PERM_CHANNELS}) { return @{$self->{PERM_CHANNELS}} }
    else                                { return undef                     }
}

# Checks to see if a channel is set never to leave.
sub is_permanent {
    my $self = shift;
    my ($channel) = @_;

    if    (!defined $self->{PERM_CHANNELS})       { return 0 }
    elsif (!defined $channel)                     { return 0 }
    elsif (!${$self->{PERM_CHANNELS}}[$channel])  { return 0 }

    else { return ${$self->{PERM_CHANNELS}}[$channel] }
}

sub clear_lines {
    my $self = shift;
    my ($channel) = @_;
    if ($channel !~ /\D/ and $channel >= 0 and
                 $channel <= $self->high_channel) {
        @{${$self->{CHAN_LINES}}[$channel]} = ();
    }
}

sub chan_lines {
    my $self = shift;
    my ($channel, $line) = @_;

    if (defined $line) {
        if ($#{${$self->{CHAN_LINES}}[$channel]} >= ($self->max_recchan - 1)) {
            shift @{${$self->{CHAN_LINES}}[$channel]};
        }
        push (@{${$self->{CHAN_LINES}}[$channel]}, $line);
    }
                
    if (defined $self->on_channel($channel)) {
        return (@{${$self->{CHAN_LINES}}[$channel]})
    } else { return () }
}

# Creates a new Cambot object.
sub new {
    my $class = shift;
    my ($client) = @_;

    umask 022;
    my $self = {};
    bless ($self, $class);
    $self->{AUTOJOIN} = undef;
    $self->{ON_CHANNELS} = undef;
    $self->{PERM_CHANNELS} = undef;
    $self->{CHAN_LINES} = undef;
    $self->add_time(1);
    $self->use_numerics(1);
    $self->max_recchan(10);
    $self->max_readlog(1000);
    $self->enable_recall(1);
    $self->recall_passwd('');
    $self->high_channel(31);
    $self->logdir ('.');
    $self->basename ('public');
    $self->date($self->get_today);

    return $self;
}

# Things run when a Calvin::Client is created and the bots are attached to it.
sub startup {
    my $self = shift;
    my ($client) = @_;
    $self->openlog($client);
}

# Return a hash of help messages, the keys being the command to get help on.
sub return_help {
    my $self = shift;
    my %help;
    %help = (
             'log' =>     ['Syntax:  log <channel> <tag> [-quiet] [-force]',
                           'Command can be \'log\', \'invite\', or \'join\'',
                           'Logs a channel using <tag> for the purpose.',
                           '-quiet makes it not ack the user.',
                          ],
             'join' =>    ['Syntax:  log <channel> <tag> [-quiet] [-force]',
                           'Command can be \'log\', \'invite\', or \'join\'',
                           'Logs a channel using <tag> for the purpose.',
                           '-quiet makes it not ack the user.',
                          ],
             'invite' =>  ['Syntax:  log <channel> <tag> [-quiet] [-force]',
                           'Command can be \'log\', \'invite\', or \'join\'',
                           'Logs a channel using <tag> for the purpose.',
                           '-quiet makes it not ack the request to the user.',
                          ],
             'stoplog' => ['stop <channel> [-quiet] [-force]',
                           'Command can be \'stoplog\', \'stop\', \'dismiss\', or \'leave\'',
                           'Dismisses the logging of a channel.',
                           '-quiet makes it not ack the request to the user.',
                          ],
             'stop' =>    ['stop <channel> [-quiet] [-force]',
                           'Command can be \'stoplog\', \'stop\', \'dismiss\', or \'leave\'',
                           'Dismisses the logging of a channel.',
                           '-quiet makes it not ack the request to the user.',
                          ],
             'dismiss' => ['stop <channel> [-quiet] [-force]',
                           'Command can be \'stoplog\', \'stop\', \'dismiss\', or \'leave\'',
                           'Dismisses the logging of a channel.',
                           '-quiet makes it not ack the request to the user.',
                          ],
             'leave' =>   ['stop <channel> [-quiet] [-force]',
                           'Command can be \'stoplog\', \'stop\', \'dismiss\', or \'leave\'',
                           'Dismisses the logging of a channel.',
                           '-quiet makes it not ack the request to the user.',
                          ],
             'tag'    =>  ['tag <channel>  OR  tag *',
                           'Shows either tags for a channel or tags for all channels.',
                          ],
             'readlog' => ['readlog <channel> <minutes>',
                           'Shows all lines on botted <channel> in the past <minutes>.',
                           'Valid intervals are from 1 to 30, inclusive.',
                          ],
             'recchan' => ['recchan <channel> <lines>',
                           'Shows the past <lines> lines on botted <channel>.',
                           'Valid lines are from 1 to 10, inclusive.',
                          ],
            );
    return %help;
}

# Return a list of valid commands for this bot.
sub return_commands {
    my $self = shift;
    my (@commands) = (
                      'log',
                      'stop',
                      'tag',
                      'readlog',
                      'recchan',
                     );
    return @commands;
}

# Takes a line and performs any necessary functions on it.  If the line is
#  a command to the bot, return 1.  Return 0 otherwise.  Note that there can
#  be things for which we do functions, but return 0.  These are lines such as
#  signon messages, which more than one bot may wish to know about.
sub handle_line {
    my $self = shift;
    my ($manager, $client, $line, %result) = @_;
    my $fh = $self->{FILE};
    
    $line =~ s/\r//;
        
    my $newdate = '';
    
    # If we have a connect message and it's for the bot, perform the joins
    #  and everything else done on connect.    
    if (($result{'code'} == C_CONNECT) &&
        ($result{'name'} eq $client->{nick})) {
        if ($self->add_time) {
            $newdate = $self->get_time;
        }
        if (!$self->use_numerics) { $line = $self->clear_numerics($line) }
        $fh->print ("$newdate$line\n");
        $self->on_connect ($manager, $client);

    # See if it's time to roll over to the next log.
    } elsif ($result{'code'} == C_S_TIME) {
        $self->check_time ($client);
        
    # Hand off to the appropriate sub based on the command.
    } elsif (($result{'code'} == C_WHIS) && (!$result{'on_channels'})) {

        # If the bot sent the message, drop it.
        if ($result{'s1'} =~ /^- /) { return 0 }
        
        # Parse the message sent us.
        my $message = $result{'s1'};
        $message =~ s/\t/\s/;
        $message =~ s/\s+$//;
        my ($command, @args) = split (/ +/,$message);

        if (!defined $command) {
            $client->msg ($result{'name'}, "Parse error in \"$message\".");
            return 1;
        }

        if (($command eq 'dismiss') || ($command eq 'stop') ||
            ($command eq 'stoplog') || ($command eq 'leave')) {
            $self->leave_cmd ($client, $result{'name'}, @args);
            return 1;
        }
        elsif (($command eq 'invite') || ($command eq 'log') ||
               ($command eq 'join')) {
            $self->join_cmd ($client, $result{'name'}, @args);
            return 1;
        }
        elsif ($command eq 'tag') {
            $self->show_tag ($client, $result{'name'}, @args);
            return 1;
        }
        elsif ($command eq 'readlog') {
            $self->spam_log ($manager, $client, $result{'name'}, 1, @args);
            return 1;
        }
        elsif ($command eq 'recchan') {
            $self->spam_log ($manager, $client, $result{'name'}, 2, @args);
            return 1;
        }
    } else {
        if ($result{'line'} =~ /^<\d+: \S+> - Starting to log channel (\d+) (\[.*\]) at /) {
            $self->add_offset ($result{'line'}, $1, $2);
        }

        if ($line =~ /^10\d{2} /) {
            $self->record_line ($result{'channel'}, $result{'line'});
        }

        if ($self->add_time)      { $newdate = $self->get_time           }
        if (!$self->use_numerics) { $line = $self->clear_numerics($line) }

        $fh->print ("$newdate$line\n");
    }
        
    return 0;
}

1;
