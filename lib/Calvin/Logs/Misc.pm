# Calvin::Logs::Misc - General functions for log processing
#
# Copyright 2017 by Jon Robertson <jonrober@eyrie.org>
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

############################################################################
# Modules and declarations
############################################################################

package Calvin::Logs::Misc;
require 5.002;

use strict;

BEGIN {
    use Exporter ();
    use vars qw (@ISA @EXPORT_OK);
    @ISA = qw (Exporter);
    @EXPORT_OK = qw (&to_numeric);
}

use vars @EXPORT_OK;

######################################################################
# Line handling
######################################################################

# Converts a line that's been stripped of numeric markup to one that has the
# numeric tags.  This isn't perfect as stripping the numerics in the first
# place is a lossy process, but works well enough and lets us handle personal
# and old logs with the same code as we do for numeric logs.
sub to_numeric {
    $_ = shift;
    my ($defnum) = @_;
    local $SIG{__WARN__} = sub {
        for ($_[0]) { warn $_ unless /Use of uninitialized value/ }
    };

    s/\\/\\1/g;
    s/\|/\\2/g;

    # If the line's from the default channel, give it a dummy number.
    s/^(<|\[|{)(?!\d+:)/$1$defnum: /;
    if (/^(\*|##) / and !/^(\*|##) \[?\d+:/ and !/^(\*|##) -> /) {
        if   (s/^(\*|##) (\[|{)/$1 $2$defnum: /) { }
        else { s/^(\*|##) /$1 $defnum: / }
    }

    # Empty or bot messages.
    if    (/^% /)                                                        { }
    elsif (/^CC: /)                                                      { }
    elsif (/^---- Recall \w+ ----/)                                      { }
    elsif (/^\s*$/)                                                      { }

    # /trustchars rewriting.
    elsif (s/^\{(\d+): (.*?)\} (.*) <(\S+)>$/1026 <|c$1|E: |2$2|E> |1$3|E [|n$4|E]/) { }
    elsif (s/^\* \{(\d+): (.*)\}\s+<(\S+)>$/1025 * |c$1|E: |1$2|E [|n$3|E]/) { }

    # Rewrite new server stuff.
    elsif (s/^<(\d+): (.*?)> (.*) \[(\S+)\]$/1026 <|c$1|E: |2$2|E> |1$3|E [|n$4|E]/) { }
    elsif (s/^<(.*?)> (.*) \[(\S+)\]$/1006 <|2$2|E> |1$3|E [|n$4|E]/) { }
    elsif (s/^\* (\d+): (.*) \[(\S+)\]$/1025 * |c$1|E: |1$2|E [|n$3|E]/) { }
    elsif (s/^\* \[(\d+): (.*)\] \[(\S+)\]$/1035 * [|c$1|E: |1$2|E] [|n$3|E]/) { }
    elsif (s/^\* (.*) \[(\S+)\]$/1005 * |1$1|E [|n$2|E]/) { }

    # Rewrite brackets.
    elsif (s/^<(\d+): (\S+)> \[([^][]+)\] +([^][].*)$/1026 <|c$1|E: |2$3|E> |1$4|E [|n$2|E]/) { }
    elsif (s/^<(\d+): (\S+)> \[([^][]+)\]( +\[.*)$/1025 * |c$1|E: |1$3$4|E [|n$2|E]/) { }
    elsif (s/^<(\d+): (\S+)> \[([^][]+)\] *$/1025 * |c$1|E: |1$3|E [|n$2|E]/) { }
    elsif (s/^\[(\d+): (\S+)\] \[([^][]+)\] *$/1035 * [|c$1|E: |1$3|E] [|n$2|E]/) { }
    elsif (s/^\[(\d+): (\S+)\] \[([^][]+)\]( +\[.*)$/1035 * [|c$1|E: |1$3$4|E] [|n$2|E]/) { }

    # Rewrite messages from non-default channel.
    elsif (s/^<(\d+): (.+?)>(?: (.*))?$/1021 <|c$1|E: |n$2|E> |1$3|E/)         { }
    elsif (s/^\[(\d+): (.+?)\](?: (.*))?$/1031 [|c$1|E: |n$2|E] |1$3|E/)       { }
    elsif (s/^\* (\d+): (\S+) *$/1022 * |c$1|E: |n$2|E |1|E/)            { }
    elsif (s/^\* (\d+): (\S+) (.*)/1022 * |c$1|E: |n$2|E |1$3|E/)        { }
    elsif (s/^\* \[(\d+): (\S+)( (.*))?\]$/1032 * [|c$1|E: |n$2|E |1$4|E]/) { }
    elsif (s/^\#\# (\d+): (\S+) rolled (.+)/1024 ## |c$1|E: |n$2|E rolled |1$3|E/) { }
    elsif (s/^\#\# \[(\d+): (\S+) rolled (.+)\]/1034 ## [|c$1|E: |n$2|E rolled |1$3|E]/) { }

    # Rewrite whispers.
    elsif (s/^\*([^* ]|\S{2,})\* \[(.*)\]$/1115 *|n$1|E* [|1$2|E]/)      { }
    elsif (s/^-> \*([^* ]|\S{2,})\* \[(.*)\]$/1105 -> *|n$1|E* [|1$2|E]/) { }
    elsif (s/^\*([^* ]|\S{2,})\* (.*)/1111 *|n$1|E* |1$2|E/)             { }
    elsif (s/^-> \*([^* ]|\S{2,})\* (.*)/1101 -> *|n$1|E* |1$2|E/)       { }
    elsif (s/^\*> (\S+) (.*)/1112 *> |n$1|E |1$2|E/)                     { }
    elsif (s/^\* -> (\S+) (.*)/1102 * -> |n$1|E |1$2|E/)                 { }
    elsif (s/^\#\#> (\S+) \S+ (.+)/1114 ##> |n$1|E rolled |1$2|E/)       { }
    elsif (s/^\#\# -> (\S+): \S+ \S+ (.*)/1104 ## -> |n$1|E rolled |1$2|E/) { }

    # Connect/signoff/leave/join messages.
    elsif (s/^\*{3} (\S+) connected at (.*) from (\S+)\./2001 *** |n$1|E connected at |d$2|E from |A$3|E./)
                                              { }
    elsif (s/^\*{3} Signoff: (\S+) \((.*)\) at (.*)\./2002 *** Signoff: |n$1|E (|1$2|E) at |d$3|E./)
                                              { }
    elsif (s/^\*{3} (\S+) has left channel (\d+) \[(.*?)\]\./2003 *** |n$1|E has left channel |c$2|E [|t$3|E]/)
                                              { }
    elsif (s/^\*{3} (\S+) has joined channel (\d+) \[(.*)\]\./2004 *** |n$1|E has joined channel |c$2|E [|t$3|E]./)
                                              { }

    # @topic messages.
    elsif (s/^\*{3} (\S+) (has changed the topic on channel) (\d+) to (.*)/2102 *** |n$1|E $2 |c$3|E to |t$4|E./)
                                              { }

    # Channels on/default channels messages.
    elsif (s/^(\*{3} You are currently on channels:) (.+)\./3001 $1 |C$2|E./) { }
    elsif (s/^(\*{3} You are not currently on any channels\.)/3002 $1/)  { }

    elsif (s/^(\*{3} Your nickname is) (\S+)\./3201 $1 |n$2|E./)         { }
    elsif (s/^(\*{3} You are now known as) (\S+)\./3203 $1 |n$2|E./)     { }
    elsif (s/^\*{3} (\S+) is now known as (\S+)\./3204 *** |1$1|E is now known as |n$2|E./)
                                              { }

    # @list messages.
    elsif (s/^(\*{3} Current users on channel) (\d+) \[(.*)\]:/4101 $1 |c$2|E [|t$3|E]:/)
                                              { }
    elsif (s/^(\*{3} Current users on the chatserver:)/4102 $1/)         { }
    elsif (s/^\*{3} (\S+)(\s+)\[idle(\s+)(.+)\] <ch\. ((\d+ ?)+)?>/4103 *** |n$1|E$2\[idle$3|i$4|E\] <ch. |C$5|E>/)
                                              { }

    # @users mesage.
    elsif (s/^\*{3} (\d+)(\s+)\[idle(\s+)(.+?)\] (.*)/4201 *** |c$1|E$2\[idle$3|I$4|E\] |1$5|E/)
                                              { }

    # @time messages.
    elsif (s/^(\*{3} It is currently) (.*)\./4401 $1 |d$2|E./)           { }

    elsif (s/^\*{3}/9999 ***/)                 { }
    elsif (/^390[1-3]/)                        { return ''    }
    #    else  { print "Error in to_numerics ($ARGV): $_\n"; return undef }
    #    print;
    return $_;
}

1;
