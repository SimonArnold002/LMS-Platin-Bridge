package Plugins::PlatinBridge::UPnP;

# The Platin Hub's UPnP MediaRenderer: description handshake, SOAP client, and
# the AVTransport / RenderingControl actions the bridge drives.
#
# Derived from the UPnP.pm that LMS-HQPlayer-Bridge carried until 0.2.54 (its
# _soap envelope and the _av/_rc currying are lifted almost verbatim), but that
# module only ever read a volume range off a device whose control URLs it already
# knew. Four things it did not do, all of which a real renderer needs:
#
#   1. URLBase / relative control URLs.  It prepended "/" to whatever it found
#      and assumed the host was http://<ip>:8019.  A renderer may put its
#      control URLs on another port, another path root, or state a <URLBase>
#      that overrides the description's own location.
#   2. Service versions.  It hardcoded ":3" in the SOAPACTION while matching the
#      description loosely on ":AVTransport:".  If the device says :1 and we say
#      :3, a strict renderer answers 401 Invalid Action.  The version we send is
#      now the version the DEVICE stated.
#   3. eventSubURL.  Never captured, so GENA was impossible.  Captured here even
#      though eventing is deliberately not wired yet - see Design rule 4 in the
#      plan: poll first, event only once NOTIFY is proven through LMS's HTTP
#      server.
#   4. SOAP faults.  A UPnP fault is HTTP 500 with <errorCode> in the BODY, and
#      the old module's own comment admitted it could not read it, so it matched
#      a substring on "701" and retried blind.
#
# THE SCPD FETCH IS THE POINT OF THIS MODULE.  A renderer publishes its own
# action list, so whether the Hub can do gapless (SetNextAVTransportURI) is a
# question the plugin ASKS THE DEVICE at connect rather than a decision baked in
# at build time.  Nothing in this plugin may assume an optional action exists.
#
# All requests go through Slim::Networking::SimpleAsyncHTTP, so nothing here
# blocks the event loop.

use strict;
use warnings;

use Encode ();

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log   = logger('plugin.platinbridge');
my $prefs = preferences('plugin.platinbridge');

use constant SOAP_TIMEOUT     => 10;
use constant DESCRIBE_TIMEOUT => 10;

# Describe runs at player-create and at link-up, neither of which recurs, so a
# boot race (LMS up before the Hub) would otherwise leave the player permanently
# unplayable. Same reasoning, and the same numbers, as the HQPlayer module.
use constant DESCRIBE_RETRY_MIN => 5;
use constant DESCRIBE_RETRY_MAX => 60;

# Matched loosely against the description; the version actually found is what we
# send back in the SOAPACTION and the u: namespace.
use constant AV_URN => 'urn:schemas-upnp-org:service:AVTransport';
use constant RC_URN => 'urn:schemas-upnp-org:service:RenderingControl';
use constant CM_URN => 'urn:schemas-upnp-org:service:ConnectionManager';

sub new {
    my ( $class, %args ) = @_;

    # A PROBE is Plugin::_identify reading a renderer to see what it is: the
    # brand gate applies to it alone, and until its description names it, it is
    # known by its UDN - most renderers that answer are not Hubs.
    my $probe = $args{probe} ? 1 : 0;

    return bless {
        location => $args{location},        # the SSDP LOCATION: url
        name     => $args{name} || ( $probe && $args{udn} ) || 'Platin Hub',
        udn      => $args{udn},
        probe    => $probe,
        maker    => '',
        model    => '',
        base     => undef,
        svc      => {},                     # av|rc|cm => { type, control, event, scpd }
        actions  => {},                     # 'SetNextAVTransportURI' => 1
        vol      => undef,                  # { min, max, step }
        ready    => 0,
        backoff  => 0,
        epoch    => 0,
        quiet    => 0,                      # a transport failure was warned; the rest go to debug
    }, $class;
}

sub name     { $_[0]->{name} }
sub udn      { $_[0]->{udn} }
sub maker    { $_[0]->{maker} }
sub model    { $_[0]->{model} }

# The renderer is the device this plugin exists for. Read off its own description
# (2026-10-25: manufacturer "Platin", modelName "Stereo Hub HT") rather than keyed
# on a stored UDN, because the UDN is NOT stable: a factory reset mints a new one,
# and Simon's Hub has had two (c1cbe6e3... in September, e1d04a48... now). A
# check on the model also keeps the plugin off every other MediaRenderer on the
# network - a television, the Eversolo, HQPlayer's own renderer.
sub isPlatinHub {
    my $self = shift;
    return ( $self->{maker} =~ /\bplatin\b/i && $self->{model} =~ /\bhub\b/i ) ? 1 : 0;
}
sub location { $_[0]->{location} }
sub isReady  { $_[0]->{ready} }
sub volRange { $_[0]->{vol} }

# The whole reason the SCPD is fetched. Returns true only when the device itself
# listed the action. An unknown action is FALSE, never assumed present.
sub can_action {
    my ( $self, $action ) = @_;
    return $self->{actions}{$action} ? 1 : 0;
}

# True when the Hub advertised the gapless action. Named separately because this
# single answer selects the entire transport strategy.
sub canGapless { $_[0]->can_action('SetNextAVTransportURI') }

sub close {
    my $self = shift;
    $self->{epoch}++;
    $self->{ready} = 0;
    Slim::Utils::Timers::killTimers( $self, \&_describeRetry );
    return;
}

# ---------------------------------------------------------------------------
# Description handshake

# A renderer that will not serve its description is asked again at every
# discovery round (Plugin::_identify - since 0.2.7 rounds identify after a Hub is
# adopted too): one warning per address until it answers, not one per round
# (`A SILENT HUB FLOODS THE LOG`). Across objects, because each round's probe is
# a new one.
my %fetchWarned;

sub describe {
    my ( $self, $cb ) = @_;

    my $url = $self->{location};

    if ( !$url ) {
        $log->warn("$self->{name}: describe with no location url");
        $cb->(0) if $cb;
        return;
    }

    my $epoch = $self->{epoch};

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $res = shift;
            return if $epoch != $self->{epoch};
            delete $fetchWarned{$url};
            $self->_onDescription( $res->content || '', $cb );
        },
        sub {
            my ( $http, $err ) = @_;
            return if $epoch != $self->{epoch};
            my $lvl = $fetchWarned{$url}++ ? 'debug' : 'warn';
            $log->$lvl("$self->{name}: description fetch failed at $url: $err");
            $self->_scheduleDescribe($cb);
            $cb->(0) if $cb;
        },
        { timeout => DESCRIBE_TIMEOUT },
    )->get($url);

    return;
}

# The description was read - whether or not it named a Platin Hub, or one we can
# drive.
sub fetched { $_[0]->{fetched} ? 1 : 0 }

sub _onDescription {
    my ( $self, $body, $cb ) = @_;

    $self->{fetched} = 1;

    # <URLBase> wins over the location url when present; the spec allows either
    # and devices disagree about which they populate.
    my ($urlbase) = $body =~ m{<URLBase>\s*([^<\s]+)\s*</URLBase>}i;
    $self->{base} = $self->_baseFrom( $urlbase, $self->{location} );

    my ($udn) = $body =~ m{<UDN>\s*([^<\s]+)\s*</UDN>}i;
    $self->{udn} = $udn if $udn && !$self->{udn};

    my ($fname) = $body =~ m{<friendlyName>\s*(.*?)\s*</friendlyName>}is;
    $self->{name} = _unescape($fname) if $fname;

    my ($maker) = $body =~ m{<manufacturer>\s*(.*?)\s*</manufacturer>}is;
    my ($model) = $body =~ m{<modelName>\s*(.*?)\s*</modelName>}is;
    $self->{maker} = defined $maker ? _unescape($maker) : '';
    $self->{model} = defined $model ? _unescape($model) : '';

    # ONLY A HUB IS DESCRIBED IN FULL (0.2.9). Every renderer on the network
    # answers discovery, and the brand is here, in its description. Until 0.2.8
    # the whole describe ran first: two SCPDs and a GetProtocolInfo to every
    # Sonos, WiiM and television, each one's action list kept in the prefs, and a
    # warning for those with no AVTransport. No retry: a device that says it is
    # something else is not asked again this run (Plugin::_identify).
    #
    # A PROBE ONLY (0.2.10). A link the plugin already holds - a Hub adopted by
    # its UDN, described again after a move - is not re-judged on its brand: a
    # 0 here, with no retry, left a moved Hub's player on its closed link until
    # LMS restarted (`A MOVED HUB'S RETRY ANSWERED NO ONE`, reopened by 0.2.9).
    if ( $self->{probe} && !$self->isPlatinHub ) {
        $cb->(0) if $cb;
        return;
    }

    # A Hub that names itself nothing is a Platin Hub, not its UDN.
    $self->{name} = 'Platin Hub' if $self->{probe} && !$fname;

    # Pair each serviceType with the URLs inside ITS OWN <service> element.
    # Scoping to the element matters: a MediaRenderer description contains
    # several services and a global match would cross-pair them.
    $self->{svc} = {};
    while ( $body =~ m{<service>(.*?)</service>}gis ) {
        my $el = $1;
        my ($type) = $el =~ m{<serviceType>\s*([^<\s]+)\s*</serviceType>}i or next;

        # Matched on the version-less URN plus a colon, so any version the device
        # states is accepted; the version itself is kept in {type} and echoed
        # back in the SOAPACTION rather than hardcoded.
        my $slot = index( $type, AV_URN . ':' ) == 0 ? 'av'
                 : index( $type, RC_URN . ':' ) == 0 ? 'rc'
                 : index( $type, CM_URN . ':' ) == 0 ? 'cm'
                 :                                     undef;
        next unless $slot;

        my ($ctrl)  = $el =~ m{<controlURL>\s*([^<\s]*)\s*</controlURL>}i;
        my ($event) = $el =~ m{<eventSubURL>\s*([^<\s]*)\s*</eventSubURL>}i;
        my ($scpd)  = $el =~ m{<SCPDURL>\s*([^<\s]*)\s*</SCPDURL>}i;

        $self->{svc}{$slot} = {
            type    => $type,
            control => $self->_absolute($ctrl),
            event   => $self->_absolute($event),
            scpd    => $self->_absolute($scpd),
        };
    }

    if ( !$self->{svc}{av} || !$self->{svc}{av}{control} ) {
        $log->warn("$self->{name}: description has no AVTransport control url - not a renderer we can drive");
        $self->_scheduleDescribe($cb);
        $cb->(0) if $cb;
        return;
    }

    $self->{ready}   = 1;
    $self->{backoff} = 0;
    Slim::Utils::Timers::killTimers( $self, \&_describeRetry );

    main::INFOLOG && $log->is_info && $log->info(
        sprintf '%s: described - AV %s, RC %s, base %s',
        $self->{name}, $self->{svc}{av}{type},
        ( $self->{svc}{rc} ? $self->{svc}{rc}{type} : 'none' ),
        $self->{base}
    );

    # The action list, the volume range and the accepted formats are what the rest
    # of the plugin makes decisions on, so the describe is not "done" until all
    # three have been asked for. Each is best-effort: a device that will not serve
    # its SCPD still plays.
    $self->_fetchActions( sub {
        $self->_fetchVolRange( sub {
            $self->_fetchProtocolInfo( sub { $cb->(1) if $cb } );
        } );
    } );

    return;
}

# http://host:port from an explicit URLBase, else from the description url.
sub _baseFrom {
    my ( $self, $urlbase, $location ) = @_;

    # A <URLBase> on another host than the one that served the description is
    # ignored: it would redirect every service url, and the SOAP bodies, there.
    for my $u ( $urlbase, $location ) {
        next unless $u;
        if ( my ($b) = $u =~ m{^(https?://[^/]+)} ) {
            next if $u eq ( $urlbase || '' ) && $location && _hostOf($b) ne _hostOf($location);
            return $b;
        }
    }
    return '';
}

# The lower-cased host of an http(s) url, '' when it has none.
sub _hostOf {
    my ($url) = @_;

    return '' unless defined $url;
    my ($host) = $url =~ m{^https?://(?:[^/\@?#]*\@)?([^/\@?#:]+)}i;

    return defined $host ? lc $host : '';
}

# Resolve a controlURL/eventSubURL/SCPDURL against the base. Devices publish all
# three forms: absolute, root-relative, and bare-relative.
sub _absolute {
    my ( $self, $path ) = @_;

    return undef unless defined $path && $path ne '';

    my $base = $self->{base} || '';

    # An absolute url is followed only to the host the description came from.
    if ( $path =~ m{^https?://}i ) {
        return ( $base && $path !~ m{^https?://[^/?#]*\@} && _hostOf($path) eq _hostOf($base) ) ? $path : undef;
    }

    return $path =~ m{^/} ? $base . $path : $base . '/' . $path;
}

sub _scheduleDescribe {
    my ( $self, $cb ) = @_;

    my $wait = $self->{backoff} ? $self->{backoff} * 2 : DESCRIBE_RETRY_MIN;
    $wait = DESCRIBE_RETRY_MAX if $wait > DESCRIBE_RETRY_MAX;
    $self->{backoff} = $wait;

    Slim::Utils::Timers::killTimers( $self, \&_describeRetry );
    Slim::Utils::Timers::setTimer( $self, time() + $wait, \&_describeRetry, $cb );

    main::DEBUGLOG && $log->is_debug && $log->debug("$self->{name}: describe retry in ${wait}s");
    return;
}

# THE RETRY ANSWERS WHOEVER ASKED. Plugin::_moved hands a re-described Hub to its
# player only from the describe's callback; a retry that called back no one left
# the player on the closed link for good when the first describe at a new address
# failed (found 2026-11-01, `A MOVED HUB'S RETRY ANSWERED NO ONE`). Each failed
# retry calls back with 0 as well - _moved ignores that, and _identify closes the
# object on its first failure, which cancels the retries.
sub _describeRetry {
    my ( $self, $cb ) = @_;
    $self->describe($cb);
    return;
}

# ---------------------------------------------------------------------------
# Capability discovery

# Read the AVTransport SCPD and record every action the device lists. This is
# the measurement that says whether the next track can be handed over gaplessly.
#
# A FAILED READ IS "UNKNOWN", NOT "ABSENT" - and the difference matters, because
# treating unknown as absent silently costs a gapless Hub its gapless on nothing
# worse than a transient network blip. So the answer is CACHED AGAINST THE UDN
# once the device has actually told us (Simon's call, 2026-09-09): a later failed
# read under the same UDN reuses what it said before rather than degrading.
#
# The cache is keyed on the UDN, so it cannot leak between devices, and it is
# only ever WRITTEN from a successful read - a failure never poisons it.
#
# ITS REACH IS NARROW. The Hub's UDN changes at every reboot and CACHE_GEN at
# every build, so a list is found again only by the same build, for a Hub that
# has not rebooted since it was read - an LMS restart, or a move. A reboot LMS
# sees keeps the link's own list in memory (Plugin::_rekey, same address); an
# SCPD read that fails right after a reboot finds nothing here.
# BUMPED ON EVERY DEV BUILD. The remembered capability list is keyed by it, so a
# new build never reasons from what a previous build recorded - a stale entry
# would be indistinguishable from a fresh answer and would survive exactly the
# change that made it wrong.
use constant CACHE_GEN => 15;

sub cacheKeyFor {
    my ( $class, $udn ) = @_;
    return 'caps' . CACHE_GEN . '_' . ( $udn || 'unknown' );
}

sub _cacheKey { return __PACKAGE__->cacheKeyFor( $_[0]->{udn} ) }

# REMEMBERED ACTIONS FOLLOW THE HUB LIST (0.2.9). A list is keyed on a UDN, and
# the Hub's changes at every reboot: kept for good, one was left behind at every
# reboot and every build, and until 0.2.8 one was kept for every renderer
# described (read back 2026-11-01: the Sonos Arc, the WiiM and the television,
# under three builds). Every list goes but this build's for the UDNs given -
# Plugin::_remember gives the Hubs it knows.
sub keepRemembered {
    my ( $class, @udns ) = @_;

    my %keep = map { ( $class->cacheKeyFor($_) => 1 ) } grep { $_ } @udns;
    my @gone = grep { /^caps\d+_/ && !$keep{$_} } keys %{ $prefs->all };

    # In ONE call: LMS saves the namespace once per remove (Prefs::Base, 9.1).
    $prefs->remove(@gone) if @gone;

    return scalar @gone;
}

sub _fetchActions {
    my ( $self, $cb ) = @_;

    my $url = $self->{svc}{av} && $self->{svc}{av}{scpd};
    if ( !$url ) {
        $log->warn("$self->{name}: no AVTransport SCPD url");
        $self->_useCachedActions;
        $cb->() if $cb;
        return;
    }

    my $epoch = $self->{epoch};

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $body = shift->content || '';
            return if $epoch != $self->{epoch};

            my %seen;
            while ( $body =~ m{<action>\s*<name>\s*([^<\s]+)\s*</name>}gis ) {
                $seen{$1} = 1;
            }
            $self->{actions} = \%seen;
            $self->{cached}  = 0;

            # Only a SUCCESSFUL read writes the cache.
            $prefs->set( $self->_cacheKey, [ sort keys %seen ] ) if %seen;

            $log->info( sprintf
                '%s: AVTransport lists %d actions; gapless (SetNextAVTransportURI) %s',
                $self->{name}, scalar keys %seen,
                ( $seen{SetNextAVTransportURI} ? 'IS supported' : 'is NOT supported' ) );

            $cb->() if $cb;
        },
        sub {
            my ( $http, $err ) = @_;
            return if $epoch != $self->{epoch};
            $log->warn("$self->{name}: AVTransport SCPD fetch failed: $err");
            $self->_useCachedActions;
            $cb->() if $cb;
        },
        { timeout => DESCRIBE_TIMEOUT },
    )->get($url);

    return;
}

# Fall back to what this device told us on a previous run. Loud, because acting
# on a remembered fact is not the same as measuring one, and if the Hub's
# firmware ever changes its action list this is where a stale answer would come
# from.
sub _useCachedActions {
    my $self = shift;

    my $cached = $prefs->get( $self->_cacheKey );

    if ( !$cached || !@$cached ) {
        $log->warn( "$self->{name}: no remembered capabilities either - optional actions "
            . 'are treated as ABSENT, so tracks will not be handed over gaplessly' );
        return;
    }

    $self->{actions} = { map { $_ => 1 } @$cached };
    $self->{cached}  = 1;

    $log->warn( sprintf '%s: using REMEMBERED capabilities from a previous run (%d actions, gapless %s)',
        $self->{name}, scalar @$cached,
        ( $self->{actions}{SetNextAVTransportURI} ? 'supported' : 'not supported' ) );

    return;
}

# True when the action list came from the cache rather than from the device on
# this run - surfaced so a settings page or log can say so.
sub actionsAreRemembered { $_[0]->{cached} ? 1 : 0 }

# The Volume state variable's allowedValueRange, which is the authoritative
# range - GetVolume only says where it is now. Absent means fall back to the
# UPnP default of 0..100, which is what RenderingControl mandates anyway.
sub _fetchVolRange {
    my ( $self, $cb ) = @_;

    my $url = $self->{svc}{rc} && $self->{svc}{rc}{scpd};
    if ( !$url ) {
        $cb->() if $cb;
        return;
    }

    my $epoch = $self->{epoch};

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $body = shift->content || '';
            return if $epoch != $self->{epoch};

            while ( $body =~ m{<stateVariable[^>]*>(.*?)</stateVariable>}gis ) {
                my $el = $1;
                next unless $el =~ m{<name>\s*Volume\s*</name>}i;

                my ($min)  = $el =~ m{<minimum>\s*(-?\d+)\s*</minimum>}i;
                my ($max)  = $el =~ m{<maximum>\s*(-?\d+)\s*</maximum>}i;
                my ($step) = $el =~ m{<step>\s*(\d+)\s*</step>}i;

                if ( defined $min && defined $max && $max > $min ) {
                    $self->{vol} = { min => $min + 0, max => $max + 0, step => ( $step || 1 ) + 0 };
                    main::INFOLOG && $log->is_info && $log->info(
                        "$self->{name}: volume range $min..$max step " . ( $step || 1 ) );
                }
                last;
            }

            $cb->() if $cb;
        },
        sub {
            my ( $http, $err ) = @_;
            return if $epoch != $self->{epoch};
            main::DEBUGLOG && $log->is_debug && $log->debug("$self->{name}: RenderingControl SCPD fetch failed: $err");
            $cb->() if $cb;
        },
        { timeout => DESCRIBE_TIMEOUT },
    )->get($url);

    return;
}

# ConnectionManager's GetProtocolInfo: the device's own list of what it will
# accept. THIS IS WHAT THE PLAYER ADVERTISES TO LMS (Format::formatsFromSink):
# a format is offered only where the Hub names a decoder for it. The list
# carries 82 audio entries and NO audio/L16 or audio/L24, which is why raw pcm
# is never offered - the Hub could not tell its rate or depth.
#
# The list is also the only place the device says what it IS. Entries like
# audio/x-gst-av-mp3adufloat are GStreamer element names, and a GStreamer
# renderer picks its decoder by SNIFFING THE STREAM rather than by reading a
# Content-Type - which is why a headerless format would have been accepted
# (there is a wildcard in the list) and then silently failed to play.
#
# Measured here rather than asked of the user, and logged in full at info so the
# answer is in log.txt the first time the plugin runs. A device that does not
# answer leaves {sink} undef, which means UNKNOWN - the caller must then use its
# configured default rather than assume anything.
sub _fetchProtocolInfo {
    my ( $self, $cb ) = @_;

    if ( !$self->{svc}{cm} || !$self->{svc}{cm}{control} ) {
        main::INFOLOG && $log->is_info
            && $log->info("$self->{name}: no ConnectionManager - accepted formats unknown");
        $cb->() if $cb;
        return;
    }

    $self->_soap(
        'cm',
        'GetProtocolInfo',
        [],
        sub {
            my ( $res, $err ) = @_;

            if ( !$res || !defined $res->{Sink} ) {
                $log->warn("$self->{name}: GetProtocolInfo gave no Sink - accepted formats unknown");
                $cb->() if $cb;
                return;
            }

            my @sink = split /\s*,\s*/, $res->{Sink};
            $self->{sink} = \@sink;

            # The mime type is the third colon-separated field of a protocolInfo
            # entry: 'http-get:*:audio/L16:DLNA.ORG_PN=LPCM'.
            my %mime;
            for my $e (@sink) {
                my @f = split /:/, $e;
                $mime{ lc $f[2] } = 1 if defined $f[2] && $f[2] ne '*';
            }
            $self->{mime} = \%mime;

            main::INFOLOG && $log->is_info && $log->info( sprintf
                '%s: accepts %d protocolInfo entries; audio: %s',
                $self->{name}, scalar @sink,
                join( ' ', sort grep { m{^audio/} } keys %mime ) || '(none listed)' );

            $cb->() if $cb;
        }
    );

    return;
}

# The device's Sink list, or undef when it never told us. UNDEF MEANS UNKNOWN and
# must not be read as "accepts nothing".
sub sink { $_[0]->{sink} }

# True only when the device explicitly listed the mime type. Undef (unknown)
# answers undef, so a caller can distinguish "said no" from "never said".
sub acceptsMime {
    my ( $self, $mime ) = @_;

    return undef unless $self->{mime};

    return $self->{mime}{ lc $mime } ? 1 : 0;
}

# ---------------------------------------------------------------------------
# SOAP

# Callback shape is ($result_hashref, $err) - NOT ($body, $err) as the HQPlayer
# module used, and NOT ($attrs, $raw) as its Control::send used. Confusing those
# two shipped a bug there; one shape, documented here, for everything.
sub _soap {
    my ( $self, $slot, $action, $args, $cb, $timeout ) = @_;

    my $svc = $self->{svc}{$slot};

    if ( !$svc || !$svc->{control} ) {
        main::DEBUGLOG && $log->is_debug
            && $log->debug("$self->{name}: $action requested before the renderer was described");
        $cb->( undef, 'not ready' ) if $cb;
        return;
    }

    my $service = $svc->{type};

    my $body = '';
    for my $pair ( @{ $args || [] } ) {
        my ( $k, $v ) = @$pair;
        $body .= "<$k>" . escape($v) . "</$k>";
    }

    my $env =
        '<?xml version="1.0" encoding="utf-8"?>'
      . '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
      . ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
      . "<u:$action xmlns:u=\"$service\">$body</u:$action>"
      . '</s:Body></s:Envelope>';

    # THE ENVELOPE GOES ON THE WIRE AS OCTETS, NEVER AS CHARACTERS.
    #
    # This is what made every track with a non-ASCII title hang the player, and
    # it hung it SILENTLY. HTTP::Message croaks "content must be bytes" on a
    # string carrying a character above 255, and it croaks inside LMS's own async
    # read - which is nobody's callback, so our error handler never ran,
    # _loadFailed never fired, nothing was logged as a failure, and the controller
    # sat waiting for a renderer that had never been told anything.
    #
    # It hid for so long because only ONE call carries free text: every other
    # verb here (Play, Stop, GetVolume, GetTransportInfo) is pure ASCII and was
    # perfectly happy. Volume control working was not evidence that SOAP worked.
    #
    # escape() has already promoted every interpolated value to characters, so the
    # whole envelope is characters here and one encode is correct. Encoding a
    # string that was already octets would double-encode it, which is exactly why
    # the promotion happens there rather than being guessed at here.
    $env = Encode::encode( 'UTF-8', $env );

    my $epoch = $self->{epoch};

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $res = shift;
            return if $epoch != $self->{epoch};
            $self->{quiet} = 0;
            $cb->( _parseResponse( $res->content || '', $action ), undef ) if $cb;
        },
        sub {
            my ( $http, $err ) = @_;
            return if $epoch != $self->{epoch};

            # A UPnP fault is HTTP 500 with <errorCode> in the BODY. Whether
            # SimpleAsyncHTTP still exposes that body on an error status is NOT
            # yet verified against LMS 9.x, so read it defensively and fall back
            # to the transport error string. Do not build logic on the fault code
            # until a live run has shown one arriving here.
            my $fault = '';
            my $code;
            my $c = eval { $http->content };
            if ( defined $c && length $c ) {
                ($code) = $c =~ m{<errorCode>\s*(\d+)\s*</errorCode>}i;
                my ($desc) = $c =~ m{<errorDescription>\s*(.*?)\s*</errorDescription>}is;
                $fault = ' fault ' . $code . ( $desc ? " ($desc)" : '' ) if $code;
            }

            # 701 "Transition not available" and 715 "not playing" are ordinary
            # answers to a transport verb sent in a state that disallows it -
            # noise, not a fault worth a warning.
            my $benign = ( defined $code && ( $code == 701 || $code == 715 ) )
                      || ( $err && $err =~ /\b701\b/ );

            # ONE WARNING PER OUTAGE, not one per call (`A SILENT HUB FLOODS THE
            # LOG`, measured 2026-11-01: 78 lines in a 1m45s power cycle, three a
            # second while the Hub booted). A transport failure - no HTTP status,
            # no fault - is a Hub that did not answer at all: the first is warned,
            # the rest wait at debug until it answers anything, as Control's link
            # does. A status or a fault IS an answer, and is warned as before.
            my $silent = ( !$code && !$benign && !( $err && $err =~ /^\s*\d{3}\b/ ) ) ? 1 : 0;

            my $lvl  = ( $benign || ( $silent && $self->{quiet} ) ) ? 'debug' : 'warn';
            my $more = ( $silent && !$self->{quiet} ) ? ' - further failures are logged at debug until it answers' : '';

            $log->$lvl("$self->{name}: $action failed: $err$fault$more");

            $self->{quiet} = $silent;

            $cb->( undef, ( $code ? "upnp$code" : $err ) ) if $cb;
        },
        { timeout => $timeout || SOAP_TIMEOUT },
    )->post(
        $svc->{control},
        'Content-Type' => 'text/xml; charset="utf-8"',
        'SOAPACTION'   => "\"$service#$action\"",
        $env,
    );

    return;
}

# Pull the out-arguments of a SOAP response into a flat hash. Tag names are
# taken as-is apart from an optional namespace prefix; a renderer's response
# body is small and flat, so this is sufficient and avoids an XML dependency.
sub _parseResponse {
    my ( $body, $action ) = @_;

    my %out;

    my ($inner) = $body =~ m{<(?:\w+:)?${action}Response[^>]*>(.*?)</(?:\w+:)?${action}Response>}is;
    $inner = $body unless defined $inner;

    while ( $inner =~ m{<(?:\w+:)?([A-Za-z][\w.-]*)\s*>(.*?)</(?:\w+:)?\1>}gis ) {
        $out{$1} = _unescape($2);
    }

    return \%out;
}

# XML-escape, and NORMALISE TO CHARACTERS on the way past.
#
# Values arrive here from several places - LMS track titles, urls we built, plain
# ASCII literals - and Perl silently upgrades the whole concatenation the moment
# one character string joins it, corrupting any part that was octets. Promoting
# everything here means the envelope is uniformly characters by the time _soap
# encodes it once, instead of being a mixture nobody can encode correctly.
#
# THE PROMOTION IS TRIED, NOT ASSUMED. An unflagged string holding a single
# Latin-1 character ("caf\x{e9}") is byte-identical to one octet, so the flag
# alone cannot say which it is. Decoding STRICTLY and keeping the original when
# that fails resolves it correctly both ways: real UTF-8 octets decode, and a
# character string that merely looked like octets is left exactly as it was.
# Either outcome is safe to encode later, because a string that failed to decode
# holds nothing above 255 and so cannot trip HTTP::Message.
sub escape {
    my $s = shift;
    return '' unless defined $s;

    if ( !utf8::is_utf8($s) && $s =~ /[^\x00-\x7F]/ ) {
        my $decoded = eval { Encode::decode( 'UTF-8', $s, Encode::FB_CROAK() ) };
        $s = $decoded if defined $decoded;
    }

    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&apos;/g;
    return $s;
}

sub _unescape {
    my $s = shift;
    return '' unless defined $s;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g;
    $s =~ s/&apos;/'/g;
    $s =~ s/&#(\d+);/chr($1)/ge;
    $s =~ s/&amp;/&/g;    # last, so &amp;lt; does not become <
    return $s;
}

sub _av { my $self = shift; $self->_soap( 'av', @_ ) }
sub _rc { my $self = shift; $self->_soap( 'rc', @_ ) }

# ---------------------------------------------------------------------------
# AVTransport

sub setURI {
    my ( $self, $uri, $didl, $cb ) = @_;
    return $self->_av( 'SetAVTransportURI',
        [ [ InstanceID => 0 ], [ CurrentURI => $uri ], [ CurrentURIMetaData => $didl || '' ] ], $cb );
}

# Gapless. NEVER call without checking canGapless first - an unsupported action
# answers 401 and, worse, some renderers stop the current track when they refuse.
sub setNextURI {
    my ( $self, $uri, $didl, $cb ) = @_;

    if ( !$self->canGapless ) {
        main::DEBUGLOG && $log->is_debug
            && $log->debug("$self->{name}: setNextURI refused locally - the device does not list the action");
        $cb->( undef, 'unsupported' ) if $cb;
        return;
    }

    return $self->_av( 'SetNextAVTransportURI',
        [ [ InstanceID => 0 ], [ NextURI => $uri ], [ NextURIMetaData => $didl || '' ] ], $cb );
}

sub play {
    my ( $self, $cb ) = @_;
    return $self->_av( 'Play', [ [ InstanceID => 0 ], [ Speed => 1 ] ], $cb );
}

sub pause {
    my ( $self, $cb ) = @_;
    return $self->_av( 'Pause', [ [ InstanceID => 0 ] ], $cb );
}

sub stop {
    my ( $self, $cb ) = @_;
    return $self->_av( 'Stop', [ [ InstanceID => 0 ] ], $cb );
}

sub seek {
    my ( $self, $secs, $cb ) = @_;
    my $t = sprintf( '%d:%02d:%02d', int( $secs / 3600 ), int( $secs / 60 ) % 60, int($secs) % 60 );
    return $self->_av( 'Seek', [ [ InstanceID => 0 ], [ Unit => 'REL_TIME' ], [ Target => $t ] ], $cb );
}

# Answers { CurrentTransportState => PLAYING|PAUSED_PLAYBACK|STOPPED|TRANSITIONING|NO_MEDIA_PRESENT, ... }
sub transportInfo {
    my ( $self, $cb ) = @_;
    return $self->_av( 'GetTransportInfo', [ [ InstanceID => 0 ] ], $cb );
}

# Answers { RelTime => 'H:MM:SS', TrackDuration => 'H:MM:SS', TrackURI => ... }
sub positionInfo {
    my ( $self, $cb ) = @_;
    return $self->_av( 'GetPositionInfo', [ [ InstanceID => 0 ] ], $cb );
}

# ---------------------------------------------------------------------------
# RenderingControl

sub getVolume {
    my ( $self, $cb ) = @_;
    return $self->_rc( 'GetVolume', [ [ InstanceID => 0 ], [ Channel => 'Master' ] ], $cb );
}

sub setVolume {
    my ( $self, $vol, $cb ) = @_;

    my $r   = $self->{vol} || { min => 0, max => 100 };
    my $v   = int( $vol + 0.5 );
    $v = $r->{min} if $v < $r->{min};
    $v = $r->{max} if $v > $r->{max};

    return $self->_rc( 'SetVolume',
        [ [ InstanceID => 0 ], [ Channel => 'Master' ], [ DesiredVolume => $v ] ], $cb );
}

sub getMute {
    my ( $self, $cb ) = @_;
    return $self->_rc( 'GetMute', [ [ InstanceID => 0 ], [ Channel => 'Master' ] ], $cb );
}

sub setMute {
    my ( $self, $on, $cb ) = @_;
    return $self->_rc( 'SetMute',
        [ [ InstanceID => 0 ], [ Channel => 'Master' ], [ DesiredMute => ( $on ? 1 : 0 ) ] ], $cb );
}

# ---------------------------------------------------------------------------
# Helpers shared with the player

# 'H:MM:SS' or 'H:MM:SS.mmm' -> seconds. Returns undef for the placeholders a
# renderer uses when it has nothing to report ('NOT_IMPLEMENTED', '0:00:00' is a
# real zero and must NOT be folded into undef).
sub timeToSecs {
    my $t = shift;

    return undef unless defined $t && $t =~ /^(\d+):([0-5]?\d):([0-5]?\d)(?:\.(\d+))?$/;

    return $1 * 3600 + $2 * 60 + $3;
}

1;
