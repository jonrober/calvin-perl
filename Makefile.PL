use ExtUtils::MakeMaker;

$VERSION = '1.0.0';

WriteMakefile(
    NAME         => 'Calvin',
    VERSION      => $VERSION,
    dist         => {
        COMPRESS     => 'gzip ',
        SUFFIX       => '.gz',
        DIST_DEFAULT => 'all tardist'
    },
    PREREQ_PM    => {},
    PM           => {
        'lib/Calvin/Bots/Cambot.pm'         => '$(INST_LIBDIR)/Calvin/Bots/Cambot.pm',
        'lib/Calvin/Bots/Descbot.pm'        => '$(INST_LIBDIR)/Calvin/Bots/Descbot.pm',
        'lib/Calvin/Bots/Fengroll.pm'       => '$(INST_LIBDIR)/Calvin/Bots/Fengroll.pm',
        'lib/Calvin/Bots/INroll.pm'         => '$(INST_LIBDIR)/Calvin/Bots/INroll.pm',
        'lib/Calvin/Bots/MTG.pm'            => '$(INST_LIBDIR)/Calvin/Bots/MTG.pm',
        'lib/Calvin/Bots/Nagbot.pm'         => '$(INST_LIBDIR)/Calvin/Bots/Nagbot.pm',
        'lib/Calvin/Bots/Standard.pm'       => '$(INST_LIBDIR)/Calvin/Bots/Standard.pm',
        'lib/Calvin/Bots/URL_Store.pm'      => '$(INST_LIBDIR)/Calvin/Bots/URL_Store.pm',
        'lib/Calvin/Bots/Passthrough.pm'    => '$(INST_LIBDIR)/Calvin/Bots/Passthrough.pm',
        'lib/Calvin/Logs/Characters.pm'     => '$(INST_LIBDIR)/Logs/Characters.pm',
        'lib/Calvin/Logs/Characters/Tag.pm' => '$(INST_LIBDIR)/Calvin/Logs/Characters/Tag.pm',
        'lib/Calvin/Logs/Logread.pm'        => '$(INST_LIBDIR)/Calvin/Logs/Logread.pm',
        'lib/Calvin/Logs/Misc.pm'           => '$(INST_LIBDIR)/Calvin/Logs/Misc.pm',
        'lib/Calvin/Logs/Split.pm'          => '$(INST_LIBDIR)/Calvin/Logs/Split.pm',
        'lib/Calvin/Client.pm'              => '$(INST_LIBDIR)/Calvin/Client.pm',
        'lib/Calvin/Config.pm'              => '$(INST_LIBDIR)/Calvin/Config.pm',
        'lib/Calvin/Logs.pm'                => '$(INST_LIBDIR)/Calvin/Logs.pm',
        'lib/Calvin/Manager.pm'             => '$(INST_LIBDIR)/Calvin/Manager.pm',
        'lib/Calvin/Parse.pm'               => '$(INST_LIBDIR)/Calvin/Parse.pm',
    }
);
