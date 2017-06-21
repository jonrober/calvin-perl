package Calvin::Bots::Descbot;
require 5.002;

# descbot -- A Calvin bot to send character descriptions on request.
#            Original version by Russ Allbery, 1996.
#            Module version and modifications by Jon Robertson, 1997.
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
use Calvin::Parse qw (:constants);

use strict;


############################################################################
# Sending files and directorie contents and information
############################################################################

# Check a filename for security.  We want to ensure that all filenames are
# simple names, containing no slashes, and are not equal to . or .. (to
# ensure that all file accesses stay relative to $descroot).
sub check_file {
    my $self = shift;
    my ($filename) = @_;
    not ($filename =~ m%/% or $filename =~ /^\.\.?$/);
}

# Send a file to a user.  We want to let Calvin or their client do the line
# wrapping for us, so read in the entire file, killing initial and final
# whitespace, join the lines together, and send the whole thing to the user.
# Note that the result will be truncated if it exceeds Calvin's buffer size
# of 1024 characters.
sub send_file {
    my $self = shift;
    my ($client, $user, $file) = @_;
    my $desc = '';
    open (FILE, $file) or return undef;
    while (<FILE>) {
        next if /^\s*$/;
        s/^\s+//;
        s/\s+$//;
        if (/\.$/) { $_ .= ' ' }
        $desc .= $_ . ' ';
    }
    chop $desc;
    $client->msg ($user, $desc);
}

# Send a directory listing to a user, prefixed by a message.  We skip all
# files beginning with ., so dotfiles can be used to hide files from all
# listings sent by descbot.  We also require that all the files be regular
# files and be readable by descbot.  If the total length of the directory
# listing exceeds 1024 characters, we split it into separate messages.
sub send_directory {
    my $self = shift;
    my ($client, $user, $message, $dir) = @_;
    opendir (DIR, $dir) or return undef;
    my @list = sort grep { ! /^\./ && -r "$dir/$_" } readdir DIR;
    closedir DIR;
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
    1;
}

# Send the owner of a given file (as "name <e-mail@address>").  Name is
# obtained via getpwuid().
sub send_owner {
    my $self = shift;
    my ($client, $user, $file) = @_;
    my $localhost = $self->localhost;
    my $uid = (stat $file)[4];
    my ($account, $name) = (getpwuid ($uid))[0,6];
    if (not defined $account) { return undef }
    $client->msg ($user, "$name <$account\@$localhost>");
}

# Find all characters in a directory who are owned by a certain person.
#  The list of characters is returned as a string, and split if it is greater
#  than 1024 characters.  0 is returned if no characters are found, 1
#  otherwise.
sub send_oneowner {
    my $self = shift;
    my ($client, $user, $player, $message, $dir) = @_;
    my ($file, @list);
    opendir (DIR, $dir) or return undef;
    my @filelist = sort grep { ! /^\./ && -r "$dir/$_" } readdir DIR;
    closedir DIR;
    foreach $file (@filelist) {
        my $uid = (stat "$dir/$file")[4];
        my ($account, $name) = (getpwuid ($uid))[0,6];
        if (not defined $account) { return undef }
        if ((defined $account) && (lc $account eq lc $player)) {
            push (@list, $file);
        }
    }
    if (!@list) { return 0 }
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
    1;
}

############################################################################
# Basic commands
############################################################################

# Send a description to a user.  We take the name of the object or character
# and an optional type; if type isn't specified, we use "default".
sub send_desc {
    my $self = shift;
    my ($client, $user, $char, $type) = @_;
    my $descroot = $self->descroot;
    $type = 'default' unless $type;
    if ($self->check_file ($char) && $self->check_file ($type)) {
        if ($self->send_file ($client, $user, "$descroot/$type/$char")) {
            return 1;
        }
    }
    $client->msg ($user, "No description of type $type for $char");
    return 0;
}

# Send the list of descriptions of a certain type to a user.  If no type is
# specified, assume "default".
sub send_list {
    my $self = shift;
    my ($client, $user, $type) = @_;
    my $descroot = $self->descroot;
    $type = 'default' unless $type;
    if ($self->check_file ($type)) {
        if ($self->send_directory ($client, $user, "Available descriptions: ",
                                          "$descroot/$type")) {
            return 1;
        }
    }
    $client->msg ($user, "Unknown type $type");
}

# Send the list of descriptions of a certain type, belonging to a certain
#  person, to a user.  If no type is specified, assume "default".
sub send_oneplayer {
    my $self = shift;
    my ($client, $user, $player, $type) = @_;
    my $descroot = $self->descroot;
    $type = 'default' unless $type;
    if ($self->check_file ($type)) {
        if ($self->send_oneowner ($client, $user, $player,
                                         "Characters for $player: ",
                                         "$descroot/$type")) {
            return 1;
        } else {
            $client->msg ($user, "No characters for $player under type $type");
            return 0;
        }
    }
    $client->msg ($user, "No descriptions of type $type");
}

# Send the name and address of the player of a given character.  If no type
# is specified, assume "default".
sub send_player {
    my $self = shift;
    my ($client, $user, $char, $type) = @_;
    my $descroot = $self->descroot;
    $type = 'default' unless $type;
    if ($self->check_file ($char) && $self->check_file ($type)) {
        if ($self->send_owner ($client, $user, "$descroot/$type/$char")) {
            return 1;
        }
    }
    $client->msg ($user, "No description of type $type for $char");
}

# Send the list of valid description types.
sub send_types {
    my $self = shift;
    my ($client, $user) = @_;
    my $descroot = $self->descroot;
    $self->send_directory ($client, $user, "Available description types: ",
                                  $descroot);
}


############################################################################
# Command parsing
############################################################################

# Parses a single line, splitting it on whitespace, and returns the
# resulting array.  Double quotes are supported for arguments that have
# embedded whitespace, and backslashes inside double quotes escape the next
# character (whatever it is).  Any text outside of double quotes is
# automatically lowercased (to support directives in either case), but
# anything inside quotes is left alone.  We can't use Text::ParseWords
# because it's too smart for its own good.
sub parse_line {
    my $self = shift;
    my ($line) = @_;
    my (@args, $snippet, $tmp);
    while ($line ne '') {
        $line =~ s/^\s+//;
        $snippet = '';
        while ($line !~ /^\s/ && $line ne '') {
            if (index ($line, '"') == 0) {
                $line =~ s/^\"(([^\"\\]|\\.)+)\"// or return undef;
                $tmp = $1;
                $tmp =~ s/\\(.)/$1/g;
                $snippet .= $tmp;
            } else {
                $line =~ s/^([^\"\s]+)//;
                $snippet .= lc $1;
            }
        }
        push (@args, $snippet);
    }
    @args;
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
    $self->descroot ('/calvin/descs/');
    $self->localhost ('eyrie.org');
    
    return $self;
}

# Sets the root directory for the descs if one is sent, returns the root
#  directory.
sub descroot {
    my $self = shift;
    if (@_) { $self->{DESCROOT} = shift }
    return $self->{DESCROOT};
}

# Sets the localhost if one is sent, returns the localhost.
sub localhost {
    my $self = shift;
    if (@_) { $self->{LOCALHOST} = shift }
    return $self->{LOCALHOST};
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
             'desc' => [
                        'Syntax:  desc <command> <arguments>  OR  desc <character> [<type>]',
                        'Valid commands:  !list <type>, !types, !player <character> [<type>]',
                        '                 !listchars <player> [<type>]',
                       ],
            );
    return %help;
}

# Returns a list containing all valid commands.
sub return_commands {
    my $self = shift;
    my (@commands) = ('desc',
                     );
    return @commands;
}

# Takes a line and performs any necessary functions on it.  If the line is
#  a command to the bot, return 1.  Return 0 otherwise.  Note that there can
#  be things for which we do functions, but return 0.  These are lines such
#  as signon messages, which more than one bot may wish to know about.
sub handle_line {
    my $self = shift;
    my ($manager, $client, $line, %result) = @_;

    if (($result{'code'} != C_WHIS) || ($result{'s1'} =~ /^- /) ||
        $result{'on_channels'}) {
        return 0;
    }

    # Clean up the message and parse it.  If the parsing comes with a
    #  bad result (such as unbalanced "'s) return an error message.
    my $message = $result{'s1'};
    $message =~ s/\s+$//;
    my ($prefix, $command, @args) = $self->parse_line ($message);
    if (!defined $prefix) {
        $client->msg ($result{'name'}, "Parse error in \"$message\".");
        return 1;
    }
    
    if ($prefix eq 'desc') {
        # Hand off to the appropriate sub based on the command.
        if      ($command eq '!list')    {
            $self->send_list ($client, $result{'name'}, @args);
            return 1;
        } elsif ($command eq '!player')  {
            $self->send_player ($client, $result{'name'}, @args);
            return 1;
        } elsif ($command eq '!types')   {
            $self->send_types ($client, $result{'name'});
            return 1;
        } elsif ($command eq '!listchars') {
            $self->send_oneplayer ($client, $result{'name'}, @args);
            return 1;
        } elsif ($command eq '') {
            $client->msg ($result{'name'}, "Use \%$client->{nick} help desc for help.");
        } else                   {
            $self->send_desc ($client, $result{'name'}, $command, @args);
            return 1;
        }
    } else { return 0 }
}

1;
