package Calvin::Calsplit;
require 5.002;

############################################################################
# Modules and declarations
############################################################################

use lib '/home/jonrober/perl-stuff';

use Term::ANSIColor;
use Calvin::Parse2;
use Logfunctions qw (&roll_over_log &get_fname &last_file);

use strict;
use vars qw (%colors);

############################################################################
# Line handling.
############################################################################

# Handle a line read from a logfile.  Display if we want to, rewrite if we
#  want to, throw it in the trash and go out for a beer otherwise.
sub handle_line {
    my($self, $line) = @_;

    my $pchan = $self->pchan;
    my @channels = $self->channels;
    my $defnum = $self->defnum;
    my @eag_chans = $self->eag_chans;
    
    # Remove timestamps and save in $time.
    my $time = '';
    $line =~ s/^#(\d{2}:\d{2}:\d{2} \w+)# //;
    if (defined $1) { $time = $1 }

    # If the line's from the default channel, give it a dummy number.
    $line =~ s/^(<|\[|\#\# \[?)(?!\d+:)/$1$defnum: /;
    if ($line =~ /^\* / and $line !~ /^\* \d+:/ and $line !~ /^\* -> /) {
        if ($line =~ s/^\* (\[|{)/* $1$defnum: /) {
        } else { $line =~ s/^\* /* $defnum: / }
    }

    # Send the line to Calvin::Parse to get information on it.  $dummy is
    #  there because Calvin::Parse is designed to be used with a client
    #  object, so we need something to fill in that place.  Since it doesn't
    #  do anything with that object, we can get away with this.
    my ($dummy) = "dummy";
    my ($code, $parseone, $parsetwo, $parsethree, $parsefour) =
        (&Calvin::Parse2::parse ($dummy, $line), '', '', '');

    # If we're skimming through a @list from a channel we're lurking and
    #  have hit the line where it ends, stop showing @list entries until
    #  we've found the next proper header.
    if ($self->pos_inlist and $code != C_LIST_CHANNEL) { $self->pos_inlist(0) }

    # If we're starting to log, save the bot's name.
    if ($line =~ /Starting to log channel $pchan( \[.*\])? at \w+ \w+ {1,2}\w+ (.*) \d+ by/) {
        $self->logger($parsetwo);
    }
    
    # If we're at the end, roll over.
    if (($line =~ /^\% (\S+) closing logfile at/) and $self->do_roll) {
        return 2;
        
    } elsif (!$self->found_start) {

        if ($self->start_time > -1) {
            if (defined $time and $time =~ /^(\d{2}):(\d{2}):(\d{2}) (\w+)$/) {
                my $hour = $1;
                if ($self->start_time == $hour) {
                    $self->found_start(1);
                    return $self->handle_line($line);
                }
            } elsif ($code == C_TIME and $parseone =~ /^(\w{3}) (\w{3}) +(\d+) +(\d+):(\d{2}) (\w{2})/) {
                my $hour = $4;
                my $dayhalf = $6;
                if ($dayhalf eq 'AM') {
                    if ($hour == 12) { $hour = 0   }
                } elsif ($hour < 12) { $hour += 12 }
                if ($self->start_time == $hour) {
                    $self->found(1);
                    return $self->handle_line($line);
                }
            }

        # If the line's a starting to join line from our primary channel, we've
        # found our starting point.  Mark $found to be true and call ourself
        #  again with the same line, to actually process it this time.
        } elsif ($line =~ /Starting to log channel $pchan( \[.*\])? at \w+ \w+ {1,2}\w+ (.*) \d+ by/) {
            if ($self->start_seek or $self->start_join) {
                $self->found_start(1);
                return $self->handle_line($line);
            }

        # If it's a message from our primary channel and we're not
        #  insisting on waiting for bot's joining, we've found our point
        #  to start reading from.
        } elsif ($self->start_seek and
                      ($code == C_PUBLIC or $code == C_POSE or $code == C_ROLL)
                      and $parseone == $pchan) {
            $self->found_start(1);
            return $self->handle_line($line);
        }
        return 1;
        
    } else {
        if (!$self->show_noserver and $line =~ /^\*{3}/) {

            # If we want to be shown all server messages, do so.
            if ($self->show_allserver) {
                $self->print_line('system', $line);

            # The line is a channel join, leave, or topic change.  Show it
            #  if it's on a channel we're lurking or if we're skimming.
            } elsif ($code == C_JOIN  or $code == C_LEAVE or
                           $code == C_TOPIC_CHANGE) {
                if ((defined $channels[$parsetwo]) or $self->skim) {
                    $self->print_line('system', $line);
                }
                
            # We like signoffs.  If the line's one, show it.
            } elsif ($code == C_SIGNOFF) {
                $self->print_line('system', $line);

            # If it's a time message and the user wants to see those, show it.
            } elsif ($self->show_time and $code == C_TIME) {
                $self->print_line('system', $line);

            # If the line is the head for a "@list" of a channel and we're
            #  splitting that channel, show the line and set pos_inlist so
            #  that we'll know to show the actual @list entries after it.
            } elsif ($code == C_LIST_HEAD) {
                if ((defined $channels [$parseone]) or $self->skim) {
                    $self->pos_inlist(1);
                    $self->print_line('system', $line);
                }

            # If the line's part of a "@list" or "@listall", then we show it
            #  only if we're either skimming, or if we're in the middle of a
            #  listing from a channel we're lurking.
            } elsif ($code == C_LIST_CHANNEL) {
                if ($self->skim or $self->pos_inlist) {
                    $self->print_line('system', $line);
                }
            }

        } else {

            # A whisper.
            if ($code == C_WHIS or $code == C_WHIS_POSE or
                      $code == C_WHIS_ROLL) {
                if ($self->show_msg) { $self->print_line ('whisper', $line) }

            # If the line is from a channel, we check to see if that channel's
            #  in our list of channels we're watching.  If so, check to see if
            #  it's our primary or secondary channel, then use that and whether
            #  or not we're eagle-rewriting to see if and how to rewrite it
            #  before printing.
            } elsif ($line =~ /^(<|\[|\{|\* (\{|\[)?|\* |\#\# \[?)(\d+): /) {
                my $chan = $3;
                $line = $self->rewrite_reflect ($line);
                if ($self->do_rewrite_nochans) {
                    $line = $self->rewrite_eag ($line);
                    $line = $self->remove_channel ($line);
                    $self->print_line ('none', $line);
                } elsif ($self->do_rewrite_spam) {
                    if ((defined $pchan and $pchan eq $chan) or
                        !defined $pchan or $pchan eq '') {
                        $line = $self->rewrite_for_spam ($line);
                        $self->print_line ('none', $line);
                    }
                } elsif (defined $channels[$chan]) {
                    if ($self->do_rewrite_eag and $eag_chans[$chan]) {
                        $line = $self->rewrite_eag ($line);
                    }
                    if ($chan eq $pchan or $chan eq $defnum) {
                        $line = $self->remove_channel ($line);
                    }
                    if (!$self->colors_offset) {
                        $self->print_line ($chan, $line);
                    } else {
                        $self->print_line ($channels[$chan], $line);
                    }
                }

            # If this line is a yell, and for some godforsaken reason we want
            #  to *see* yells, then show the line and have mercy on your souls.
            } elsif ($code == C_YELL or $code == C_YELL_POSE or
                           $code == C_YELL_ROLL) {
                if ($self->show_yell) { $self->print_line('yell', $line) }

            # Message from the client (either TF or CalCli).
            } elsif ($self->show_bot and
                          ($line =~ /^CC: Log/ or $line =~ /^% /)) {
                $self->print_line('none', $line);
            }

            # Special case: if the line was the end of a Cambot scene and
            # we want to quit there, die.
            if ($self->do_quit) {
                if (($line =~ /Ending log of channel / and $parseone == $pchan
                           and $parsetwo eq $self->logger)
                    or $line =~ /^\*{3} Welcome/) {
                    return 0;
                }
            }
        }
        return 1;
    }
}

############################################################################
# Line rewriting methods.
############################################################################

sub rewrite_for_spam {
    my ($self, $line) = @_;
    
    $line =~ s/^<(?:\d+: )?\S+> \[(.*)\]$/[$1]/;
    $line =~ s/^<(?:\d+: )?\S+> \[([^\]]+)\]/[$1]/;
    $line =~ s/^\{(?:\d+: )?(.*?)\} (.*) <\S+>$/[$1] $2/;
    $line =~ s/^\* \{(?:\d+: )?(.*)\} <\S+>$/[$1]/;
    $line =~ s/^<(?:\d+: )?(\S+)>/[$1]/;
    $line =~ s/^<(?:\d+: )?(.*?)>/[$1]/;
    $line =~ s/^\* (?:\d+: )?(.*)/[$1]/;
    # Off-channel "[7: Van] Hi!" ?  Rewrite, don't show, or leave as-is
    #  for easy checking/removal?

    return $line;
}

# Rewrite a message from the primary channel to remove the channel # prefix.
sub remove_channel {
    my ($self, $line) = @_;
    $line =~ s/^(<|\[|\{|\* (\{|\[)?|\#\# \[?)\d+: /$1/;
    return $line;
}

# Rewrite a message sent by reflector.
sub rewrite_reflect {
    my ($self, $line) = @_;
    my $reflector = $self->reflector();
    
    # Rewrite a message sent by reflector.
    $line =~ s/^<(\d+): $reflector> \[([^\[].*?)( <{\S+}>)?\]$/* $1: $2/;
    $line =~ s/^<(\d+): $reflector> \[([^\[\]]+)\] (.*?)( <{\S+}>)?$/<$1: $2> $3/;

    # Rewrite a message sent by reflector, then rewritten by Calvinhelps.
    $line =~ s/^<(\d+): \(Ref\) (\S+)>/<$1: $2>/;
    $line =~ s/^\* (\d+): \(Ref\)/* $1:/;
    
    return $line;
}

# Rewrite a message from a secondary channel, using eagle-style complete rewrites.
sub rewrite_eag {
    my ($self, $line) = @_;

    # Rewrite messages badly spammed, like <10: .> <Van> [Kaye pouts.]
    # Won't work if they've been linewrapped first, but I do what I can.
    $line =~ s/^<(\d+): \W> <(\S{2,})>/<$1: $2>/;
    $line =~ s/^<(\d+): \W> (\*|\#\#) /$2 $1: /;

    #    my $outline = '';
    #    while ($line =~ /^<\d+: \S+> \[[^\[][^\]]*\]/) {
    #        if ($line =~ s/^<(\d+): (\S+)> \[([^\]\[]+)\] ([^\[]+)/<$1: $2> /) {
    #            $outline .= "<$1: $3> $4\n";
    #        } elsif ($line =~ s/^<(\d+): (\S+)> \[([^\[][^\]]*)\]/<$1: $2>/) {
    #            $outline .= "* $1: $3\n";
    #        }
    #    }
    #    $line = $outline;
    
    # Rewrite bracket-channeled messages.
    $line =~ s/^<(\d+): \S+> \[([^\[][^\]]*)\]\s*$/* $1: $2/;
    $line =~ s/^<(\d+): \S+> \[([^\]\[]+)\]/<$1: $2>/;

    # Rewrite messages rewritten by /trustchars in calvinhelps.
    $line =~ s/^\* \{(\d+): (.*)\}\s+<\S+>$/* $1: $2/;
    $line =~ s/^\{(\d+): (.*?)\} (.*) <\S+>$/<$1: $2> $3/;

    return $line;
}

############################################################################
# Wrapping and printing methods.
############################################################################

sub fold {
    my ($self, $line) = @_;
    my $width = $self->width;
    $line =~ s/(?:(.{1,$width})\s+|(\S{$width}))/(defined($1) ? $1 : $2) . "\n"/ego;
    $line;
}

sub c_fold {
    my ($self, $color, $line) = @_;
    my $width = $self->width;
    $line =~ s/(?:(.{1,$width})\s+|(\S{$width}))/$color.(defined($1) ? $1 : $2) . "\n"/ego;
    $line;
}

sub print_line {
    my ($self, $line_type, $line) = @_;
    my $wrap = $self->width;
    my %colors = $self->colors();

    if (!$wrap) { print OUTPUT $line }

    elsif ($self->use_colors and defined($colors{$line_type})) {
        print OUTPUT $self->c_fold(color($colors{$line_type}), $line);

    } elsif ($self->use_colors) {
        print OUTPUT $self->c_fold(color('reset'), $line);

    } else { print OUTPUT $self->fold($line) }
}

############################################################################
# Public methods.
############################################################################

sub new {
    my ($class, $client) = @_;

    my $self = {};
    bless ($self, $class);

    $self->use_less(0);         # Pipe through less -r.
    $self->width(77);           # Columns to fold to.
    $self->reflector('=R=');    # Reflector name.
    $self->defnum(99);          # Dummy number used to rewrite the default
                                #   channel to have a channel number.

    $self->do_roll(1);          # Roll over to next file?

    $self->skim(0);
    $self->do_quit(0);          # Quit at bot's dismissal?

    $self->found_start(1);      # Found the start of the log?
    $self->start_time(-1);      # Start reading at a certain time.
    $self->start_seek(0);       # Start at first message from primary channel?
    $self->start_join(0);       # Start at a bot join message?
    $self->start_end(0);        # Default is to not start at end

    $self->show_yell(0);        # Show yells?
    $self->show_noserver(0);    # Repress all server messages?
    $self->show_allserver(0);   # Show all server messages?
    $self->show_bot(0);         # Show lines from the logging bot?
    $self->show_defchan(0);     # Show lines from a channel with no number?
    $self->show_msg(0);         # Show whispers?
    $self->show_time(0);        # Show @time server messages?

    $self->do_rewrite_eag(0);     # Rewrite bracket-channeled lines?
    $self->do_rewrite_spam(0);    # Rewrite for spamming?
    $self->do_rewrite_nochans(0); # Remove all channel numbers?

    $self->use_colors(0);       # Use colors?
    $self->colors_offset(0);    # Use offset colors?

    $self->pos_inlist(0);       # Are we in the middle of a @list?

    $self->{COLORS} = undef;    # Colors array
    $self->{CHANNELS} = undef;  # Channel color code offset array
    $self->{EAG_CHANS} = undef; # Channels to Eagle-split with -E

    return $self;
}

sub colors {
    my $self = shift;
    my (%colors) = @_;
    if (%colors) { %{$self->{COLORS}} = %colors }
    if (defined $self->{COLORS}) { return %{$self->{COLORS}} }
    else                         { return undef                 }
}

sub channels {
    my $self = shift;
    if (@_) { @{$self->{CHANNELS}} = @_ }
    if (defined $self->{CHANNELS}) { return @{$self->{CHANNELS}} }
    else                           { return undef                }
}

sub eag_chans {
    my $self = shift;
    if (@_) { @{$self->{EAG_CHANS}} = @_ }
    if (defined $self->{EAG_CHANS}) { return @{$self->{EAG_CHANS}} }
    else                            { return undef                 }
}

sub logger {
    my $self = shift;
    if (@_) { $self->{LOGGER} = shift }
    return $self->{LOGGER};
}

sub use_less {
    my $self = shift;
    if (@_) {
        my $use_less = shift;
        $self->{USE_LESS} = $use_less;
        if ($use_less) {
            unless (-t STDOUT and open(OUTPUT, "| less $use_less")) {
                open(OUTPUT, '>-') || die "Can't write to STDOUT: $!\n";
            }
        } else { open(OUTPUT, '>-') || die "Can't write to STDOUT: $!\n" }
    }
    return $self->{USE_LESS};
}

sub pchan {
    my $self = shift;
    if (@_) { $self->{PCHAN} = shift }
    return $self->{PCHAN};
}

sub skim {
    my $self = shift;
    if (@_) { $self->{SKIM} = shift }
    return $self->{SKIM};
}

sub start_end {
    my $self = shift;
    if (@_) {
        $self->{START_END} = shift;
        if ($self->{START_END}) {
            $self->found_start(0);
            $self->start_time(-1);
            $self->start_join(0);
            $self->start_seek(0);
        }
    }
    return $self->{START_END};
}

sub width {
    my $self = shift;
    if (@_) { $self->{WIDTH} = shift }
    return $self->{WIDTH};
}

sub colors_offset {
    my $self = shift;
    if (@_) { $self->{COLORS_OFFSET} = shift }
    return $self->{COLORS_OFFSET};
}

sub reflector {
    my $self = shift;
    if (@_) { $self->{REFLECTOR} = shift }
    return $self->{REFLECTOR};
}

sub defnum {
    my $self = shift;
    if (@_) { $self->{DEFNUM} = shift }
    return $self->{DEFNUM};
}

sub do_roll {
    my $self = shift;
    if (@_) { $self->{DO_ROLL} = shift }
    return $self->{DO_ROLL};
}

sub do_quit {
    my $self = shift;
    if (@_) { $self->{DO_QUIT} = shift }
    return $self->{DO_QUIT};
}

sub found_start {
    my $self = shift;
    if (@_) { $self->{FOUND_START} = shift }
    return $self->{FOUND_START};
}

sub start_time {
    my $self = shift;
    if (@_) {
        my $time = shift;
        if ($time < -1 or $time > 23) {
            print OUTPUT "Bad search-time: $time\n";
        } else {
            $self->{START_TIME} = $time;
            if ($self->{START_TIME} != -1) {
                $self->found_start(0);
                $self->start_join(0);
                $self->start_seek(0);
                $self->start_end(0);
            }
        }
    }
    return $self->{START_TIME};
}

sub start_seek {
    my $self = shift;
    if (@_) {
        $self->{START_SEEK} = shift;
        if ($self->{START_SEEK}) {
            $self->found_start(0);
            $self->start_time(-1);
            $self->start_join(0);
            $self->start_end(0);
        }
    }
    return $self->{START_SEEK};
}

sub start_join {
    my $self = shift;
    if (@_) {
        $self->{START_JOIN} = shift;
        if ($self->{START_JOIN}) {
            $self->found_start(0);
            $self->start_time(-1);
            $self->start_seek(0);
            $self->start_end(0);
        }
    }
    return $self->{START_JOIN};
}

sub show_yell {
    my $self = shift;
    if (@_) { $self->{SHOW_YELL} = shift }
    return $self->{SHOW_YELL};
}

sub show_noserver {
    my $self = shift;
    if (@_) { $self->{SHOW_NOSERVER} = shift }
    return $self->{SHOW_NOSERVER};
}

sub show_allserver {
    my $self = shift;
    if (@_) { $self->{SHOW_ALLSERVER} = shift }
    return $self->{SHOW_ALLSERVER};
}

sub show_bot {
    my $self = shift;
    if (@_) { $self->{SHOW_BOT} = shift }
    return $self->{SHOW_BOT};
}

sub show_defchan {
    my $self = shift;
    if (@_) { $self->{SHOW_DEFCHAN} = shift }
    return $self->{SHOW_DEFCHAN};
}

sub show_msg {
    my $self = shift;
    if (@_) { $self->{SHOW_MSG} = shift }
    return $self->{SHOW_MSG};
}

sub show_time {
    my $self = shift;
    if (@_) { $self->{SHOW_TIME} = shift }
    return $self->{SHOW_TIME};
}

sub do_rewrite_eag {
    my $self = shift;
    if (@_) { $self->{DO_REWRITE_EAG} = shift }
    return $self->{DO_REWRITE_EAG};
}

sub do_rewrite_spam {
    my $self = shift;
    if (@_) {
        $self->{DO_REWRITE_SPAM} = shift;
        if ($self->{DO_REWRITE_SPAM}) {
            $self->width(0);           #  ..don't wrap lines
            $self->show_noserver(1);   #  ..don't show server messages
        }
    }
    return $self->{DO_REWRITE_SPAM};
}

sub do_rewrite_nochans {
    my $self = shift;
    if (@_) {
        $self->{DO_REWRITE_NOCHANS} = shift;
        if ($self->{DO_REWRITE_NOCHANS}) {
            $self->show_noserver(1);   #  ..show no server messages
            $self->show_defchan(1);    #  ..show any default channels
        }
    }
    return $self->{DO_REWRITE_NOCHANS};
}

sub use_colors {
    my $self = shift;
    if (@_) { $self->{USE_COLORS} = shift }
    return $self->{USE_COLORS};
}

sub pos_inlist {
    my $self = shift;
    if (@_) { $self->{POS_INLIST} = shift }
    return $self->{POS_INLIST};
}


1;
