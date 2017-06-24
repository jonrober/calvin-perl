# Calvin::Logs::Characters - Character parsing functions for Calvin chatservs
#
# Copyright 2017 by Jon Robertson <jonrober@eyrie.org>
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

############################################################################
# Modules and declarations
############################################################################

package Calvin::Logs::Characters;
use 5.010;
use autodie;
use strict;
use warnings;

use Calvin::Logs::Characters::Tag;
use Calvin::Parse qw (:constants);
use Date::Parse;
use IO::Handle;
use Hash::Merge qw(merge);
use Storable;
use Text::ParseWords;

use strict;
use vars qw();

# Directories for our data files.
my $DATA_DIR   = '/srv/calvin/logs/chardata/';
my $CHAR_DATA  = '/srv/calvin/logs/complex/characters.store';

our $STARTDATE = 0;
our $ENDDATE = 0;

#############################################################################
# File handlers
#############################################################################

# Load the storable hash of characters and their players and scenes.
sub raw_characters {
    my ($self) = @_;

    return %{ $self->{CHARDATARAW} } if defined $self->{CHARDATARAW};

    my @files = @{ $self->{CHARACTER_FILES} };
    return () unless @files;

    my $all_characters = {};
    for my $fname (@files) {
        unless (-f $fname) {
            warn "no such character file: $fname\n";
            next;
        }

        my $char_ref = retrieve($fname);
        $all_characters = merge($all_characters, $char_ref);
    }

    $self->{CHARDATARAW} = $all_characters;
    return %{ $self->{CHARDATARAW} };
}

# Get a hash of all overrides.  Each will start with a command and then have
# 2-3 options -- one to two keys and one value to rename a player or character
# when the key(s) match.  Build the hash and then return it.
sub aliases {
    my ($self) = @_;

    return %{ $self->{ALIASES} } if defined $self->{ALIASES};

    my (%aliases);
    my $fname = $DATA_DIR . 'overrides';
    open (my $fh, '<', $fname);
    while (my $line = <$fh>) {
        chomp $line;
    	next if $line =~ m{^#};
    	next if $line !~ m{\S};

        my ($action, @tokens) = quotewords('\s+', 0, $line);

        my $success = 1;
        if ($action eq 'ALIAS' && scalar @tokens == 3) {
            my ($alias, $player, $original) = @tokens;
            $aliases{owners}{$original}{$player}{$alias} = 1;
            $aliases{aliased}{$alias}{$player} = 1;
            #print "Added alias $alias to $original\n";
            #print Dumper($aliases{owners}), "\n";
        }
    }
    close $fh;

    $self->{ALIASES} = \%aliases;
    return %aliases;
}

#############################################################################
# Misc functions
#############################################################################

# Given a character name, check to find a unique character matching.  Since
# some character names are used by multiple players, we need a way to look up
# the specific character in question.
# Returns the character plus player combo, or dies with an error if we can't
# find a unique matching charcter.
sub distinguish_char {
    my ($self, $char) = @_;

    my %characters = $self->raw_characters;

    my $player = undef;
    ($char, $player) = split(':', $char) if $char =~ m{:};
    die "Could not find $char\n" unless exists $characters{$char};

    # Find the character and player.  If more than one player for the character,
    # we need the character specified.
    if (scalar(keys %{ $characters{$char} }) == 1) {
        ($player) = keys %{ $characters{$char} };
    } else {
        if (!defined $player) {
            my $players = join(', ', keys %{ $characters{$char} });
            die "More than one possible player for $char: $players\n";
        } elsif (!exists $characters{$char}{$player}) {
            die "No matching player $player for $char\n";
        }
    }

    return ($char, $player);
}

# Given a character and the alias list, merge in any aliases the character has
# into the character structure.
sub merge_aliases {
    my ($self, $char, $player) = @_;

    my %characters = $self->raw_characters;
    my %aliases    = $self->aliases;

    # Add all of the primary character's files to our mapping.
    my %files;
    my $prime_data = $characters{$char}{$player}{files};
    for my $chan (sort { $a <=> $b } keys %{$prime_data}) {
        for my $tag (sort keys %{ $prime_data->{$chan} }) {
            for my $log (sort keys %{ $prime_data->{$chan}{$tag} }) {
                $files{$chan}{$tag}{$log}{$char} = 1;
            }
        }
    }

    # Return the character if there are no aliases, or if the character itself
    # is an alias.  The latter is a little iffy, but is also a case we
    # shouldn't normally hit.
    return \%files if exists $aliases{aliased}{$char}{$player};
    return \%files unless exists $aliases{owners}{$char}{$player};

    # Now go through each alias and save their own files to the files data.
    for my $alias (keys %{ $aliases{owners}{$char}{$player} }) {
        my $alias_data = $characters{$alias}{$player}{files};
        for my $chan (sort { $a <=> $b } keys %{$alias_data}) {
            for my $tag (sort keys %{ $alias_data->{$chan} }) {
                for my $log (sort keys %{ $alias_data->{$chan}{$tag} }) {
                    $files{$chan}{$tag}{$log}{$alias} = 1;
                }
            }
        }
    }

    #use Data::Dumper; print Dumper(%aliases), "\n";
    return \%files;
}

# Given data for two characters, compare and see if they have any matching
# channels.
sub match_chars {
    my ($self, $first, $second) = @_;

    # Go through all hits for the first character, seeing if there is a match
    # for the second character in the same log.  Prune out no-matches on each
    # step to avoid unnecessary loops.
    my %matches = ();
    for my $chan (keys %{$first}) {
        next unless exists $second->{$chan};
        for my $tag (keys %{ $first->{$chan} }) {
            next unless exists $second->{$chan}{$tag};
            for my $log (keys %{ $first->{$chan}{$tag} }) {
                next unless exists $second->{$chan}{$tag}{$log};

                # Filter out if the log isn't in the requested time period.
                # TODO: Why is this here?  This should be done elsewhere.
                my $logdate = str2time($log =~ m{(\d{4}-\d{2}-\d{2})});
                next if $STARTDATE && $logdate < $STARTDATE;
                next if $ENDDATE && $logdate > $ENDDATE;

                # Add any characters for either log to the array.  This tells
                # us what character/character aliases were actually in this
                # log.
                for my $char (keys %{ $first->{$chan}{$tag}{$log} },
                              keys %{ $second->{$chan}{$tag}{$log} }) {
                    $matches{$chan}{$tag}{$log}{$char} = 1;
                }
            }
        }
    }

    return \%matches;
}

# Decide whether a character should be visible.  This uses a filter to decide
# if we should display the character.  Currently the filter is only about
# whether the character has appeared more than some number of times.
sub visible_character {
    my ($self, $char_nicks, $player, %characters) = @_;

    my $filters = $self->{FILTER};
    return 1 unless defined $filters;
    return 0 if $filters->{player} && $filters->{player} ne $player;

    # Check to see if we have a tag match.
    if (defined $filters->{tag}) {
        my $tagobj = Calvin::Logs::Characters::Tag->new;
        my $match = 0;
        for my $char (@{ $char_nicks }) {
            my $charkey = $char . ':' . $player;
            $match = $tagobj->has_tag($filters->{tag}, $charkey);
            last if $match;
        }
        return 0 unless $match;
    }

    # Create an echo of the filters that will tell if we've passed checks,
    # save anything that returns immediately.
    my %checks;
    for my $check (keys %{ $filters } ) {
        next if $check eq 'player' || $check eq 'lastseen'
            || $check eq 'intro_after' || $check eq 'tag';
        $checks{$check} = 0;
    }

    my $logs = 0;
    LOGNUMBER: for my $char (@{ $char_nicks }) {
        my $record = $characters{$char}{$player}{files};
        for my $chan (keys %{ $record }) {
            for my $tag (keys %{ $record->{$chan} }) {
                for my $fname (keys %{ $record->{$chan}{$tag} }) {

                    # Check to see if the character is in logs before a date.
                    my ($logdate) = ($fname =~ m{/(\d{4}-\d{2}-\d{2})-[^/]+$});
                    if (defined $logdate) {
                        my $logtime = str2time($logdate);
                        if ($logtime < $filters->{intro_before}) {
                            $checks{intro_before} = 1;
                        }

                        # If the character has been seen too recently, or was
                        # in logs before an intro date, don't show.,
                        return 0 if $logtime > $filters->{lastseen};
                        return 0 if $logtime < $filters->{intro_after};
                    }

                    # Check to see if the character is in enough logs.
                    $logs++;
                    if ($logs >= $filters->{minimum_logs}) {
                        $checks{minimum_logs} = 1;
                    }
                }
            }
        }
    }

    for my $check (keys %checks) {
        return 0 if $checks{$check} == 0;
    }
    return 1;
}

# Build a search filter for characters, given a Getopt::Long::Descriptive
# options object.
sub filter {
    my ($self, $options) = @_;

    # Only set the new options if we were given new ones to set.
    if ($options) {
        my $minimum_logs = $options->minimumlogs  || 5;
        my $intro_before = $options->intro_before || '2099-01-01';
        my $intro_after  = $options->intro_after  || '1990-01-01';
        my $lastseen     = $options->lastseen     || '2099-01-01';
        my $player       = $options->player       || undef;
        my $tag          = $options->tag          || undef;

        my %filter = (minimum_logs => $minimum_logs,
                      intro_before => str2time($intro_before),
                      intro_after  => str2time($intro_after),
                      lastseen     => str2time($lastseen),
                      player       => $player,
                      tag          => $tag,
        );

        $self->{FILTER} = \%filter;
    }

    return $self->{FILTER};
}

############################################################################
# Exported functions
############################################################################

# Command handler to list all characters.
sub characters {
    my ($self) = @_;

    return %{ $self->{CHARDATA} } if defined $self->{CHARDATA};

    my %characters = $self->raw_characters;
    my %aliases    = $self->aliases;
    my %all        = ();

    for my $char (sort keys %characters) {
        for my $player (sort keys %{ $characters{$char} }) {
            next if exists $aliases{aliased}{$char}{$player};
            my (@nicks);
            my $other_nicks = '';
            if (exists $aliases{owners}{$char}{$player}) {
                @nicks = keys %{ $aliases{owners}{$char}{$player} };
                $other_nicks = '(' . join(', ', @nicks) . ')';
            }

            my @all_chars = ($char, @nicks);
            next unless $self->visible_character(\@all_chars, $player,
                                                 %characters);

            my $key = $char . ':' . $player;
            $all{$key}{player}      = $player;
            $all{$key}{character}   = $char;
            $all{$key}{other_nicks} = \@nicks;
            $all{$key}{display}     = sprintf("%-20s %-15s %s\n", $char,
                                              $player, $other_nicks);
        }
    }

    $self->{CHARDATA} = \%all;
    return %all;
}

# Given one or more characters, find a list of logs that they were each in.
sub character_logs {
    my ($self, $primary, @other_chars) = @_;
    my %logs;
    my $prime_player;

    # Get the primary character and any aliases.
    my %characters = $self->raw_characters;
    my %aliases    = $self->aliases;
    ($primary, $prime_player) = $self->distinguish_char($primary);
    my $prime_data = $self->merge_aliases($primary, $prime_player);

    # For every additional character we go through and find any matches.  At
    # each level we update the prime data with the results of the search in
    # order to prune it down for the next search.
    for my $char (sort @other_chars) {
        my $current_player;
        ($char, $current_player) = $self->distinguish_char($char);
        my $current_data = $self->merge_aliases($char, $current_player);
        $prime_data = $self->match_chars($prime_data, $current_data);
    }

    my $chars = join(', ', sort($primary, @other_chars));
    return () if scalar(keys %$prime_data) == 0;

    # Now take all that data and iterate through it to reformat for output,
    # saving characters and coming up with a display line.
    for my $chan (sort { $a <=> $b } keys %{$prime_data}) {
        for my $tag (sort keys %{ $prime_data->{$chan} }) {
            for my $log (sort keys %{ $prime_data->{$chan}{$tag} }) {
                my ($short_log) = ($log =~ m{/([^/]+)$});
                my $key   = $short_log . ' ' . $chan . ' ' . $log;
                my @chars = sort keys %{ $prime_data->{$chan}{$tag}{$log} };
                $logs{$key}{channel}    = $chan;
                $logs{$key}{tag}        = $tag;
                $logs{$key}{fname}      = $log;
                $logs{$key}{characters} = \@chars;

                # TODO: How to display the characters?
                $logs{$key}{display}    = sprintf("%02d: %-40s %s\n", $chan, $tag, $short_log);
            }
        }
    }

    return %logs;
}

############################################################################
# Exported functions
############################################################################

# Create a new characters object.
sub new {
    my ($class, $config) = @_;

    my $self = {};
    bless ($self, $class);

    # Set the data files we want to use for characters.
    my @files;
    $config ||= {};
    if (exists $config->{character_files} && @{ $config->{character_files} }) {
        @files = @{ $config->{character_files}};
    } else {
        @files = ($CHAR_DATA);
    }
    @{ $self->{CHARACTER_FILES} } = @files;

    $self->{CHARDATA}    = undef;
    $self->{CHARDATARAW} = undef;
    $self->{ALIASES}     = undef;
    $self->{FILTER}      = undef;

    return $self;
}

1;
