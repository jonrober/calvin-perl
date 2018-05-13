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
use Getopt::Long qw(GetOptionsFromString);
use IO::File;
use POSIX qw(strftime);
use Storable;

# Comment out for systems compiled without support for crypt(), if you
#  have Crypt.pm.
#use Crypt;

use strict;

############################################################################
# Session list handling commands.
############################################################################

# Because there are so many options possible to session-list, we throw it
# through Getopt::Long for parsing.
sub parse_session_list {
    my $self = shift;
    my ($client, $user, $request) = @_;

    # Set our options and defaults.
    my @options = ('players=s', 'older-than=s', 'password=s', 'fuzzy', 'exact',
                   'noplayers', 'pending', 'active', 'all');
    my %args = ('players'    => '',
                'password'   => undef,
                'older-than' => 0,
                'fuzzy'      => 0,
                'noplayers'  => 0,
                'pending'    => 0,
                'active'     => 0,
                'all'        => 0,
    );

    # Parse the arguments.  Anything not an option should be thrown away
    # normally, but if we didn't succeed it can be used for error message.
    my ($success, $remaining_args) = GetOptionsFromString($request, \%args,
                                                          @options);
    if (! $success) {
        my $error = "Problem parsing list request at '" .
                    join (' ', @{$remaining_args}) . "'";
        $client->msg ($user, $error);
        return undef;
    }

    # Now do a little jiggering of the values for mutually exclusive defaults.
    $args{active} = 1 if $args{pending} == 0;
    $args{'older_than'} = $args{'older-than'};

    return %args;
}

############################################################################
# Logfile commands.
############################################################################

# Returns the time for a timestamp format.  This is currently '#time()# '.
sub get_time {
    my $self = shift;
    return '#'.time().'# ';
}

# Return the present year, month, day.  This is only used to determine
#  when to roll over logs.  Really, this could just return the day and
#  work fine.
sub get_today {
    my $self = shift;
    my ($sec, $min, $hour, $day, $month, $year) = localtime(time);
    return $year.$month.$day;
}

# Return the name of the present day's logfile.  The logfile will
#  be in the format YYYY-MM-DD-base.log, where `base' is a string
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
    return $logname;
}

# Return the name of the present day's offset file.  The offset file will
#  be in the format .offset-YYYY-MM-DD-base.log, where `base' is a string
#  assigned in configuration.
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

# Adds a line to the offset file.  This line will indicate the joining
#  of a new channel, or what channels the bot is on during a rollover.
sub add_offset {
    my $self = shift;
    my ($line, $channel, $tag, $default) = @_;
    my ($fh, $pos);

    # Get the unique identifier for the log in question, if it is a session.
    my %sessions = $self->sessions();
    my $found = '';
    my $baretag = $tag;
    $baretag =~ s#^\[(.*)\]$#$1#;
    $baretag =~ s# \(Cont\.\)##;
    foreach my $name (%sessions) {

	# If tag and channel match, then we say that the session matches
	#  this invite.
	if (defined $sessions{$name}->{'tag'}
	    && $sessions{$name}->{'tag'} eq $baretag
	    && $sessions{$name}->{'channel'} == $channel) {

	    $found = $name;
	    last;
	}
    }

    # Pad the channel number for prettification.
    if (length ($channel) == 1) { $channel .= ' ' }

    # If this is a default channel, we don't care about the line the
    #  log starts on.
    if (defined $default && $default) {
        $pos = 0;

	# Otherwise, find the position offset that the log for this channel starts
	#  on by taking our current position in the filehandle and subtracting the
	#  characters in the invite line.
    } else {
        $fh = $self->{FILE};
        $pos = $fh->tell() - length ($line);
    }

    # If we found a session for the log, we add the identifier
    if ($found) {
	my $identifier = $sessions{$found}->{'identifier'};
	$line = "$channel $tag $pos $identifier\n";
    } else {
	$line = "$channel $tag $pos\n";
    }

    # Actually print the notification to our offset file now!
    my $offset_fh = $self->{OFFSET_FILE};
    $offset_fh->print ($line);
}

# Check to see if the log directory exists, creating it if not.
sub check_logdir {
    my ($self, $client, $logname) = @_;

    # Find the log directory by removing the log name from the end of the
    #  full directory/logname, then remove the ending / as well.
    my $logdir = $logname;
    $logdir =~ s/^((.+?\/)*)(.*)$/$1/;
    $logdir =~ s/^(.*)\/$/$1/;

	# Create the logdir if it does not exist.
    if (!-e $logdir) {
        mkdir ($logdir, 0750) or
            ($client->quit("Exiting: Cambot can't create directory: $!"));
    }
}

# Returns lines from a channel that were sent in a certain period of time.
sub loglines_time {
    my $self = shift;
    my ($findchan, $time) = @_;
    my (@spamlines, @files, $start_time, $foundstart, $code, $channel,
                  $is_numeric);

    @spamlines = ();
    $foundstart = 0;
    $start_time = time() - $time * 60;

    # Check and see if the range of time falls into yesterday's log.
    #  Since we can't know *exactly* when rollover occurs (Without keeping
    #  record?  No, then this won't work when the bot's shut down and
    #  restored.), we have to subtract 10 minutes from the interval.
    if ((localtime($start_time - 60 * 10))[3] != (localtime(time()))[3]) {
        my $fname = $self->logdir."/".
            $self->get_logname($start_time - 60 * 24);
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

# Returns a number of lines from a channel, in a list.
sub loglines_lines {
    my $self = shift;
    my ($channel, $lines) = @_;
    my (@spamlines);

    @spamlines = $self->chan_lines($channel);
    while ($#spamlines >= $lines) { shift @spamlines }
    return @spamlines;
}

# Creates a queue to delay sending an array of lines to a user by one line
#  per second, to avoid killing a client.  Not really a worry unless someone
#  sets the amount of lines that can be spammed to higher than usual, but good
#  to have this just in case.
sub queue_line {
    my $self = shift;
    my ($manager, $client, $user, @lines) = @_;

    # Remove the first line of those to be spammed and send it to the client.
    my $grabline = shift @lines;
    $client->msg ($user, $grabline);

    # So long as there are lines left, queue up another iteration of this
    #  function to run in one second.
    if ($#lines >= 0) {
        $manager->enqueue (1 + time(), sub { $self->queue_line ($manager, $client, $user, @lines) });
    }
}

# Add a line to our records of backlog for each channel.  Fairly simple, just
#  cleans the line and passes it along to the method for handling channel
#  lines.
sub record_line {
    my $self = shift;
    my ($channel, $line) = @_;
    chomp $line;
    $self->chan_lines($channel, $line);
}

# Remove the server's numeric codes from a line to make it human readable,
#  then returns the cleaned line.
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
# Saved status commands
############################################################################

# Prints out all sessions to a status file, which may then be reloaded upon
#  startup.
sub sessions_to_file {
    my $self = shift;
    my ($logdir, $session_file);

    # Get the name of the sessions file.
    $logdir = $self->logdir();
    $session_file = $logdir.'/.sessions';

    store $self->{SESSIONS}, $session_file;
}

# Reads all sessions from a file, into the list of sessions.  To be run on
#  startup of the bot to restore from a previous state.
sub sessions_from_file {
    my $self = shift;
    my ($logdir, $session_file);

    # Get the name of the sessions file.
    $logdir = $self->logdir();
    $session_file = $logdir.'/.sessions';

    if (-e $session_file) {
	$self->{SESSIONS} = retrieve($session_file);
    }
}

############################################################################
# Session commands
############################################################################

# Prints out all sessions.  Here simply for testing purposes...
sub session_dump {
    my $self = shift;

    my %sessions = $self->sessions();
    foreach my $name (keys %sessions) {
	print "$name\n";
	print "\tTag:", $sessions{$name}->{'tag'}, "\n";
	print "\tLines:\n";
	foreach my $line (@{$sessions{$name}->{'lines'}}) {
	    print "\t\t$line\n";
	}
    }
}

# Checks to see if we have more than the allowed number of sessions, and if so
#  then deletes the oldest existing one.  Used to keep us from adding and
#  adding and adding...
sub clean_sessions {
    my $self = shift;

    # Check to see if we're above the maximum allowed sessions and return if
    #  not.  No need to clean unless we're already full!
    my %sessions = $self->sessions();
    my $max_items = $self->max_sessions();
    return unless ((keys %sessions) >= $max_items);

    # Go through each entry to find the one with the earliest update time.
    #  We want to find the name of that entry so that we can delete it.
    my $earliest_name = '';
    my $earliest_time = 0;
    foreach my $name (keys %sessions) {
	my $log = $sessions{$name};
	if (!$earliest_time || $log->{'time'} < $earliest_time) {
	    $earliest_name = $name;
	    $earliest_time = $log->{'time'};
	}
    }

    # If there was indeed such a name (the array isn't empty), then we
    #  remove that entry.  Of course, if the array is empty, we shouldn't
    #  be cleaning anyway.
    $self->clear_session($earliest_name) if $earliest_name;
}

# Spam session backlog lines to a channel.
sub spam_session {
    my $self = shift;
    my ($client, $user, $channel, @lines) = @_;

    # Spam the lines.  Add a front buffer text so that we can know to not
    #  log these lines...
    my $spamflag = $self->spamflag();
    foreach my $line (@lines) {
	$client->msg ($channel, "$spamflag $line");
    }
}

# Given the command to join a channel and spam session data, pull that info
#  and then pass along to the normal join command.
sub session_join_cmd {
    my $self = shift;
    my ($client, $user, $name, $channel, @args) = @_;
    my ($arg, $now, $logmsg, $quiet, $force, $nospam, $tag, $base);
    $quiet = $nospam = $force = $base = 0;
    $tag = '';

    # Right off the bat, see if this session exists.
    my %session = $self->sessions();
    if (!defined $name) {
        $client->msg ($user, "Please give the name of the session to log.");
        return;
    } elsif (!exists $session{$name}) {
        $client->msg ($user, "Could not find session '$name'.");
        return;
    }

    # Reads in any arguments sent to the bot.  "-quiet" as an argument keeps
    #  the bot from sending an acknowledge to the user who sent the command.
    #  "-force" forces a join, even if the bot thinks it is already on the
    #  requested channel.  "-nospam" keeps us from spamming lines for the
    #  channel pre-invite.  "-base" marks this as a base channel.  Anything
    #  else is added together into a tag to be sent in a message to the
    #  joined channel.
    foreach $arg (@args) {
        if    ((lc($arg) eq '-quiet')  || (lc($arg) eq '-q'))  { $quiet  = 1 }
        elsif ((lc($arg) eq '-nospam') || (lc($arg) eq '-n'))  { $nospam = 1 }
        elsif ((lc($arg) eq '-force')  || (lc($arg) eq '-f'))  { $force  = 1 }
        elsif ((lc($arg) eq '-base')   || (lc($arg) eq '-b'))  { $base   = 1 }
        else  { $tag .= ' '.$arg }
    }

    # Handle channel and tag.. clean up the tag and then set it and the channel
    #  to the defaults for the session unless they were given here.
    $tag =~ s/^\s+//;
    $tag = $session{$name}->{'tag'} unless $tag;
    $channel = $session{$name}->{'channel'} unless defined $channel;

    # If we've previously joined the channel, and the tag doesn't end with a
    #  continue notice, append that continue notice.  Also, make the
    #  indicator for first joining go false.
    if (!$session{$name}->{'firstjoin'} && $tag !~ /\(Cont\.?\)$/) {
		$tag .= ' (Cont.)';
    }
    $session{$name}->{'firstjoin'} = 0;

    # Now do any needed updates to the sessions.  Update channel and tag,
    #  in case we've been sent new ones.
    my $session_tag = $tag;
    $session_tag =~ s# \(Cont\.\)$##;
    $self->update_session($name, $channel, $session_tag);

    # Now rebuild the args and pass on to our normal join command.  Also
    #  add the arg '-spam' to the argument list unless we've asked for nospam.
    my @newargs = split(/ /, $tag);
    unshift (@newargs, "-spam=$name") unless $nospam;
    unshift (@newargs, '-quiet') if $quiet;
    unshift (@newargs, '-force') if $force;
    unshift (@newargs, '-base')  if $base;
    $self->join_cmd($client, $user, $channel, @newargs);
}

# Check to see if two array refs (one for players in a scene, one for
#  players searched for) match exactly.
sub player_exact_search {
    my $self = shift;
    my ($players, $search) = @_;
    my @search = sort @{$search};

    no warnings;  # silence spurious -w undef complaints
    return 0 unless @$players == @search;
    for (my $i = 0; $i < @$players; $i++) {
        return 0 if $players->[$i] ne $search[$i];
    }
    return 1;
}

# See if all members of one array are in the array reference of players.
sub search_array {
    my $self = shift;
    my ($array_ref, @search) = @_;
    @search = sort @search;

    # For each search player, search our players array to see if the
    #  player exists in it.
    foreach my $player (@search) {
	my $found = 0;
	foreach (@{$array_ref}) {
	    if ($_ eq $player) {
		$found = 1;
		last;
	    }
	}

	# If we did not find this term, then return false.
	return 0 unless $found;
    }

    # Now we've searched each player and found them all, so success.
    return 1;
}

# Change the name of a session.
sub session_rename_cmd {
    my $self = shift;
    my ($client, $user, $source, $dest) = @_;
    my %session = $self->sessions();

    # Check for the source and destination both to be sent us.
    if (!$source) {
	$client->msg ($user, "Error: Did not include source session.");
    } elsif (!$dest) {
	$client->msg ($user, "Error: Did not include dest session.");

    # Check to ensure the old session does exist and the new does not.
    } elsif (!exists $session{$source}) {
	$client->msg ($user, "Error: Source session '$source' does not exist.");
    } elsif (exists $session{$dest}) {
	$client->msg ($user, "Error: Destination session '$dest' already exists.");

    # Okay, we're clear.  Do the move and update the sessions file.
    } else {
	$self->rename_session($source, $dest);
	$client->msg ($user, "Renamed session '$source' to '$dest'.");
	$self->sessions_to_file();
    }
}

# Given the command to list all session data, print it out to the requester.
sub session_list_cmd {
    my $self = shift;
    my ($manager, $client, $user, @request) = @_;

    # Parse out arguments for our request.
    my $request = join (' ', @request);
    my %args = $self->parse_session_list($client, $user, $request);
    return unless %args;

    # If we had a recall password set, pop off the last value and see if
    #  it matches our password.  Complain and leave if the user neglected
    #  to give us a password or gave us the wrong password.
    if ($self->recall_passwd ne '') {
        if (!defined $args{password}) {
            $client->msg ($user, "Error: Password required.");
            return 0;
        } elsif (crypt($args{password}, 'jr') ne $self->recall_passwd) {
            $client->msg ($user, "Error: Bad password.");
            return 0;
        }
    }

    my @search_players = split(',', $args{players});

    # Grab all sessions, sort them by the session name, and then iterate
    #  through each.
    my %session = $self->sessions();
    my @session_keys = sort { $a cmp $b } keys %session;
    my @lines;
    foreach my $name (@session_keys) {
        my ($log, $players, $line);
        $log = $session{$name};

        # First our all/active/pending check.  If nothing is set then we
        # assume we want to see active lines only.  If all is set, then we
        # don't care about these checks at all.
        if ($args{all} == 0) {
            next if $args{pending} && defined $log->{lines};
            next if $args{active}  && ! defined $log->{lines};;
        }

        # Request for logs with no players.
        next if $args{noplayers} && $log->{players};

        # Search for given players.  We assume an exact search unless fuzzy is
        # explicitly requested.
        if (@search_players) {
            next unless $log->{players};

            if ($args{fuzzy}) {
                next unless $self->search_array($log->{players},
                                                @search_players);
            } else {
                next unless $self->player_exact_search($log->{players},
                                                       \@search_players);
            }
        }

        # Sessions not used within a certain number of days.
        if ($args{older_than}) {
            my $starttime = time - 60 * 60 * 24 * $args{older_than};
            next if $log->{time} > $starttime;
        }

        # Make the players, or a no player string.
        if ($log->{players}) {
            $players = join (', ', @{$log->{players}});
        } else {
            $players = 'No players';
        }

        # Annnd print.
        my $date = strftime("%Y-%m-%d", localtime($log->{time}));
        $line = sprintf("%s: (%s) (%s) (Ch: %s) %s", $name, $players, $date,
                        $log->{channel}, $log->{tag});
        push(@lines, $line);
    }

    if (@lines) {
#        $manager->enqueue(1 + time(),
#                          sub { $self->queue_line ($manager, $client,
#                                                   $user, @lines) });
        foreach my $line (@lines) {
            $client->msg($user, $line);
        }
    } else {
        $client->msg($user, "No sessions were found that match your query.");
    }
}

# Create a new session in the session tables.  If we are at our limit, then
#  delete the oldest session.
sub session_create_cmd {
	my $self = shift;
	my ($client, $user, $name, $channel, @args) = @_;
	my $tag = join(' ', @args);

	# Make sure we've had name for the session and its tag both sent.
	if (defined $name && $name ne '' && defined $tag && $tag ne ''
		&& defined $channel && $channel !~ /\D/) {

		# Make sure that we do not already have a session with this
                #  name defined.
		my %sessions  = $self->sessions();
		if (!exists $sessions{$name}) {

			# Go to our cleaner to make sure we never get too many sessions.  If
			#  there are too many, it will delete the oldest before we add.
			$self->clean_sessions();

			# Create the session and inform the user.
			$self->add_session($name, $channel, $tag);
			$client->msg ($user, "Added session '$name' with tag '$tag'.");

			# Write all sessions to a Storable file.
			$self->sessions_to_file();

		} else {
			$client->msg ($user, "A session with name '$name' already exists.");
		}

	} else {

		# If there was a problem with the data, tell the user about it.
		$channel ||= '';
		$name ||= '';
		$tag ||= '';
		$client->msg ($user, "There was a problem adding session '$name' on on channel '$channel' with tag '$tag'.");
	}

}

# Change the players defined to a session.  This simply gives us a way to
#  search on sessions.
sub session_changeplayers_cmd {
	my $self = shift;
	my ($client, $user, $name, @players) = @_;

	# Check for data all sent properly.
	if (defined $name && $name  ne '' && @players > 0) {

		# Make sure the players are sorted for consistent formatting.
                @players = sort @players;

		# Ensure that the session in question actually exists.
		my %sessions = $self->sessions();
		if (exists $sessions{$name}) {

			# Make the players sent the new listed players for this session.
			$self->change_session_players($name, @players);
			my $player_str = join (', ', @players);
			$client->msg ($user, "'$player_str' have been added to session '$name'.");

			# Write all sessions to a Storable file.
			$self->sessions_to_file();

		# Error message if the session did not exist.
		} else {
			$client->msg ($user, "The session '$name' does not exist!");
		}
	} else {

		# If there was a problem with the data, tell the user about it.
		$client->msg ($user, "There was a problem with your request to add players to '$name'.");
	}
}

# Destroy a session, removing all data for it.
sub session_destroy_cmd {
	my $self = shift;
	my ($client, $user, $session_name) = @_;
	my $found = 0;

	# Make sure we actually have a session name.
	if (defined $session_name && $session_name ne '') {
		my %session = $self->sessions();

		# Look through each session.  If we find one with a name that matches,
		#  delete that entry, mark our search as successful, and break out of
		#  the loop.
		foreach my $name (keys %session) {
			my $log = $session{$name};
			if ($name eq $session_name) {
				$self->clear_session($name);
				$found = 1;
				last;
			}
		}
	}

	# Message the user to tell them if we found the entry they requested or
	#  not.
	if ($found) {
		$client->msg ($user, "Entry '$session_name' was found and removed.");

		# Write all sessions to a Storable file.
		$self->sessions_to_file();

	} else {
		$client->msg ($user, "Entry '$session_name' could not be found.");
	}

}

# When we're leaving a channel, check to see if it's a sessioned connect.  If
#  so, update the lines for backlog and the time we last used this session.
sub leave_session_check {
    my $self = shift;
    my ($client, $user, $channel, $tag) = @_;

    # Remove a continue note on the end of a tag.
    $tag =~ s# \(Cont\.\)$##;

    my %sessions = $self->sessions();
    my $found = '';
    foreach my $name (%sessions) {

		# If tag and channel match, then we say that the session matches
		#  this invite.
		if (defined($sessions{$name}->{'tag'})
				&& $sessions{$name}->{'tag'} eq $tag
				&& defined($sessions{$name}->{'channel'})
				&& $sessions{$name}->{'channel'} == $channel) {
		    $found = $name;
		    last;
		}
    }

    # We did find a session!  Now we do the updates...
    if ($found) {

        # Update -- the channel and tag don't change, but this updates the
        #  time as well.
        $self->update_session($found, $channel, $tag);

        # Grab the last few lines from the channel for later spamming.
        my @lines = $self->loglines_lines($channel, '15');
        $self->change_session_backlog($found, @lines);

        # Update the sessions file with this new data.
        $self->sessions_to_file();
    }

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
        if (($channel !~ /\D/) && ($channel >= 0) &&
            ($channel <= $self->high_channel)) {

            if ($self->is_permanent($channel)) {
                $client->msg ($user, "I'm not supposed to leave channel $channel.");
            } else {
                if (!$quiet) {
                    $client->msg ($user, "Okay, I'll quit logging $channel.");
                }
                $tag = $self->on_channel ($channel);
                $now = localtime;

                # Check to see if this is a sessioned channel and do needed
                #  updates if so.
                $self->leave_session_check($client, $user, $channel, $tag);

               # Remove this channel from the autojoin list!
                $self->autojoin($channel, '');

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
    my ($arg, $now, $logmsg, $quiet, $nospam, $force, $tag, $base, $spam);
    $quiet = $force = $base = $nospam = $spam = 0;
    $tag = '';

    # Reads in any arguments sent to the bot.  "-quiet" as an argument keeps
    #  the bot from sending an acknowledge to the user who sent the command.
    #  "-force" forces a join, even if the bot thinks it is already on the
    #  requested channel.  "-nospam" keeps us from spamming lines for the
    #  channel pre-invite, but is only here in case someone accidentally sends
    #  it to a normal join -- it only matters with a session join, and is
    #  taken care of there.  "-base" marks this as a base channel.  Anything
    #  else is added together into a tag to be sent in a message to the
    #  joined channel.
    foreach $arg (@args) {
        if    ((lc($arg) eq '-quiet')  || (lc($arg) eq '-q'))  { $quiet  = 1 }
        elsif ((lc($arg) eq '-nospam') || (lc($arg) eq '-n'))  { $nospam = 1 }
        elsif ((lc($arg) eq '-force')  || (lc($arg) eq '-f'))  { $force  = 1 }
        elsif ((lc($arg) eq '-base')   || (lc($arg) eq '-b'))  { $base   = 1 }
        elsif (($arg =~ /^-spam=(.*)$/i))                      { $spam  = $1 }
        else  { $tag .= ' '.$arg }
    }

    # Take out any extra spaces from the tag, and give an error message
    #  if no tag was specified.
    $tag =~ s/^\s+//;
    if ($tag eq '') {
        $client->msg ($user, "Sorry, you must specify a channel tag.");
    } else {

        # Make sure that we're not already on the channel.
        if ((!defined $self->on_channel($channel)) || $force) {

            # Make sure the requested channel is a valid channel.
            if (($channel !~ /\D/) && ($channel >= 0) &&
                ($channel <= $self->high_channel)) {

                # Unless we have the quiet flag, then send ack to inviter.
                $client->msg ($user, "Okay, I'll log $channel.") unless $quiet;

                # We want this to be a base channel.. join it!
                if ($base) { $self->autojoin($channel, $tag) }

                # If we were sent here via a session spam command, pause to
                #  grab the lines in that session's backlog.
                my @lines;
                if ($spam) {
                    my %sessions = $self->sessions();
                    if ($sessions{$spam}->{'lines'}) {
                        @lines = @{$sessions{$spam}->{'lines'}};
                    }
                }

                # If we're to spam pre-invite, do now.
                if ($spam && !$self->spam_after_invite()) {
                    $self->spam_session($client,  $user, $channel, @lines);
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

                # If we're to spam *after* the invite, do now.
                if ($spam && $self->spam_after_invite()) {
                    $self->spam_session($client,  $user, $channel, @lines);
                }

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

    # If the bot has a recall password set, make sure that we have a correct
    #  password sent us.  If not, drop out of this function after sending an
    #  error to the user.
    if ($self->recall_passwd ne '') {
        if (!defined $passwd) {
            $client->msg ($user, "Error: Password required.");
            return 0;
        } elsif (crypt($passwd, 'jr') ne $self->recall_passwd) {
            $client->msg ($user, "Error: Bad password.");
            return 0;
        }
    }

    # Make sure we actually are allowed to use the recall commands.
    if (!$self->enable_recall) {
        $client->msg ($user, "recall commands are not enabled.");
        return 0;
    }

    # If the user forgot to send us the required arguments, remind them how to
    #  use the command.
    if (!defined $channel or !defined $span) {
        if ($type eq 'readlog') {
            $client->msg ($user, "Usage: \"readlog <channel> <time>\".");
        } elsif ($type eq 'recall') {
            $client->msg ($user, "Usage: \"recall <channel> <lines>\".");
        } elsif ($type eq 'spamrecall') {
            $client->msg ($user, "Usage: \"spamrecall <channel> <lines>\".");
	}
        return 0;
    }

    # Check to make sure the channel is valid...
    if ($channel !~ /\D/ and $channel >= 0 and $channel <= $self->high_channel) {

	# For a readlog, check validity of the time period we're given, and
	#  grab the lines for that time if it's valid, or send error and drop
	#  out if it is not.
        if ($type eq 'readlog') {
            if ($span !~ /\D/ and $span > 0 and $span < $self->max_readlog) {
                @lines = $self->loglines_time ($channel, $span);
            } else {
                $client->msg ($user, "Sorry, $span is an invalid time interval.");
                return 0;
            }

	# For a recchan or spamrecchan, check validity of the number of lines
	#  requested, and grab those lines if the number is valid, or send error
	#  and drop out if it is not.  If it's a spamrecall, wrap it in a
	#  beginning and end line to make sure we can tell the user.
        } elsif ($type eq 'recall' || $type eq 'spamrecall') {
            if ($span !~ /\D/ and $span > 0 and $span <= $self->max_recchan) {
                @lines = $self->loglines_lines ($channel, $span);
		if ($type eq 'spamrecall') {
		    unshift(@lines, "Spam requested by $user.");
		    push(@lines, "End spam.");
		}
            } else {
                $client->msg ($user, "Sorry, $span is an invalid number of lines.");
                return 0;
            }
        }

	# Send to the user, unless it's a spamrecall and then send to channel.
	my $destination = $user;
	$destination = $channel if $type eq 'spamrecall';

	# So long as we actually have lines to spam, add them to a queue
	#  to start spamming in one second.  This is to prevent spam killing
	#  a client.
        if (@lines) {
            $manager->enqueue (1 + time(), sub { $self->queue_line ($manager, $client, $destination, @lines) });
            return 1;
        } else {
            $client->msg ($user, "Sorry, I have no lines to spam.");
			return 0;
        }
    } else {
        $client->msg ($user, "Sorry, $channel is an invalid channel.");
		return 0;
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
#            $client->quit("Exiting: Cambot could not open file $logname");
            $client->quit("Exiting: Cambot could not open file.");
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
#            $client->quit("Exiting: Cambot could not open file $logname");
            $client->quit("Exiting: Cambot could not open file.");
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
#            $client->quit("Exiting: Cambot could not open offset file $offsetname.\n");
            $client->quit("Exiting: Cambot could not open offset file.\n");
        }
        $offset_fh->autoflush();
        $self->{OFFSET_FILE} = $offset_fh;

        # Reset autojoined channels.
        my @autojoins = $self->autojoin;
        for (my $i = 0; $i <= $self->high_channel; $i++) {
            if ($autojoins[$i]) { $self->inactive_defaults ($i, 1) }
        }

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
	    sleep 1;
        }
    }
}


# Open a log.  We only want to do it this way at startup.
sub openlog {
    my $self = shift;
    my ($client) = @_;

    # Reset autojoined channels.
    my @autojoins = $self->autojoin;
    for (my $i = 0; $i <= $self->high_channel; $i++) {
        if ($autojoins[$i]) { $self->inactive_defaults ($i, 1) }
    }

    # Get logfile name
    my $logname = $self->logdir."/".$self->get_logname(time);
    $self->check_logdir($client, $logname);
    $self->fname($logname);

    # Open logfile.
    my $fh = new IO::File $logname, "a", 644;
    if (!defined $fh) {
#        $client->quit("Exiting: Cambot could not open logfile $logname.\n");
        $client->quit("Exiting: Cambot could not open logfile.\n");
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
#  about it or change it or anything.  Good god, these are a lot of comments
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
    return if $channel =~ /\D/;
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
# Methods to track session data.
############################################################################

# Keep track of all sessions.  In the form of:
#  %sessions = (
#               {
#                  Channel => 3,
#                  Tag     => 'Jon - Testing Cambot',
#                  Last    => <timestamp>,
#                  Lines   => ('line', 'line', 'line'),
#               },
#               ...
#              );
sub sessions {
    my $self = shift;
    return %{$self->{SESSIONS}};
}


# Removes an entry from the session records, given the the name for
#  that entry.  Returns all sessions post-removal.
sub clear_session {
    my $self = shift;
    my ($name) = @_;

    if (defined($name)) {
	delete (${$self->{SESSIONS}}{$name});
    }

    return %{$self->{SESSIONS}};
}

# Add a session to the hash of them all.  Return the sessions hash after
#  completion.
sub add_session {
    my $self = shift;
    if (@_) {
        my ($name, $channel, $tag) = @_;
        my $time = time();
        my $rec = {};
        $rec->{identifier} = $time.'-'.$name;
        $rec->{tag}        = $tag;
        $rec->{firstjoin}  = 1;
        $rec->{time}       = $time;
        $rec->{channel}    = $channel;
        $rec->{lines}      = undef;
        $rec->{players}    = ();

        ${$self->{SESSIONS}}{$name} = $rec;
    }
    return %{$self->{SESSIONS}};
}

# Rename a session, given the original and new names.  Return the hash of all
#  sessions after completion.
sub rename_session {
    my $self = shift;
    if (@_) {
        my ($source, $dest) = @_;
        ${$self->{SESSIONS}}{$dest} = ${$self->{SESSIONS}}{$source};
        delete (${$self->{SESSIONS}}{$source});
    }
    return %{$self->{SESSIONS}};
}

# Update one session out of the whole.  Return the hash after completion.
#  This is very similar to add_session, however there we want to create an
#  entirely new record with empty lines and players. Here we want to preserve
#  and just update channel/tag/time.
sub update_session {
    my $self = shift;
    if (@_) {
        my ($name, $channel, $tag) = @_;

        # Update each of the entries...
        ${$self->{SESSIONS}}{$name}->{'channel'} = $channel;
        ${$self->{SESSIONS}}{$name}->{'tag'}     = $tag;
        ${$self->{SESSIONS}}{$name}->{'time'}    = time();

    }
    return %{$self->{SESSIONS}};
}

# Change the list of players for a session.  Returns the hash of all sessions
#  after completion.
sub change_session_players {
    my $self = shift;
    if (@_) {
        my ($name, @players) = @_;
        @{${$self->{SESSIONS}}{$name}->{'players'}} = @players;
    }
    return %{$self->{SESSIONS}};
}

# Change the backlog lines for a session.  Returns the hash of all sessions
#  after completion.
sub change_session_backlog {
    my $self = shift;
    if (@_) {
        my ($name, @lines) = @_;

        @{${$self->{SESSIONS}}{$name}->{'lines'}} = @lines;
    }
    return %{$self->{SESSIONS}};
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

# This keeps the list of default channels that haven't yet gotten lines
#  this day.  Just used to then know when to give one a mark in the offsets
#  file.  Reset daily at log rollover (or disconnect), and then one by one
#  cleared as a channel gets lines.
sub inactive_defaults {
    my ($self, $channel, $add) = @_;
    if (defined $channel && defined $add && $add) {
        ${$self->{INACTIVE}}[$channel] = 1;
    } elsif (defined $channel) {
        ${$self->{INACTIVE}}[$channel] = 0;
    }
    if (defined $self->{INACTIVE}) { return @{$self->{INACTIVE}} }
    else                           { return undef                }
}

# Sets the maximum number of sessions, if a value is sent.  Returns the max
#  number of sessions after any change.
sub max_sessions {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{MAX_SESSIONS} = shift }
    return $self->{MAX_SESSIONS};
}

# The flag to decide if, in a session-spam, we spam the lines before or after
#  we join the channel.
sub spam_after_invite {
	my $self = shift;
	if (@_ && defined $_[0]) { $self->{SPAM_AFTER_INVITE} = shift }
	return $self->{SPAM_AFTER_INVITE};
}

# Returns the flag placed at the start of any session-join spams.  If a value
#  is sent us, also sets that flag to the value.
sub spamflag {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{SPAMFLAG} = shift }
    return $self->{SPAMFLAG};
}

# Sets the logdir if one is sent.  Returns the logging directory.
sub logdir {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{LOGDIR} = shift }
    return $self->{LOGDIR};
}

# Sets the logdir if one is sent.  Returns the logging directory.
sub fname {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{FNAME} = shift }
    return $self->{FNAME};
}

# Returns a flag of whether or not we add the timestamp to log lines.  If sent
#  a value, change the flag to that value.
sub add_time {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{ADD_TIME} = shift }
    return $self->{ADD_TIME};
}

# Returns a the max lines we can recchan.  If sent a value, change the max
#  lines to that value.
sub max_recchan {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{MAX_RECCHAN} = shift }
    return $self->{MAX_RECCHAN};
}

# Returns the maximum minutes we can look back for a readlog.  If sent a value
#  then change the max minutes to that value.
sub max_readlog {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{MAX_READLOG} = shift }
    return $self->{MAX_READLOG};
}

# Returns a flag of whether or not we allow getting backlog from the bot via
#  request.  If sent a value, change the flag to that value.
sub enable_recall {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{ENABLE_RECALL} = shift }
    return $self->{ENABLE_RECALL};
}

sub use_numerics {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{USE_NUMERICS} = shift }
    return $self->{USE_NUMERICS};
}

sub recall_passwd {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{RECALL_PASSWD} = shift }
    return $self->{RECALL_PASSWD};
}

# Sets the base name of the logfile if one is sent.  Returns the base name.
sub basename {
    my $self = shift;
    if (@_ && defined $_[0]) { $self->{BASENAME} = shift }
    return $self->{BASENAME};
}

# Sets the list of channels not to leave if it is sent.  Returns the list of
#  channels not to leave.  Oh, I dunno.  See a trend?
sub perm_channels {
    my $self = shift;
    my (@chans);

    if (defined $_) {
        foreach (@_)     { push (@chans, split (/ /, $_))    }
        foreach (@chans) { ${$self->{PERM_CHANNELS}}[$_] = 1 }
    }

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
    %{$self->{SESSIONS}} = ();

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

    $self->spamflag('BACK:');
    $self->max_sessions(20);
	$self->spam_after_invite(0);

    return $self;
}

# Things run when a Calvin::Client is created and the bots are attached to it.
sub startup {
    my $self = shift;
    my ($client) = @_;
    $self->sessions_from_file();
    $self->openlog($client);
}

# Return a hash of help messages, the keys being the command to get help on.
sub return_help {
    my $self = shift;
    my %help;
    %help = (
             'log' =>     ['Syntax:  log <channel> <tag> [-quiet] [-force] [-base]',
                           'Command can be \'log\', \'invite\', or \'join\'',
                           'Logs a channel using <tag> for the purpose.',
                           '-quiet makes it not ack the user.',
                           '-base makes it mark as a channel where the bot stays overnight.',
                          ],
             'join' =>    ['Syntax:  log <channel> <tag> [-quiet] [-force] [-base]',
                           'Command can be \'log\', \'invite\', or \'join\'',
                           'Logs a channel using <tag> for the purpose.',
                           '-quiet makes it not ack the user.',
                           '-base makes it mark as a channel where the bot stays overnight.',
                          ],
             'invite' =>  ['Syntax:  log <channel> <tag> [-quiet] [-force] [-base]',
                           'Command can be \'log\', \'invite\', or \'join\'',
                           'Logs a channel using <tag> for the purpose.',
                           '-quiet makes it not ack the request to the user.',
                           '-base makes it mark as a channel where the bot stays overnight.',
                          ],
             'logbase' => ['Synonym for: log <channel> <tag> -base',
                          ],
             'joinbase' => ['Synonym for: join <channel> <tag> -base',
                           ],
             'invitebase' =>  ['Synonym for: invite <channel> <tag> -base',,
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
                           'Shows the past <lines> lines on botted <channel> to the requesting user.',
                           'Valid lines are from 1 to 10, inclusive.',
                          ],
             'spamchan' => ['spamchan <channel> <lines>',
                           'Shows the past <lines> lines on botted <channel> on the botted <channel>.',
                           'Valid lines are from 1 to 10, inclusive.',
                          ],
             'session-log' => [
                           'Syntax: session-log <session> [channel] [tag] [-quiet] [-force]',
                           'Logs a channel previously defined in a session.',
                           'Channel and tag will default to the previous values if not present.',
                           '-quiet makes it not ack the request to the user.',
                          ],
             'session-join' => [
                           'Syntax: session-log <session> [channel] [tag] [-quiet] [-force]',
                           'Logs a channel previously defined in a session.',
                           'Channel and tag will default to the previous values if not present.',
                           '-quiet makes it not ack the request to the user.',
                          ],
             'session-invite' => [
                           'Syntax: session-log <session> [channel] [tag] [-quiet] [-force]',
                           'Logs a channel previously defined in a session.',
                           'Channel and tag will default to the previous values if not present.',
                           '-quiet makes it not ack the request to the user.',
                          ],
             'session-create' => [
                           'Syntax: session-create <session> <channel> <tag>',
                           'Creates a new named session with the specified starting channel and tag.',
                          ],
             'session-remove' => [
                           'Syntax: session-destroy <session>',
                           'Removes an existing session',
                          ],
             'session-rename' => [
                           'Syntax: session-rename <source> <dest>',
                           'Renames an existing session from <source> to <dest>',
                          ],
             'session-list' => [
                           'Syntax: session-list [--player <player,player,player>] [--older-than <days>]',
                           '                     [--fuzzy] [--all] [--noplayers] [--pending] [--active]',
                           'Shows a list of sessions defined, with many options.  You can display',
                           'a list of players (fuzzy lets you see those players plus any others),',
                           'those still pending a scene, those without assigned players, and those',
                           'older than a set number of days.',
                          ],
             'session-players' => [
                           'Syntax: session-players <session> [player] ... [player]',
                           'Adds a space-seperated list of players to a session.',
                          ],
            );
    return %help;
}

# Return a list of valid commands for this bot.
sub return_commands {
    my $self = shift;
    my (@commands) = (
                      'log',
                      'logbase',
                      'stop',
                      'tag',
                      'readlog',
                      'recchan',
                      'spamchan',
                      'session-invite',
                      'session-create',
                      'session-remove',
                      'session-list',
                      'session-rename',
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
        $message =~ s/\t/ /;
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
        elsif (($command eq 'invitebase') || ($command eq 'logbase') ||
               ($command eq 'joinbase')) {
            push (@args, '-base');
            $self->join_cmd ($client, $result{'name'}, @args);
            return 1;
        }
	elsif (($command eq 'session-invite') || ($command eq 'session-log') ||
               ($command eq 'session-join')) {
            $self->session_join_cmd ($client, $result{'name'}, @args);
            return 1;
        }
        elsif (($command eq 'session-create')) {
            $self->session_create_cmd ($client, $result{'name'}, @args);
            return 1;
        }
        elsif (($command eq 'session-remove')) {
            $self->session_destroy_cmd ($client, $result{'name'}, @args);
            return 1;
        }
        elsif (($command eq 'session-list')) {
            $self->session_list_cmd ($manager, $client, $result{'name'}, @args);
            return 1;
        }
        elsif (($command eq 'session-players')) {
            $self->session_changeplayers_cmd ($client, $result{'name'}, @args);
            return 1;
        }
        elsif (($command eq 'session-rename')) {
            $self->session_rename_cmd ($client, $result{'name'}, @args);
            return 1;
        }

# Testing only.
#        elsif (($command eq 'session-dump')) {
#            $self->sessions_to_file();
#            $self->session_dump();
#            return 1;
#        }

        elsif ($command eq 'tag') {
            $self->show_tag ($client, $result{'name'}, @args);
            return 1;
        }
        elsif ($command eq 'readlog') {
            $self->spam_log ($manager, $client, $result{'name'}, 'readlog', @args);
            return 1;
        }
        elsif ($command eq 'recchan') {
            $self->spam_log ($manager, $client, $result{'name'}, 'recall', @args);
            return 1;
        }
        elsif ($command eq 'spamchan') {
            $self->spam_log ($manager, $client, $result{'name'}, 'spamrecall', @args);
            return 1;
        }
    } else {
        my ($nick) = $client->{nick};

        # What we have here is a log joining line, from this bot.  If the
        #  channel's an autojoin channel, it gets an offset tag denoting this,
        #  otherwise, the standard.  Then we clear it in the list of inactive
        #  channels for the day, whether or not it's actually there.
        if ($result{'line'} =~ /^<\d+: $nick\d*> - Starting to log channel (\d+) (\[.*\]) at /) {
            my @autojoins = $self->autojoin;
            if (defined $autojoins[$1] && $autojoins[$1]) {
                $self->add_offset ($result{'line'}, $1, $2, 1);
            } else {
                $self->add_offset ($result{'line'}, $1, $2);
            }
            $self->inactive_defaults ($result{'channel'}, 0);
        }

        # And here we have a say line, or a pose, or a ppose, or any line
        #  actually going to a channel.  Record it in that channel's buffer.
        #  Then if it's a channel in the inactive default list, drop it into
        #  the offset file as well and clear its entry from said list --
        #  it's a default channel with the first line today.
        if ($line =~ /^10\d{2} /) {
            $self->record_line ($result{'channel'}, $result{'line'});

            my @inactives = $self->inactive_defaults;
            my $channel = $result{'channel'};
            if ($inactives[$channel]) {
                $self->inactive_defaults ($channel, 0);
                my @autojoins = $self->autojoin;
                my $tag = $autojoins[$channel];
                $self->add_offset ($result{'line'}, $channel, "[$tag]", 1);
            }
        }

        # And before we actually print the nice line, check to see if we
        #  want the timestamp added, and if we want to remove numerics.
        if ($self->add_time)      { $newdate = $self->get_time           }
        if (!$self->use_numerics) { $line = $self->clear_numerics($line) }

        $fh->print ("$newdate$line\n");
    }

    return 0;
}

1;
