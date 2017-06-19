# Calvin::Logs - Functions for handling log names and directories
#
# Copyright 2017 by Jon Robertson <jonrober@eyrie.org>
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

############################################################################
# Modules and declarations
############################################################################

package Calvin::Logs;
require 5.002;

use strict;

use Cwd;
use Date::Parse;
use POSIX qw(strftime);

use vars qw();

######################################################################
# Filename parsing
######################################################################

# Given the name of a file, separate it into directory and file, then apply
# dated directories if not yet there.
#
# Formerly get_fname.
sub parse_filename {
    my ($self, $fname) = @_;

    my $dated_dirs = $self->dated_dirs;
    my $dir        = '';

    # Take the name of the file and split it up into directory and file.
    if ($fname =~ m{^(.+/)?([^/]+)$}) {
        $dir   = $1 || '';
        $fname = $2;
    }

    # If we're using dated directories, then find the right subdirectory.
    if ($dated_dirs && $fname =~ /^(\d+)-(\d+)-/) {
        my $subdir = "$1-$2";

        # If the current directory ends in the appropriate YYYY-MM name,
        # chdir to the previous dir so that we're in the root and will
        # have our work be straightforward during rollover.
        # TODO: Check to see if this is ever needed.  We should use paths
        #       rather than chdir.  Need everything using this first though.
        my $cwd = cwd();
        if ($cwd =~ /$subdir\/?$/) {
            chdir('..');
        }

        # Add the subdirectory to the directory if not there already.
        $dir .= $subdir if $dir !~ /$subdir\/?$/;
        $dir .= '/' unless $dir =~ m{/$};
    }

    return ($dir, $fname);
}

######################################################################
# Generating filenames
######################################################################

# Finds filename given date, directory, and type (offset or not).
#  Long-term, improve this to not assume suffix from directory, but grab
#  the directory and use a regex to match the right file.
sub find_fname {
    my ($self, $date, $type) = @_;

    my $dir = $self->dir;

    my ($prefix, $suffix, $fulldir, @list);
    my ($yearmonth) = ($date =~ /^(\d{4}-\d{2})-/);
    return '' unless $yearmonth;

    $fulldir = $dir . $yearmonth . '/';
    return '' unless -d $fulldir;

    opendir (DIR, $fulldir)
        or die "Error in find_fname looking at directory $fulldir: $!.\n";
    if ($type eq 'offset') {
        @list = sort grep { /^\.offset-$date/ && -f "$fulldir$_" } readdir DIR;
    } else {
        @list = sort grep { /^$date/ && -f "$fulldir$_" } readdir DIR;
    }
    closedir DIR;

    return $fulldir . $list[0] if @list;
    return '';
}

# Find and return the last sorted file in the set directory.
sub last_file {
    my ($self) = @_;

    my $dir        = $self->dir;
    my $dated_dirs = $self->dated_dirs;

    $dir ||= './';
    my (@list);

    # If we have dated subdirs, find the last of them to add to the directory.
    if ($dated_dirs) {
        opendir (DIR, $dir) or die "Error in last_file looking at dirs: $!.\n";
        @list = sort grep { ! /^\./ && /^\d{4}-\d{2}$/ && -d "$dir$_" } readdir DIR;
        closedir DIR;
        $dir .= $list[-1] . '/' if @list;
    }

    # Now actually check the files in the directory to find all.
    opendir (DIR, $dir) or die "Error in last_file looking at files: $!.\n";
    @list = sort grep { ! /^\./ && -f "$dir$_" } readdir DIR;
    closedir DIR;
    return '' unless @list;

    # Now get the last listed file, clean, and return.
    my $lastfile = $dir . $list[-1];
    $lastfile =~ s/^\.\///;
    return $lastfile;
}

# Find the next filename to read from at rollover.  Returns the filename or
# empty string if none.
#
# $line       - Closing line for the current log
#
# Misc: Renamed from roll_over_log.
sub next_log {
    my ($self, $line) = @_;

    my $dated_dirs = $self->dated_dirs;
    my $roll_mode  = $self->rollover_mode;
    my $fname      = $self->filename;
    my $dir        = $self->dir;

    my $place   = -1;
    my $nextdir = '';

    # Parse the closing logfile line to get the date of the next log.
    my $nextdate;
    if ($line =~ /closing logfile at (.+)\.$/) {
        $nextdate = str2time($1);

        if ($dated_dirs) {
            $nextdir = strftime('%Y-%m', localtime($nextdate));
            if ($dir =~ /$nextdir\/$/) { $nextdir = '' }
            else { $dir =~ s#^((.+?/)*)(.+)/$#$1$nextdir/# }
        }
    }

    # This roll mode means we're just picking the next file in the directory,
    # no matter what the supposed next log date is.
    if ($roll_mode eq 'nextfile') {

        # Still no directory?  Then assume current directory.
        $dir ||= './';

        # Get a list of all files in our directory.  Return if the list is
        # empty.
        opendir (DIR, $dir) or return undef;
        my @list = sort grep { ! /^\./ && -r "$dir$_" } readdir DIR;
        closedir DIR;
        return '' unless @list;

        # If we've moved to a new directory, pick the first file in it.
        if ($nextdir ne '') {
            $place = 0;

        # Otherwise same directory, so find the previous file and pick the
        # next one.
        } else {
            for (my $i = 0; $i < @list; $i++) {
                if ($list[$i] eq $fname) {
                    $place = $i + 1;
                    last;
                }
            }
        }

        # If the placement is out of bounds, return ''.  Otherwise create the
        # new file from directory and list, then strip current directory and
        # return.
        return '' if $place == -1 || $place > $#list;
        my $newfile = $dir . $list[$place];
        $newfile =~ s/^\.\///;
        return $newfile;

    } else {
        if ($fname =~ /(\d+)-\d+-\d+-(\w+\.\w+)(.gz)?$/) {
            my $oldyear  = $1;
            my $basename = $2;

            # Check to see if the log used two or four digits for year in
            # deciding what the next log should look like.
            my $datefmt;
            if ($oldyear =~ /^\d{2}$/) {
                $datefmt = '%y-%m-%d';
            } else {
                $datefmt = '%Y-%m-%d';
            }

            # Generate the new filename and strip current dir if needed.
            my $newfile = $dir . strftime($datefmt, localtime($nextdate))
                . '-' . $basename;
            $newfile =~ s/^\.\///;

            # Finally check to see if there's a file by the newfile name ending
            # in .gz or without.  If neither, there's nothing to roll to.
            return $newfile . 'gz' if -f $newfile . 'gz';
            return $newfile        if -f $newfile;
            return '';
        }
    }
    return '';
}

######################################################################
# Directory handling
######################################################################

# Returns a list of all subdirectories of a directory that do not begin
#  with '.'.
sub subdirs {
    my ($self) = @_;

    my $dir = $self->dir;

    opendir (DIR, $dir) or die "Error in subdirs looking at dirs: $!.\n";
    my @list = sort grep { ! /^\./ && -d $dir.$_ } readdir DIR;
    @list = map { $dir.$_.'/' } @list;
    closedir DIR;
    return (@list);
}

######################################################################
# Offsets
######################################################################

# Given a offsets filename and a new directory layout flag, parse the file for
# the channels used, their tags, and offsets.  Return those offsets as an
# array of arrays.
sub parse_offsetfile {
    my ($self) = @_;

    my $dir = $self->dir;
    my $fname = $self->filename;
    $fname = $dir . $fname;

    $fname =~ s/^((.+?\/)*)(.*)$/$1.offset-$3/;
    return () unless -f $fname;
    open(FILE, $fname) || die "Could not open file $fname in parse_offsetfile: $!.\n";

    my (@offsets);
    while (<FILE>) {
        if (/^(\d+) +(\[.*\]) (\d+) (.*)/) {
            push @offsets, [($1, $2, $3, $4)];
        } elsif (/^(\d+) +(\[.*\]) (\d+)/) {
            push @offsets, [($1, $2, $3)];
        }
    }

    return (@offsets);
}

############################################################################
# Setup functions
############################################################################

# Set or query for whether we are to use dated subdirs (YYYY-MM).
sub dated_dirs {
    my ($self, $setting) = @_;
    if (defined $setting) {
        if ($setting == 1 || $setting == 0) {
            $self->{DATED_DIRS} = $setting;
        } else {
            warn "setting '$setting' is invalid for dated_dirs, use 0 or 1\n";
        }
    }

    return $self->{DATED_DIRS};
}

# Set or query whether we are to use the rollover method of strict (find the
# next file by the date of the ending line of the current file) or nextfile
# (find the next file in the directory).
sub rollover_mode {
    my ($self, $setting) = @_;
    if (defined $setting) {
        if ($setting eq 'strict' || $setting eq 'nextfile') {
            $self->{ROLLOVER_MODE} = $setting;
        } else {
            warn "setting '$setting' is invalid for rollover_mode, use strict or nextfile\n";
        }
    }

    return $self->{ROLLOVER_MODE};
}

# Set and query a filename.  When given a filename, process it for anything
# that needs cleaning, then set.
sub filename {
    my ($self, $raw_fname) = @_;

    if (defined $raw_fname) {
        my ($dir, $fname) = $self->parse_filename($raw_fname);
        $self->{DIR}   = $dir;
        $self->{FNAME} = $fname;
    }

    return $self->{FNAME};
}

# Query or set the directory.
sub dir {
    my ($self, $dir) = @_;

    if (defined $dir) {
        $self->{DIR} = $dir;
    }

    return $self->{DIR};
}

# Create a new log object.
sub new {
    my ($class, $config) = @_;

    my $self = {};
    bless ($self, $class);

    $self->{FNAME}         = undef;
    $self->{DIR}           = undef;
    $self->{DATED_DIRS}    = 1;
    $self->{ROLLOVER_MODE} = 'strict';

    return $self;
}

1;
