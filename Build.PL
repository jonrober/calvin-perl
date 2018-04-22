#!/usr/bin/perl
#
# Build script for Calvin bots and logging utilities.
#
# Copyright 2018 Russ Allbery <rra@cpan.org>
#
# This program is free software; you may redistribute it and/or modify it
# under the same terms as Perl itself.
#
# SPDX-License-Identifier: GPL-1.0-or-later OR Artistic-1.0-Perl

use 5.018;
use autodie;
use warnings;

use Module::Build;

# Package configuration.
my $build = Module::Build->new(
    dist_abstract        => 'Bot and logging tools for Calvin chatservers',
    dist_author          => 'Jon Robertson <jonrober@eyrie.org>',
    dist_version         => '1.03',
    license              => 'perl',
    module_name          => 'Calvin',
    recursive_test_files => 1,
    add_to_cleanup       => [qw(MANIFEST.bak cover_db)],

    # Add additional package metadata.
    meta_merge => {
        resources => {
            repository => {
                url  => 'https://github.com/jonrober/calvin-perl',
                web  => 'https://github.com/jonrober/calvin-perl',
                type => 'git',
            },
        },
    },

    # Other package relationships.
    configure_requires => { 'Module::Build' => 0.36 },
    requires           => {
        'Config::Simple'            => 0,
        'Curses'                    => 0,
        'Curses::UI'                => 0,
        'Date::Calc'                => 0,
        'Date::Manip'               => 0,
        'Date::Parse'               => 0,
        'File::HomeDir'             => 0,
        'Getopt::Long::Descriptive' => 0,
        'HTML::Entities'            => 0,
        'Hash::Merge'               => 0,
        'JSON'                      => 0,
        'Net::Remctl::Backend'      => 0,
        'Perl6::Slurp'              => 0,
        'YAML'                      => 0,
        perl                        => '5.018',
    },
);

# Generate the build script.
$build->create_build_script;
