#!/usr/bin/perl
#
# Unit tests for Plugins::PlatinBridge::Discovery.
#
# The socket half cannot be tested offline, so these cover the parsing and the
# identity rules - which is where the damaging bugs live. A discovery module that
# mis-identifies a device tears down a player and takes its playlist and sync
# group with it.
#
# `ok` TAKES THE ASSERTION NAME OFF THE END: a failed match in list context is
# the EMPTY list, so a name-last `ok` cannot read the label as the condition.

use strict;
use warnings;
use lib '.';

BEGIN {
    package main;
    use constant DEBUGLOG => 0;
    use constant INFOLOG  => 0;
    use constant WEBUI    => 1;
}

require Plugins::PlatinBridge::Discovery;

my $D = 'Plugins::PlatinBridge::Discovery';

my $parseHeaders = \&Plugins::PlatinBridge::Discovery::parseHeaders;
my $udnFromUSN   = \&Plugins::PlatinBridge::Discovery::udnFromUSN;

my ( $pass, $fail ) = ( 0, 0 );

sub ok {
    my $n = pop;
    my $c = @_ ? $_[0] : 0;
    if   ($c) { $pass++ }
    else      { $fail++; print "  FAIL $n\n" }
}

sub is {
    my ( $got, $want, $n ) = @_;
    my $g = defined $got  ? $got  : '(undef)';
    my $w = defined $want ? $want : '(undef)';
    if ( $g eq $w ) { $pass++ }
    else { $fail++; print "  FAIL $n\n    got:  $g\n    want: $w\n" }
}

# ---------------------------------------------------------------------------
print "-- SSDP reply parsing --\n";

{
    # Header case is deliberately mixed and the line endings are CRLF, as real
    # devices send. Devices disagree wildly on capitalisation.
    my $reply = join( "\r\n",
        'HTTP/1.1 200 OK',
        'CACHE-CONTROL: max-age=1800',
        'EXT:',
        'LOCATION: http://10.0.0.9:49152/description.xml',
        'Server: Linux/4.9 UPnP/1.0 Platin/1.2',
        'st: urn:schemas-upnp-org:device:MediaRenderer:1',
        'USN: uuid:5f9ec1b3-ed59-79ee-4530-0005cdaabbcc::urn:schemas-upnp-org:device:MediaRenderer:1',
        '', '' );

    my $h = $parseHeaders->($reply);

    ok( $h, 'a well-formed reply parses' );
    is( $h->{_status}, 'HTTP/1.1 200 OK', 'the status line is kept' );
    is( $h->{location}, 'http://10.0.0.9:49152/description.xml',
        'LOCATION is found regardless of header case' );
    is( $h->{server}, 'Linux/4.9 UPnP/1.0 Platin/1.2', 'Server is found when sent as "Server"' );
    is( $h->{st}, 'urn:schemas-upnp-org:device:MediaRenderer:1', 'ST is found when sent lower case' );
    ok( exists $h->{ext}, 'a valueless header still appears' );
    is( $h->{ext}, '', 'and its value is empty rather than undef' );
}

{
    # LF-only line endings: out of spec, but devices do it and a bridge that only
    # splits on CRLF sees one enormous header and finds nothing.
    my $h = $parseHeaders->("HTTP/1.1 200 OK\nLOCATION: http://1.2.3.4/d.xml\nUSN: uuid:abc\n\n");
    is( $h->{location}, 'http://1.2.3.4/d.xml', 'LF-only line endings still parse' );
}

{
    my $h = $parseHeaders->(
        "HTTP/1.1 200 OK\r\nLOCATION: http://1.2.3.4/d.xml\r\n\r\nBODY: not-a-header\r\n" );
    is( $h->{body}, undef, 'parsing stops at the blank line - a body is not read as headers' );
}

is( $parseHeaders->(''),    undef, 'an empty datagram parses to nothing' );
is( $parseHeaders->(undef), undef, 'undef parses to nothing' );

{
    my $h = $parseHeaders->('NOTIFY * HTTP/1.1');
    is( $h->{_status}, 'NOTIFY * HTTP/1.1',
        'a NOTIFY is parsed but its status line is preserved so the caller can reject it' );
}

# ---------------------------------------------------------------------------
print "-- a LOCATION is followed only to the host that answered --\n";

{
    my $from = \&Plugins::PlatinBridge::Discovery::locationIsFrom;

    ok( $from->( 'http://10.0.0.9:49152/description.xml', '10.0.0.9' ), 'LOCATION on the answering host is accepted' );
    ok( $from->( 'http://10.0.0.9/d.xml', '10.0.0.9' ), 'with no port' );
    ok( !$from->( 'http://10.0.0.50:80/d.xml', '10.0.0.9' ), 'another LAN host is refused' );
    ok( !$from->( 'http://127.0.0.1:9000/d.xml', '10.0.0.9' ), 'loopback is refused' );
    ok( !$from->( 'http://10.0.0.9@10.0.0.50/d.xml', '10.0.0.9' ), 'userinfo cannot dress up another host' );
    ok( !$from->( 'http://10.0.0.9.evil.example/d.xml', '10.0.0.9' ), 'a longer hostname is refused' );
    ok( !$from->( 'ftp://10.0.0.9/d.xml', '10.0.0.9' ), 'a non-http scheme is refused' );
    ok( !$from->( undef, '10.0.0.9' ), 'no LOCATION is refused' );
}

# ---------------------------------------------------------------------------
print "-- the UDN is the identity --\n";

is( $udnFromUSN->('uuid:5f9ec1b3-ed59-79ee-4530-0005cdaabbcc::urn:schemas-upnp-org:device:MediaRenderer:1'),
    'uuid:5f9ec1b3-ed59-79ee-4530-0005cdaabbcc',
    'the UDN is taken from a USN carrying a service suffix' );

is( $udnFromUSN->('uuid:5f9ec1b3-ed59-79ee-4530-0005cdaabbcc'),
    'uuid:5f9ec1b3-ed59-79ee-4530-0005cdaabbcc',
    'and from a bare USN' );

# The prefix MUST be kept: the description's own <UDN> element includes it, and
# the two values are compared for identity. Strip it in one place and not the
# other and the check silently never matches.
ok( $udnFromUSN->('uuid:abc::urn:x') =~ /^uuid:/,
    'the uuid: prefix is KEPT, so it compares equal to the description <UDN>' );

is( $udnFromUSN->('UUID:ABC-123'), 'UUID:ABC-123', 'a device shouting its USN still yields a UDN' );

is( $udnFromUSN->(''),        undef, 'an empty USN yields no identity' );
is( $udnFromUSN->(undef),     undef, 'a missing USN yields no identity' );
is( $udnFromUSN->('garbage'), undef, 'a USN with no uuid: yields no identity, rather than a guess' );

# ---------------------------------------------------------------------------
print "-- no subnet sweeping, ever --\n";

# This is a source assertion on purpose. The rule is architectural: a /24 probe
# from a plugin once ARP-flooded this server off the network, so the guarantee
# worth testing is that no code exists which could enumerate hosts.
{
    my $src = do {
        open my $fh, '<', '../PlatinBridge/Discovery.pm' or die "cannot read Discovery.pm: $!";
        local $/;
        <$fh>;
    };

    ok( $src !~ /for\s*\(?\s*(?:my\s*\$\w+\s*=\s*)?1\s*\.\.\s*25[45]/,
        'no loop over a host range exists in the source' );
    ok( $src !~ /\.\d+\.\d+\.\$/, 'no address is built by interpolating a host number' );
    ok( $src =~ /NEVER SWEEP A SUBNET/, 'and the rule is stated in the file for the next reader' );

    # Port 1900 must not be bound - it would fight the other UPnP software on the
    # box and buy nothing, since a byebye is "no opinion" not "stopped".
    ok( $src !~ /LocalPort\s*=>\s*(?:SSDP_PORT|1900)/,
        'the discovery socket does not bind port 1900' );
    ok( $src =~ /LocalPort\s*=>\s*0/, 'it uses an ephemeral local port' );
}

# ---------------------------------------------------------------------------
print "-- lifecycle --\n";

{
    Slim::Utils::Timers::_reset();
    $D->stop;
    is( Slim::Utils::Timers::_pending(), 0, 'stop leaves no timers pending' );
    is( scalar keys %{ $D->devices }, 0, 'and no devices are reported after a clean stop' );
}

{
    # probeNow on a stopped module must do nothing - a settings page saving while
    # the plugin is disabled must not open a socket.
    Slim::Utils::Timers::_reset();
    $D->probeNow;
    is( Slim::Utils::Timers::_pending(), 0, 'probeNow while stopped does nothing' );
}

{
    # devices() must hand back a COPY. Returning the live hash would let a caller
    # mutate discovery's own state, and the reconcile pass in Plugin.pm iterates
    # it while creating and tearing down players.
    my $a = $D->devices;
    $a->{'uuid:injected'} = { udn => 'uuid:injected' };
    is( scalar keys %{ $D->devices }, 0, 'devices() returns a copy, not the live hash' );
}

# ---------------------------------------------------------------------------
print "-- the pace keys on the plugin having its Hub --\n";

# Every renderer is reported now, so "something answered" is no longer "the Hub
# was found": settling on the Eversolo would leave a Hub that missed that round
# waiting ten minutes. Driven without a socket - _round is stubbed so start() sets
# the module running and sends nothing onto the network.
{
    no warnings 'redefine';
    local *Plugins::PlatinBridge::Discovery::_round = sub { };

    my $next = sub {
        my @t = grep { $_->{cb} == \&Plugins::PlatinBridge::Discovery::_round } @{ Slim::Utils::Timers::_timers() };
        return @t ? int( $t[0]{when} - Time::HiRes::time() + 0.5 ) : undef;
    };

    Slim::Utils::Timers::_reset();
    $D->start( sub { } );
    $D->setSettled(0);
    Plugins::PlatinBridge::Discovery::_roundDone();
    is( $next->(), 15, 'with no Hub adopted, discovery asks again in 15 s' );

    Slim::Utils::Timers::_reset();
    $D->setSettled(1);
    Plugins::PlatinBridge::Discovery::_roundDone();
    is( $next->(), 600, 'once the plugin has its Hub, every 10 minutes' );

    Slim::Utils::Timers::_reset();
    $D->setSettled(0);
    Plugins::PlatinBridge::Discovery::_roundDone();
    is( $next->(), 15, 'and back to 15 s when the Hub is lost' );

    # A SILENT HUB IS LOOKED FOR, per player (0.2.7): an adopted Hub its player
    # has not heard from brings back the 15 s pace until it answers.
    Slim::Utils::Timers::_reset();
    $D->setSettled(1);
    $D->setSilent( '02:aa:00:00:00:01', 1 );
    Plugins::PlatinBridge::Discovery::_roundDone();
    is( $next->(), 15, 'a Hub adopted but silent: 15 s' );

    Slim::Utils::Timers::_reset();
    $D->setSilent( '02:aa:00:00:00:02', 1 );
    $D->setSilent( '02:aa:00:00:00:01', 0 );
    Plugins::PlatinBridge::Discovery::_roundDone();
    is( $next->(), 15, 'one of two silent Hubs answering keeps 15 s for the other' );

    Slim::Utils::Timers::_reset();
    $D->setSilent( '02:aa:00:00:00:02', 0 );
    Plugins::PlatinBridge::Discovery::_roundDone();
    is( $next->(), 600, 'every Hub answering: 10 minutes again' );
    is( $D->silent, 0, 'and nothing is left marked silent' );

    $D->stop;
    $D->setSettled(0);
}

# ---------------------------------------------------------------------------
printf "\n%s: %d passed, %d failed\n", ( $fail ? 'FAIL' : 'ok' ), $pass, $fail;
exit( $fail ? 1 : 0 );
