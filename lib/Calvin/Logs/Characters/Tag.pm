# Calvin::Logs::Characters - Character parsing functions for Calvin chatservs
#
# Copyright 2017 by Jon Robertson <jonrober@eyrie.org>
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

############################################################################
# Modules and declarations
############################################################################

package Calvin::Logs::Characters::Tag;
use 5.010;
use autodie;
use strict;
use warnings;

use Fcntl qw(LOCK_EX LOCK_NB);
use File::Copy qw(move);
use JSON;
use Perl6::Slurp;

my $DATA_DIR   = '/srv/calvin/chardata/';
my $TAGS_FNAME = $DATA_DIR . 'tags.json';
my $LOCKFILE   = $DATA_DIR . '.lockfile';

#############################################################################
# File handlers
#############################################################################

# Create a lockfile to show that we are already running against a file that
# needs to not be clobbered.
#
# $lockfile       - Filename of the lockfile to use
# $max_lockchecks - Maximum number of times to try locking
# $rest           - Seconds to rest between checks
#
# Returns: 1 on success
#          undef on failure
sub lock_queue {
    my ($lockfile, $max_lockchecks, $rest) = @_;
    my $count = 0;
    open (LOCKFILE, '>', $lockfile);
    while ($count < $max_lockchecks) {
        if (flock (LOCKFILE, LOCK_EX | LOCK_NB)) {
            return 1;
        } else {
            $count++;
            sleep $rest unless ($count == $max_lockchecks);
        }
    }

    die "unable to lock lockfile after $count attempts\n";
}

# Removes a lockfile at the end of a run.
#
# $lockfile       - Filename of the lockfile to use
#
# Returns: Return value of the unlink
sub unlock_queue {
    my ($lockfile) = @_;
    close LOCKFILE;
    if (-f $lockfile) {
        unlink $lockfile;
    } else {
        warn "lockfile $lockfile did not exist\n";
    }
}

# Load JSON content from a file, parse it, and return the resulting hashref
# for the data.
#
# $fname - filename to load JSON data from
#
# Returns: hash of the file data
sub load_json_file {
    my ($fname) = @_;

    my $json_obj = JSON->new->allow_nonref;
    my $data_ref;
    if (-e $fname) {
        my $tmp_json = slurp $fname;
        $data_ref = $json_obj->decode($tmp_json);
    } else {
        my %arr = ();
        $data_ref = \%arr;
    }

    return %{ $data_ref };
}

# Save a hashref of data to a file as JSON data.  We first save to a temp
# filename and then copy over.
#
# $data_ref - hash reference of data to save
# $fname    - filename to save to
#
# Returns: nothing
sub save_json_file {
    my ($data_ref, $fname) = @_;

    my $lockfile = $fname . '.lock';

    my $json_obj = JSON->new->allow_nonref;
    my $tmp_fname = $fname.'.bak';
    open(my $fh, '>', $tmp_fname);
    print {$fh} $json_obj->pretty->encode($data_ref);
    close($fh);
    move($tmp_fname, $fname);

    return;
}

#############################################################################
# Misc functions
#############################################################################

# Given a tag and the hash of all tags, figure out what tags are descendants
# of the given tag.  Our convention for this is that various 'levels' of a tag
# are separated by :, so anything set for x:y:z should also be returned when we
# search for just x or x:y.
sub tag_rolldown {
    my ($self, $tag) = @_;

    my %valid_tags;
    for my $check_tag (keys %{ $self->{TAGS} }) {
        next unless $tag eq $check_tag || $check_tag =~ m{^$tag:};
        $valid_tags{$check_tag} = 1;
    }

    return keys %valid_tags;
}

# Return a list of characters that have a specific tag.  Use a
# Calvin::Logs::Characters object that already has a filter applied to only
# show some characters.
sub characters {
    my ($self, $tag, $charobj) = @_;

    die "tag '$tag' does not exist\n" unless exists $self->{TAGS}->{$tag};

    # Get a rolldown of any children of the current tag.
    my @valid_tags = $self->tag_rolldown($tag);
    die "tag '$tag' has no characters assigned it\n" unless @valid_tags;

    # For each tagged character, check to see if it passes our filter.
    my @output;
    for my $t (@valid_tags) {
        for my $charkey (keys %{ $self->{TAGS}->{$t} }) {
            my ($char, $player) = split(':', $charkey);
            next unless $charobj->exists($char, $player);

            push (@output, $charkey);
        }
    }

    return sort @output;
}

# Given a tag and character, return 1 if the character has that tag, 0
# otherwise.  Use tag_rolldown to find children of that tag as well.
sub has_tag {
    my ($self, $tag, $char) = @_;

    my @valid_tags = $self->tag_rolldown($tag);
    for my $t (@valid_tags) {
        return 1 if exists $self->{TAGS}->{$t}->{$char};
    }

    return 0;
}

# Create a new tag if one does not already exist.
sub add {
    my ($self, $tag) = @_;

    die "tag '$tag' already exists\n" if exists $self->{TAGS}->{$tag};
    %{ $self->{TAGS}->{$tag} } = ();
    save_json_file($self->{TAGS}, $TAGS_FNAME);
}

# Renames an existing tag.
sub rename_tag {
    my ($self, $oldtag, $newtag) = @_;

    die "tag '$oldtag' does not exist\n" unless exists $self->{TAGS}->{$oldtag};
    die "tag '$newtag' already exists\n" if exists $self->{TAGS}->{$newtag};

    # Copy and delete the tag and save the result.
    $self->{TAGS}->{$newtag} = $self->{TAGS}->{$oldtag};
    delete $self->{TAGS}->{$oldtag};
    save_json_file($self->{TAGS}, $TAGS_FNAME);
}

# Removes an existing tag only if it's empty of characters.
sub remove {
    my ($self, $tag) = @_;

    die "tag '$tag' does not exist\n" unless exists $self->{TAGS}->{$tag};
    die "tag '$tag' is not empty\n" if keys %{ $self->{TAGS}->{$tag} };

    delete $self->{TAGS}->{$tag};
    save_json_file($self->{TAGS}, $TAGS_FNAME);
}

# Assign a given set of characters to an existing tag.
sub assign {
    my ($self, $tag, @characters) = @_;

    die "tag '$tag' does not exist\n" unless exists $self->{TAGS}->{$tag};

    # Add any characters.  They will be sent to us in $character:$player form.
    for my $char (@characters) {
        $self->{TAGS}->{$tag}->{$char} = 1;
    }

    save_json_file($self->{TAGS}, $TAGS_FNAME);
}

# Remove a given set of characters from a tag.
sub unassign {
    my ($self, $tag, @characters) = @_;

    die "tag '$tag' does not exist\n" unless exists $self->{TAGS}->{$tag};

    for my $char (@characters) {
        warn "no tag '$tag' for $char\n"
            unless exists $self->{TAGS}->{$tag}->{$char};
        delete $self->{TAGS}->{$tag}->{$char};
    }

    save_json_file($self->{TAGS}, $TAGS_FNAME);
}

# Get and return our current set of tags.  Only load from the file if it's not
# already set.
sub tags {
    my ($self) = @_;

    return %{ $self->{TAGS} } if defined $self->{TAGS};

    lock_queue($LOCKFILE, 30, 2);
    my %tags = load_json_file($TAGS_FNAME);
    $self->{TAGS} = \%tags;
    return %tags;
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
    my $fname;
    $config ||= {};
    if (exists $config->{tag_file}) {
        $fname = $config->{tag_file};
    } else {
        $fname = $TAGS_FNAME;
    }

    $self->{FNAME} = $fname;
    $self->{TAGS} = undef;
    $self->tags;

    return $self;
}

# Unlock the lockfile (used for tags) if we did tagfile operations.
DESTROY { unlock_queue($LOCKFILE) if -f $LOCKFILE; }

1;
