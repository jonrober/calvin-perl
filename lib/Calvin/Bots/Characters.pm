package Calvin::Bots::Characters;
require 5.002;

# This is a Calvin Bot module that will interface with character and player
# data from the Calvin::Logs::Character module and present that data.  Broadly
# speaking, it's the bot equivalent to the plexchar-search script.
#
# Jon Robertson, 2018.
#
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.
#
# The purpose of this bot is to send descriptions of characters and other
# objects (for supporting channeling on a Calvin server).  What this means
# in general is that it sends files and directory listings via @msg at
# users' request, and therefore could potentially be modified to do other
# interesting things.

############################################################################
# Modules and declarations
############################################################################

use Calvin::Client;
use Calvin::Manager;
use Calvin::Logs::Characters;
use Calvin::Parse qw (:constants);

use Getopt::Long qw(GetOptionsFromString);

use strict;

############################################################################
# Option handling commands
############################################################################

# Run a set of arguments through Getopt::Long, in order to feed them back to
# the Character search as a filter.
sub parse_character_arguments {
    my $self = shift;
    my ($client, $user, $request) = @_;

    # Set our options and defaults.
    my @options = ('intro_before=s', 'intro_after=s', 'lastseen=s',
                   'minimumlogs=i', 'tag=s');
    my %args = ('intro_before' => undef,
                'intro_after'  => undef,
                'lastseen'     => undef,
                'minimumlogs'  => 10,
                'tag'          => undef,
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

    # If there are any remaining arguments, that is presumably the player name.
    # Otherwise just take the name of our current user and assume they are
    # searching for their own characters.
    my $player = $user;
    if (@{ $remaining_args }) {
        ($player) = @{ $remaining_args };
    }
    $args{player} = $player;

    return %args;
}

# Run a set of tag arguments through Getopt::Long, in order to feed them back
# to the Character search as a filter.
sub parse_tag_arguments {
    my $self = shift;
    my ($client, $user, $request) = @_;

    # Set our options and defaults.
    my @options = ('intro_before=s', 'intro_after=s', 'lastseen=s',
                   'minimumlogs=i', 'player=s');
    my %args = ('intro_before' => undef,
                'intro_after'  => undef,
                'lastseen'     => undef,
                'minimumlogs'  => 10,
                'player'       => undef,
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

    # Any remaining argument is the tag name.  If none is remaining, then
    # error out.
    if (@{ $remaining_args }) {
        my ($tag) = @{ $remaining_args };
        return ($tag, %args);
    } else {
        my $error = "No tag given";
        $client->msg ($user, $error);
        return undef;
    }
}

############################################################################
# Basic commands
############################################################################

# Several commands can send something that's longer than the maximum buffer
# for complex (1024 characters).  This takes a sent line and splits it on
# whitespace so that nothing is lost.  The split is actually at 1000 characters
# to leave space for the server to add formatting.
sub send_wrapped_message {
    my ($self, $client, $user, $header, @list) = @_;

    my $message = $header;
    while (@list) {
        my $total = length $message;
        while (@list && (!$total || $total + length $list[0] < 1000)) {
            $message .= (shift @list) . ' ';
            $total = length $message;
        }
        chop $message;
        $client->msg ($user, $message);
        $message = '';
    }
}

# Find all characters in a directory who are owned by a certain person.
# The list of characters is returned as a string, and split if it is greater
# than 1024 characters.
sub send_character_list {
    my $self = shift;
    my ($client, $user, @args) = @_;

    # Parse out our arguments.
    my $request = join (' ', @args);
    my %filter = $self->parse_character_arguments($client, $user, $request);
    return unless %filter;

    # Create the Characters object and check to see if the player matches one
    # we know about.
    my $chardata = Calvin::Logs::Characters->new;
    my $player = $chardata->canonical_player($filter{player});
    if ($player eq '') {
        $client->msg ($user, "Could find no matching players for '$player'");
        return 1;
    }
    $filter{player} = $player;

    # Build the filter for characters, then search.  Assume a minimum log
    # appearance level of 10.
    $chardata->filter(\%filter);
    my %characters = $chardata->characters;
    unless (%characters) {
        $client->msg ($user, 'No matching characters were found');
        return;
    }

    # Strip the :Playername off of the end of the found characters.
    my @list = map { $_ =~ s#:.+$##; $_ } sort keys %characters;
    my $header = "Characters for $player: ";
    $self->send_wrapped_message ($client, $user, $header, @list);
}

# Send the list of all existing tags.
sub send_tag_list {
    my $self = shift;
    my ($client, $user) = @_;

    my $tagobj = Calvin::Logs::Characters::Tag->new;
    my %tags = $tagobj->tags;

    my $header = "Current tags: ";
    $self->send_wrapped_message ($client, $user, $header, sort keys %tags);
}

# Send the list of characters who all have a specific tag.
sub send_tagged_characters {
    my $self = shift;
    my ($client, $user, @args) = @_;

    # Parse out our arguments.
    my $request = join (' ', @args);
    my ($tag, %filter) = $self->parse_tag_arguments($client, $user, $request);
    return unless %filter;

    # Load our character data.
    my $charobj = Calvin::Logs::Characters->new();
    $charobj->filter(\%filter);

    my $tagobj = Calvin::Logs::Characters::Tag->new;
    my %tags = $tagobj->tags;
    unless (exists $tags{$tag}) {
        $client->msg ($user, "No tags named '$tag'");
        return;
    }

    # Get the characters.  They're already formatted, so strip down to the
    # base character names.
    my @matches = $tagobj->characters($tag, $charobj);
    @matches = map { chomp; s#^(\S+)\s.+$#$1#; $_ } @matches;

    unless (@matches) {
        $client->msg ($user, 'No matching characters were found');
        return;
    }

    my $header = "Characters tagged '$tag': ";
    $self->send_wrapped_message ($client, $user, $header, @matches);
}

############################################################################
# Public routines.
############################################################################

# Create a new Descbot object and set necessary configs to their default.
sub new {
    my $class = shift;
    my ($client) = @_;

    my $self = {};
    bless ($self, $class);

    return $self;
}

# Things that must be done after the client owning the bot is created.  Not a
#  darn thing, but put here because Cambot needs it and we want to remain
#  consistent between bots.
sub startup {
    my $self = shift;
}

# Returns a hash of lists containing all commands and the help for each.
sub return_help {
    my $self = shift;
    my %help;
    %help = (
             'characters' => [ 'Syntax:   characters <player>',
                               'Lists all characters owned by a given player',
                             ],
             'tags'       => [ 'Syntax:   list-tags',
                               'Lists all current tags defined for characters',
                             ],
             'tagged'     => [ 'Syntax:   tagged <tagname>',
                               'Shows all characters that have the given tag',
                             ],
            );
    return %help;
}

# Returns a list containing all valid commands.
sub return_commands {
    my $self = shift;
    my (@commands) = ('characters', 'tags', 'tagged');
    return @commands;
}

# Takes a line and performs any necessary functions on it.  If the line is
#  a command to the bot, return 1.  Return 0 otherwise.  Note that there can
#  be things for which we do functions, but return 0.  These are lines such
#  as signon messages, which more than one bot may wish to know about.
sub handle_line {
    my $self = shift;
    my ($manager, $client, $line, %result) = @_;

    if (($result{'code'} != C_WHIS) || $result{'on_channels'}) {
        return 0;
    }

    # Separate the message out into command and arguments.
    my $message = $result{'s1'};
    $message =~ s/\s+$//;
    my ($command, @args) = split (/\s+/, $message);

    # List all characters for a given player.
    if ($command eq 'characters')    {
        $self->send_character_list ($client, $result{'name'}, @args);
        return 1;

    # List all tags.
    } elsif ($command eq 'tags')  {
        $self->send_tag_list ($client, $result{'name'});
        return 1;

    # List all characters that have a specific tag.
    } elsif ($command eq 'tagged')   {
        $self->send_tagged_characters ($client, $result{'name'}, @args);
        return 1;
    }

    return 0;
}

1;
