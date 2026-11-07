package Plugins::PlatinBridge::Trace;

# A small in-memory ring of what the bridge just did, readable over the CLI.
#
# IT EXISTS BECAUSE THE SERVER LOG IS NOT USABLE HERE. Measured 2026-09-09:
# log.txt ran 60,000 lines per 50 seconds because another plugin logs whole API
# responses at debug, so every line this plugin wrote aged out within seconds and
# three faults in a row had to be diagnosed without it.
#
# This is not a second logging system. It records the handful of moments that
# decide whether audio moves - a track loading, a renderer connecting, the first
# byte going out, a stream ending, a stop - and nothing else, so it stays small
# and stays readable in one screen.
#
# NO Slim:: DEPENDENCIES, so it can be unit-tested and so it cannot itself be the
# reason something fails to load.

use strict;
use warnings;

use Time::HiRes ();

use constant KEEP => 120;

my @ring;

# Deliberately takes plain strings. Anything that needs formatting formats it at
# the call site, so nothing here can die on a value it was not expecting.
sub note {
    my ( $what, $detail ) = @_;

    push @ring, {
        at     => Time::HiRes::time(),
        what   => ( defined $what   ? $what   : '' ),
        detail => ( defined $detail ? $detail : '' ),
    };

    shift @ring while @ring > KEEP;

    return;
}

# Newest LAST, so it reads like a log rather than needing to be reversed by eye.
sub entries { return [@ring] }

sub clear { @ring = (); return }

sub count { return scalar @ring }

1;
