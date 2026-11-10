package Plugins::PlatinBridge::Plugin;

# Lifecycle: discovery wiring, player create and teardown.
#
# BESPOKE TO ONE MODEL, NOT ONE UNIT. Discovery sees every MediaRenderer on the
# network - a search can only name a device type - so this plugin reads each
# one's description, adopts every one that says it is a Platin Hub
# (UPnP::isPlatinHub), and asks nothing more of the rest this run. Asked again,
# at each discovery round: a renderer whose description did not come, and a
# Platin Hub with no AVTransport yet (still starting). One LMS player per Hub,
# so a home with two Hubs gets two players. It used to adopt "the first
# MediaRenderer seen" and then key on a stored UDN, which was wrong twice over:
# the first renderer could be a television, and the Hub's UDN changes at EVERY
# REBOOT (Simon, 2026-11-01).
#
# WHICH HUB IS WHICH - Simon's rule, 2026-11-01: a Hub is the SAME Hub when its
# UDN or its IP matches one we know (the UDN changes at a reboot, the IP with
# DHCP); when both are new it is a NEW Hub. Every Hub given a player is kept in
# the `hubs` pref - its player id with the UDN and IP it last had - so a Hub
# keeps its player, its playlist and SqueezeDSP's settings for it through a
# reboot, a new address, and an LMS restart.

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Digest::MD5 qw(md5_hex);
use Scalar::Util ();
use Socket qw(pack_sockaddr_in inet_aton INADDR_LOOPBACK);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes ();
use Slim::Display::NoDisplay;
use Slim::Control::Request;

use Plugins::PlatinBridge::Control;
use Plugins::PlatinBridge::Discovery;
use Plugins::PlatinBridge::Player;
use Plugins::PlatinBridge::Stream;
use Plugins::PlatinBridge::Trace;
use Plugins::PlatinBridge::UPnP;

# Bumped with install.xml. Reported by `platinbridge info` so the RUNNING
# version can be read back, which install.xml cannot tell you.
use constant VERSION => '0.2.11';

my $prefs = preferences('plugin.platinbridge');

my $log = Slim::Utils::Log->addLogCategory( {
    category     => 'plugin.platinbridge',
    defaultLevel => 'WARN',
    description  => 'PLUGIN_PLATIN_BRIDGE',
} );

# udn => { udn, device, client, upnp, control } - keyed by the UDN the Hub answers
# as NOW; a reboot re-keys its bridge (_rekey)
my %bridges;

# udn => UPnP object, while a renderer's description is being read to see what it is
my %probing;

# udn => 1, a renderer that was described and is not a Platin Hub (this run)
my %notHub;

sub getDisplayName { 'PLUGIN_PLATIN_BRIDGE' }

sub initPlugin {
    my $class = shift;

    # `hubs` is every Hub given a player: [ { id, udn, ip } ] (see _knownFor).
    # `playerid` / `udn` are 0.2.6's single Hub - read once, to seed `hubs`, so
    # that Hub keeps its player id; never written since.
    # `address` is an optional known address, probed by unicast as well.
    $prefs->init( { hubs => [], udn => undef, address => undef, playerid => undef } );

    if ( main::WEBUI ) {
        require Plugins::PlatinBridge::Settings;
        Plugins::PlatinBridge::Settings->new;
    }

    $class->SUPER::initPlugin(@_);

    # BEFORE discovery, so the first player created already has an endpoint.
    Plugins::PlatinBridge::Stream->init;

    # A CLI/JSON-RPC query, because it is the ONLY diagnostic channel that works
    # from off the home network: LMS refuses settings pages and pref reads unless
    # the request's source ip is on the LAN, while jsonrpc queries answer fine.
    Slim::Control::Request::addDispatch( [qw(platinbridge info)], [ 0, 1, 0, \&_infoQuery ] );
    Slim::Control::Request::addDispatch( [qw(platinbridge seekop _op)], [ 0, 0, 0, \&_seekOpCommand ] );

    Plugins::PlatinBridge::Discovery->start(
        \&_onDevices,
        address => $prefs->get('address'),
    );

    main::INFOLOG && $log->is_info && $log->info('Platin Hub Bridge started');

    return;
}

sub shutdownPlugin {
    Plugins::PlatinBridge::Discovery->stop;

    $_->close for values %probing;
    %probing = ();

    _teardown($_) for keys %bridges;

    return;
}

# ---------------------------------------------------------------------------
# Reconciliation

# $partial is true when discovery is reporting a device mid-round, before the
# list is complete. THE REMOVAL PASS MUST BE SKIPPED THEN: a partial list says
# nothing about who is absent, and tearing a player down destroys its playlist.
sub _onDevices {
    my ( $devices, $partial ) = @_;

    for my $udn ( keys %$devices ) {
        my $dev = $devices->{$udn};

        # An eval per device so one bad device cannot abort the round - a bare
        # die inside a timer callback surfaces only as "Timer ... failed".
        eval {
            if ( my $b = $bridges{$udn} ) {
                # The same UDN at another address: a DHCP move.
                _moved( $udn, $b, $dev ) if ( $b->{device}{location} || '' ) ne ( $dev->{location} || '' );
            }
            elsif ( !$probing{$udn} && !$notHub{$udn} && !_stale( $udn, $dev, $devices ) ) {
                _identify( $udn, $dev );
            }
            1;
        } or $log->error("failed to reconcile $udn: $@");
    }

    return if $partial;

    for my $udn ( keys %bridges ) {
        next if $devices->{$udn};

        # A Hub that is merely switched off keeps its player - it stays on the
        # network in standby, and Discovery's own TTL is generous for exactly this
        # reason. This only fires once discovery has genuinely given up on it.
        main::INFOLOG && $log->is_info && $log->info("$udn is gone - removing its player");
        _teardown($udn);
    }

    return;
}

# Read a renderer's own description to see whether it is the Hub.
sub _identify {
    my ( $udn, $dev ) = @_;

    my $upnp = Plugins::PlatinBridge::UPnP->new( location => $dev->{location}, udn => $udn, probe => 1 );

    $probing{$udn} = $upnp;

    $upnp->describe( sub {
        my $ok = shift;

        delete $probing{$udn};

        if ( !$ok ) {
            # Unreachable for now. Stop its own retries; the next discovery round
            # asks again.
            $upnp->close;

            # READ, AND NOT A PLATIN HUB (a Sonos, a television, a bonded
            # speaker): asked once per run, and for nothing past its description
            # (`ONLY A HUB IS DESCRIBED IN FULL`, 0.2.9). 0.2.7 asked again at
            # every discovery callback (`A RENDERER WE CANNOT DRIVE IS ASKED
            # ONCE`). A Platin Hub whose description lacks AVTransport (still
            # starting) is asked again.
            if ( $upnp->fetched && !$upnp->isPlatinHub ) {
                $notHub{$udn} = 1;
                main::INFOLOG && $log->is_info && $log->info( sprintf 'ignoring %s at %s (%s %s) - not a Platin Hub',
                    $upnp->name, ( $dev->{ip} || '?' ), ( $upnp->maker || '?' ), ( $upnp->model || '?' ) );
            }

            return;
        }

        # Described in full: a Platin Hub - describe succeeds for nothing else.

        # Adopted under this UDN while it was being read.
        if ( $bridges{$udn} ) {
            $upnp->close;
            return;
        }

        # THE SAME HUB, REBOOTED: a new UDN where a bridge already answers at
        # this IP. It keeps its player (Simon's rule: the IP is the same).
        if ( my $b = _bridgeAtIp( $dev->{ip} ) ) {
            eval { _rekey( $b, $udn, $dev, $upnp ); 1 } or $log->error("could not re-key the Hub at $dev->{ip}: $@");
            return;
        }

        eval { _create( $udn, $dev, $upnp ); 1 } or $log->error("could not create the player for $udn: $@");
    } );

    return;
}

# A UDN no newer than the one the bridge at the same IP answers as now. After a
# reboot discovery keeps listing the Hub's PREVIOUS UDN at its address until it
# ages out (Discovery's DEVICE_TTL): that is not a Hub to adopt, nor one to
# re-key back to.
sub _stale {
    my ( $udn, $dev, $devices ) = @_;

    my $b = _bridgeAtIp( $dev->{ip} ) or return 0;

    my $now = $devices->{ $b->{udn} };
    my $cur = $now ? ( $now->{lastSeen} || 0 ) : 0;

    return ( $dev->{lastSeen} || 0 ) <= $cur ? 1 : 0;
}

sub _bridgeAtIp {
    my $ip = shift;

    return undef unless defined $ip && length $ip;

    for my $b ( values %bridges ) {
        return $b if ( $b->{device}{ip} || '' ) eq $ip;
    }

    return undef;
}

# THE SAME HUB UNDER A NEW UDN - a reboot. Its bridge, player and control link
# carry on; only the key changes. Until 0.2.7 the player stayed on the old UDN
# until that aged out of discovery, then was torn down and made again
# (`A REBOOTED HUB IS RE-ADOPTED LATE`, measured 2026-11-01).
sub _rekey {
    my ( $b, $udn, $dev, $upnp ) = @_;

    my $old = $b->{udn};

    delete $bridges{$old} if defined $old;
    $bridges{$udn} = $b;
    $b->{udn}      = $udn;

    main::INFOLOG && $log->is_info && $log->info( sprintf '%s at %s is now %s - the same Hub, rebooted',
        ( $old || '?' ), ( $dev->{ip} || '?' ), $udn );

    Plugins::PlatinBridge::Trace::note( 'rekey', ( $old || '?' ) . " -> $udn" );

    my $sameLink = ( $b->{device}{location} || '' ) eq ( $dev->{location} || '' );

    $b->{device} = $dev;
    $b->{client}->pbDevice($dev);

    if ($sameLink) {
        # The same address: the link the player holds still works, so it is
        # kept - nothing in flight (a load, a volume) is dropped. The probe goes;
        # the kept link takes the new UDN, which keys its remembered capabilities.
        $upnp->close;
        $b->{upnp}{udn} = $udn if $b->{upnp};
    }
    else {
        # Another port or path on the same IP: the probe is described already,
        # so it becomes the player's link, as after a move.
        $b->{upnp}->close if $b->{upnp};
        $b->{upnp} = $upnp;
        _ready( $b, $upnp );
    }

    _remember( $b->{client}->id, $udn, $dev->{ip} );

    return;
}

# A device that moved keeps its player; only the transports are rebuilt. Keying on
# the UDN rather than the address is what makes that possible.
sub _moved {
    my ( $udn, $b, $dev ) = @_;

    main::INFOLOG && $log->is_info && $log->info("$udn moved to $dev->{location}");

    $b->{device} = $dev;
    $b->{client}->pbDevice($dev);
    $b->{client}->paddr( _paddrFor($dev) );
    $b->{control}->setHost( $dev->{ip} ) if $b->{control};

    $b->{upnp}->close if $b->{upnp};

    my $upnp = Plugins::PlatinBridge::UPnP->new( location => $dev->{location}, udn => $udn );
    $b->{upnp} = $upnp;

    _remember( $b->{client}->id, $udn, $dev->{ip} );

    # Found again by its link, not by its key: a reboot while this describe runs
    # re-keys the bridge (_rekey), and a lookup by the old UDN would find nothing
    # and leave the player on the closed link.
    $upnp->describe( sub {
        my $ok = shift;
        my ($now) = grep { $_->{upnp} && $_->{upnp} == $upnp } values %bridges;
        return unless $now;
        _ready( $now, $upnp ) if $ok;
    } );

    return;
}

# The renderer is described: hand it to the player.
sub _ready {
    my ( $b, $upnp ) = @_;

    my $client = $b->{client};

    $client->pbUPnP($upnp);
    $client->name( $upnp->name ) if $upnp->name;
    $client->updateFormats( $upnp->sink );

    # Polling starts at describe, not at a track load: its lifetime is the
    # DEVICE's, because it is the only thing that notices the user touching the
    # Hub's own handset while nothing is playing.
    $client->startPolling;

    $log->info( sprintf '%s: ready - gapless %s, volume %s, formats %s',
        $upnp->name,
        ( $upnp->canGapless ? 'via SetNextAVTransportURI' : 'not offered - each next track starts at the end of the last' ),
        ( $upnp->volRange ? "$upnp->{vol}{min}..$upnp->{vol}{max}" : 'assumed 0..100' ),
        join( ' ', $client->formats ) );

    return;
}

# ---------------------------------------------------------------------------
# Player construction

# A locally-administered MAC derived from the UDN a NEW Hub was first adopted
# under, then kept with that Hub in the `hubs` pref for good.
sub _idFor {
    my $udn = shift;

    my $h = md5_hex($udn);

    return join ':', '02', map { substr( $h, $_ * 2, 2 ) } 1 .. 5;
}

# ---------------------------------------------------------------------------
# The Hubs we know - every Hub given a player, with the UDN and IP it last had.

# A Hub that came back with BOTH a new UDN and a new IP is a new Hub by the rule,
# and leaves its old entry behind. The newest this many are kept.
use constant KNOWN_MAX => 16;

sub _knownHubs {
    my $list = $prefs->get('hubs');
    $list = [] unless ref $list eq 'ARRAY';

    # 0.2.6 KEPT ONE HUB: its player id in `playerid`, its UDN in `udn`, and no
    # IP. Seeded so, the first Hub found that matches nothing else takes that id
    # (_knownFor) - Simon's Lounge keeps its id and SqueezeDSP's settings for it.
    if ( !@$list && ( my $id = $prefs->get('playerid') ) ) {
        $list = [ { id => $id, udn => $prefs->get('udn'), ip => undef } ];
    }

    return $list;
}

# Which known Hub a Platin Hub found at ($udn, $ip) is - Simon's rule: the same
# UDN, or else the same IP. undef when both are new: a new Hub, a new player. An
# id a bridge already holds is never handed out twice.
sub _knownFor {
    my ( $udn, $ip ) = @_;

    my @free = grep { !_bridgeWithId( $_->{id} ) } @{ _knownHubs() };

    for my $h (@free) { return $h if defined $h->{udn} && $h->{udn} eq $udn }
    for my $h (@free) { return $h if defined $h->{ip} && defined $ip && $h->{ip} eq $ip }
    for my $h (@free) { return $h if !defined $h->{ip} }    # 0.2.6's Hub: its IP was never kept

    return undef;
}

sub _bridgeWithId {
    my $id = shift;

    for my $b ( values %bridges ) {
        return $b if $b->{client} && $b->{client}->id eq $id;
    }

    return undef;
}

# Keep a Hub's player id with the UDN and IP it has now.
sub _remember {
    my ( $id, $udn, $ip ) = @_;

    my @list = map { { %$_ } } @{ _knownHubs() };
    my ($h) = grep { $_->{id} eq $id } @list;

    if ($h) {
        $h->{udn} = $udn;
        $h->{ip}  = $ip;
    }
    else {
        push @list, { id => $id, udn => $udn, ip => $ip };
    }

    # Over the limit, the oldest entry no bridge holds goes - never the one being
    # written: _create remembers a Hub before its bridge exists.
    while ( @list > KNOWN_MAX ) {
        my ($i) = grep { $list[$_]{id} ne $id && !_bridgeWithId( $list[$_]{id} ) } 0 .. $#list;
        last unless defined $i;
        splice @list, $i, 1;
    }

    $prefs->set( 'hubs', \@list );

    # REMEMBERED ACTIONS FOLLOW THE HUB LIST (0.2.9): an action list is kept for
    # the UDN each Hub has now, and for a Hub still being read - its list is
    # written during its describe, before it is remembered. In its own eval: a
    # tidy that fails must not stop a Hub being adopted (_create remembers first).
    eval { Plugins::PlatinBridge::UPnP->keepRemembered( ( map { $_->{udn} } @list ), keys %probing ); 1 }
        or $log->warn("could not tidy the remembered action lists: $@");

    return;
}

sub _create {
    my ( $udn, $dev, $upnp ) = @_;

    # WHICH HUB: one we know - the same UDN, or the same IP - keeps its player id;
    # both new is a new Hub, with an id made from its UDN.
    my $known = _knownFor( $udn, $dev->{ip} );
    my $id    = $known ? $known->{id} : _idFor($udn);

    _remember( $id, $udn, $dev->{ip} );

    # THE PLAYER'S ADDRESS IS THE HUB'S ADDRESS. LMS derives $client->ip from the
    # peer address it was constructed with. NEVER use sockaddr_in() here: it
    # switches on wantarray and croaks when called in an argument list.
    my $paddr = _paddrFor($dev);

    # The constructor itself queues `client new` (Slim::Player::Client::new, LMS
    # 9.1) - a notification, delivered on the next idle loop, by which time the
    # name and the format list below are set.
    my $client = Plugins::PlatinBridge::Player->new(
        $id,        # id
        $paddr,     # peer address
        1.0,        # revision
        undef,      # NO socket - there is no SlimProto link
        12,         # deviceid
        undef,      # uuid
    );

    $client->macaddress($id);

    # A literal 1 is what lets the rest of LMS treat the player as connected
    # without a SlimProto link; connected() reads it back.
    $client->tcpsock(1);

    $client->display( Slim::Display::NoDisplay->new($client) );

    $client->pbDevice($dev);

    $client->init;

    # STRICTLY AFTER init, which is what runs initPrefs - a name set before it is
    # overwritten, and initBitrateLimit reads a pref that does not exist yet.
    $client->name( ( $upnp && $upnp->name ) || $dev->{name} || 'Platin Hub' );
    $client->initBitrateLimit;

    # The Hub's own control port. Weak, so the player and its link do not hold
    # each other alive past a teardown.
    my $weak = $client;
    Scalar::Util::weaken($weak);

    my $ctl = Plugins::PlatinBridge::Control->new(
        host     => $dev->{ip},
        name     => $client->name,
        onPower  => sub { $weak && $weak->_onHubPower(@_) },
        onSource => sub { $weak && $weak->_onHubSource(@_) },
    );

    $client->pbControl($ctl);

    my $b = { udn => $udn, device => $dev, client => $client, upnp => $upnp, control => $ctl };
    $bridges{$udn} = $b;

    $ctl->start;

    Plugins::PlatinBridge::Discovery->setSettled(1);

    _ready( $b, $upnp ) if $upnp && $upnp->isReady;

    main::INFOLOG && $log->is_info && $log->info("created player $id for $udn");

    return $client;
}

# Falls back to loopback only if the device somehow has no address, because a
# player that cannot be constructed is worse than one with a useless ip.
sub _paddrFor {
    my $dev = shift;

    my $packed = $dev && $dev->{ip} ? inet_aton( $dev->{ip} ) : undef;

    return pack_sockaddr_in( 0, $packed || INADDR_LOOPBACK );
}

sub _teardown {
    my $udn = shift;

    my $b = delete $bridges{$udn} or return;

    Plugins::PlatinBridge::Discovery->setSettled(0) unless %bridges;

    eval {
        $b->{upnp}->close    if $b->{upnp};
        $b->{control}->close if $b->{control};

        if ( my $client = $b->{client} ) {
            # A Hub torn down while silent must not keep discovery searching.
            Plugins::PlatinBridge::Discovery->setSilent( $client->id, 0 );
            $client->stopPolling;
            $client->controller->stop;
            Slim::Player::Client::forgetClient($client);
        }
        1;
    } or $log->error("teardown of $udn failed: $@");

    return;
}

# Read-only view, for the tests and the settings page.
sub bridges { return { %bridges } }

# `platinbridge info` - what the Hub told us about itself, and what the bridge
# just did.
sub _infoQuery {
    my $request = shift;

    $request->addResult( 'count', scalar keys %bridges );

    my $i = 0;

    for my $udn ( sort keys %bridges ) {
        my $b      = $bridges{$udn};
        my $upnp   = $b->{upnp};
        my $client = $b->{client};
        my $ctl    = $b->{control};

        $request->addResultLoop( 'devices_loop', $i, 'udn',      $udn );
        $request->addResultLoop( 'devices_loop', $i, 'location', $b->{device}{location} || '' );
        $request->addResultLoop( 'devices_loop', $i, 'ip',       $b->{device}{ip} || '' );

        if ($client) {
            $request->addResultLoop( 'devices_loop', $i, 'player_id',   $client->id );
            $request->addResultLoop( 'devices_loop', $i, 'player_name', $client->name || '' );
            $request->addResultLoop( 'devices_loop', $i, 'formats',     join ' ', $client->formats );
            $request->addResultLoop( 'devices_loop', $i, 'max_rate',    $client->maxSupportedSamplerate );
            $request->addResultLoop( 'devices_loop', $i, 'per_track',   $client->pbPerTrack ? 1 : 0 );
            $request->addResultLoop( 'devices_loop', $i, 'url',         $client->pbURL || '' );
            $request->addResultLoop( 'devices_loop', $i, 'armed_url',   $client->pbArmedURL || '' );
            $request->addResultLoop( 'devices_loop', $i, 'wanted',      $client->pbWanted || '' );
            $request->addResultLoop( 'devices_loop', $i, 'hub_state',   $client->pbHubState || '' );

            # WHAT THE BYTES SAY: the opening of the stream the Hub is playing, and
            # of the one LMS is streaming now (the same track except across a
            # gapless hand-over), read off the wire.
            $request->addResultLoop( 'devices_loop', $i, 'wire_playing',   $client->pbWireFor( $client->pbPlayingSeq ) );
            $request->addResultLoop( 'devices_loop', $i, 'wire_streaming', $client->pbWireFor( $client->pbLiveSeq ) );
        }

        if ($ctl) {
            my $src = $ctl->source;
            $request->addResultLoop( 'devices_loop', $i, 'control_up', $ctl->isUp );
            $request->addResultLoop( 'devices_loop', $i, 'hub_power',
                defined $ctl->power ? ( $ctl->power ? 'on' : 'off' ) : 'unknown' );
            $request->addResultLoop( 'devices_loop', $i, 'hub_source', $src ? "$src->{name} ($src->{ix})" : 'unknown' );
            $request->addResultLoop( 'devices_loop', $i, 'hub_sources',
                join ', ', map { "$_->{ix}=$_->{name}" } @{ $ctl->sources } );
        }

        if ($upnp) {
            $request->addResultLoop( 'devices_loop', $i, 'ready',      $upnp->isReady ? 1 : 0 );
            $request->addResultLoop( 'devices_loop', $i, 'name',       $upnp->name || '' );
            $request->addResultLoop( 'devices_loop', $i, 'model',      join ' ', grep { $_ } $upnp->maker, $upnp->model );
            $request->addResultLoop( 'devices_loop', $i, 'gapless',    $upnp->canGapless ? 1 : 0 );
            $request->addResultLoop( 'devices_loop', $i, 'remembered', $upnp->actionsAreRemembered );

            my $acts = $upnp->{actions} || {};
            $request->addResultLoop( 'devices_loop', $i, 'actions', join ' ', sort keys %$acts );

            my $r = $upnp->volRange;
            $request->addResultLoop( 'devices_loop', $i, 'volume_range',
                $r ? "$r->{min}..$r->{max} step $r->{step}" : 'not stated' );

            my $sink = $upnp->sink;
            $request->addResultLoop( 'devices_loop', $i, 'sink_total', defined $sink ? scalar @$sink : -1 );
        }

        $i++;
    }

    # THE RUNNING VERSION, not the one on disk: install.xml is re-read per
    # request, a .pm once at start-up.
    $request->addResult( 'version', VERSION );

    # The seek test's DLNA.ORG_OP, or 'off' (see Format::seekOp).
    my $op = Plugins::PlatinBridge::Format::seekOpNow();
    $request->addResult( 'seek_op', defined $op ? $op : 'off' );

    # WHAT THE BRIDGE JUST DID, newest last.
    my $t   = Plugins::PlatinBridge::Trace::entries();
    my $now = Time::HiRes::time();
    my $n   = 0;

    for my $e (@$t) {
        $request->addResultLoop( 'trace_loop', $n, 'ago',    sprintf( '%.1f', $now - $e->{at} ) );
        $request->addResultLoop( 'trace_loop', $n, 'what',   $e->{what} );
        $request->addResultLoop( 'trace_loop', $n, 'detail', $e->{detail} );
        $n++;
    }

    $request->addResult( 'trace_count', scalar @$t );

    $request->setStatusDone;

    return;
}

# `platinbridge seekop <00|01|10|11|off>` - the seek test's switch: what the
# plugin says it can serve when the Hub seeks (DLNA.ORG_OP: time, byte). Held in
# memory only, so an LMS restart puts it back to off.
sub _seekOpCommand {
    my $request = shift;

    my $op = $request->getParam('_op');
    $op = '' unless defined $op;

    if ( $op !~ /^(?:[01]{2}|off)$/ ) {
        $request->setStatusBadParams;
        return;
    }

    my $now = Plugins::PlatinBridge::Format::seekOp( $op eq 'off' ? undef : $op );

    Plugins::PlatinBridge::Trace::note( 'seek-op', defined $now ? "DLNA.ORG_OP=$now" : 'off' );

    $request->addResult( 'seek_op', defined $now ? $now : 'off' );
    $request->setStatusDone;

    return;
}

1;
