# Calvin::Logs::Split - Functions for handling individual log lines
#
# Copyright 2017 by Jon Robertson <jonrober@eyrie.org>
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

############################################################################
# Modules and declarations
############################################################################

package Calvin::Logs::Split;

use Calvin::Parse qw(:constants);
use Calvin::Logs;
use HTML::Entities;
use Term::ANSIColor qw(:constants color colored);

use strict;
use vars qw();

############################################################################
# Handlers for types of lines
############################################################################

# For public lines, we print if the line channel and requested channel are the
# same.  We also try to find the logger for this channel to use to tell when
# to stop reading the log.
sub line_public {
    my ($self) = @_;

    my $view_channel = $self->channel;
    my $parsed       = $self->parsed;

    my $line_channel = $parsed->{channel};
    my $player       = $parsed->{name};
    my $player_line  = $parsed->{s1};

    return if $line_channel ne $view_channel;

    # This is also the start of a log.  Add the logger if there's not one
    # already.
    if ($player_line =~ /^- Starting to log channel /) {
        $self->logger($player) if !defined $self->logger || $self->logger eq '';

    # Ending log line.  If the player is the same as the bot that started
    # logging, then we stop the log.  This is used to avoid stopping early if
    # another bot was invited by accident and then dismissed.
    } elsif ($player_line =~ /^- Ending log of channel /) {
        $self->do_continue(0) if $player eq $self->logger;
    }

    $self->print_line;
}

# Print a whisper only if we're configured to do so.
sub line_whisper {
    my ($self) = @_;
    my $preferences = $self->preferences;

    $self->print_line if $preferences->{show_whisp};
}

# Show joins for the channel we're on if the user wants to see server lines,
# along with marking the player as seen.
sub line_join {
    my ($self) = @_;

    my $view_channel = $self->channel;
    my $prefs        = $self->preferences;
    my $base         = $self->is_base;
    my $parsed       = $self->parsed;

    my $line_channel = $parsed->{channel};
    my $player       = $parsed->{name};

    return if $line_channel ne $view_channel;

    return if $base  && $prefs->{show_serv};
    return if !$base && $prefs->{show_serv_base};

    $self->player_seen($player, 'seen');
    $self->print_line;
}

# Show leaves for the channel we're on if the user wants to see server lines,
# along with marking the player as no longer seen.
sub line_leave {
    my ($self) = @_;

    my $view_channel = $self->channel;
    my $prefs        = $self->preferences;
    my $base         = $self->is_base;
    my $parsed       = $self->parsed;

    my $line_channel = $parsed->{channel};
    my $player       = $parsed->{name};

    return if $line_channel ne $view_channel;

    return if $base  && $prefs->{show_serv};
    return if !$base && $prefs->{show_serv_base};

    $self->player_seen($player, 'clear');
    $self->print_line;
}

# View a channel topic if we want to see server messages and it's for our
# channel.
sub line_topic {
    my ($self) = @_;

    my $view_channel = $self->channel;
    my $prefs        = $self->preferences;
    my $base         = $self->is_base;
    my $parsed       = $self->parsed;

    my $line_channel = $parsed->{channel};
    my $player       = $parsed->{name};

    return if $line_channel ne $view_channel;

    return if $base  && $prefs->{show_serv};
    return if !$base && $prefs->{show_serv_base};

    $self->print_line;
}

# Signoffs are shown if they're for a player we've seen on a channel we're on.
sub line_signoff {
    my ($self) = @_;

    my $parsed = $self->parsed;
    my $prefs  = $self->preferences;
    my $base   = $self->is_base;

    my $player = $parsed->{name};

    return if $base  && $prefs->{show_serv};
    return if !$base && $prefs->{show_serv_base};

    # Only show the line if we've seen the player in another context.
    return unless $self->player_seen($player);
    $self->player_seen($player, 'clear');
    $self->print_line;
}

# Nick changes are seen if they're for a player we've seen on a channel we're
# on.  At the same time we'll update the player tracking for the new nick.
sub line_nick_change {
    my ($self) = @_;

    my $parsed   = $self->parsed;
    my $prefs    = $self->preferences;
    my $base     = $self->is_base;

    my $old_nick = $parsed->{name};
    my $new_nick = $parsed->{s1};

    return if $base  && $prefs->{show_serv};
    return if !$base && $prefs->{show_serv_base};

    # Return if we're not tracking this nick, otherwise update the nick and
    # display.
    return unless $self->player_seen($old_nick);
    $self->player_seen($old_nick, 'clear');
    $self->player_seen($new_nick, 'seen');
    $self->print_line;
}

# On bot close, attempt to roll over to the next line.
sub line_bot_close {
    my ($self) = @_;

    # Stop if this is a base channel.
    if ($self->is_base) {
        $self->do_continue(0);

    # Attempt to roll over, stopping if it fails.
    } else {
        my $status = $self->rollover;
        $self->do_continue(0) if !defined $status;
    }
}

# We never see a channel list line, but use it to update the list of players we
# can see.
sub line_channel_list {
    my ($self) = @_;

    my $view_channel = $self->channel;
    my $parsed       = $self->parsed;

    my $player       = $parsed->{name};
    my $channels_on  = $parsed->{chans_on};

    foreach my $chan (split / /, $channels_on) {
        next unless $chan == $view_channel;
        $self->player_seen($player, 'seen');
    }
}

############################################################################
# Line processing
############################################################################

# Removes any numeric codes from a line, then returns the line.
sub clean_numerics {
    my ($self, $line) = @_;

    # Remove channel number, numeric number and delimiters.
    $line =~ s/\|c\d+\|E: //;
    $line =~ s/^\d{4} //;
    $line =~ s/\|.(.*?)\|E/$1/g;
    $line =~ s/\\1/\\/g;
    $line =~ s/\\2/|/g;

    return $line;
}

# Removes numeric codes, folds, and then prints a line.
sub print_line {
    my ($self) = @_;

    my $channel    = $self->channel;
    my $color_type = $self->color_type;
    my $line       = $self->line;
    my $prefs      = $self->preferences;
    my $parsed     = $self->parsed;

    my $code       = $parsed->{code};
    my $width      = $prefs->{width};

    # Remove the player bracket from end of line if we're on any non-player
    # channel.
    if ($prefs->{remove_player} && $channel > 1) {
        $line =~ s/^(10[02][5-8] .*) \[\S+\]$/$1/;
    }

    # Remove numerics for printing.
    $line = $self->clean_numerics($line);

    # If we're using ANSI color, look up the correct color and then add it
    #  into the line.
    my ($color);
    if ($color_type eq 'ANSI') {

        # Find the type of color to use.
        if    ($code =~ /^[2-9]\d{3} /) { $color = color($prefs->{'server_color'}) }
        elsif ($code =~ /^11\d{2} /)    { $color = color($prefs->{'whisp_color'})  }
        else                            { $color = color($prefs->{'normal_color'}) }

		# Fold and apply color.
		$line =~ s/(?:(.{1,$width})\s+|(\S{$width}))/$color.(defined($1) ? $1 : $2) . "\n"/eg;

    } elsif ($color_type eq 'HTML') {
	    # Find the type of log so that we may define a CSS tag.
        if    ($code =~ /^[2-9]\d{3} /) { $color = 'server_color' }
        elsif ($code =~ /^11\d{2} /)    { $color = 'whisp_color'  }
        else                            { $color = 'normal_color' }

		# Clean up and then apply the tag.
		chomp $line;
		encode_entities($line);
		$line = "<p class='$color'>$line</p>\n";

    # Otherwise we have no coloring for the line... just clean it up.
    } else {
        $color = '';
		$line =~ s/(?:(.{1,$width})\s+|(\S{$width}))/$color.(defined($1) ? $1 : $2) . "\n"/eg;
    }

    print OUT $line;
}

# Run to start splitting the set log, on the set channel.  This is called when
# the process of running a split is to start, and returns only when the split
# is done.
sub do_split {
    my ($self) = @_;

    my $channel = $self->channel;
    my $fname   = $self->filename;
    my $prefs   = $self->preferences;
    my $offset  = $self->offset;
    my $base    = $self->is_base;
    my $header  = $self->log_header;
    my $dest    = $self->destination;

    my $fh = $self->file('open');

    # Use the log destination to decide how we handle output.  We open a
    # filehandle for it, and potentially feed other information for coloring
    # or mailing.
    if ($dest eq 'screen') {
        unless (-t STDOUT and open(OUT, "| less ".$prefs->{'less_flags'})) {
            open(OUT, '>-') or die "Can't write to STDOUT: $!\n";
        }
        select OUT;
        $| = 1;
        select STDOUT;
        $self->color_type('ANSI');
    } elsif ($dest eq 'email') {
        my $email_settings = $self->email;
        my $subject = $email_settings->{subject};
        my $to      = $email_settings->{to};

        my ($user, $from);
        $user = (getpwuid($<))[0];
        $from = 'Logread <'.$user.'@eyrie.org>';

        open (OUT, '| /usr/lib/sendmail -t -oi -oem $dest')
            or (&endwin && die "Can't open output: $!\n");
        print OUT "To: $to\n";
        print OUT "From: $from\n";
        print OUT "Subject: $subject\n\n";
        $self->color_type('');

    # Save as a plain file.  Open the file and select to use no colors.
    } elsif ($dest eq 'plain_file') {
        return unless open (OUT, "> $dest");
        $self->color_type('');

    # Save as an HTML file.  Open file and select to use HTML colors, then
    #  drop the start of an HTML file (head and opening body).
    } elsif ($dest eq 'html_file') {
        return unless open (OUT, "> $dest");
        $self->color_type('HTML');
		html_opening($fname, $channel);
    }

	print OUT $header, "\n" if defined $header;

    # First go to the offset (if any) and start processing our log up til we
    # either are waiting on input or have been told to stop via do_continue.
    # Cases where we'd stop are usually at end of log (if we're not rolling
    # over) or when the bot leaves the scene.
    seek ($fh, $offset, 1) if defined $offset and $offset > 0;
    $self->do_continue(1);
    local ($SIG{'INT'}) = 'IGNORE';
    while (my $line = <$fh>)  {
        $self->line($line);
        $self->do_line;
        last if !$self->do_continue;
        $fh = $self->file;
    }

    # At this point we have to decide if we're actually done or if we want to
    # follow the log.  We never follow if the log is destined somewhere other
    # than the screen, or if the user settings say not to.
    $self->do_continue(0) if $dest ne 'screen';
    $self->do_continue(0) if !$base && !$prefs->{follow};
    $self->do_continue(0) if $base && !$prefs->{follow_base};

    # Continue following if so, via seek on the filehandle.  Stop on either
    # an interrupt signal, or when the bot is dismissed or we can't roll over
    # anymore.
    local ($SIG{'INT'}) = sub { $self->do_continue(0) };
    while ($self->do_continue) {
        seek($fh, 0, 1)
            || (warn "Error reading from $fname!\n" && $self->do_continue(0));
        sleep 1;
        while (my $line = <$fh>) {
            $self->line($line);
            $self->do_line;
            $fh = $self->file;
        }
    }

    # Done with the log, so send any closing information and restore SIGINT.
    html_closing() if $dest eq 'HTML_file';
    local ($SIG{'INT'}) = 'DEFAULT';

    # Close our files to finish cleaning up.
    close (OUT);
    $self->file('close');
}

# Takes a line from a log file and sees if it should be printed, if we should
# stop splitting, if we should rollover, or a few other needy cases.
sub do_line {
    my ($self) = @_;

    my $base   = $self->is_base;
    my $line   = $self->line;
    my $parsed = $self->parsed;

    my $code   = $parsed->{code};

    # TODO: Neither of these are normal codes, find where used.
    if ($code =~ /^(6001|9999)$/ && !$base) { $self->do_continue(0) }

    # Use line handlers to keep the flow of this function clear.
    # All public line types.
    if    ($code == C_PUBLIC)       { $self->line_public       }
    elsif ($code == C_POSE)         { $self->line_public       }
    elsif ($code == C_PPOSE)        { $self->line_public       }
    elsif ($code == C_ROLL)         { $self->line_public       }
    elsif ($code == C_NARRATE)      { $self->line_public       }
    elsif ($code == C_ALIAS)        { $self->line_public       }
    elsif ($code == C_ALIAS_POSE)   { $self->line_public       }
    elsif ($code == C_ALIAS_PPOSE)  { $self->line_public       }

    # Whisper types.
    elsif ($code == C_WHIS)         { $self->line_whisper      }
    elsif ($code == C_WHIS_POSE)    { $self->line_whisper      }
    elsif ($code == C_WHIS_PPOSE)   { $self->line_whisper      }
    elsif ($code == C_WHIS_ROLL)    { $self->line_whisper      }
    elsif ($code == C_WHIS_NARR)    { $self->line_whisper      }

    # Information about a channel topic.
    elsif ($code == C_S_TOPIC)      { $self->line_topic        }
    elsif ($code == C_TOPIC_CHANGE) { $self->line_topic        }

    # Miscellaneous other things we care about.
    elsif ($code == C_LEAVE)        { $self->line_leave        }
    elsif ($code == C_JOIN)         { $self->line_join         }
    elsif ($code == C_S_LIST)       { $self->line_channel_list }
    elsif ($code == C_SIGNOFF)      { $self->line_signoff      }
    elsif ($code == C_NICK_CHANGE)  { $self->line_nick_change  }

    # Different from the rest, as it's a bot line rather than server line.
    elsif ($line =~ /^% \S+ closing logfile at /) { $self->line_bot_close }

    return '';
}

# Perform a log rollover to the next log, closing the current log, finding the
# next log name, and then opening that new log file.
sub rollover {
    my ($self) = @_;

    my $line  = $self->line;
    my $fname = $self->filename;

    $self->file('close');

    # Get the following logfile.
	my $logobj = Calvin::Logs->new;
	$logobj->filename($fname);
	$fname = $logobj->next_log($line);

    return undef if $fname eq '';

    $self->filename($fname);
    return $self->file('open');
}

######################################################################
# Processing to print HTML
######################################################################

# ANSI attributes and what they should translate to in CSS.
our %HTML_ATTRIBUTES = (
        'bold'       => ['font-weight', 'bold'],
        'dark'       => ['font-weight', 'lighter'],
        'underline'  => ['text-decoration', 'underline'],
        'underscore' => ['text-decoration', 'underline'],
        'blink'      => ['text-decoration', 'blink'],
        'reverse'    => [],
        'concealed'  => ['display', 'none'],
	    );

# Foreground colors and what they should translate to in CSS.  We can use this
#  to tweak colors if desired.
our %HTML_FOREGROUNDS = (
		'black'      => 'black',
		'red'        => 'red',
		'green'      => 'green',
		'yellow'     => 'yellow',
		'blue'       => 'blue',
		'magenta'    => 'magenta',
		'cyan'       => 'cyan',
		'white'      => 'white',
		);

# Background colors and what they should translate to in CSS.  Again, if we
#  want to tweak colors, we can use this to do so.
our %HTML_BACKGROUNDS = ('on_black'   => 'black',
		'on_red'     => 'red',
		'on_green'   => 'green',
		'on_yellow'  => 'yellow',
		'on_blue'    => 'blue',
		'on_magenta' => 'magenta',
		'on_cyan'    => 'cyan',
		'on_white'   => 'white',
		);

# Prints the opening tags for an HTML files.  Opens the html tag, prints the
#  head, and opens the body tag.
sub html_opening {
    my ($self) = @_;

    my $fname   = $self->filename;
    my $channel = $self->channel;
    my $prefs   = $self->preferences;

    print OUT "<html>\n";
    print OUT "\t<head>\n";
    print OUT "\t\t<title>Logs for $fname on channel $channel</title>\n";
    print OUT "\t\t<style type='text/css' media='screen'>\n";
    print OUT "\t\t\tbody\t{ ".$prefs->{'body_css'}." }\n";
    print OUT "\t\t\tp\t{ margin-bottom: -.5em; }\n";
    foreach my $linetype ('normal_color', 'server_color', 'whisp_color') {
        print OUT "\t\t\t", css_color($linetype, $prefs->{$linetype}), "\n";
    }
    print OUT "\t\t</style>\n";
    print OUT "\t</head>\n";
    print OUT "\t<body>\n";
}

# Prints the closing tags for an HTML file.. simply closes the body and html
#  tags.
sub html_closing {
    my ($self) = @_;
    print OUT "\t</body>\n";
    print OUT "</html>\n";
}

# Create CSS codes for Term::ANSIColor values.  This is to make the screen
#  colors translate to HTML for HTML export.  Given a fieldname and a list
#  of codes, return a css class for that fieldname.
sub css_color {
    my $field = shift;
    my @codes = map { split } @_;

    my %current_attrs;
    foreach my $code (@codes) {
        $code = lc $code;

        # If we have a clear or reset, clear the current attributes.  Only
        #  count as a change if there was actually already some attribute
        #  defined.
        if ($code eq 'clear' || $code eq 'reset') {
            %current_attrs = ();

        } elsif (exists $HTML_FOREGROUNDS{$code}) {
            $current_attrs{'color'}[0] = $HTML_FOREGROUNDS{$code};

        } elsif (exists $HTML_BACKGROUNDS{$code}) {
            $current_attrs{'background-color'}[0] = $HTML_BACKGROUNDS{$code};

        } elsif (exists $HTML_ATTRIBUTES{$code}) {
	        my ($attr, $value) = @{$HTML_ATTRIBUTES{$code}};
            if ($attr && $value) {
                push (@{$current_attrs{$attr}}, $value);
            }

        # If we have an attribute we don't recognize, die with a complaint.
        } else {
            require Carp;
	    	Carp::croak ("Invalid attribute name $_");
        }
    }

    # Now actually create the tag, if we have any attributes.
    my ($attribute, $class);
    if (%current_attrs) {
        foreach my $i (keys %current_attrs) {
            $class .= $i.': '.join(',', @{$current_attrs{$i}}).'; ';
        }
        $attribute = ".$field\t{ $class }";
    } else {
        $attribute = ".$field\t{ }";
    }
    return $attribute;
}

############################################################################
# Construction functions
############################################################################

# Set and return the flag for whether or not to use color in printing a line.
sub color_type {
    my ($self, $setting) = @_;

    if (defined $setting) {
       $self->{COLOR_TYPE} = $setting;
    }

    return $self->{COLOR_TYPE};
}

# Set and return the flag for whether or not to continue a log at rollover.
sub do_continue {
    my ($self, $setting) = @_;

    if (defined $setting) {
       if ($setting == 0 || $setting == 1) {
           $self->{CONTINUE} = $setting;
       } else {
           warn "setting '$setting' is invalid for do_continue, use 0 or 1\n";
       }
    }

    return $self->{CONTINUE};
}

# Set and return the flag for whether or not a channel is a base channel.  This
# is normally set by setting an offset, but here if an override is needed.
sub is_base {
    my ($self, $setting) = @_;

    if (defined $setting) {
       if ($setting == 0 || $setting == 1) {
           $self->{IS_BASE} = $setting;
       } else {
           warn "setting '$setting' is invalid for is_base, use 0 or 1\n";
       }
    }

    return $self->{IS_BASE};
}

# Set and return the channel for a line.
sub channel {
    my ($self, $setting) = @_;

    if (defined $setting) {
        $setting =~ s{\s+}{}g;
        if ($setting =~ /\D/ || $setting < 0 || $setting > 31) {
            warn "setting '$setting' is invalid for channel, use 0-31\n";
        } else {
            $self->{CHANNEL} = $setting;
        }
    }

    return $self->{CHANNEL};
}

# Set and return the channel for a line.
sub offset {
    my ($self, $setting) = @_;

    if (defined $setting) {
       if ($setting =~ /\D/) {
           warn "setting '$setting' is invalid for offset, use a positive int\n";
       } else {
           $self->{OFFSET} = $setting;

           # It's a base if the offset is 0 (was there since start of day).
           $self->{IS_BASE} = $self->{OFFSET} == 0 ? 1 : 0;
       }
    }

    return $self->{OFFSET};
}

# Set and return the logger name for a line.
sub logger {
    my ($self, $setting) = @_;

    if (defined $setting) {
       $self->{LOGGER} = $setting;
    }

    return $self->{LOGGER};
}

# Set and return the logger name for a line.
sub filename {
    my ($self, $setting) = @_;

    if (defined $setting) {
       $self->{FNAME} = $setting;
    }

    return $self->{FNAME};
}

# Set and return a log line.
sub line {
    my ($self, $setting) = @_;

    if (defined $setting) {
        $setting =~ s/^#(\d{9,})# //;
        my %result = Calvin::Parse::parse($setting);
        $self->{LINE}   = $setting;
        $self->{PARSED} = \%result;
    }

    return $self->{LINE};
}

sub preferences {
    my ($self, $setting) = @_;

    if (defined $setting) {
        $self->{PREFERENCES}= $setting;
    }

    return $self->{PREFERENCES};
}

# Set and return a header to appear at the start of logs.  Used most often to
# do a list of characters appearing in the log.
sub log_header {
    my ($self, $setting) = @_;

    if (defined $setting) {
        $self->{LOG_HEADER}= $setting;
    }

    return $self->{LOG_HEADER};
}

# Return a parse result.  This is set automatically when we set a line.
sub parsed {
    my ($self) = @_;
    return $self->{PARSED};
}

# Track if a player has been seen.  If status is given, set or clear the player
# setting.
sub player_seen {
    my ($self, $player, $status) = @_;

    if (defined $status) {
        if ($status eq 'seen') {
            $self->{PLAYER_SEEN}->{$player} = 1;
        } elsif ($status eq 'clear') {
            delete $self->{PLAYER_SEEN}->{$player}
                if exists $self->{PLAYER_SEEN}->{$player};
        }
    }

    return exists $self->{PLAYER_SEEN}->{$player};
}

# Return email settings for mailing the log out to the calling user.
sub email {
    my ($self, $settings) = @_;
    if (defined $settings) {
        if (exists $settings->{subject} && $settings->{to}) {
            $self->{EMAIL} = $settings;
        } else {
            warn "email requires both subject and to fields\n";
        }
    }

    return $self->{EMAIL};
}

sub destination {
    my ($self, $setting) = @_;

    if (defined $setting) {
        if ($setting eq 'screen' || $setting eq 'html_file'
            || $setting eq 'plain_file' || $setting eq 'email') {

            $self->{DESTINATION} = $setting;
        } else {
            warn "setting '$setting' is invalid for destination\n";
        }
    }

    return $self->{DESTINATION};
}

# Maintain our log file.  If given a command, open or close the filehandle, and
# return it for use.
sub file {
    my ($self, $operation) = @_;

    if (defined $operation) {
        if ($operation eq 'open') {
            my $fname = $self->filename;

            # Try to open the new file, erroring on failure.
        	if ($fname =~ /\.gz$/) {
        		if (!open ($self->{FH}, '<', "gzip -dc $fname |")) {
        			print "Could not open file $fname.\n";
                    $self->{FH} = undef;
        		}
        	} else {
        		if (!open ($self->{FH}, '<', $fname)) {
        			print "Could not open file $fname.\n";
                    $self->{FH} = undef;
        		}
        	}

        } elsif ($operation eq 'close') {
            close $self->{FH};
            $self->{FH} = undef;
        }
    }

    return $self->{FH};
}

# Create a new characters object.
sub new {
    my ($class, $config) = @_;

    my $self = {};
    bless ($self, $class);

    $self->{COLOR_TYPE}    = '';
    $self->{CONTINUE}      = 1;
    $self->{PLAYER_SEEN}   = {};
    $self->{PREFERENCES}   = {};
    $self->{OFFSET}        = 0;
    $self->{IS_BASE}       = 1;
    $self->{DESTINATION}   = 'screen';
    $self->{EMAIL}         = undef;
    $self->{FH}            = undef;
    $self->{CHANNEL}       = undef;
    $self->{HEADER}        = undef;
    $self->{LOGGER}        = undef;
    $self->{FNAME}         = undef;
    $self->{LINE}          = undef;

    return $self;
}

1;
