# Calvin::Logs::Logread - Common functions around logread and character-ui
#
# Copyright 2017 by Jon Robertson <jonrober@eyrie.org>
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.

############################################################################
# Modules and declarations
############################################################################

package Calvin::Logs::Logread;

use Config::Simple;
use Curses;
use Curses::UI;
use Date::Calc qw(Add_Delta_Days Add_Delta_YM);
use File::HomeDir;
use HTML::Entities;
use Term::ANSIColor qw(:constants color colored);

BEGIN {
    use Exporter ();
    use vars qw(@ISA @EXPORT_OK);
    @ISA = qw(Exporter);
    @EXPORT_OK = qw(&action_quit &action_save &action_mail &mail_querybox
		&save_to_file &print_line &do_split &do_line
		&do_rollover &read_prefs &write_prefs &logs_around_day
		&channels_for_day &clean_numerics &last_file_subdirs %prefs);
}

use vars @EXPORT_OK;
use vars qw();

#############################################################################
# Processing responses
#############################################################################

# Bring up a confirm box on a quit request and exit if the user responds yes.
sub action_quit {
	my ($cui) = @_;
    my $quit = $cui->dialog(
			    -message => 'Do you want to quit?',
			    -buttons => [
					 {
					     -label => '< Yes >',
					     -value => 1,
					     -shortcut => 'y',
					 },
					 {
					     -label => '< No >',
					     -value => 0,
					     -shortcut => 'n',
					 },
					 ],
			    );
    exit(0) if $quit;
}

#############################################################################
# Save Screen
#############################################################################

# The function that gets called when we've made a selection in the save
#  list...  Takes the item selected, splits it out and drops to a file that
#  we specify here.
sub action_save {
    my ($savetype, $cui) = @_;

    # Grab the listbox for the Main view.  Then grab whatever item the cursor
    #  is currently on from that box.
	my $window   = $cui->getobj('mainwindow');
    my $listbox  = $window->getobj('navlist');
    my $selected = $listbox->get_active_value();
	my $userdata = $window->userdata;

    # Get the information for this selection.
	my $channel = $userdata->{$selected}{channel};
	my $fname   = $userdata->{$selected}{fname};
	my $base    = 1;
	my $offset  = 0;

    # Select the file you wish to save to, then split to that file...
    my $savefile = $cui->savefilebrowser("Select a file to save as:");
    do_split($channel, $offset, $fname, $base, '', $savetype, $savefile);

    # Refresh after viewing the logs, and refocus on the screen.
    refresh();
    clear();
    $window->focus();
    $window->intellidraw();

    # Should do exactly what the last two items did.  Remove these lines later
    # and make sure things don't go wrong.  (In case you couldn't tell, I had
    # frustration getting the refreshing to work right.)
    my $menu = $listbox->parent->getobj('navlist');
    $menu->focus();
    $menu->intellidraw();
}

#############################################################################
# Mailing logs
#############################################################################

# The function that's called when we want to mail an item in the main nav list.
#  grabs the item selected, splits it out, and mails it to a specified user.
sub action_mail {
    my ($mailto, $cui) = @_;

    # Grab the listbox for the Main view.  Then grab whatever item the cursor
    #  is currently on from that box.
	my $window = $cui->getobj('mainwindow');
    my $listbox = $window->getobj('navlist');
    my $selected = $listbox->get_active_value();
	my $userdata = $window->userdata;

	# Get the information for this selection.
	my $channel = $window->{$selected}{channel};
	my $fname   = $window->{$selected}{fname};
	my $base    = 1;
	my $offset  = 0;

    # Split the log out with a destination set to the supplied mail address.
    do_split($channel, $offset, $fname, $base, '', 'mail', $mailto);

	# Refresh after viewing the logs, and refocus on the screen.
    refresh();
    clear();
    $window->focus();
    $window->intellidraw();

    # Should do exactly what the last two items did.  Remove these lines later
    #  and make sure things don't go wrong.  (In case you couldn't tell, I had
    #  frustration getting the refreshing to work right.)
    my $menu  = $listbox->parent->getobj('navlist');
    $menu->focus();
    $menu->intellidraw();
}

# Sets the window for a query box for asking for an address to mail a log to.
sub mail_querybox {
	my ($cui) = @_;

	my $window = $cui->getobj('mail_query');

    # For each item in this window, see if it exists and delete if so.  Clears
    #  out any old information if this isn't the first time we've called this
    #  function.
    foreach my $control ('mail_label', 'mail_address', 'buttons') {
		if ($window->getobj($control)) {
	    	$window->delete($control);
		}
    }

    # Add in the label for the add field..
    $window->add(
			  'mail_label', 'Label',
			  -x => 0, -y => 0, -width => 20,
			  -textalignment => 'left',
			  -text => "Mail this log to:",
			  );

    # Add in the actual text box...
    $window->add(
			   'mail_address', 'TextEntry',
			   -x => 14, -y => 0,
			   -text => '',
			   )->focus;

    # And lastly, create the buttons for this window.
    my $buttons = $window->add(
	    'buttons', 'Buttonbox',
	    -x => 14, -y => 2,
	    -buttons => [
			 {

			     # OK Button - if clicked, grab the value of the
			     #  mail address and make the mail with that value.
			     -label => '< OK >',
			     -onpress => sub {
				 	my $obj = $window->getobj('mail_address');
				 	my $mailto = $obj->get;
				 	action_mail($mailto, $cui);
			     },
			 },
			 {

			     # Cancel button - Never mind, just focus on the
			     #  main menu again.
			     -label => '< Cancel >',
			     -onpress => sub
			     {
				 	$cui->getobj('mainwindow')->focus;
			     }
			 },
			 ],
	    );

    # And then focus on the menu we've just built, so the user can answer it.
    $window->focus;
}

#############################################################################
# Preferences operations
#############################################################################

# Really simple function that just takes a value and if it's true, returns
#  Yes, otherwise returns No.  Used to map preferences to Yes/No for display.
sub boolean_to_yesno {
    my ($value) = @_;
    if ($value) { return 'Yes' }
    else        { return 'No'  }
}

# Sets the window for a query box for asking for a new value in preference
#  strings.
sub preferences_querybox {
    my ($cui, $box_selected, $label, $field) = @_;

    # For each item in this window, see if it exists and delete if so.  Clears
    #  out any old information if this isn't the first time we've called this
    #  function.
	my $window = $cui->getobj('preferences_query');
    foreach my $control ('query_label', 'newterm', 'buttons') {
		$window->delete($control) if $window->getobj($control);
    }

    # Add in the label that says which preference we are asking about...
    $window->add(
  				 'query_label', 'Label',
			   	 -x => 0,
				 -y             => 0,
				 -width 		=> 20,
				 -textalignment => 'left',
				 -text          => $label,
	);

    # Add the box where the user can enter the new value.
    $window->add(
				 'newterm', 'TextEntry',
				 -x    => 14,
				 -y    => 0,
				 -text => '',
	)->focus;

    # Add the buttons that let him save or cancel the entry he's made.
    my $buttons = $window->add(
	    'buttons', 'Buttonbox',
	    -x => 14, -y => 2,
	    -buttons => [
			 {
			     # OK Button - Copy the preference entered into the
			     #  %prefs hash, then go back to the preferences
			     #  menu.
			     -label => '< OK >',
			     -onpress => sub {
				 	my $obj = $window->getobj('newterm');
				 	$prefs{$field} = $obj->get;
				 	make_prefs_menu($box_selected);
			     },
			 },
			 {

			     # Cancel Button - Go back to the prefs menu.  We
			     #  don't need to rebuild the menu, since nothing
			     #  has changed.
			     -label => '< Cancel >',
			     -onpress => sub
			     {
				 	$cui->getobj('preferences')->focus;
			     }
			 },
			 ],
	    );

    # Focus on this window so that we can get the user input.
    $window->focus;
}

# The function that determines what we do when an item is selected out of the
#  preferences listbox.
sub action_prefs {
	my ($listbox) = @_;

    # Get the listbox that called us, then grab the current selection from it.
    my @sel = $listbox->get;
    my $selected = $sel[0];

    # Grab the necessary fields from our menu data structure.
	my $userdata = $listbox->parent->userdata;
    my $action   = $userdata->{$selected}{action};
    my $field    = $userdata->{$selected}{field};
    my $label    = $userdata->{$selected}{query};

    # If we chose to toggle a boolean-style field, just flip its value and
    #  reload the menu.
    if ($action eq 'toggle') {
		$prefs{$field} = !$prefs{$field};
		make_prefs_menu($selected);

    # If we have a string we need to change, then pull up a query for changing
    #  it...
    } elsif ($action eq 'text') {
		preferences_querybox($selected, $label, $field);

    # If we've selected to write preferences to their file, well.. we have
    #  a function just for that.
    } elsif ($action eq 'write_file') {
        write_prefs(%prefs);
		menu_character_logs();

    # If we've selected to leave the preferences file, then back to the main
    #  menu we go!
    } elsif ($action eq 'cancel_prefs') {
		menu_character_logs();
    }

}

# Given the big setup of the preferences window data structure, yank out the
#  display stuff only, to use in building the visible menu.
sub prefs_display {
    my (%prefs) = @_;
    my (%display);

    # Iterate through the preferences hash and drop each display item into a
    #  more abbrieviated hash.
    foreach my $key (keys %prefs) {
		$display{$key} = $prefs{$key}{'display'};
    }
    return %display;
}

# Builds all the information we need for figuring out what to do when we have
#  selected an item from the preferences.
# For each item:
#  display: What appears in the menu.
#  action:  What we should do when this item is selected (the function
#           prefs_action has information on what each does).
#  field:   What field, if any, this item acts on.
#  query:   What prompt will appear in a query box, if one is called to ask for
#           entry on this item.
sub prefs_information {
    my %prefs_menu = (
		   0 => {
		       display => 'Back to channels...',
		       action  => 'cancel_prefs',
		       field   => '',
		   },
		   1 => {
		       display => 'Write preferences to .logreadrc',
		       action  => 'write_file',
		       field   => '',
		   },
		   2 => {
		       display => "Following: " . boolean_to_yesno($prefs{'do_follow'}),
		       action  => 'toggle',
		       field   => 'do_follow',
		       query   => 'Following?',
		   },
		   3 => {
		       display => "Following base channels: " . boolean_to_yesno($prefs{'do_follow_base'}),
		       action  => 'toggle',
		       field   => 'do_follow_base',
		       query   => 'Following base?',
		   },
		   4 => {
		       display => "Showing server messages: " . boolean_to_yesno($prefs{'show_serv'}),
		       action  => 'toggle',
		       field   => 'show_serv',
		       query   => 'Showing server lines?',
		   },
		   5 => {
		       display => "Showing server messages on base channels: " . boolean_to_yesno($prefs{'show_serv_base'}),
		       action  => 'toggle',
		       field   => 'show_serv_base',
		       query   => 'Showing server lines on base?',
		   },
		   6 => {
		       display => "Showing whispers: " . boolean_to_yesno($prefs{'show_whisp'}),
		       action  => 'toggle',
		       field   => 'show_whisp',
		       query   => 'Showing whispers?',
		   },
		   7 => {
		       display => "Removing player names: " . boolean_to_yesno($prefs{'remove_player'}),
		       action  => 'toggle',
		       field   => 'remove_player',
		       query   => 'Removing player names?',
		   },
		   8 => {
		       display => "Display fkids logs: " . boolean_to_yesno($prefs{'display_fkids'}),
		       action  => 'toggle',
		       field   => 'display_fkids',
		       query   => 'Display FKids?',
		   },
		   9 => {
		       display => "Flags to less: '" . $prefs{'less_flags'} . "'",
		       action  => 'text',
		       field   => 'less_flags',
		       query   => 'Flags to less?',
		   },
		   10 => {
		       display => "Line color: '" . $prefs{'normal_color'} . "'",
		       action  => 'text',
		       field   => 'normal_color',
		       query   => 'Line color?',
		   },
		   11 => {
		       display => "Server line color: '" . $prefs{'server_color'} . "'",
		       action  => 'text',
		       field   => 'server_color',
		       query   => 'Server line color?',
		   },
		   12 => {
		       display => "Whisper color: '" . $prefs{'whisp_color'} . "'",
                       action  => 'text',
                       field   => 'whisp_color',
		       query   => 'Whisper color?',
		   },
		   13 => {
		       display => "Wrap width: " . $prefs{'width'},
                       action  => 'text',
                       field   => 'width',
		       query   => 'Wordwrap width?',
		   },
		   14 => {
		       display => "Body CSS: '" . $prefs{'body_css'} . "'",
		       action  => 'text',
		       field   => 'body_css',
		       query   => 'Body CSS?',
		   },
	       );
}

# Create the content that goes into the preferences menu, deleting the content
#  if it already exists.
sub make_prefs_menu {
	my ($cui, $sel) = @_;

    # Get the menu (defined in another subroutine for length), add it to the
	# userdata for this window, and then find the labels and values for our
	# menu from that data.
	my $window = $cui->getobj('preferences');
    my %menu = prefs_information();
	$window->userdata(\%menu);
    my %labels = prefs_display(%menu);
    my @channels = sort { $a <=> $b } keys(%labels);

    # If we've already created the items in this window before, delete them
    #  now so that we may start fresh.
    if ($window->getobj('prefslabel')) { $window->delete('prefslabel') }
    if ($window->getobj('prefslist'))  { $window->delete('prefslist')  }

    # First, we add the label.  Nothing special, just telling us what this is.
    $window->add(
		     'prefslabel', 'Label',
		     -width => -1,
		     -bold => 1,
		     -text => "View/Edit My Preferences",
		     -intellidraw  => 1,
		     );

    # Actually create the listbox.  When an item is selected, we call the
    #  funcion prefs_action.
    my $prefslist = $window->add(
                                  'prefslist', 'Listbox',
                                  -y => 2,
                                  -values  => \@channels,
                                  -labels  => \%labels,
                                  -title   => 'Preferences',
                                  -vscrollbar => 1,
                                  -onchange   => \&action_prefs,
                                  -intellidraw  => 1,
                                  );

    # If we've had an option already selected from viewing this list already,
    #  then scroll through the list until we've set the same item active.
	$sel ||= 0;
    for (my $i = 0; $i < $sel; $i++) {
        $prefslist->option_next();
    }

    # And now that we've created the window's information, we want it to be
    #  the window that we actually see.
    $prefslist->focus();
}

######################################################################
# Reading and saving to the config file.
######################################################################

# Set some default preferences for new logread users.
sub default_prefs {
	my %preferences = (
						show_serv => 0,
						show_serv_base => 1,
						width          => 76,
						remove_player  => 1,
						use_color      => 1,
						display_fkids  => 1,
						less_flags     => '-r',
						server_color   => 'reset bold yellow',
						normal_color   => 'reset clear',
						whisp_color    => 'reset on_blue',
						body_css       => 'color: white; background-color: black;',
	);

	return %preferences;
}

# Read the preferences from .logreadrc and return as a hash after adding any
# defaults.
sub read_prefs {
	my $pref_file = File::HomeDir->my_home . '/.logreadrc';

	my %prefs = ();
	if (-f $pref_file) {
		my $cfg = new Config::Simple(syntax => 'simple', filename => $pref_file);
		%prefs = $cfg->vars;

		# Copy a few preferences that had name drift.
		$prefs{show_serv}      = $prefs{show_nicks};
		$prefs{show_serv_base} = $prefs{show_nicks_base};
	}

	# Load and add the defaults to any unset preferences.
	my %defaults = default_prefs;
	foreach my $name (keys %defaults) {
		next if exists $prefs{$name};
	    $prefs{$name} = $defaults{$name};
	}

    return %prefs;
}

# Write the preferences back to the .logreadrc.
sub write_prefs {
    my (%prefs) = @_;

	my $pref_file = File::HomeDir->my_home . '/.logreadrc';
	die "could not find preferences $pref_file\n" unless -f $pref_file;

	my $cfg = new Config::Simple(syntax => 'simple', filename => $pref_file);
	for my $key (keys %prefs) {
		$cfg->param($key, $prefs{$key});
	}
	$cfg->save;
}

######################################################################
# Logfile processing
######################################################################

# Finds the last valid file in multiple subdirectories.
sub last_file_subdirs {
    my (@list) = @_;

    my (@files);
	my $dirobj = Calvin::Logs->new;
    foreach my $dir (@list) {
		$dirobj->dir($dir);
		my $addfile = $dirobj->last_file;
	   	push (@files, $addfile) if $addfile;
    }

    my ($fname) = reverse sort @files;

    $fname =~ s{^.+/(\d{4}-\d{2}/[^/]+)$}{$1};
    return $fname;
}

# Given a date and a set of directories, check to see if a file belonging
#  to that date exists in any directory.
sub date_has_logs {
    my ($date, @dirs) = @_;

	my $dirobj = Calvin::Logs->new;
    foreach my $dir (@dirs) {
		$dirobj->dir($dir);
        return $date if $dirobj->find_fname($date, '');
    }

    return 0;
}

# Given a date, we go through and see if there are available logs for the
#  previous and next days.
# Returns a list of hashes, the list containing information on each day
#  in order, the hash containing the following fields:
#  display: What to show on the menu for the day in question.
#  date:    The date of the log for this day, or 'null' if no log exists.
sub logs_around_day {
    my ($date, @dirs) = @_;
    my ($nextday, $lastday, @logs);

    # Make the call to check the existance of any logs, in any directory, for
    #  yesterday and today.
    $nextday   = date_has_logs(tomorrow($date, 1), @dirs);
    $lastday   = date_has_logs(tomorrow($date, -1), @dirs);
    $nextweek  = date_has_logs(tomorrow($date, 7), @dirs);
    $lastweek  = date_has_logs(tomorrow($date, -7), @dirs);

	# Define what an empty date item looks like once, since we'll use it often.
	my %empty_item = (display => '*** -----------------------------',
	            	  date    => 'null',
	);

	# Check to see if yesterday had logs and make menu based upon...
    if ($lastday) {
        push @logs, {
            display => "<-- Yesterday's log ($lastday)",
            date    => $lastday,
        };
    } else {
        push @logs, \%empty_item;
    }

    # Check to see if tomorrow had logs and make menu based upon...
    if ($nextday) {
        push @logs, {
            display => "--> Tomorrow's log ($nextday)",
            date    => $nextday,
        };
    } else {
		push @logs, \%empty_item;
    }

   # Check to see if last week had logs and make menu based upon...
    if ($lastweek) {
        push @logs, {
            display => "<-- Last week's log ($lastweek)",
            date    => $lastweek,
        };
    } else {
		push @logs, \%empty_item;
    }

    # Check to see if next week had logs and make menu based upon...
    if ($nextweek) {
        push @logs, {
            display => "--> Next week's log ($nextweek)",
            date    => $nextweek,
        };
    } else {
		push @logs, \%empty_item;
    }

    return (@logs);
}

# Given a date and a list of directories to search in, slip through and make
#  for us every valid channel that appears on that day for splitting.
# Return a list of hashes, where every item in the list is one channel (in a
#  set order) and every item in the hash is as follows:
#  display: What to show in the menu for this channel.
#  channel: The actual number of the channel.
#  offset:  The offset in the file where this channel's logging began (0 if a
#           base channel, as those are always considered as logged from the
#           start).
#  file:    The name of the file to check (since we can be dealing with 'plex,
#           fkids, and private logs, all).
#  base:    If this is a base channel, as we handle those slightly different.
sub channels_for_day {
    my ($date, @dirs) = @_;
    my (@done, @splits, @base, $server_reg, $server_fk);
    $server_reg = $server_fk = 0;

    # Go through each directory in our tree to check for logs...
	my $dirobj = Calvin::Logs->new;
    foreach my $dir (@dirs) {
		$dirobj->dir($dir);
        @done = ();

        # Check for the file name for this date in this directory, and return
        #  if none is found.
        my $fname = $dirobj->find_fname($date, '');
        next unless $fname;

        # Find the suffix we want to append to the file name in the menu.
        my ($suffix) = $fname =~ /^.*\/(\w+)\/.*?\//;
        $suffix = ucfirst ($suffix);
        if ($dir =~ /\/fkids\//) { $suffix = "<FK> ($suffix)" }
        else                     { $suffix = "($suffix)"      }

        # Read in the offsets file to get channels used.
		my $logobj = Calvin::Logs->new;
		$logobj->filename($fname);
		my @offsets = $logobj->parse_offsetfile;

        # And now we increment the number of servers, fkids or non, if we
        #  actually had an offsets file.  This is used to figger out if we
        #  want to remove the suffix, after seeing all lines we've got.
        if (@offsets) {
            if ($dir =~ /\/fkids\//) { $server_fk++  }
            else                     { $server_reg++ }
        }

        # Iterates through the offsets returned, and adds items to the menu
        #  array.  Channels with offset 0 are base channels, so are marked
        #  special.
        for (my $i = 0; $i <= $#offsets; $i++) {
            my $chan   = $offsets[$i][0];
            my $tag    = $offsets[$i][1];
            my $offset = $offsets[$i][2];

            # Remove the [] from around the channel name.
            $tag =~ s#^\[(.*)\]$#$1#;

            # Base channel...
            if ($offset == 0) {
                if (!$done[$chan]) {
                    $done[$chan] = 1;
                    my $display = sprintf ("%2s: %s (day's log) %s", $chan,
					   $tag, $suffix);
                    push @base, {
                        channel => $chan,
                        offset  => $offset,
                        display => $display,
                        file    => $fname,
                        base    => 1,
                    };

                }

            # Any non-base channel.
            } else {
                $chan = sprintf("%2d", $chan);
                my $display = "$chan: $tag $suffix";
                push @splits, {
                    display => $display,
                    channel => $chan,
                    offset  => $offset,
                    file    => $fname,
                    base    => 0,
                };
            }
        }
    }

    # Now some fun post-processing magic...
    # For the base channels, sort by channel number.
#    @base = sort { ($a->{'display'} =~ /^\s*(\d)/)[0] <=> ($b->{'display'} =~ /^\s*(\d)/)[0] } @base;
    @base = sort { $a->{'channel'} <=> $b->{'channel'} } @base;

    # Add the bases and the splits together, then if we have 1 or 0 lines for
    #  each channel, remove the ($server) tag at the end...  I have no idea
    #  why I did it that way.  Look into that later.. what I really want is
    #  to remove those tags only if the logs are for one channel-type.
    @splits = (@base, @splits);
    if ($server_reg < 2 && $server_fk < 2) {
        for (my $i = 0; $i < @splits; $i++) {
            $splits[$i]{'display'} =~ s/ \(\S+\)$//;
        }
    }
    return (@splits);
}

# Shift a filename by a certain number of days.  You could make it a *LOT*
#  simpler by changing day and offset to epoch seconds and then back to
#  a date, but we're already taking a large hit in startup and don't need
#  to load more modules. :P
sub tomorrow {
    my ($date, $offset) = @_;

	my ($year, $month, $day) = ($date =~ /^(\d{4})-(\d{2})-(\d{2})$/);
	my ($new_y, $new_m, $new_d) = Add_Delta_Days($year, $month, $day, $offset);

	return sprintf("%04s-%02s-%02s", $new_y, $new_m, $new_d);
}
1;
