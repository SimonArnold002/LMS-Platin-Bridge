#!/usr/bin/perl
#
# Unit tests for Plugins::PlatinBridge::Plugin - adoption, the Hub moving, and
# which Hub is which.
#
# Driven through the REAL Plugin, UPnP and Player modules on the stub Slim tree:
# _onDevices is called as Discovery calls it, and every description and SOAP
# request is answered (or failed) through the SimpleAsyncHTTP stub. Nothing here
# touches the network: Control's TCP connect is replaced, and the addresses are
# TEST-NET-1 (192.0.2.0/24, documentation only).
#
# WHICH HUB IS WHICH - Simon's rule, 2026-11-01: the same UDN or the same IP is
# the same Hub (the UDN changes at every reboot, the IP with DHCP); both new is a
# new Hub, with its own player.
#
# The sections run in order on ONE plugin state, as LMS would see it.
#
# `ok` TAKES THE ASSERTION NAME OFF THE END: a failed match in list context is
# the EMPTY list, so a name-last `ok` cannot read the label as the condition.

use strict;
use warnings;
use lib '.';

no warnings 'once';

BEGIN {
    package main;
    use constant DEBUGLOG => 0;
    use constant INFOLOG  => 0;
    use constant WEBUI    => 0;
}

require Plugins::PlatinBridge::Plugin;

my $HTTP  = 'Slim::Networking::SimpleAsyncHTTP';
my $P     = 'Plugins::PlatinBridge::Plugin';
my $prefs = Slim::Utils::Prefs::preferences('plugin.platinbridge');

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

# The control port is the one thing _create starts that would open a socket.
{
    no warnings 'redefine';
    *Plugins::PlatinBridge::Control::connect = sub { };
}

# The stub client has no controller; teardown stops one.
{
    package NullController;
    sub new  { bless {}, shift }
    sub stop { return }
}

sub controlled {
    for my $b ( values %{ $P->bridges } ) {
        $b->{client}->controller( NullController->new ) unless $b->{client}->controller;
    }
}

sub restartLMS {
    controlled();
    $P->can('shutdownPlugin')->();
}

# --- the Hub's answers --------------------------------------------------------

my $UDN = 'uuid:e1d04a48-18d2-4a95-be84-643ac1295c1f';

sub description {
    my %o = @_;
    my $maker = $o{maker} || 'Platin';
    my $model = $o{model} || 'Stereo Hub HT';
    my $av    = $o{noav} ? '' : '<service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/upnp/control/rendertransport1</controlURL>
        <SCPDURL>/upnp/rendertransportSCPD.xml</SCPDURL>
      </service>';
    return <<"XML";
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Lounge</friendlyName>
    <manufacturer>$maker</manufacturer>
    <modelName>$model</modelName>
    <UDN>$UDN</UDN>
    <serviceList>
      $av
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/upnp/control/rendercontrol1</controlURL>
        <SCPDURL>/upnp/rendercontrolSCPD.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/upnp/control/connmgr1</controlURL>
        <SCPDURL>/upnp/connmgrSCPD.xml</SCPDURL>
      </service>
    </serviceList>
  </device>
</root>
XML
}

sub avscpd {
    return '<scpd><actionList><action><name>SetAVTransportURI</name></action>'
         . '<action><name>SetNextAVTransportURI</name></action></actionList></scpd>';
}

sub rcscpd {
    return '<scpd><serviceStateTable><stateVariable sendEvents="no"><name>Volume</name>'
         . '<allowedValueRange><minimum>0</minimum><maximum>100</maximum><step>1</step></allowedValueRange>'
         . '</stateVariable></serviceStateTable></scpd>';
}

sub protoinfo {
    return '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
         . '<u:GetProtocolInfoResponse xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">'
         . '<Source></Source><Sink>http-get:*:audio/x-flac:*,http-get:*:audio/x-wav:*</Sink>'
         . '</u:GetProtocolInfoResponse></s:Body></s:Envelope>';
}

# A whole describe, answered: the description, the two SCPDs, GetProtocolInfo.
# A describe that was never asked for is a FAIL, not a death: the stub dies with
# nothing to answer, and a dead suite hides every section after it.
sub answerDescribe {
    my @o = @_;
    eval {
        $HTTP->_respond( description(@o) );
        $HTTP->_respond( avscpd() );
        $HTTP->_respond( rcscpd() );
        $HTTP->_respond( protoinfo() );
        1;
    } or do { $fail++; print "  FAIL a describe to answer was expected: $@" };
}

# A device as Discovery reports it.
sub dev {
    my ( $ip, %o ) = @_;
    my $port = $o{port} || 49494;
    return {
        udn      => ( $o{udn} || $UDN ),
        location => "http://$ip:$port/description.xml",
        ip       => $ip,
        ( defined $o{seen} ? ( lastSeen => $o{seen} ) : () ),
    };
}

sub devices {
    my %d;
    $d{ $_->{udn} } = $_ for @_;
    return \%d;
}

sub onDevices { $P->can('_onDevices')->(@_) }

# Fire only the pending describe retry - not the player's poll.
sub fireDescribeRetry {
    my ($t) = grep { $_->{cb} == \&Plugins::PlatinBridge::UPnP::_describeRetry } @{ Slim::Utils::Timers::_timers() };
    return 0 unless $t;
    Slim::Utils::Timers::killTimers( $t->{obj}, \&Plugins::PlatinBridge::UPnP::_describeRetry );
    $t->{cb}->( $t->{obj}, @{ $t->{args} } );
    return 1;
}

# Answer the latest request sent to $ip - for two describes running at once.
sub answerAt {
    my ( $ip, $body ) = @_;
    my @r = @Slim::Networking::SimpleAsyncHTTP::REQ;
    my ($i) = grep { index( $r[$_]{url}, "//$ip:" ) >= 0 } reverse 0 .. $#r;
    if ( !defined $i ) { $fail++; print "  FAIL nothing was asked of $ip\n"; return }
    $HTTP->_respond( $body, $i );
}

# The saved Hub list's entry for a player id.
sub known {
    my $id = shift;
    my ($h) = grep { $_->{id} eq $id } @{ $prefs->get('hubs') || [] };
    return $h || {};
}

# A remembered action list (UPnP's capability cache), by UDN.
sub listFor { Plugins::PlatinBridge::UPnP->cacheKeyFor(shift) }
sub listed  { $prefs->get( listFor(shift) ) }

sub clientAt {
    my $udn = shift;
    my $b = $P->bridges->{$udn} or return undef;
    return $b->{client};
}

# ---------------------------------------------------------------------------
print "-- the Hub is adopted --\n";

$HTTP->_reset;
Slim::Utils::Timers::_reset();
onDevices( devices( dev('192.0.2.35') ), 1 );
answerDescribe();

my $b      = $P->bridges->{$UDN};
my $client = $b && $b->{client};

ok( $client && $client->isa('Plugins::PlatinBridge::Player'), 'a Platin Hub gets a player' );
ok( $client->pbUPnP && $client->pbUPnP->isReady, 'bound to a described UPnP link' );
is( Plugins::PlatinBridge::Discovery->settled, 1, 'and discovery is settled on it' );
is( $client->id, $P->can('_idFor')->($UDN), 'a new Hub\'s player id is made from its UDN' );
is( known( $client->id )->{udn}, $UDN, 'the saved Hub list has its UDN' );
is( known( $client->id )->{ip}, '192.0.2.35', 'and its IP' );

my $idA = $client->id;

# ---------------------------------------------------------------------------
print "-- the Hub moves and its first describe there FAILS (A MOVED HUB'S RETRY ANSWERED NO ONE) --\n";

{
    my $old = $client->pbUPnP;

    $HTTP->_reset;
    onDevices( devices( dev('192.0.2.77') ), 1 );
    my $new = $P->bridges->{$UDN}{upnp};

    is( $HTTP->_last && $HTTP->_last->{url}, 'http://192.0.2.77:49494/description.xml', 'the new location is described' );
    is( $old->isReady, 0, 'the old link is closed' );

    $HTTP->_failed('Timed out');
    ok( $client->pbUPnP != $new, 'while the new link is not described, the player keeps the old one' );

    ok( fireDescribeRetry(), 'a describe retry was scheduled' );
    answerDescribe();

    is( $new->isReady, 1, 'the retry describes the Hub at its new address' );
    ok( $client->pbUPnP == $new, 'and the player is handed the new link' );
    is( $client->pbUPnP->isReady, 1, 'which is ready - play() refuses a link that is not' );
    is( $client->pbDevice->{ip}, '192.0.2.77', 'the player\'s device address follows the Hub' );
    is( $b->{control}->host, '192.0.2.77', 'and so does the control port\'s' );
    is( known($idA)->{ip}, '192.0.2.77', 'and the saved Hub list\'s IP (same UDN, new IP: the same Hub)' );

    # The case the fix exists for: nothing else would ever rebind it.
    $HTTP->_reset;
    onDevices( devices( dev('192.0.2.77') ), 0 );
    is( $HTTP->_count, 0, 'a later round at the same location sends nothing - the retry is the only rebind' );
}

# ---------------------------------------------------------------------------
print "-- control: a move whose first describe succeeds --\n";

{
    $HTTP->_reset;
    onDevices( devices( dev('192.0.2.88') ), 1 );
    answerDescribe();
    my $new = $P->bridges->{$UDN}{upnp};
    ok( $client->pbUPnP == $new, 'the player is rebound at once' );
    is( $client->pbUPnP->isReady, 1, 'to a ready link' );
}

# ---------------------------------------------------------------------------
print "-- a moved Hub is not re-judged on its brand (0.2.10) --\n";

# 0.2.9's brand gate ran on every describe: a moved Hub whose description there
# did not name the brand was called back 0 with no retry, and its player kept the
# closed link until LMS restarted. The brand decides adoption; once a Hub is
# adopted, its UDN is what says it is that Hub.
{
    $HTTP->_reset;
    onDevices( devices( dev('192.0.2.89') ), 1 );
    my $new = $P->bridges->{$UDN}{upnp};
    answerDescribe( maker => 'gmrender-resurrect', model => 'GMediaRender' );
    is( $new->isReady, 1, 'its description there is read in full, brand or not' );
    ok( $client->pbUPnP == $new, 'and the player is rebound' );
}

# ---------------------------------------------------------------------------
print "-- a retry for a link already replaced is not acted on --\n";

{
    # Moved, first describe fails; moved AGAIN before the retry fires.
    $HTTP->_reset;
    onDevices( devices( dev('192.0.2.90') ), 1 );
    my $first = $P->bridges->{$UDN}{upnp};
    $HTTP->_failed('Timed out');

    $HTTP->_reset;
    onDevices( devices( dev('192.0.2.91') ), 1 );
    answerDescribe();
    my $second = $P->bridges->{$UDN}{upnp};

    ok( !fireDescribeRetry(), 'the replaced link\'s retry was cancelled with it' );
    ok( $client->pbUPnP == $second, 'the player stays on the current link' );
    is( $first->isReady, 0, 'and the replaced one is never described' );
}

# ---------------------------------------------------------------------------
print "-- a REBOOTED Hub keeps its player: a new UDN, the same IP (A REBOOTED HUB IS RE-ADOPTED LATE) --\n";

my $UDN2 = 'uuid:2e23fb30-5679-4bda-9392-7c2994f60360';
my $t0   = time();

{
    my $link = $client->pbUPnP;
    ok( listed($UDN), 'control: before the reboot, the Hub\'s action list is kept under its UDN' );

    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.91', seen => $t0 - 600 ), dev( '192.0.2.91', udn => $UDN2, seen => $t0 ) ), 0 );
    is( $HTTP->_count, 1, 'the new UDN at the Hub\'s address is described' );
    answerDescribe();

    my $br = $P->bridges;
    ok( $br->{$UDN2} && !$br->{$UDN}, 'the bridge is re-keyed to the new UDN' );
    ok( $br->{$UDN2} && $br->{$UDN2}{client} == $client, 'the SAME player carries on - nothing torn down, nothing re-created' );
    ok( $client->pbUPnP == $link, 'on the link it had (same address): nothing in flight is dropped' );
    is( $link->udn, $UDN2, 'which now answers to the new UDN' );
    is( $link->isReady, 1, 'and is still ready' );
    is( known($idA)->{udn}, $UDN2, 'the saved Hub list has the new UDN' );
    is( known($idA)->{ip}, '192.0.2.91', 'and the same IP' );
    ok( listed($UDN2), 'its action list is kept under the new UDN' );
    is( listed($UDN), undef, 'and the one under the UDN it had before is gone (0.2.9)' );

    # The old UDN ages out of discovery. In 0.2.6 this tore the player down (the
    # removal pass found its key gone) and made it again a round later.
    onDevices( devices( dev( '192.0.2.91', udn => $UDN2, seen => $t0 ) ), 0 );
    ok( clientAt($UDN2) && clientAt($UDN2) == $client, 'when the old UDN ages out, the player stays' );

    # The previous UDN still listed, older: not re-keyed back to, not even described.
    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.91', seen => $t0 - 600 ), dev( '192.0.2.91', udn => $UDN2, seen => $t0 ) ), 0 );
    is( $HTTP->_count, 0, 'the previous UDN, still listed, is not described again' );
    ok( $P->bridges->{$UDN2} && !$P->bridges->{$UDN}, 'nor re-keyed back to' );
}

# ---------------------------------------------------------------------------
print "-- a reboot onto another port of the same IP: re-keyed AND rebound --\n";

my $UDN3 = 'uuid:3c0ffee0-0000-4000-8000-000000000003';

{
    my $link = $client->pbUPnP;

    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.91', udn => $UDN2, seen => $t0 ), dev( '192.0.2.91', udn => $UDN3, seen => $t0 + 5, port => 49500 ) ), 0 );
    answerDescribe();

    ok( clientAt($UDN3) && clientAt($UDN3) == $client, 'the same player, under the new UDN' );
    ok( $client->pbUPnP != $link, 'handed a new link' );
    is( $client->pbUPnP->location, 'http://192.0.2.91:49500/description.xml', 'at the new port' );
    is( $client->pbUPnP->isReady, 1, 'described and ready' );
    is( $link->isReady, 0, 'the old link is closed' );
}

# ---------------------------------------------------------------------------
print "-- both new: a SECOND Hub gets a second player --\n";

my $UDNB = 'uuid:b0b0b0b0-0000-4000-8000-00000000000b';
my $idB;

{
    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.50', udn => $UDNB, seen => $t0 + 6 ) ), 1 );
    answerDescribe();

    my $other = clientAt($UDNB);
    is( scalar keys %{ $P->bridges }, 2, 'two Hubs, two players' );
    ok( $other && $other != $client, 'the second Hub has its own player' );
    $idB = $other ? $other->id : '';
    is( $idB, $P->can('_idFor')->($UDNB), 'with an id made from its own UDN' );
    ok( $idB ne $idA, 'not the first Hub\'s' );
    ok( clientAt($UDN3) == $client, 'and the first Hub keeps its player' );
    is( scalar @{ $prefs->get('hubs') || [] }, 2, 'both are in the saved Hub list' );
}

# ---------------------------------------------------------------------------
print "-- an LMS restart: each Hub gets its own player back --\n";

my $UDN4 = 'uuid:4a4a4a4a-0000-4000-8000-000000000004';

{
    # A Hub silent at the restart must not leave discovery searching for good.
    Plugins::PlatinBridge::Discovery->setSilent( $idA, 1 );

    restartLMS();
    is( scalar keys %{ $P->bridges }, 0, 'LMS stopped: no players' );
    is( Plugins::PlatinBridge::Discovery->settled, 0, 'and discovery unsettled' );
    is( Plugins::PlatinBridge::Discovery->silent, 0, 'a Hub torn down while silent is no longer counted silent' );

    # Hub A rebooted while LMS was down: a new UDN, at the IP it last had.
    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.91', udn => $UDN4, seen => $t0 + 10, port => 49500 ) ), 1 );
    answerDescribe();
    is( clientAt($UDN4) && clientAt($UDN4)->id, $idA, 'Hub A (new UDN, same IP) gets player A back' );
    ok( listed($UDN4), 'Hub A\'s action list is kept under its new UDN' );
    is( listed($UDN3), undef, 'and the one under the UDN it had before LMS stopped is gone' );
    ok( listed($UDNB), 'Hub B, not found yet this run, keeps its list: it is on the saved list' );

    # Hub B as it was.
    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.50', udn => $UDNB, seen => $t0 + 10 ) ), 1 );
    answerDescribe();
    is( clientAt($UDNB) && clientAt($UDNB)->id, $idB, 'Hub B (same UDN, same IP) gets player B back' );

    # Hub B kept its UDN but moved while LMS was down: the UDN alone says which.
    restartLMS();
    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.51', udn => $UDNB, seen => $t0 + 11 ) ), 1 );
    answerDescribe();
    is( clientAt($UDNB) && clientAt($UDNB)->id, $idB, 'Hub B (same UDN, new IP) still gets player B back' );
    is( known($idB)->{ip}, '192.0.2.51', 'and its new IP is kept' );

    # The same through a Hub whose player id was NOT made from the UDN it has now
    # (Hub A's came from its first UDN): only the saved UDN can say who it is.
    restartLMS();
    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.93', udn => $UDN4, seen => $t0 + 12 ) ), 1 );
    answerDescribe();
    is( clientAt($UDN4) && clientAt($UDN4)->id, $idA, 'Hub A (same UDN as last time, new IP) gets player A back' );
    ok( $idA ne $P->can('_idFor')->($UDN4), 'control: an id made from that UDN would differ' );
}

# ---------------------------------------------------------------------------
print "-- both changed: by the rule, a NEW Hub --\n";

my $UDN5 = 'uuid:5a5a5a5a-0000-4000-8000-000000000005';

{
    restartLMS();

    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.92', udn => $UDN5, seen => $t0 + 20 ) ), 1 );
    answerDescribe();

    my $c = clientAt($UDN5);
    ok( $c && $c->id ne $idA && $c->id ne $idB, 'a new UDN at a new IP is a new Hub: a new player id' );
    is( $c && $c->id, $P->can('_idFor')->($UDN5), 'made from its UDN' );
}

# ---------------------------------------------------------------------------
print "-- 0.2.6's one Hub keeps its player id on the upgrade --\n";

my $UDNL = 'uuid:1a1a1a1a-0000-4000-8000-00000000001a';
my $UDNM = 'uuid:1b1b1b1b-0000-4000-8000-00000000001b';

{
    restartLMS();

    # 0.2.6 kept ONE id in `playerid` and the UDN in `udn`, and never an IP. The
    # Hub has rebooted since, so neither of its identities matches.
    $prefs->set( 'hubs', undef );
    $prefs->set( 'playerid', '02:26:c2:1f:49:04' );
    $prefs->set( 'udn', 'uuid:e1d04a48-18d2-4a95-be84-643ac1295c1f' );

    # And what 0.2.8 left on the rig (read back 2026-11-01): action lists for
    # renderers that are not Hubs, under several builds, and the Hub's under a
    # UDN it no longer has.
    my $gen = Plugins::PlatinBridge::UPnP::CACHE_GEN();
    my @old = ( 'caps11_uuid:RINCON_48A6B805B63501400_MR', 'caps' . ( $gen - 1 ) . '_uuid:FF98FCDE-001A-209F-2BB6-0529FF98FCDE',
        listFor('uuid:23456789-1234-1010-8000-CC988B4B7888'), 'caps11_uuid:e1d04a48-18d2-4a95-be84-643ac1295c1f' );
    $prefs->set( $_, ['Play'] ) for @old;

    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.35', udn => $UDNL, seen => $t0 + 30 ) ), 1 );
    answerDescribe();
    is( clientAt($UDNL) && clientAt($UDNL)->id, '02:26:c2:1f:49:04', 'the first Hub found keeps 0.2.6\'s player id' );
    is( known('02:26:c2:1f:49:04')->{ip}, '192.0.2.35', 'and its IP is kept from now on' );
    is( known('02:26:c2:1f:49:04')->{udn}, $UDNL, 'with its UDN' );
    is( scalar( grep { defined $prefs->get($_) } @old ), 0, 'every action list an older build left is gone at that first adoption (0.2.9)' );
    my @stray = grep { /^caps/ && $_ ne listFor($UDNL) } keys %{ $prefs->all };
    is( "@stray", '', 'nothing is left but the list of the Hub on the saved list' );
    ok( listed($UDNL), 'which is kept' );

    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.36', udn => $UDNM, seen => $t0 + 30 ) ), 1 );
    answerDescribe();
    my $m = clientAt($UDNM);
    ok( $m && $m->id ne '02:26:c2:1f:49:04', 'a second Hub on the same first run gets a new id' );
}

# ---------------------------------------------------------------------------
print "-- another device at a Hub's address is not taken for it --\n";

my $UDNX = 'uuid:5050505a-0000-4000-8000-0000000000aa';

{
    my $lounge = clientAt($UDNL);

    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.35', udn => $UDNL, seen => $t0 + 30 ), dev( '192.0.2.35', udn => $UDNX, seen => $t0 + 40 ) ), 1 );
    $HTTP->_respond( description( maker => 'Sonos, Inc.', model => 'Sonos Arc' ) );
    is( $HTTP->_count, 1, 'it is asked for its description and nothing more (ONLY A HUB IS DESCRIBED IN FULL)' );
    is( listed($UDNX), undef, 'and no action list of it is kept' );

    ok( $P->bridges->{$UDNL} && !$P->bridges->{$UDNX}, 'a newer UDN that is not a Platin Hub is never re-keyed onto' );
    ok( clientAt($UDNL) == $lounge, 'the Hub keeps its player' );

    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.35', udn => $UDNL, seen => $t0 + 30 ), dev( '192.0.2.35', udn => $UDNX, seen => $t0 + 50 ) ), 1 );
    is( $HTTP->_count, 0, 'and it is not described again this run' );
}

# ---------------------------------------------------------------------------
print "-- a reboot while a move's describe is still pending --\n";

# _moved hands the player its new link from the describe's callback. A reboot in
# that window re-keys the bridge; a callback that looked the bridge up by its OLD
# UDN would find nothing and leave the player on the closed link.
my $UDNL2 = 'uuid:1c1c1c1c-0000-4000-8000-00000000001c';

{
    my $lounge = clientAt($UDNL);

    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.37', udn => $UDNL, seen => $t0 + 41 ) ), 1 );    # moved: same UDN
    my $moving = $P->bridges->{$UDNL}{upnp};

    onDevices( devices( dev( '192.0.2.37', udn => $UDNL2, seen => $t0 + 42 ) ), 1 );   # ...and rebooted
    answerDescribe();                                                                 # the reboot's probe
    ok( clientAt($UDNL2) && clientAt($UDNL2) == $lounge, 'the reboot re-keys the moving bridge' );
    ok( $lounge->pbUPnP != $moving, 'the move\'s link is not ready yet' );

    $HTTP->_respond( description(), 0 );                                              # the move's describe ends
    $HTTP->_respond( avscpd() );
    $HTTP->_respond( rcscpd() );
    $HTTP->_respond( protoinfo() );
    is( $moving->isReady, 1, 'the move\'s link is described' );
    ok( $lounge->pbUPnP == $moving, 'and still handed to the player, though its bridge was re-keyed' );
}

# ---------------------------------------------------------------------------
print "-- a renderer we cannot drive is described once per run --\n";

# 0.2.7 identifies at every round, not only before the first Hub. Read but with
# no AVTransport (a Sonos sub, a bonded speaker), such a renderer was described
# again - with a warning - whenever any renderer answered: 11 warnings in the
# first minute on the rig (2026-11-01 17:08).
{
    no warnings 'redefine';
    my @W;
    local *Slim::Utils::Log::Obj::warn = sub { push @W, $_[1]; return };
    my $driveWarnings = sub { scalar grep { /not a renderer we can drive/ } @W };

    my $sub = 'uuid:RINCON_804AF266238601400_MR';

    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.97', udn => $sub, seen => $t0 + 70, port => 1400 ) ), 1 );
    is( $HTTP->_count, 1, 'a new renderer is described' );
    $HTTP->_respond( description( maker => 'Sonos, Inc.', model => 'Sonos Sub Mini', noav => 1 ) );
    is( $driveWarnings->(), 0, 'not being a Platin Hub, it is not warned about (0.2.9)' );

    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.97', udn => $sub, seen => $t0 + 71, port => 1400 ) ), 1 );
    onDevices( devices( dev( '192.0.2.97', udn => $sub, seen => $t0 + 72, port => 1400 ) ), 0 );
    is( $HTTP->_count, 0, 'read, with no AVTransport and not a Hub: not described again this run' );

    # Control: a PLATIN HUB whose description has no AVTransport yet (starting up)
    # is asked again, and adopted once it has one.
    my $booting = 'uuid:b007b007-0000-4000-8000-0000000000b0';
    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.98', udn => $booting, seen => $t0 + 73 ) ), 1 );
    $HTTP->_respond( description( noav => 1 ) );
    is( $driveWarnings->(), 1, 'control: a Platin Hub with no AVTransport yet IS warned about' );
    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.98', udn => $booting, seen => $t0 + 74 ) ), 1 );
    is( $HTTP->_count, 1, 'control: a Platin Hub with no AVTransport yet is asked again' );
    answerDescribe();
    ok( clientAt($booting), 'and adopted once its description is whole' );

    # Control: a renderer that does not answer may be a Hub booting - asked again.
    my $silent = 'uuid:5110e500-0000-4000-8000-0000000000c0';
    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.99', udn => $silent, seen => $t0 + 75 ) ), 1 );
    $HTTP->_failed('Connect timed out: ');
    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.99', udn => $silent, seen => $t0 + 76 ) ), 1 );
    is( $HTTP->_count, 1, 'control: a renderer that did not answer is asked again' );
    eval { $HTTP->_failed('Connect timed out: ') };    # nothing to fail if it was not asked: the assertion above says so
}

# ---------------------------------------------------------------------------
print "-- a Hub still being read keeps its action list while another is adopted --\n";

# Two Hubs answering the same round (an LMS start with two). A Hub's action list
# is written during its describe, before it is remembered: the tidy that comes
# with adopting the other must not take it.
{
    my $U1 = 'uuid:d1d1d1d1-0000-4000-8000-0000000000d1';
    my $U2 = 'uuid:d2d2d2d2-0000-4000-8000-0000000000d2';

    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.61', udn => $U1, seen => $t0 + 80 ), dev( '192.0.2.62', udn => $U2, seen => $t0 + 80 ) ), 1 );
    is( $HTTP->_count, 2, 'both are described' );

    answerAt( '192.0.2.62', description() );    # Hub 2's description...
    answerAt( '192.0.2.62', avscpd() );         # ...and AVTransport SCPD: its list is written
    ok( listed($U2), 'Hub 2\'s action list is written while it is still being read' );

    answerAt( '192.0.2.61', description() );    # Hub 1 in full: adopted, remembered, tidied
    answerAt( '192.0.2.61', avscpd() );
    answerAt( '192.0.2.61', rcscpd() );
    answerAt( '192.0.2.61', protoinfo() );
    ok( clientAt($U1), 'Hub 1 is adopted' );
    ok( listed($U2), 'and Hub 2\'s list survives the tidy that came with it' );

    answerAt( '192.0.2.62', rcscpd() );
    answerAt( '192.0.2.62', protoinfo() );
    ok( clientAt($U2), 'Hub 2 is adopted' );
    ok( listed($U1) && listed($U2), 'each with its own list' );
}

# ---------------------------------------------------------------------------
print "-- a tidy that fails does not stop a Hub being adopted --\n";

{
    no warnings 'redefine';
    my @W;
    local *Slim::Utils::Log::Obj::warn = sub { push @W, $_[1]; return };
    local *Plugins::PlatinBridge::UPnP::keepRemembered = sub { die "prefs unwritable\n" };

    my $U = 'uuid:e7e7e7e7-0000-4000-8000-0000000000e7';
    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.63', udn => $U, seen => $t0 + 81 ) ), 1 );
    answerDescribe();
    ok( clientAt($U), 'the Hub is adopted all the same' );
    is( scalar( grep { /could not tidy/ } @W ), 1, 'and the failed tidy is warned' );
}

# ---------------------------------------------------------------------------
print "-- the saved Hub list is bounded --\n";

{
    restartLMS();

    for my $n ( 1 .. 20 ) {
        my $u = sprintf 'uuid:%08x-0000-4000-8000-%012x', $n, $n;
        $HTTP->_reset;
        onDevices( devices( dev( "192.0.2.1$n", udn => $u, seen => $t0 + 60 + $n ) ), 1 );
        answerDescribe();
    }

    is( scalar keys %{ $P->bridges }, 20, 'twenty Hubs, twenty players' );
    my @live = grep { my $id = $_->{id}; grep { $_->{client}->id eq $id } values %{ $P->bridges } } @{ $prefs->get('hubs') || [] };
    is( scalar @live, 20, 'no Hub that has a player is ever dropped from the list' );

    restartLMS();
    $HTTP->_reset;
    onDevices( devices( dev( '192.0.2.200', udn => 'uuid:ffffffff-0000-4000-8000-0000000000ff', seen => $t0 + 99 ) ), 1 );
    answerDescribe();
    is( scalar @{ $prefs->get('hubs') || [] }, 16, 'with no players holding them, the oldest entries go: 16 kept' );

    my %kept  = map { ( listFor( $_->{udn} ) => 1 ) } @{ $prefs->get('hubs') || [] };
    my @lists = grep { /^caps/ } keys %{ $prefs->all };
    is( scalar @lists, 16, 'and the action lists follow the list: 16' );
    is( scalar( grep { !$kept{$_} } @lists ), 0, 'each one a listed Hub\'s' );
}

# ---------------------------------------------------------------------------
printf "\n%s: %d passed, %d failed\n", ( $fail ? 'FAIL' : 'ok' ), $pass, $fail;
exit( $fail ? 1 : 0 );
