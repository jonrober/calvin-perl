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

use Perl6::Slurp;
use YAML;

use strict;
use vars qw($host %bottypes);

# Default hostname, for descbot.
$host = 'haven.eyrie.org';
%bottypes = (
             'cambot'     => \&make_cambot,
             'descbot'    => \&make_descbot,
             'nagbot'     => \&make_nagbot,
             'fengroll'   => \&make_fengroll,
             'standard'   => \&make_standard,
             'characters' => \&make_characters,
            );


############################################################################
# Misc functions.
############################################################################

# Is sent client, error message, either usernick or empty string, and
#  whether the error is fatal to creating a bot.  Prints error and dies if
#  empty string (no specified user).  Otherwise msgs user with error string.
sub send_error {
    my ($error, $fatal) = @_;

    if (!$fatal)     { print STDOUT $error."\n"    }
    else             { die $error."\n"             }

    return $fatal;
}

############################################################################
# Configuration handling.
############################################################################

# Given a string, determine if it's one that represents a boolean true or not,
# returning 1 or 0.
sub string_to_boolean {
    my ($string) = @_;
    return 1 if $string eq 'yes';
    return 1 if $string eq 'true';
    return 1 if $string eq '1';
    return 0;
}

# Initialize any unset cambot fields to a default of undef, for setting
# configuration values.  undef will be ignored by the setters, which will then
# stay their defaults.
sub clean_config {
    my ($config, $fields, $bool_fields, $list_fields) = @_;

    my %valid_fields = map { $_ => 1 } @$fields, @$bool_fields, @$list_fields;

    # Complain if we find any unknown fields in the set.
    for my $f (keys %{ $config} ) {
        next if exists $valid_fields{$f};
        my $error = "Invalid field: '$f'";
        send_error('', '', $error, 1);
    }

    # Most fields we just set the default undef on if not set.
    for my $f (@{ $fields }) {
        $config->{$f} = undef unless exists $config->{$f};
    }

    # For boolean fields, also change the setting to 0/1.
    for my $f (@{ $bool_fields }) {
        if (exists $config->{$f}) {
            $config->{$f} = string_to_boolean($config->{$f});
        } else {
            $config->{$f} = undef;
        }
    }

    # Set any list fields to an empty array instead, since we'll be trying to
    # iterate through at a higher level.
    for my $f (@{ $list_fields }) {
        $config->{$f} = [] unless exists $config->{$f};
    }

    return $config;
}

# Given a potential log directory, check to ensure that it is set up correctly
# and has no problems.  Sends a fatal error if there are any non-warning
# errors.
sub cambot_logdir_check {
    my ($logdir) = @_;

    # Fail if the directory doesn't exist.
    unless (-d $logdir) {
        my $error = "Nonexistant log directory: '$logdir'.";
        send_error('', '', $error, 1);
    }

    # Fail if the log directory isn't accessible.
    unless (-x $logdir && -w $logdir) {
        my $error = "Incorrect permissions: '$logdir'.";
        send_error('', '', $error, 1);
    }

    # Get the mode to verify the logdir isn't accessible to others.
    my ($mode) = (stat($logdir))[2];
    $mode = $mode & 0777;
    $mode = sprintf "%o", $mode;
    if ($mode !~ /33$/) {
        my $error = "Security warning: dir '$logdir' is ".
            "accessible to others.";
        send_error('', '', $error, 0);

    # Also verify the parent of the logdir isn't accessible to others.
    } else {
        ($mode) = (stat($logdir."/.."))[2];
        $mode = $mode & 0777;
        $mode = sprintf "%o", $mode;
        if ($mode !~ /11$/) {
            my $error = "Security warning: parent of '$logdir' ".
                "is accessible to others.";
            send_error('', '', $error, 0);
        }
    }
}

############################################################################
# Bot creators
############################################################################

sub make_cambot {
    my ($config) = @_;
    my $cambot = new Calvin::Bots::Cambot;

    # Defaults.
    $cambot->enable_recall(0);

    # The fields we want to parse.
    my @fields      = qw(readlog recchan basename perm_channels max_sessions
                         spamflag recall_passwd);
    my @bool_fields = qw(recall addtime usenumerics spam_after_invite);
    my @list_fields = qw(autojoins);

    # Settable configuration.
    $config = clean_config($config, \@fields, \@bool_fields, \@list_fields);
    $cambot->max_readlog($config->{readlog});
    $cambot->max_recchan($config->{recchan});
    $cambot->basename($config->{basename});
    $cambot->perm_channels($config->{perm_channels});
    $cambot->max_sessions($config->{max_sessions});
    $cambot->spamflag($config->{spamflag});
    $cambot->spam_after_invite($config->{spam_after_invite});
    $cambot->use_numerics($config->{usenumerics});
    $cambot->add_time($config->{addtime});
    $cambot->enable_recall($config->{recall});

    # Recall password both needs encryption, and will set enable_recall.
    if (defined $config->{recall_passwd}) {
        $cambot->enable_recall(1);
        my $passwd = crypt($config->{recall_passwd}, 'jr');
        $cambot->recall_passwd($passwd);
    }

    # Add any autojoin entries.
    if ($config->{autojoins}) {
        for my $chan (keys %{ $config->{autojoins}}) {
            my $tag = $config->{autojoins}{$chan};
            $tag =~ s#\\'#'#;
            $cambot->autojoin($chan, $tag);
        }
    }

    # Check the log directory is valid, dying if not.
    my $logdir = $config->{logdir};
    cambot_logdir_check($logdir);
    $cambot->logdir($logdir);

    return $cambot;
}

sub make_nagbot {
    my ($config) = @_;
    my $nagbot = new Calvin::Bots::Nagbot;

    # Nagbot has no configuration, but we still want to run it through the
    # parser to make sure nothing has been sent that shouldn't have been.
    my @fields      = qw();
    my @bool_fields = qw();
    my @list_fields = qw();
    $config = clean_config($config, \@fields, \@bool_fields, \@list_fields);

    return $nagbot;
}

sub make_standard {
    my ($config) = @_;
    my $standard = new Calvin::Bots::Standard;

    # Default settings.
    $standard->say_ok(0);
    $standard->ping_ok(1);
    $standard->quit_ok(1);
    $standard->renick_ok(1);

    # Normalize our fields.
    my @fields      = qw();
    my @bool_fields = qw(ping time say renick);
    my @list_fields = qw();
    $config = clean_config($config, \@fields, \@bool_fields, \@list_fields);

    # Make any requested settings.
    $standard->ping_ok($config->{ping});
    $standard->time_ok($config->{time});
    $standard->say_ok($config->{say});
    $standard->renick_ok($config->{renick});

    return $standard;
}

sub make_descbot {
    my ($config) = @_;
    my $descbot = new Calvin::Bots::Descbot;

    # Default configuration.
    $descbot->localhost($host);

    # Normalize our fields.
    my @fields      = qw(descroot);
    my @bool_fields = qw();
    my @list_fields = qw();
    $config = clean_config($config, \@fields, \@bool_fields, \@list_fields);

    # Error if no descroot set.
    unless (defined $config->{descroot}) {
        my $error = "You must specify a directory for Descbot.";
        send_error('', , $error, 1);
    }

    # Error if descroot isn't accessible.
    unless (-d $config->{descroot} && -w $config->{descroot}) {
        my $error = "Bad desc root: '$1'.";
        send_error('', , $error, 1);
    }

    $descbot->descroot($config->{descroot});

    return $descbot;
}

sub make_fengroll {
    my ($config) = @_;

    # Make bot and defaults.
    my $fengroll = new Calvin::Bots::Fengroll;
    $fengroll->roll_channel(25);

    # Normalize our fields.
    my @fields      = qw(roll_chan passwd);
    my @bool_fields = qw();
    my @list_fields = qw();
    $config = clean_config($config, \@fields, \@bool_fields, \@list_fields);

    $fengroll->roll_channel($config->{roll_chan});
    $fengroll->passwd($config->{passwd});

    return $fengroll;
}

sub make_characters {
    my ($config) = @_;

    # Make bot and defaults.
    my $charbot = new Calvin::Bots::Characters;

    # Normalize our fields, of which we have none.  So this is just there to
    # error if someone tries to give us one.
    my @fields      = qw();
    my @bool_fields = qw();
    my @list_fields = qw();
    $config = clean_config($config, \@fields, \@bool_fields, \@list_fields);

    return $charbot;
}

############################################################################
# Config makers
############################################################################

# Send a manager, client, user, and argument line, then create a new bot
#  using that configuration line.
sub make_bot {
    my ($nick, $args) = @_;
    my (@bot_names);

    my $port   = $args->{port};
    my $server = $args->{server};
    my @connect = ($server, $port, $nick);

    my $found_standard = 0;
    foreach my $bot_type (keys %{ $args->{bots} }) {
        $bot_type = lc $bot_type;
        $found_standard++ if $bot_type eq 'standard';

        my $newbot = undef;
        if (exists $bottypes{$bot_type}) {
            $newbot = &{$bottypes{$bot_type}}($args->{bots}{$bot_type});
        }
        return undef unless defined $newbot;

        push (@connect, $newbot);
        push (@bot_names, ucfirst($bot_type));
    }

    # If they didn't ask for a standard bot, tough.  Define the default
    # settings for one and add it in.
    if (!$found_standard) {
        my $newbot = make_standard ({});
        push (@connect, $newbot);
        push (@bot_names, 'Standard');
    }

    # Add the connection to the manager, make connect, initialize help,
    # and confirm for the user.  Add info string
    my $connect_data = "Bot $nick on $server $port by config file using: ";
    $connect_data .= join(', ', @bot_names).'.';

    push (@connect, $connect_data);
    return @connect;
}


# Reads from a config file and reformats it into valid arguments to
#  make_bot, then sends each to make_bot to create the bots.
sub config_rc {
    my ($fname) = @_;
    my (@config, @newbots);

    my $yaml_string = slurp($fname);
    my $config = Load($yaml_string);

    for my $bot (keys %{ $config }) {
        push @newbots, [ make_bot($bot, $config->{$bot}) ]
    }
    return @newbots;
}

1;
