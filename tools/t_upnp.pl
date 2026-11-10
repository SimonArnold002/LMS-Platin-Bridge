#!/usr/bin/perl
#
# Unit tests for Plugins::PlatinBridge::UPnP - the description handshake, URL
# resolution, capability discovery and SOAP framing.
#
# Every one of these guards a failure the HQPlayer bridge's deleted UPnP.pm
# actually had, or could not detect:
#   * control URLs assumed root-relative on a known host
#   * the service VERSION hardcoded to :3 while matching the device loosely
#   * eventSubURL never captured
#   * optional actions assumed present
#   * a SOAP fault unreadable, so retried blind on a substring match
#
# `ok` TAKES THE ASSERTION NAME OFF THE END: a failed match evaluated in list
# context returns the EMPTY list, so a name-last `ok` cannot be fooled into
# reading the label as the condition.

use strict;
use warnings;
use lib '.';

BEGIN {
    package main;
    use constant DEBUGLOG => 0;
    use constant INFOLOG  => 0;
    use constant WEBUI    => 1;
}

use Encode ();

require Plugins::PlatinBridge::UPnP;

my $CLASS = 'Plugins::PlatinBridge::UPnP';
my $HTTP  = 'Slim::Networking::SimpleAsyncHTTP';
my $prefs = Slim::Utils::Prefs::preferences('plugin.platinbridge');

# timeToSecs and escape are plain FUNCTIONS, not methods. Invoked with arrow
# syntax on the class they silently return the CLASS NAME instead of erroring -
# a failure that looks like a pass - hence these explicit function aliases.
my $timeToSecs = \&Plugins::PlatinBridge::UPnP::timeToSecs;
my $escape     = \&Plugins::PlatinBridge::UPnP::escape;

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

# A MediaRenderer:1 description in the shape a real device publishes: mixed
# absolute / root-relative / bare-relative URLs, and NO <URLBase>.
sub description {
    my %o = @_;
    my $urlbase = $o{urlbase} ? "<URLBase>$o{urlbase}</URLBase>" : '';
    my $maker   = defined $o{maker} ? $o{maker} : 'Platin Audio';
    my $model   = defined $o{model} ? $o{model} : 'Stereo Hub HT';
    return <<"XML";
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  $urlbase
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Platin Stereo Hub HT</friendlyName>
    <manufacturer>$maker</manufacturer>
    <modelName>$model</modelName>
    <UDN>uuid:5f9ec1b3-ed59-79ee-4530-0005cdaabbcc</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/upnp/control/AVTransport1</controlURL>
        <eventSubURL>/upnp/event/AVTransport1</eventSubURL>
        <SCPDURL>AVTransport1.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>http://10.0.0.9:49494/upnp/control/RenderingControl1</controlURL>
        <eventSubURL>/upnp/event/RenderingControl1</eventSubURL>
        <SCPDURL>/RenderingControl1.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/upnp/control/ConnectionManager1</controlURL>
        <eventSubURL></eventSubURL>
        <SCPDURL>/ConnectionManager1.xml</SCPDURL>
      </service>
    </serviceList>
  </device>
</root>
XML
}

sub avscpd {
    my $extra = shift || '';
    return <<"XML";
<?xml version="1.0"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <actionList>
    <action><name>SetAVTransportURI</name></action>
    <action><name>GetTransportInfo</name></action>
    <action><name>GetPositionInfo</name></action>
    <action><name>Play</name></action>
    <action><name>Pause</name></action>
    <action><name>Stop</name></action>
    <action><name>Seek</name></action>
    $extra
  </actionList>
</scpd>
XML
}

sub rcscpd {
    my ( $min, $max, $step ) = @_;
    my $range = defined $min
        ? "<allowedValueRange><minimum>$min</minimum><maximum>$max</maximum><step>$step</step></allowedValueRange>"
        : '';
    return <<"XML";
<?xml version="1.0"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <serviceStateTable>
    <stateVariable sendEvents="yes"><name>LastChange</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>Volume</name><dataType>ui2</dataType>$range</stateVariable>
  </serviceStateTable>
</scpd>
XML
}

sub protoinfo {
    my $sink = shift;
    $sink = 'http-get:*:audio/L16:DLNA.ORG_PN=LPCM,http-get:*:audio/mpeg:*,http-get:*:audio/x-flac:*'
        unless defined $sink;
    return <<"XML";
<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
<u:GetProtocolInfoResponse xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">
<Source></Source><Sink>$sink</Sink>
</u:GetProtocolInfoResponse></s:Body></s:Envelope>
XML
}

# Drive a full describe: description, the two SCPD fetches and GetProtocolInfo.
sub described {
    my %o = @_;
    $HTTP->_reset;
    Slim::Utils::Timers::_reset();

    my $u = $CLASS->new(
        location => 'http://10.0.0.9:49152/description.xml',
        ( $o{udn}   ? ( udn   => $o{udn} ) : () ),
        ( $o{probe} ? ( probe => 1 )       : () ),
    );
    my $done;
    $u->describe( sub { $done = shift } );

    $HTTP->_respond( description( urlbase => $o{urlbase}, maker => $o{maker}, model => $o{model} ) );

    # NOT A PLATIN HUB: its description is all that is asked (0.2.9).
    return ( $u, $done ) if $HTTP->_count == 1;

    if ( $o{no_av_scpd} ) { $HTTP->_failed('500 error') }
    else { $HTTP->_respond( avscpd( $o{gapless} ? '<action><name>SetNextAVTransportURI</name></action>' : '' ) ) }

    if ( $o{no_rc_scpd} ) { $HTTP->_failed('500 error') }
    else { $HTTP->_respond( rcscpd( $o{volmin}, $o{volmax}, $o{volstep} ) ) }

    if    ( $o{no_protoinfo} ) { $HTTP->_failed('Connection refused') }
    elsif ( $o{sink} )         { $HTTP->_respond( protoinfo( $o{sink} ) ) }
    else                       { $HTTP->_respond( protoinfo() ) }

    return ( $u, $done );
}

# A description naming no AVTransport: a Sonos sub or bonded speaker - or a Hub
# still starting.
sub bare {
    my %o = @_;
    return "<root><device><friendlyName>$o{name}</friendlyName><manufacturer>$o{maker}</manufacturer>"
         . "<modelName>$o{model}</modelName></device></root>";
}

# ---------------------------------------------------------------------------
print "-- is it the Hub: adopted by what the device says it is --\n";

# The UDN is NOT stable - a factory reset mints a new one, and Simon's Hub has had
# two - so the plugin adopts a renderer by its own description instead. The
# strings below are the ones the real Hub published on 2026-10-25.
{
    my ($u) = described( maker => 'Platin', model => 'Stereo Hub HT' );
    is( $u->maker, 'Platin', 'the manufacturer is read off the description' );
    is( $u->model, 'Stereo Hub HT', 'and the model' );
    is( $u->isPlatinHub, 1, 'the real Hub\'s own strings are recognised' );
}

{
    my ($u) = described();
    is( $u->isPlatinHub, 1, 'and "Platin Audio" reads as Platin too' );
}

{
    # CONTROLS: the renderers that share this network must NOT be adopted, or
    # the plugin would make a player for the Eversolo or HQPlayer.
    my ($e) = described( maker => 'Eversolo', model => 'DMP-A8' );
    is( $e->isPlatinHub, 0, 'the Eversolo is not taken for the Hub' );

    my ($h) = described( maker => 'Signalyst', model => 'HQPlayer Embedded' );
    is( $h->isPlatinHub, 0, 'nor is HQPlayer\'s own renderer' );

    my ($p) = described( maker => 'Platin', model => 'Monaco Speaker' );
    is( $p->isPlatinHub, 0, 'nor a Platin product that is not a Hub' );

    my ($n) = described( maker => '', model => '' );
    is( $n->isPlatinHub, 0, 'and a device that names neither is not adopted' );
}

# ---------------------------------------------------------------------------
print "-- ONLY A HUB IS DESCRIBED IN FULL (0.2.9) --\n";

# A search can only name a device TYPE, so every renderer on the network answers
# and has its description read. Until 0.2.8 the brand was checked after the whole
# describe: the Sonos Arc, the WiiM and the television were sent four requests
# each per LMS run and had their action lists kept (read back 2026-11-01), and the
# speakers with no AVTransport were each warned about.
{
    no warnings 'redefine';
    my @W;
    local *Slim::Utils::Log::Obj::warn = sub { push @W, $_[1]; return };

    my $arc = 'uuid:RINCON_48A6B805B63501400_MR';
    my ( $u, $done ) = described( maker => 'Sonos, Inc.', model => 'Sonos Arc', udn => $arc, probe => 1 );
    is( $done, 0, 'a renderer that is not a Platin Hub is reported as not one to drive' );
    is( $HTTP->_count, 1, 'after ONE request, its description - no SCPD, no GetProtocolInfo' );
    is( $u->fetched, 1, 'the description was read' );
    is( $u->isReady, 0, 'it is not made ready' );
    is( Slim::Utils::Timers::_pending(), 0, 'nor asked again' );
    is( $prefs->get( $CLASS->cacheKeyFor($arc) ), undef, 'and no action list of it is kept' );

    $HTTP->_reset;
    Slim::Utils::Timers::_reset();
    my $sub = $CLASS->new( location => 'http://10.0.0.97:1400/xml/device_description.xml', probe => 1 );
    my $subDone = 'unset';
    $sub->describe( sub { $subDone = shift } );
    $HTTP->_respond( bare( name => 'Sub', maker => 'Sonos, Inc.', model => 'Sonos Sub Mini' ) );
    is( $subDone, 0, 'one with no AVTransport (a Sonos sub) is reported the same' );
    is( Slim::Utils::Timers::_pending(), 0, 'and not asked again' );
    is( scalar @W, 0, 'and neither is warned about' );

    # CONTROL: the Hub's own strings take the whole describe, warned or not.
    my $hub = 'uuid:control-hub-described-in-full';
    my ( $h, $hdone ) = described( maker => 'Platin', model => 'Stereo Hub HT', udn => $hub, probe => 1 );
    is( $hdone, 1, 'control: a Platin Hub is described' );
    is( $HTTP->_count, 4, 'in full - its description, two SCPDs and GetProtocolInfo' );
    ok( $prefs->get( $CLASS->cacheKeyFor($hub) ), 'and its action list is kept' );

    $HTTP->_reset;
    Slim::Utils::Timers::_reset();
    my $boot = $CLASS->new( location => 'http://10.0.0.9:49152/description.xml', probe => 1 );
    $boot->describe( sub { } );
    $HTTP->_respond( bare( name => 'Lounge', maker => 'Platin', model => 'Stereo Hub HT' ) );
    is( scalar grep( { /not a renderer we can drive/ } @W ), 1,
        'control: a Platin Hub with no AVTransport yet IS warned about' );
}

# ---------------------------------------------------------------------------
print "-- the brand gate is for a probe only (0.2.10) --\n";

# A link the plugin holds - a Hub adopted by its UDN, described again after a
# move - is not re-judged on its brand: 0.2.9 called it back 0 with no retry,
# and the moved Hub's player kept its closed link until LMS restarted.
{
    my ( $u, $done ) = described( maker => 'gmrender-resurrect', model => 'GMediaRender' );
    is( $done, 1, 'a link (not a probe) whose description names no brand is described' );
    is( $HTTP->_count, 4, 'in full, as before 0.2.9' );
    is( $u->isReady, 1, 'and made ready' );
}

# A probe is known by its UDN until its description names it: a "Platin Hub:"
# warning for a Sonos that will not serve its description points at the wrong
# device.
{
    no warnings 'redefine';
    my @W;
    local *Slim::Utils::Log::Obj::warn = sub { push @W, $_[1]; return };

    my $udn = 'uuid:probe-name-0000-4000-8000-000000000001';

    $HTTP->_reset;
    Slim::Utils::Timers::_reset();
    my $p = $CLASS->new( location => 'http://10.0.0.61:1400/xml/device_description.xml', udn => $udn, probe => 1 );
    $p->describe( sub { } );
    $HTTP->_failed('Timed out');
    is( scalar grep( { /^\Q$udn\E: description fetch failed at http:\/\/10\.0\.0\.61:/ } @W ), 1,
        'a probe whose description does not come is warned about by its UDN' );
    is( scalar grep( { /Platin Hub/ } @W ), 0, 'not as a Platin Hub' );
    $p->close;

    $HTTP->_reset;
    Slim::Utils::Timers::_reset();
    my $n = $CLASS->new( location => 'http://10.0.0.62:1400/xml/device_description.xml', udn => $udn, probe => 1 );
    $n->describe( sub { } );
    $HTTP->_respond( bare( name => '', maker => 'Acme', model => 'Speaker' ) );
    is( $n->name, $udn, 'a non-Hub that names itself nothing keeps its UDN for a name' );

    $HTTP->_reset;
    Slim::Utils::Timers::_reset();
    my $h = $CLASS->new( location => 'http://10.0.0.63:49152/description.xml', udn => $udn, probe => 1 );
    $h->describe( sub { } );
    $HTTP->_respond( bare( name => '', maker => 'Platin', model => 'Stereo Hub HT' ) );
    is( $h->name, 'Platin Hub', 'a Platin Hub that names itself nothing is "Platin Hub", not its UDN' );
    $h->close;

    my $l = $CLASS->new( location => 'http://10.0.0.64:49152/description.xml', udn => $udn );
    is( $l->name, 'Platin Hub', 'control: a link is "Platin Hub" until described, as before' );
}

# ---------------------------------------------------------------------------
print "-- description parsing --\n";

{
    my ( $u, $done ) = described( gapless => 1, volmin => 0, volmax => 100, volstep => 1 );

    is( $done, 1, 'describe reports success' );
    is( $u->isReady, 1, 'and marks itself ready' );
    is( $u->name, 'Platin Stereo Hub HT', 'friendlyName is adopted as the player name' );
    is( $u->udn, 'uuid:5f9ec1b3-ed59-79ee-4530-0005cdaabbcc',
        'the UDN is captured - the only stable identity, unlike name or IP' );

    is( $u->{svc}{av}{type}, 'urn:schemas-upnp-org:service:AVTransport:1',
        'the version the DEVICE stated is kept, not a hardcoded one' );
    is( $u->{svc}{av}{control}, 'http://10.0.0.9:49152/upnp/control/AVTransport1',
        'a root-relative controlURL resolves against the description host AND PORT' );
    is( $u->{svc}{rc}{control}, 'http://10.0.0.9:49494/upnp/control/RenderingControl1',
        'an absolute controlURL on a DIFFERENT port is left alone' );
    is( $u->{svc}{av}{scpd}, 'http://10.0.0.9:49152/AVTransport1.xml',
        'a bare-relative SCPDURL gets a slash inserted, not concatenated blind' );
    is( $u->{svc}{av}{event}, 'http://10.0.0.9:49152/upnp/event/AVTransport1',
        'eventSubURL is captured, so GENA is possible later' );
    is( $u->{svc}{cm}{control}, 'http://10.0.0.9:49152/upnp/control/ConnectionManager1',
        'ConnectionManager is captured too, for GetProtocolInfo' );
    is( $u->{svc}{cm}{event}, undef, 'an EMPTY eventSubURL is undef, not the base url' );
}

{
    # A description is trusted only for its own host: a service url or URLBase on
    # another host would send the SOAP bodies there.
    my ( $u ) = described( urlbase => 'http://10.0.0.66:8080/', gapless => 1 );
    is( $u->{base}, 'http://10.0.0.9:49152', 'a URLBase on another host is ignored' );
    is( $u->{svc}{av}{control}, 'http://10.0.0.9:49152/upnp/control/AVTransport1',
        'so the service urls stay on the description host' );
    is( $u->_absolute('http://10.0.0.66/x'), undef, 'an absolute url on another host is dropped' );
    is( $u->_absolute('http://10.0.0.9@10.0.0.66/x'), undef, 'userinfo does not disguise another host' );
    is( $u->_absolute('http://10.0.0.9:1234/x'), 'http://10.0.0.9:1234/x', 'a different port on the same host is kept' );
}

{
    # A <URLBase> must win over the location url - devices populate one or the
    # other and a bridge that only ever reads the location gets it wrong.
    my ( $u ) = described( urlbase => 'http://10.0.0.9:8080/', gapless => 1 );
    is( $u->{svc}{av}{control}, 'http://10.0.0.9:8080/upnp/control/AVTransport1',
        'URLBase overrides the description url when present' );
}

{
    # Cross-pairing check: RenderingControl's control URL must not be attached to
    # AVTransport. A global (unscoped) regex over the whole document does exactly
    # that, and it is the bug the scoped <service> match exists to prevent.
    my ( $u ) = described( gapless => 1 );
    ok( $u->{svc}{av}{control} ne $u->{svc}{rc}{control},
        'each service keeps its OWN control url - no cross-pairing' );
}

# ---------------------------------------------------------------------------
print "-- capability discovery: the gapless decision --\n";

{
    my ( $u ) = described( gapless => 1 );
    is( $u->canGapless, 1, 'SetNextAVTransportURI listed by the device means gapless is available' );
    is( $u->can_action('Seek'), 1, 'a listed action reads as present' );
    is( $u->can_action('Record'), 0, 'an UNLISTED action reads as absent, not unknown-so-assume-yes' );
}

{
    my ( $u ) = described( gapless => 0 );
    is( $u->canGapless, 0, 'a device that does not list it is not gapless' );
    is( $u->can_action('Play'), 1, 'while the mandatory actions are still seen' );
}

{
    # An unreadable SCPD, for a device NEVER SEEN BEFORE, must leave us knowing
    # nothing - never optimistic. A distinct UDN, so no remembered answer exists.
    my ( $u ) = described( no_av_scpd => 1, udn => 'uuid:never-seen-before' );
    is( $u->canGapless, 0, 'an unreadable SCPD on an unknown device treats actions as ABSENT' );
    is( $u->can_action('Play'), 0, 'and nothing at all is assumed, not even the mandatory actions' );
    is( $u->isReady, 1, 'but the renderer is still ready - a missing SCPD does not stop playback' );
    is( $u->actionsAreRemembered, 0, 'and nothing is claimed to be remembered' );
}

# THE CACHE (Simon's call, 2026-09-09). Treating "unknown" as "absent" silently
# downgrades a gapless Hub to Flow on nothing worse than a transient blip, so a
# successful read is remembered against the UDN and reused when a later one fails.
{
    my $udn = 'uuid:remembers-me';

    my ( $first ) = described( gapless => 1, udn => $udn );
    is( $first->canGapless, 1, 'the device is read successfully once' );
    is( $first->actionsAreRemembered, 0, 'from the device itself, not from memory' );

    my ( $second ) = described( no_av_scpd => 1, udn => $udn );
    is( $second->canGapless, 1,
        'a later FAILED read reuses what this device said before, rather than losing gapless' );
    is( $second->actionsAreRemembered, 1, 'and says so, because acting on a remembered fact is not measuring one' );
}

{
    # The cache is keyed on the UDN, so one device's capabilities can never be
    # attributed to another.
    my ( $other ) = described( no_av_scpd => 1, udn => 'uuid:a-different-device' );
    is( $other->canGapless, 0, 'a different UDN gets no benefit from another device\'s remembered answer' );
}

{
    # A failure must never POISON the cache: a device that once answered keeps
    # its remembered answer even after several failed reads.
    my $udn = 'uuid:stays-remembered';
    described( gapless => 1, udn => $udn );
    described( no_av_scpd => 1, udn => $udn );
    my ( $third ) = described( no_av_scpd => 1, udn => $udn );
    is( $third->canGapless, 1, 'repeated failures do not erase what the device once said' );
}

# setNextURI must refuse LOCALLY when the action is absent. Sending it anyway is
# not merely useless: some renderers stop the playing track when they refuse.
{
    my ( $u ) = described( gapless => 0 );
    $HTTP->_reset;
    my ( $res, $err );
    $u->setNextURI( 'http://x/y.lpcm', '', sub { ( $res, $err ) = @_ } );
    is( $HTTP->_count, 0, 'setNextURI on a non-gapless device sends NOTHING over the wire' );
    is( $err, 'unsupported', 'and reports why' );
}

{
    my ( $u ) = described( gapless => 1 );
    $HTTP->_reset;
    $u->setNextURI( 'http://x/y.lpcm', '<DIDL/>', sub { } );
    is( $HTTP->_count, 1, 'setNextURI on a gapless device does send' );
    my $r = $HTTP->_last;
    is( $r->{headers}{SOAPACTION},
        '"urn:schemas-upnp-org:service:AVTransport:1#SetNextAVTransportURI"',
        'and the SOAPACTION carries the version the device stated, not :3' );
}

# ---------------------------------------------------------------------------
print "-- volume range --\n";

{
    my ( $u ) = described( volmin => 0, volmax => 100, volstep => 1 );
    is( $u->volRange->{min}, 0,   'volume minimum read from the SCPD' );
    is( $u->volRange->{max}, 100, 'volume maximum read from the SCPD' );
    is( $u->volRange->{step}, 1,  'volume step read from the SCPD' );
}

{
    my ( $u ) = described( volmin => 0, volmax => 32, volstep => 2 );
    is( $u->volRange->{max}, 32, 'a non-standard range is honoured rather than assumed 0..100' );

    $HTTP->_reset;
    $u->setVolume( 99, sub { } );
    my $body = $HTTP->_last->{body};
    ok( $body =~ m{<DesiredVolume>32</DesiredVolume>},
        'setVolume clamps to the device maximum instead of sending 99' );

    $HTTP->_reset;
    $u->setVolume( -5, sub { } );
    ok( $HTTP->_last->{body} =~ m{<DesiredVolume>0</DesiredVolume>},
        'and clamps at the bottom' );
}

{
    my ( $u ) = described( no_rc_scpd => 1 );
    is( $u->volRange, undef, 'an unreadable RenderingControl SCPD leaves the range unknown' );
    $HTTP->_reset;
    $u->setVolume( 150, sub { } );
    ok( $HTTP->_last->{body} =~ m{<DesiredVolume>100</DesiredVolume>},
        'and setVolume falls back to the UPnP-mandated 0..100' );
}

# ---------------------------------------------------------------------------
print "-- accepted formats (decides the wire format) --\n";

{
    my ( $u ) = described( gapless => 1 );
    is( $u->acceptsMime('audio/L16'), 1, 'a listed mime type reads as accepted' );
    is( $u->acceptsMime('audio/l16'), 1, 'and the match is case-insensitive' );
    is( $u->acceptsMime('audio/L24'), 0, 'an UNLISTED mime type reads as not accepted' );
    is( scalar @{ $u->sink }, 3, 'the whole Sink list is kept for the log and the settings page' );
}

{
    my ( $u ) = described( gapless => 1,
        sink => 'http-get:*:audio/L24:DLNA.ORG_PN=LPCM,http-get:*:audio/L16:*' );
    is( $u->acceptsMime('audio/L24'), 1, 'a Hub advertising L24 is detected' );
}

{
    # UNKNOWN must be distinguishable from "said no". A device that never answered
    # is not a device that refused, and the caller has to tell them apart to pick
    # a default rather than conclude the Hub accepts nothing.
    my ( $u ) = described( gapless => 1, no_protoinfo => 1 );
    is( $u->sink, undef, 'a failed GetProtocolInfo leaves the sink list unknown' );
    is( $u->acceptsMime('audio/L16'), undef,
        'and acceptsMime answers undef (unknown), NOT 0 (refused)' );
    is( $u->isReady, 1, 'while the renderer is still ready - formats are advisory' );
}

# ---------------------------------------------------------------------------
print "-- the envelope goes on the wire as OCTETS --\n";

# THE BUG THIS SECTION EXISTS FOR (0.1.4, found on hardware). HTTP::Message
# croaks "content must be bytes" the moment the content carries a character
# above 255, and it croaks INSIDE LMS's own async read - which is nobody's
# callback. So the error handler never ran, _loadFailed never fired, nothing was
# logged as a failure, and the player simply hung waiting for a renderer that had
# never been told anything.
#
# It survived every earlier test because only ONE call carries free text.
# Play, Stop, GetVolume and GetTransportInfo are pure ASCII and were always fine,
# so volume control working was not evidence that SOAP worked.

{
    my ( $u ) = described( gapless => 1 );
    $HTTP->_reset;

    # An en dash is U+2013, comfortably above 255. The o-umlaut is only 246 and
    # would NOT have triggered it, which is why an accented title alone might
    # have played and hidden this for longer.
    my $title = "Bj\x{f6}rk \x{2013} Vespert\x{ed}ne";

    # CONTROL ASSERTION. Without it this whole section could pass against a fix
    # that does nothing, simply because the input was ASCII all along.
    ok( $title =~ /[^\x00-\xFF]/,
        'the test title really does carry a character above 255' );

    my $didl = '<DIDL-Lite><dc:title>'
             . Plugins::PlatinBridge::UPnP::escape($title)
             . '</dc:title></DIDL-Lite>';

    $u->setURI( 'http://lms:9000/platin/abc/1.wav', $didl, sub { } );

    my $body = $HTTP->_last->{body};

    ok( defined $body && length $body, 'the request was sent' );

    # THIS IS HTTP::Message's ACTUAL RULE, restated. Anything that fails here
    # would have croaked on the real server.
    ok( $body !~ /[^\x00-\xFF]/,
        'nothing in the envelope is above 255 - this is the exact test HTTP::Message applies' );

    ok( !utf8::is_utf8($body),
        'and the string is not flagged as characters' );

    # ENCODED, NOT STRIPPED. A fix that mangled the title into question marks
    # would satisfy every assertion above and be worse than useless.
    my $back = Encode::decode( 'UTF-8', $body );
    ok( $back =~ /Bj\x{f6}rk/,        'the title survives as valid UTF-8' );
    ok( $back =~ /\x{2013}/,          'including the character that caused the croak' );
    ok( $back =~ /Vespert\x{ed}ne/,   'and the rest of it' );
}

{
    # THE PATH THAT ALWAYS WORKED MUST KEEP WORKING. Encoding an ASCII envelope
    # must leave it byte-identical, or the fix for one call breaks every other.
    my ( $u ) = described( gapless => 1 );
    $HTTP->_reset;
    $u->setVolume( 42, sub { } );

    my $body = $HTTP->_last->{body};
    ok( $body =~ m{<DesiredVolume>42</DesiredVolume>}, 'an ASCII call is unchanged' );
    ok( $body !~ /[^\x00-\x7F]/, 'and stays pure ASCII - nothing was double-encoded' );
}

{
    # escape() NORMALISES TO CHARACTERS, which is what lets _soap encode the
    # whole envelope exactly once. Perl upgrades a concatenation as soon as one
    # character string joins it, so a value that arrived as octets would be
    # corrupted by the strings around it unless it is promoted here first.
    my $chars  = "caf\x{e9}";
    my $octets = Encode::encode( 'UTF-8', $chars );

    ok( !utf8::is_utf8($octets), 'the fixture really is octets to begin with' );

    my $e = Plugins::PlatinBridge::UPnP::escape($octets);

    is( $e, $chars, 'octets in, characters out - the same text either way' );
    is( Plugins::PlatinBridge::UPnP::escape($chars), $chars, 'and characters pass through unharmed' );

    # THE AMBIGUOUS CASE, and the reason the promotion is tried rather than
    # assumed. "caf\x{e9}" written without `use utf8` is ONE unflagged byte, so
    # it is indistinguishable from a single octet by the flag alone - and it is
    # not valid UTF-8, so a strict decode rejects it and the original stands.
    my $latin1 = "caf\x{e9}";
    ok( !utf8::is_utf8($latin1), 'the fixture is unflagged, exactly like octets' );
    is( Plugins::PlatinBridge::UPnP::escape($latin1), $latin1,
        'a string that is not valid UTF-8 is left alone rather than mangled' );
}

{
    # Escaping still does its original job on text that also needs encoding.
    my $e = Plugins::PlatinBridge::UPnP::escape("AT&T \x{2013} <b>");
    ok( $e =~ /&amp;/,     'ampersands are still escaped' );
    ok( $e =~ /&lt;b&gt;/, 'and angle brackets' );
    ok( $e =~ /\x{2013}/,  'while the wide character is left as a character' );
}

# ---------------------------------------------------------------------------
print "-- SOAP framing --\n";

{
    my ( $u ) = described( gapless => 1 );
    $HTTP->_reset;
    $u->setURI( 'http://lms:9000/platin/abc/1.lpcm', '<DIDL-Lite>x</DIDL-Lite>', sub { } );

    my $r = $HTTP->_last;
    is( $r->{method}, 'POST', 'a SOAP action is a POST' );
    is( $r->{url}, 'http://10.0.0.9:49152/upnp/control/AVTransport1', 'sent to the AVTransport control url' );
    is( $r->{headers}{'Content-Type'}, 'text/xml; charset="utf-8"', 'with the SOAP content type' );
    ok( $r->{body} =~ m{<u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">},
        'the u: namespace matches the stated service version' );
    ok( $r->{body} =~ m{<InstanceID>0</InstanceID>}, 'InstanceID 0 is sent' );
    ok( $r->{body} =~ m{<CurrentURI>http://lms:9000/platin/abc/1\.lpcm</CurrentURI>}, 'the uri is sent' );
    ok( $r->{body} =~ m{<CurrentURIMetaData>&lt;DIDL-Lite&gt;x&lt;/DIDL-Lite&gt;</CurrentURIMetaData>},
        'the DIDL is ESCAPED into the metadata argument - it is a string, not markup' );
}

{
    my ( $u ) = described( gapless => 1 );
    $HTTP->_reset;
    $u->seek( 3661, sub { } );
    ok( $HTTP->_last->{body} =~ m{<Target>1:01:01</Target>}, 'Seek formats H:MM:SS' );
    ok( $HTTP->_last->{body} =~ m{<Unit>REL_TIME</Unit>},    'and asks for REL_TIME' );
}

# Argument order must survive: a hash would reorder these and some renderers are
# strict about argument sequence.
{
    my ( $u ) = described( gapless => 1 );
    $HTTP->_reset;
    $u->setURI( 'U', 'M', sub { } );
    my $b = $HTTP->_last->{body};
    my $i = index( $b, '<InstanceID>' );
    my $c = index( $b, '<CurrentURI>' );
    my $m = index( $b, '<CurrentURIMetaData>' );
    ok( $i < $c && $c < $m, 'SOAP arguments are sent in the order the spec declares them' );
}

# ---------------------------------------------------------------------------
print "-- response parsing --\n";

{
    my ( $u ) = described( gapless => 1 );
    $HTTP->_reset;
    my $got;
    $u->transportInfo( sub { $got = shift } );
    $HTTP->_respond( <<'XML' );
<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
 <s:Body>
  <u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
   <CurrentTransportState>PLAYING</CurrentTransportState>
   <CurrentTransportStatus>OK</CurrentTransportStatus>
   <CurrentSpeed>1</CurrentSpeed>
  </u:GetTransportInfoResponse>
 </s:Body>
</s:Envelope>
XML
    is( $got->{CurrentTransportState},  'PLAYING', 'a namespaced response body is parsed' );
    is( $got->{CurrentTransportStatus}, 'OK',      'all out-arguments come back' );
}

{
    my ( $u ) = described( gapless => 1 );
    $HTTP->_reset;
    my $got;
    $u->positionInfo( sub { $got = shift } );
    $HTTP->_respond( <<'XML' );
<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
<u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<Track>1</Track><TrackDuration>0:04:33</TrackDuration><RelTime>0:01:07</RelTime>
<TrackURI>http://lms:9000/platin/abc/1.lpcm</TrackURI>
<TrackMetaData>&lt;DIDL-Lite&gt;&amp;amp;&lt;/DIDL-Lite&gt;</TrackMetaData>
</u:GetPositionInfoResponse></s:Body></s:Envelope>
XML
    is( $got->{RelTime}, '0:01:07', 'RelTime is read' );
    is( $timeToSecs->( $got->{RelTime} ), 67, 'and converts to seconds' );
    is( $got->{TrackMetaData}, '<DIDL-Lite>&amp;</DIDL-Lite>',
        'unescaping does &amp; LAST, so &amp;amp; survives as &amp; rather than collapsing to &' );
}

print "-- timeToSecs edge cases --\n";

is( $timeToSecs->('0:00:00'),        0,     'a real zero is 0, not undef' );
is( $timeToSecs->('1:01:01'),        3661,  'hours, minutes and seconds' );
is( $timeToSecs->('0:03:12.500'),    192,   'a fractional part is accepted and dropped' );
is( $timeToSecs->('NOT_IMPLEMENTED'), undef, 'the NOT_IMPLEMENTED placeholder is undef, not 0' );
is( $timeToSecs->(''),               undef, 'empty is undef' );
is( $timeToSecs->(undef),            undef, 'undef is undef' );
is( $timeToSecs->('12:99:99'),       undef, 'a nonsense time is refused rather than silently wrapped' );

# ---------------------------------------------------------------------------
print "-- SOAP faults --\n";

{
    my ( $u ) = described( gapless => 1 );
    $HTTP->_reset;
    my ( $res, $err );
    $u->play( sub { ( $res, $err ) = @_ } );
    $HTTP->_failed( '500 Internal Server Error', <<'XML' );
<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>
<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
<errorCode>701</errorCode><errorDescription>Transition not available</errorDescription>
</UPnPError></detail></s:Fault></s:Body></s:Envelope>
XML
    is( $res, undef,     'a fault yields no result' );
    is( $err, 'upnp701', 'and the fault CODE is surfaced, not a substring guess at it' );
}

{
    my ( $u ) = described( gapless => 1 );
    $HTTP->_reset;
    my ( $res, $err );
    $u->play( sub { ( $res, $err ) = @_ } );
    # The case that is NOT yet verified on LMS 9.x: no body available at all.
    $HTTP->_failed( 'Connection refused', undef );
    is( $err, 'Connection refused', 'with no body, the transport error stands - nothing is invented' );
}

# ---------------------------------------------------------------------------
print "-- describe failure and retry --\n";

{
    $HTTP->_reset;
    Slim::Utils::Timers::_reset();
    my $u = $CLASS->new( location => 'http://10.0.0.9:49152/description.xml' );
    my $done = 'unset';
    $u->describe( sub { $done = shift } );
    $HTTP->_failed('Connection refused');

    is( $done, 0, 'a failed describe reports failure' );
    is( $u->isReady, 0, 'and does not mark itself ready' );
    is( Slim::Utils::Timers::_pending(), 1,
        'and schedules a retry - describe runs at create and link-up, neither of which recurs' );
}

{
    # A Hub whose description has no AVTransport (still starting) is not one we
    # can drive yet. Anything else naming none is not a Hub at all (above).
    $HTTP->_reset;
    Slim::Utils::Timers::_reset();
    my $u = $CLASS->new( location => 'http://10.0.0.9:49152/description.xml' );
    my $done = 'unset';
    $u->describe( sub { $done = shift } );
    $HTTP->_respond( bare( name => 'Lounge', maker => 'Platin', model => 'Stereo Hub HT' ) );
    is( $done, 0, 'a Hub\'s description with no AVTransport fails' );
    is( $u->isReady, 0, 'and is not ready' );
    is( Slim::Utils::Timers::_pending(), 1, 'and retries' );
}

# THE RETRY ANSWERS WHOEVER ASKED (`A MOVED HUB'S RETRY ANSWERED NO ONE`, found
# 2026-11-01). Plugin::_moved hands a re-described Hub to its player only from the
# describe's callback; the retry used to call describe with none, so a Hub whose
# first describe at a new address failed was described and never handed over.
{
    $HTTP->_reset;
    Slim::Utils::Timers::_reset();
    my $u = $CLASS->new( location => 'http://10.0.0.9:49152/description.xml' );
    my @heard;
    $u->describe( sub { push @heard, shift } );

    $HTTP->_failed('Timed out');
    is( "@heard", '0', 'the first describe fails and says so' );

    Slim::Utils::Timers::_fireNext();
    $HTTP->_failed('Timed out');
    is( "@heard", '0 0', 'a failed retry reports to the same caller' );

    Slim::Utils::Timers::_fireNext();
    $HTTP->_respond( description() );
    $HTTP->_respond( avscpd() );
    $HTTP->_respond( rcscpd() );
    $HTTP->_respond( protoinfo() );
    is( $u->isReady, 1, 'the second retry describes the device' );
    is( "@heard", '0 0 1', 'and reports success to the caller of the FIRST describe' );
    is( Slim::Utils::Timers::_pending(), 0, 'and nothing is left to retry' );
}

{
    # The same through the other failure: a description with no AVTransport.
    $HTTP->_reset;
    Slim::Utils::Timers::_reset();
    my $u = $CLASS->new( location => 'http://10.0.0.9:49152/description.xml' );
    my @heard;
    $u->describe( sub { push @heard, shift } );
    $HTTP->_respond( bare( name => 'Still booting', maker => 'Platin', model => 'Stereo Hub HT' ) );

    Slim::Utils::Timers::_fireNext();
    $HTTP->_respond( description() );
    $HTTP->_respond( avscpd() );
    $HTTP->_respond( rcscpd() );
    $HTTP->_respond( protoinfo() );
    is( "@heard", '0 1', 'a retry after a description with no AVTransport also reports success' );
}

{
    # close() must cancel the retry AND make in-flight callbacks inert, or a
    # torn-down player keeps a timer alive and resurrects itself.
    $HTTP->_reset;
    Slim::Utils::Timers::_reset();
    my $u = $CLASS->new( location => 'http://10.0.0.9:49152/description.xml' );
    $u->describe( sub { } );
    $u->close;
    is( Slim::Utils::Timers::_pending(), 0, 'close cancels a pending describe retry' );

    $HTTP->_respond( description() );
    is( $u->isReady, 0, 'and a response arriving after close is ignored, not acted on' );
}

# ---------------------------------------------------------------------------
print "-- one warning per outage, not one per call (A SILENT HUB FLOODS THE LOG) --\n";

# Measured 2026-11-01: a 1m45s power cycle wrote 78 `... failed: Connect timed
# out` warnings, three a second while the Hub booted.
{
    no warnings 'redefine';
    my ( @W, @D );
    local *Slim::Utils::Log::Obj::warn  = sub { push @W, $_[1]; return };
    local *Slim::Utils::Log::Obj::debug = sub { push @D, $_[1]; return };

    my ($u) = described();
    $HTTP->_reset;

    $u->transportInfo( sub { } ); $HTTP->_failed( 'Connect timed out: ', undef );
    $u->getVolume( sub { } );     $HTTP->_failed( 'Connect timed out: ', undef );
    $u->positionInfo( sub { } );  $HTTP->_failed( 'Connect timed out: ', undef );
    is( scalar @W, 1, 'three calls the Hub does not answer: ONE warning' );
    ok( @W && $W[0] =~ /further failures are logged at debug until it answers/, 'which says where the rest go' );
    is( scalar @D, 2, 'and the other two at debug' );

    my $res;
    $u->transportInfo( sub { $res = shift } );
    $HTTP->_respond('<u:GetTransportInfoResponse><CurrentTransportState>STOPPED</CurrentTransportState></u:GetTransportInfoResponse>');
    is( $res && $res->{CurrentTransportState}, 'STOPPED', 'the Hub answers' );
    $u->transportInfo( sub { } ); $HTTP->_failed( 'Connect timed out: ', undef );
    is( scalar @W, 2, 'and the next silence after an answer is warned again' );

    # A status line or a UPnP fault IS an answer: warned every time, as before -
    # `Pause failed: 500` is how the stuck Hub of 2026-10-25 showed itself.
    @W = ();
    $u->pause( sub { } ); $HTTP->_failed( '500 Internal Server Error', undef );
    $u->pause( sub { } ); $HTTP->_failed( '500 Internal Server Error', undef );
    is( scalar @W, 2, 'a Hub answering 500 is warned every time - it is not silent' );
    $u->play( sub { } ); $HTTP->_failed( '500 Internal Server Error', '<errorCode>702</errorCode>' );
    is( scalar @W, 3, 'and so is a UPnP fault' );

    @D = ();
    $u->pause( sub { } ); $HTTP->_failed( '500 Internal Server Error', '<errorCode>701</errorCode>' );
    is( scalar @W, 3, 'a 701 stays out of the warnings' );
    is( scalar @D, 1, 'at debug, as before' );
}

# ---------------------------------------------------------------------------
print "-- a description that will not come is warned once per address --\n";

# Every discovery round asks again (a new probe object each time), so the memory
# is per address, not per object.
{
    no warnings 'redefine';
    my ( @W, @D );
    local *Slim::Utils::Log::Obj::warn  = sub { push @W, $_[1]; return };
    local *Slim::Utils::Log::Obj::debug = sub { push @D, $_[1]; return };

    $HTTP->_reset;
    Slim::Utils::Timers::_reset();
    my $loc = 'http://10.0.0.66:49152/description.xml';
    my $fails = sub { scalar grep { /description fetch failed/ } @_ };

    for ( 1 .. 3 ) {
        my $u = $CLASS->new( location => $loc );
        $u->describe( sub { } );
        $HTTP->_failed('Connect timed out: ');
        $u->close;
    }
    is( $fails->(@W), 1, 'three rounds failing at one address: ONE warning' );
    ok( @W && $W[0] =~ /\Q$loc\E/, 'naming the address' );
    is( $fails->(@D), 2, 'the rest at debug' );

    my $u = $CLASS->new( location => $loc );
    $u->describe( sub { } );
    $HTTP->_respond( description() );
    $HTTP->_respond( avscpd() );
    $HTTP->_respond( rcscpd() );
    $HTTP->_respond( protoinfo() );
    my $v = $CLASS->new( location => $loc );
    $v->describe( sub { } );
    $HTTP->_failed('Connect timed out: ');
    is( $fails->(@W), 2, 'after it answers, the next failure is warned again' );

    my $w = $CLASS->new( location => 'http://10.0.0.67:49152/description.xml' );
    $w->describe( sub { } );
    $HTTP->_failed('Connect timed out: ');
    is( $fails->(@W), 3, 'another address has its own warning' );
}

# ---------------------------------------------------------------------------
print "-- REMEMBERED ACTIONS FOLLOW THE HUB LIST (0.2.9) --\n";

# Keyed on a UDN, and the Hub's changes at every reboot: kept for good, a list was
# left behind at every reboot and every build. On the rig, 2026-11-01: the Hub
# under both the UDNs it had that day, and three renderers that are not Hubs,
# each under three builds.
{
    my $gen = Plugins::PlatinBridge::UPnP::CACHE_GEN();
    my $now = 'uuid:2e23fb30-5679-4bda-9392-7c2994f60360';
    my $was = 'uuid:e1d04a48-18d2-4a95-be84-643ac1295c1f';
    my $two = 'uuid:b0b0b0b0-0000-4000-8000-00000000000b';
    my $arc = 'uuid:RINCON_48A6B805B63501400_MR';

    $prefs->set( $CLASS->cacheKeyFor($_), ['Play'] ) for $now, $was, $two, $arc;
    $prefs->set( 'caps' . ( $gen - 1 ) . "_$now", ['Play'] );
    $prefs->set( "caps11_$arc", ['Play'] );
    $prefs->set( 'address', '192.0.2.35' );
    $prefs->set( 'hubs', [ { id => '02:26:c2:1f:49:04', udn => $now, ip => '192.0.2.35' } ] );

    ok( $CLASS->keepRemembered( $now, $two, undef ) > 0, 'lists are removed' );
    ok( $prefs->get( $CLASS->cacheKeyFor($now) ), 'the list of a Hub we know is kept' );
    ok( $prefs->get( $CLASS->cacheKeyFor($two) ), 'every Hub\'s, not only the first' );
    is( $prefs->get( $CLASS->cacheKeyFor($was) ), undef, 'the list under the UDN a Hub had before a reboot goes' );
    is( $prefs->get( 'caps' . ( $gen - 1 ) . "_$now" ), undef, 'a previous build\'s goes, even for a Hub we know' );
    is( $prefs->get( $CLASS->cacheKeyFor($arc) ), undef, 'a renderer that is not a Hub: gone' );
    is( $prefs->get("caps11_$arc"), undef, 'under every build' );

    my @left = sort grep { /^caps/ } keys %{ $prefs->all };
    is( "@left", join( ' ', sort map { $CLASS->cacheKeyFor($_) } $now, $two ), 'and nothing else is left' );

    # CONTROL: prefs that are not action lists are never touched.
    is( $prefs->get('address'), '192.0.2.35', 'control: the known-address pref stays' );
    is( ref $prefs->get('hubs'), 'ARRAY', 'and so does the Hub list' );

    is( $CLASS->keepRemembered( $now, $two ), 0, 'a second pass finds nothing to remove' );
}

# ---------------------------------------------------------------------------
print "-- escaping --\n";

is( $escape->(q{Tom & Jerry's <b> "x"}), 'Tom &amp; Jerry&apos;s &lt;b&gt; &quot;x&quot;',
    'escape covers all five XML entities' );
is( $escape->(undef), '', 'escape of undef is empty, not a warning' );

# ---------------------------------------------------------------------------
printf "\n%s: %d passed, %d failed\n", ( $fail ? 'FAIL' : 'ok' ), $pass, $fail;
exit( $fail ? 1 : 0 );
