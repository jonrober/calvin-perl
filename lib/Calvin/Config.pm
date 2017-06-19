# Calvin::Config -- Autofunctions in creating a bot from msg or config
# file.
#
# Copyright 1999 by Jon Robertson <jonrober@eyrie.org>
#
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

############################################################################
# Modules and declarations
############################################################################

package Calvin::Config;
require 5.002;

use strict;
use vars qw($host %bottypes);

# Default hostname, for descbot.
$host = 'haven.eyrie.org';
%bottypes = (
             'cambot'   => \&make_cambot,
             'descbot'  => \&make_descbot,
             'nagbot'   => \&make_nagbot,
             'fengroll' => \&make_fengroll,
             'standard' => \&make_standard,
            );


############################################################################
# Misc functions.
############################################################################

# Is sent client, error message, either usernick or empty string, and
#  whether the error is fatal to creating a bot.  Prints error and dies if
#  empty string (no specified user).  Otherwise msgs user with error string.
sub send_error {
    my ($client, $user, $error, $fatal) = @_;

    if    ($user ne '') { $client->msg($user, $error) }
    elsif (!$fatal)     { print STDOUT $error."\n"    }
    else                { die $error."\n"             }

    return $fatal;
}


############################################################################
# Bot creators
############################################################################

sub make_cambot {
    my ($client, $user, $config) = @_;
    my $cambot = new Calvin::Bots::Cambot;
    my $error;

    # Defaults.
    $cambot->enable_recall(0);

    # Settable configuration.
    if ($config =~ s/\breadlog=(\d+)\b//)       { $cambot->max_readlog($1)   }
    if ($config =~ s/\brecchan=(\d+)\b//)       { $cambot->max_recchan($1)   }
    if ($config =~ s/\bbasename=(\S+)//)        { $cambot->basename($1)      }
    if ($config =~ s/\bperm_channels='(.*?)'//) { $cambot->perm_channels($1) }
    if ($config =~ s/\bmax_sessions=(\d+)\b//)  { $cambot->max_sessions($1)  }
    if ($config =~ s/\bspamflag=(\S+)\b//)      { $cambot->spamflag($1)      }

    while ($config =~ s/\bautojoin='(\d+), (.*?[^\\])'//) {
        my ($chan, $tag) = ($1, $2);
        $tag =~ s#\\'#'#;
        $cambot->autojoin($chan, $tag);
    }
    if ($config =~ s/\brecall_passwd=(\S+)//) {
        $cambot->enable_recall(1);
        my $passwd = crypt($1, 'jr');
        $cambot->recall_passwd($passwd);
    }
    if ($config =~ s/\brecall=(yes|no)\b//) {
        if ($1 eq 'yes') { $cambot->enable_recall(1) }
        else             { $cambot->enable_recall(0) }
    }
    if ($config =~ s/\baddtime=(yes|no)\b//) {
        if ($1 eq 'yes') { $cambot->add_time(1) }
        else             { $cambot->add_time(0) }
    }
    if ($config =~ s/\busenumerics=(yes|no)\b//) {
        if ($1 eq 'yes') { $cambot->use_numerics(1) }
        else             { $cambot->use_numerics(0) }
    }
    if ($config =~ s/\bspam_after_invite=(yes|no)\b//) {
        if ($1 eq 'yes') { $cambot->spam_after_invite(1) }
        else             { $cambot->spam_after_invite(0) }
    }

    if ($config =~ s/\blogdir='(.*?)'//) {
        my $logdir = $1;
        if (-d $logdir) {
            if (-x $logdir && -w $logdir) {
                my ($mode) = (stat($logdir))[2];
                $mode = $mode & 0777;
                $mode = sprintf "%o", $mode;
                if ($mode !~ /33$/) {
                    $error = "Security warning: dir '$logdir' is ".
                        "accessible to others.";
                    send_error($client, $user, $error, 0);
                } else {
                    ($mode) = (stat($logdir."/.."))[2];
                    $mode = $mode & 0777;
                    $mode = sprintf "%o", $mode;
                    if ($mode !~ /11$/) {
                        $error = "Security warning: parent of '$logdir' ".
                            "is accessible to others.";
                        send_error($client, $user, $error, 0);
                    }
                }
                $cambot->logdir($logdir);
            } else {
                $error = "Incorrect permissions: '$logdir'.";
                send_error($client, $user, $error, 1);
                return undef;
            }
        } else {
            $error = "Nonexistant log directory: '$logdir'.";
            send_error($client, $user, $error, 1);
            return undef;
        }
    } else {
        $error = "You must specify a log directory for Cambot.";
        send_error($client, $user, $error, 1);
        return undef;
    }

    # Make sure there are no bad config directives.
    if ($config =~ /\S/) {
        $config =~ s/^\s*(.*)\s*$/$1/;
        $error = "Error in Cambot config: '$config'.";
        send_error($client, $user, $error, 1);
        return undef;
    } else {
        return $cambot;
    }
}

sub make_nagbot {
    my ($client, $user, $config) = @_;
    my $nagbot = new Calvin::Bots::Nagbot;

    # Make sure there are no bad config directives.  Nagbot doesn't
    #  take any configurations.
    if ($config =~ /\S/) {
        $config =~ s/^\s*(.*)\s*$/$1/;
        my $error = "Error in Nagbot config: '$config'.";
        send_error($client, $user, $error, 1);
        return undef;
    } else {
        return $nagbot;
    }
}

sub make_standard {
    my ($client, $user, $config) = @_;
    my $standard = new Calvin::Bots::Standard;

    # Default settings.
    $standard->say_ok(0);
    $standard->ping_ok(1);
    $standard->quit_ok(1);
    $standard->renick_ok(1);

    # Settable configuration.
    if ($config =~ s/\bping=(yes|no)\b//) {
        if ($1 eq 'yes') { $standard->ping_ok(1) }
        else             { $standard->ping_ok(0) }
    }
    if ($config =~ s/\btime=(yes|no)\b//) {
        if ($1 eq 'yes') { $standard->time_ok(1) }
        else             { $standard->time_ok(0) }
    }
    if ($config =~ s/\bsay=(yes|no)\b//) {
        if ($1 eq 'yes') { $standard->say_ok(1) }
        else             { $standard->say_ok(0) }
    }
    if ($config =~ s/\brenick=(yes|no)\b//) {
        if ($1 eq 'yes') { $standard->renick_ok(1) }
        else             { $standard->renick_ok(0) }
    }

    # Make sure there are no bad config directives.
    if ($config =~ /\S/) {
        $config =~ s/^\s*(.*)\s*$/$1/;
        my $error = "Error in Standard config: '$config'.";
        send_error($client, $user, $error, 1);
        return undef;
    } else {
        return $standard;
    }
}

sub make_descbot {
    my ($client, $user, $config) = @_;
    my $descbot = new Calvin::Bots::Descbot;
    my $error;

    # Default configuration.
    $descbot->localhost($host);

    # Settable configuration.
    if ($config =~ s/\bdescroot='(.*?)'//) {
        if (-d $1 && -w $1) {
            $descbot->descroot($1);
        } else {
            $error = "Bad desc root: '$1'.";
            send_error($client, $user, $error, 1);
            return undef;
        }
    } else {
        $error = "You must specify a directory for Descbot.";
        send_error($client, $user, $error, 1);
        return undef;
    }

    # Make sure there are no bad config directives.
    if ($config =~ /\S/) {
        $config =~ s/^\s*(.*)\s*$/$1/;
        $error = "Error in Descbot config: '$config'.";
        send_error($client, $user, $error, 1);
        return undef;
    } else {
        return $descbot;
    }
}

sub make_fengroll {
    my ($client, $user, $config) = @_;

    # Make bot and defaults.
    my $fengroll = new Calvin::Bots::Fengroll;
    $fengroll->roll_channel(25);

    # Settable configuration.
    if ($config =~ s/\broll_chan=(\d+)\b//) { $fengroll->roll_channel($1) }
    if ($config =~ s/\bpasswd=(\S+)\b//)    { $fengroll->passwd($1)       }

    if ($config =~ /\S/) {
        $config =~ s/^\s*(.*)\s*$/$1/;
        my $error = "Error in Fengroll config: '$config'.";
        send_error($client, $user, $error, 1);
        return undef;
    } else {
        return $fengroll;
    }
}


############################################################################
# Config makers
############################################################################

# Send a manager, client, user, and argument line, then create a new bot
#  using that configuration line.
sub make_bot {
    my ($client, $user, $args) = @_;
    my ($nick, $server, $found_standard, $port, @connect, @bot_names);
    $found_standard = 0;

    ($nick, $server, $port, $args) = split(/\s+/, $args, 4);
    @connect = ($server, $port, $nick);
    foreach my $bot (split(/;\s*/, $args)) {
        my ($bot_type, $bot_args) = split(/\s+/, $bot, 2);
        if (!defined $bot_args) { $bot_args = '' }
        $bot_type = lc $bot_type;
        my $newbot;

        $found_standard++ if $bot_type eq 'standard';
        if (exists $bottypes{$bot_type}) {
            $newbot = &{$bottypes{$bot_type}}($client, $user, $bot_args);
        } else {
            $newbot = undef;
        }

        if (defined $newbot) { push (@connect, $newbot) }
        else                 { return undef             }
        push (@bot_names, ucfirst($bot_type));
    }

    # If they didn't ask for a standard bot, tough.  Define the default
    #  settings for one and add it in.
    if (!$found_standard) {
        my $newbot = make_standard ($client, $user, '');
        push (@connect, $newbot);
        push (@bot_names, 'Standard');
    }

    # Add the connection to the manager, make connect, initialize help,
    #  and confirm for the user.  Add info string
    my $connect_data;
    if ($user ne '') {
        $connect_data = "Bot $nick on $server $port by $user, using: ";
        $client->msg ($user, "Bot $nick has been created for $server $port.");
    } else {
        $connect_data = "Bot $nick on $server $port by config file using: ";
    }
    $connect_data .= join(', ', @bot_names).'.';
    push (@connect, $connect_data);
    return @connect;
}


# Reads from a config file and reformats it into valid arguments to
#  make_bot, then sends each to make_bot to create the bots.
sub config_rc {
    my ($fname) = @_;
    my (@config, @newbots, $i);
    $i = 0;

    open(CONFIG, $fname) ||
        die "Error loading specified config file $fname: $!\n";

    while (<CONFIG>) {
        next unless /\S/;
        s/^\s+//;
        s/\s+$//;
        tr/\r\n//d;
        if (/^autojoin (.*)/) {
            my $tag;
            ($tag = $1) =~ s#'#\\'#;
            $_ = "autojoin='$tag'";
        }

        if    (/^connect end/)               { $i++                         }
        elsif (/^connect (\S+) (\S+) (\d+)/) { $config[$i] = "$1 $2 $3"     }
        elsif (/^bot end/)                   { $config[$i] .= ';'           }
        elsif (/^bot (\S+)/)                 { $config[$i] .= ' '.$1        }
        else                                 { $config[$i] .= ' '.$_        }
    }
    foreach (@config) { push @newbots, [ make_bot('', '', $_) ] }
    return @newbots;
}

1;
