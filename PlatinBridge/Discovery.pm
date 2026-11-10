package Plugins::PlatinBridge::Discovery;

# SSDP discovery for the Platin Hub.
#
# An M-SEARCH datagram to the SSDP group 239.255.255.250:1900 carrying
#
#     M-SEARCH * HTTP/1.1
#     HOST: 239.255.255.250:1900
#     MAN: "ssdp:discover"
#     MX: 2
#     ST: urn:schemas-upnp-org:device:MediaRenderer:1
#
# is answered by every MediaRenderer on the segment with an HTTP-shaped reply
# carrying LOCATION (the device description url) and USN (which contains the
# device's UDN). Everything else about the device comes from fetching that
# description - see UPnP.pm.
#
# THE UDN IS THE IDENTITY, NOT THE IP AND NOT THE NAME. A DHCP move must not
# orphan the player's prefs, playlist or sync group, and two devices can share a
# friendlyName. The HQPlayer bridge had to key on the name because HQPlayer's own
# discovery protocol carries no unique id; SSDP does, so this keys on the UDN and
# treats an address change as an update to a known device rather than a new one.
#
# NEVER SWEEP A SUBNET. A /24 probe from a plugin once ARP-flooded this very
# server off the network. Multicast, or an explicitly configured address, and
# nothing else - there is no code path here that enumerates hosts.
#
# THIS DELIBERATELY DOES NOT BIND PORT 1900 to listen for ssdp:byebye. Two
# reasons. It would fight whatever else on the box speaks UPnP (the old bridge,
# LMS's own UPnP plugin) for the port, and it would not earn anything: a byebye
# means "no opinion" under Design rule 2, never "stopped", so the poll on
# GetTransportInfo already covers reachability without a second, conflicting
# listener. Powering the Hub off must never be a signal that starts LMS.

use strict;
use warnings;

use IO::Socket::INET;
use Socket qw(inet_ntoa pack_sockaddr_in unpack_sockaddr_in);
use Time::HiRes ();

use Slim::Networking::Select;
use Slim::Utils::Log;
use Slim::Utils::Timers;

my $log = logger('plugin.platinbridge');

use constant SSDP_ADDR => '239.255.255.250';
use constant SSDP_PORT => 1900;

use constant ST_RENDERER => 'urn:schemas-upnp-org:device:MediaRenderer:1';

# MX is the maximum number of seconds a device may wait before answering, so the
# listen window has to exceed it or slow devices are missed every round.
use constant MX          => 2;
use constant LISTEN_TIME => 3.5;

# One datagram per round is one point of failure, and multicast is exactly the
# part that goes missing. Three ~130-byte probes cost nothing and remove the
# whole class of "one lost packet, one wasted round".
use constant PROBE_BURST => 3;
use constant PROBE_GAP   => 0.3;

# A device silent for longer than this is dropped from the list. Generous,
# because dropping it tears down a player - and a Hub that is merely switched off
# should keep its player, its playlist and its place in a sync group.
use constant DEVICE_TTL => 30 * 60;

# COLD  - no Hub adopted yet, or an adopted Hub has gone silent. Ask often.
# IDLE  - the plugin has its Hubs (setSettled) and every one answers its player's
#         poll, so stop asking: the poll is the liveness signal. A player that
#         has not heard from its Hub for 30 s marks it silent (setSilent), and
#         discovery is COLD until it answers again - at its old address, a new
#         one, or under a new UDN (Player::_hubUnanswered).
use constant COLD_PERIOD => 15;
use constant IDLE_PERIOD => 10 * 60;

my %found;        # udn => { udn, location, ip, server, lastSeen }
my $sock;
my $running  = 0;
my $burst    = 0;
my $backoff  = 0;
my $onChange;
my $wantAddr;     # an explicitly configured address, probed by unicast
my $settled = 0;  # the plugin has a Hub: nothing left to look for, unless...
my %silent;       # player id => 1: ...an adopted Hub its player has not heard from

sub start {
    my ( $class, $cb, %args ) = @_;

    $onChange = $cb;
    $wantAddr = $args{address};
    $running  = 1;
    $backoff  = 0;

    _round();

    return;
}

sub stop {
    $running = 0;
    Slim::Utils::Timers::killTimers( undef, \&_probe );
    Slim::Utils::Timers::killTimers( undef, \&_roundDone );
    Slim::Utils::Timers::killTimers( undef, \&_round );
    _closeSocket();
    return;
}

sub devices { return { %found } }

# Set by the plugin once it has adopted a Hub, and cleared when it has none left
# (Plugin::_teardown). The pace keys on THIS, not on whether anything answered:
# every renderer is reported now, so "something answered" would settle on the
# Eversolo or a television and leave a Hub that missed that round waiting
# IDLE_PERIOD to be found.
sub setSettled {
    my ( $class, $on ) = @_;
    $settled = $on ? 1 : 0;
    return;
}

sub settled { return $settled }

# Set by a player whose Hub has not answered its poll for 30 s, cleared at the
# Hub's first answer or the player's teardown. Per player, so one Hub answering
# again cannot stop the search for another that is still silent.
sub setSilent {
    my ( $class, $who, $on ) = @_;

    return unless defined $who;

    if   ($on) { $silent{$who} = 1 }
    else       { delete $silent{$who} }

    return;
}

sub silent { return scalar keys %silent }

# The wait before the next round: IDLE only while the plugin has a Hub and no
# adopted Hub is silent.
sub period { return ( $settled && !%silent ) ? IDLE_PERIOD : COLD_PERIOD }

# A known address to probe by unicast as well as by multicast.
sub setWanted {
    my ( $class, %args ) = @_;
    $wantAddr = $args{address} if exists $args{address};
    return;
}

sub probeNow {
    return unless $running;
    Slim::Utils::Timers::killTimers( undef, \&_round );
    _round();
    return;
}

# ---------------------------------------------------------------------------

sub _round {
    return unless $running;

    # A round left half-sent - the plugin stopped and restarted inside a burst -
    # must not fire into the new round's socket.
    Slim::Utils::Timers::killTimers( undef, \&_probe );
    Slim::Utils::Timers::killTimers( undef, \&_roundDone );

    _closeSocket();

    $sock = IO::Socket::INET->new(
        Proto     => 'udp',
        Blocking  => 0,
        LocalPort => 0,
    );

    if ( !$sock ) {
        $log->warn("discovery: cannot open UDP socket: $!");
        return _schedule();
    }

    # Reach a device one hop away where the platform allows it; the default TTL
    # of 1 still covers the ordinary same-subnet case.
    eval {
        setsockopt( $sock, Socket::IPPROTO_IP(), Socket::IP_MULTICAST_TTL(), pack( 'I', 4 ) );
    };

    Slim::Networking::Select::addRead( $sock, \&_reply );

    $burst = PROBE_BURST;
    _probe();

    return;
}

sub _msearch {
    my $host = shift;
    return join( "\r\n",
        'M-SEARCH * HTTP/1.1',
        'HOST: ' . $host,
        'MAN: "ssdp:discover"',
        'MX: ' . MX,
        'ST: ' . ST_RENDERER,
        '', '' );
}

sub _probe {
    return unless $running && $sock;

    my $first = $burst == PROBE_BURST;

    my $sent = send( $sock, _msearch( SSDP_ADDR . ':' . SSDP_PORT ), 0,
        pack_sockaddr_in( SSDP_PORT, Socket::inet_aton( SSDP_ADDR ) ) );

    if ( !defined $sent && $first ) {
        $log->warn("discovery: multicast send failed: $! (is the network up?)");
        _closeSocket();
        return _schedule();
    }

    # A device we have already met, or one the user has named outright, does not
    # need multicast at all - and multicast is the fragile part (group
    # membership, IGMP snooping, which interface the kernel picked). A unicast
    # M-SEARCH to a KNOWN address is not a sweep: it is one packet to one host we
    # have already spoken to.
    my %addr;
    $addr{$wantAddr} = 1 if $wantAddr;
    $addr{ $found{$_}{ip} } = 1 for grep { $found{$_}{ip} } keys %found;

    for my $ip ( keys %addr ) {
        my $packed = Socket::inet_aton($ip) or next;
        send( $sock, _msearch( $ip . ':' . SSDP_PORT ), 0,
            pack_sockaddr_in( SSDP_PORT, $packed ) );
    }

    if ( --$burst > 0 ) {
        Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + PROBE_GAP, \&_probe );
        return;
    }

    main::DEBUGLOG && $log->is_debug && $log->debug(
        'discovery: ' . PROBE_BURST . ' probes sent, listening ' . LISTEN_TIME . 's' );

    Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + LISTEN_TIME, \&_roundDone );

    return;
}

sub _reply {
    my $s = shift || $sock;
    return unless $s;

    my $from = recv( $s, my $buf, 4096, 0 );
    return unless defined $from && length $buf;

    my ( $port, $addr ) = unpack_sockaddr_in($from);
    my $ip = inet_ntoa($addr);

    my $h = parseHeaders($buf) or return;

    # An M-SEARCH response is a 200; a NOTIFY arriving here would be a different
    # message shape with a different meaning, and is not acted on.
    return unless ( $h->{_status} || '' ) =~ m{^HTTP/1\.[01]\s+200};

    my $location = $h->{location} or return;

    # Anyone on the LAN can answer an M-SEARCH, and the LOCATION is fetched from
    # the LMS host. A renderer describes itself at its own address, so a LOCATION
    # naming any other host is not followed.
    if ( !locationIsFrom( $location, $ip ) ) {
        main::INFOLOG && $log->is_info && $log->info("discovery: $ip gave a LOCATION on another host ($location) - ignored");
        return;
    }

    my $udn = udnFromUSN( $h->{usn} );

    if ( !$udn ) {
        main::DEBUGLOG && $log->is_debug && $log->debug("discovery: $ip answered with no usable USN - ignored");
        return;
    }

    # EVERY renderer is reported, and the plugin picks the Hub out by its own
    # description (UPnP::isPlatinHub). Discovery used to drop every UDN but a
    # stored one, which made a Hub that had been factory-reset - and so minted a
    # new UDN - invisible for good: Simon's has had two.

    my $prev  = $found{$udn};
    my $isNew = !$prev;
    my $moved = $prev && ( $prev->{location} || '' ) ne $location;

    $found{$udn} = {
        udn      => $udn,
        location => $location,
        ip       => $ip,
        server   => $h->{server} || '',
        lastSeen => time(),
    };

    return unless $isNew || $moved;

    $backoff = 0;

    main::INFOLOG && $log->is_info && $log->info(
        sprintf 'discovery: %s %s at %s (%s)',
        ( $isNew ? 'found' : 'moved' ), $udn, $ip, $location );

    # PARTIAL, and it matters: the second argument tells the caller this list is
    # still being collected. Without it a reconcile would read "not in the list"
    # as "gone" and tear down a player that simply had not answered yet.
    $onChange->( devices(), 1 ) if $onChange;

    return;
}

# True when an http(s) LOCATION url names exactly the address the reply came from.
# A url with userinfo, a hostname or an IPv6 literal does not match.
sub locationIsFrom {
    my ( $location, $ip ) = @_;

    return 0 unless defined $location && defined $ip;
    my ($host) = $location =~ m{^https?://([^/\@?#:\s]+)(?::\d+)?(?:[/?#]|$)}i or return 0;

    return $host eq $ip ? 1 : 0;
}

sub _roundDone {
    _closeSocket();

    my $cutoff = time() - DEVICE_TTL;

    for my $udn ( keys %found ) {
        next if $found{$udn}{lastSeen} >= $cutoff;
        main::INFOLOG && $log->is_info && $log->info("discovery: $udn stopped answering");
        delete $found{$udn};
    }

    if ( !scalar keys %found ) {
        main::INFOLOG && $log->is_info && $log->info(
            'discovery: no MediaRenderer answered on ' . SSDP_ADDR . ':' . SSDP_PORT );
    }

    $onChange->( devices() ) if $onChange;

    _schedule();

    return;
}

sub _schedule {
    return unless $running;

    # Once the plugin has its Hubs there is nothing left to discover, so back
    # right off and let each player's poll be the liveness signal (a silent Hub
    # brings back the short pace - see setSilent).
    my $period = period();

    Slim::Utils::Timers::killTimers( undef, \&_round );
    Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + $period, \&_round );

    return;
}

sub _closeSocket {
    return unless $sock;

    Slim::Networking::Select::removeRead($sock);
    CORE::close($sock);
    $sock = undef;

    return;
}

# ---------------------------------------------------------------------------
# Parsing, kept as plain functions so the test suite can drive them directly.

# An SSDP reply is HTTP-shaped but is NOT HTTP: header names arrive in any case
# and devices are inconsistent about it, so every name is lower-cased. The status
# line is stashed as _status.
sub parseHeaders {
    my $buf = shift;

    return undef unless defined $buf && length $buf;

    my @lines = split /\r?\n/, $buf;
    my $status = shift @lines;

    return undef unless defined $status;

    my %h = ( _status => $status );

    for my $l (@lines) {
        last if $l eq '';
        next unless $l =~ /^([A-Za-z0-9._-]+)\s*:\s*(.*?)\s*$/;
        $h{ lc $1 } = $2;
    }

    return \%h;
}

# USN is 'uuid:<udn>::urn:schemas-upnp-org:device:MediaRenderer:1' or bare
# 'uuid:<udn>'. The UDN we keep INCLUDES the 'uuid:' prefix, because that is what
# the device description's own <UDN> element carries and the two must compare
# equal - stripping it here and not there is how an identity check silently fails.
sub udnFromUSN {
    my $usn = shift;

    return undef unless defined $usn && length $usn;

    my ($udn) = $usn =~ /^\s*(uuid:[^:\s]+)/i;

    return $udn;
}

1;
