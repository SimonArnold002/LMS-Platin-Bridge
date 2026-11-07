#!/usr/bin/perl
#
# Unit tests for Plugins::PlatinBridge::Control - the Hub's own control port,
# TCP 50006: power and source.
#
# Two things matter more than the rest:
#
#   1. THE BYTES. Every frame built here is checked against the byte sequences
#      aiolibresync recorded as TESTED on hardware (docs/commands.md there). A
#      frame that is merely self-consistent proves nothing about the Hub.
#
#   2. POWER IS A TOGGLE. Nothing may toggle without first reading the state,
#      and a report that answers OUR request must not be mirrored back into LMS
#      as if the Hub had been switched by hand.
#
# The socket is replaced at _send, the one place bytes leave; everything else is
# the real module.
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
    use constant WEBUI    => 1;
}

require Plugins::PlatinBridge::Control;

my $C = 'Plugins::PlatinBridge::Control';

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

sub hex_ { join ' ', unpack( '(H2)*', shift ) }
sub bytes { pack( 'C*', map { hex } split / /, shift ) }

my $frame  = $C->can('frame');
my $take   = $C->can('takeFrames');
my $decode = $C->can('decode');

# The Hub's real source list, read 2026-10-25.
my $SOURCES_JSON = '{"src":[{"ix":0,"name":"Line","sts":0},{"ix":1,"name":"eARC","sts":0},{"ix":2,"name":"OPT1","sts":0},{"ix":3,"name":"OPT2","sts":0},{"ix":4,"name":"OPT3","sts":0},{"ix":5,"name":"COAX","sts":0},{"ix":6,"name":"USBDISC","sts":0},{"ix":7,"name":"PC/MAC","sts":0},{"ix":8,"name":"Bluetooth","sts":0},{"ix":9,"name":"Streaming","sts":1}]}';

sub sourceReport {
    my $json = shift;
    my $body = pack( 'C2', 0x02, 0x02 ) . $json;
    my $sum = 0; $sum += $_ for unpack 'C*', $body;
    return pack( 'n', length($body) + 1 ) . chr( $sum & 0xFF ) . $body;
}

# ---------------------------------------------------------------------------
print "-- the bytes, against the frames recorded on hardware --\n";

is( hex_( $frame->( 0x02, 0x0d ) ),       '00 03 0f 02 0d',    'get power is 00 03 0f 02 0d' );
is( hex_( $frame->( 0x02, 0x0f, 0x00 ) ), '00 04 11 02 0f 00', 'the power toggle is 00 04 11 02 0f 00' );
is( hex_( $frame->( 0x02, 0x01 ) ),       '00 03 03 02 01',    'get sources is 00 03 03 02 01' );
is( hex_( $frame->( 0x02, 0x03, 9 ) ),    '00 04 0e 02 03 09', 'select source 9 (Streaming) is 00 04 0e 02 03 09' );

# ---------------------------------------------------------------------------
print "-- framing a byte stream --\n";

{
    my $buf = bytes('00 04 00 02 0e 01') . bytes('00 04 00 02 0e 01');
    my @f = $take->( \$buf );
    is( scalar @f, 2, 'two frames in one read are two frames' );
    is( length $buf, 0, 'and nothing is left behind' );
}

{
    my $buf = bytes('00 04 00 02 0e');
    my @f = $take->( \$buf );
    is( scalar @f, 0, 'a partial frame is not a frame' );
    is( length $buf, 5, 'and is kept for the next read' );

    $buf .= bytes('01');
    @f = $take->( \$buf );
    is( scalar @f, 1, 'the rest arriving completes it' );
}

{
    # A length that cannot be a frame costs one byte, and the reader resyncs.
    my $buf = bytes('00 00') . bytes('00 04 00 02 0e 00');
    my @f = $take->( \$buf );
    is( scalar @f, 1, 'garbage in front of a frame does not wedge the reader' );
    is( $decode->( $f[0] )->{power}, 0, 'and the frame after it reads correctly' );
}

# ---------------------------------------------------------------------------
print "-- decoding: only the REPORT forms carry state --\n";

is( $decode->( bytes('00 04 00 02 0e 01') )->{power}, 1, 'a power report of 01 is ON' );
is( $decode->( bytes('00 04 00 02 0e 00') )->{power}, 0, 'and 00 is OFF' );

{
    # THE BUS IS SHARED: the Platin app's own toggle crosses it. Read as a power
    # state it would let another client's command rewrite ours.
    my $d = $decode->( bytes('00 04 12 02 0f 01') );
    ok( $d && !exists $d->{power}, 'another client\'s power TOGGLE is not a power state' );
    my $q = $decode->( bytes('00 03 0f 02 0d') );
    ok( $q && !exists $q->{power}, 'nor is another client\'s power QUERY' );
}

{
    my $d = $decode->( sourceReport($SOURCES_JSON) );
    is( scalar @{ $d->{sources} }, 10, 'the source list is read in full' );
    is( $d->{source}{name}, 'Streaming', 'the selected source is the one with sts 1' );
    is( $d->{source}{ix}, 9, 'with its index' );
    is( $d->{sources}[7]{name}, 'PC/MAC', 'a name with a slash survives' );
}

{
    # An absent sts on every entry means the frame does not say - not "none".
    ( my $none = $SOURCES_JSON ) =~ s/"sts":1/"sts":0/;
    my $d = $decode->( sourceReport($none) );
    is( $d->{source}, undef, 'no selected source is reported as unknown' );
}

{
    my $d = $decode->( sourceReport('{"src":[{"name":"Streaming","sts":1,"ix":9}]}') );
    is( $d->{source}{ix}, 9, 'the keys may come in any order' );
}

is( $decode->( bytes('00 03 00 09 99') ), undef, 'an unknown class is unknown, not a state' );
is( $decode->('ab'), undef, 'a runt frame is not decoded' );

ok( $C->can('isStreaming')->( { name => 'Streaming' } ), 'Streaming is the streaming input' );
ok( !$C->can('isStreaming')->( { name => 'eARC' } ), 'eARC is not' );
ok( !$C->can('isStreaming')->(undef), 'and an unknown source is not' );

# ---------------------------------------------------------------------------
# A connection with the socket replaced at _send.

my @SENT;
my @POWER;
my @SOURCE;

{
    no warnings 'redefine';
    *Plugins::PlatinBridge::Control::_send = sub {
        my ( $self, $b ) = @_;
        return 0 unless $self->{up};
        push @SENT, hex_($b);
        return 1;
    };
}

sub link_ {
    @SENT = @POWER = @SOURCE = ();
    Slim::Utils::Timers::_reset();
    my $c = $C->new(
        host     => '10.0.0.35',
        onPower  => sub { push @POWER,  [@_] },
        onSource => sub { push @SOURCE, [@_] },
    );
    open my $fh, '<', '/dev/null' or die;
    $c->{sock} = $fh;
    $c->{up}   = 1;
    return $c;
}

sub report { my ( $c, $on ) = @_; $c->_onFrame( bytes( '00 04 00 02 0e ' . ( $on ? '01' : '00' ) ) ) }

sub toggles { scalar grep { $_ eq '00 04 11 02 0f 00' } @SENT }
sub queries { scalar grep { $_ eq '00 03 0f 02 0d' } @SENT }

# ---------------------------------------------------------------------------
print "-- power is read before it is ever toggled --\n";

{
    my $c = link_();
    report( $c, 1 );                 # the Hub says it is on
    @SENT = (); @POWER = ();

    my @done;
    $c->setPower( 0, sub { @done = @_ } );

    is( $SENT[0], '00 03 0f 02 0d', 'switching off starts with a READ, not a toggle' );
    is( toggles(), 0, 'and nothing is toggled before the answer' );

    report( $c, 1 );                 # the answer: still on
    is( toggles(), 1, 'the Hub is on, so one toggle is sent' );

    report( $c, 0 );                 # the Hub confirms
    is( $done[0], 1, 'the command completes on the Hub\'s confirmation' );
    is( $c->power, 0, 'and the state is off' );

    is( scalar @POWER, 1, 'the change is reported once' );
    is( $POWER[0][1], 1, 'flagged as OUR request - so it is not mirrored back into LMS' );

    report( $c, 0 );                 # the Hub sends every network change TWICE
    is( scalar @POWER, 1, 'the duplicate report is not news' );
    is( toggles(), 1, 'and costs no second toggle' );
}

{
    # THE VENDOR APP'S BUG, avoided: its "on" frame turns an ON hub OFF.
    my $c = link_();
    report( $c, 1 );
    @SENT = ();

    my @done;
    $c->setPower( 1, sub { @done = @_ } );
    report( $c, 1 );

    is( toggles(), 0, 'switching ON a Hub that is already on sends NO toggle' );
    is( $done[0], 1, 'and still completes' );
}

{
    my $c = link_();
    $c->{up} = 0;
    my @done;
    $c->setPower( 1, sub { @done = @_ } );
    is( scalar @SENT, 0, 'with the link down nothing is sent' );
    is( $done[0], 0, 'and the request fails at once rather than waiting' );
}

# ---------------------------------------------------------------------------
print "-- a toggle that is not confirmed is READ again, never toggled blind --\n";

{
    my $c = link_();
    report( $c, 1 );
    @SENT = ();

    my @done;
    $c->setPower( 0, sub { @done = @_ } );
    report( $c, 1 );                 # read: on -> toggle
    is( toggles(), 1, 'one toggle' );

    # No confirmation arrives. The timer fires - once.
    Slim::Utils::Timers::_fireNext();
    is( toggles(), 1, 'a missing confirmation does NOT send a second toggle' );
    ok( queries() >= 2, 'it reads again instead' );

    report( $c, 0 );                 # the toggle had worked; the report was lost
    is( $done[0], 1, 'and completes when the read shows the toggle worked' );
    is( toggles(), 1, 'having toggled exactly once' );
}

# ---------------------------------------------------------------------------
print "-- the Hub wins a conflict --\n";

{
    # Someone presses the remote's power button just as we toggle.
    my $c = link_();
    report( $c, 1 );
    @POWER = ();

    my @done;
    $c->setPower( 0, sub { @done = @_ } );
    report( $c, 1 );                 # read: on -> toggle sent for "off"
    $c->_onFrame( bytes('00 04 00 02 0e 01') );   # ...but the Hub reports ON again

    is( $done[0], 0, 'a report contrary to our toggle ends the command' );
    is( toggles(), 1, 'without fighting it with another toggle' );
}

{
    # The user changes their mind while a toggle is on its way: the command
    # converges on the LATEST wish.
    my $c = link_();
    report( $c, 1 );
    @POWER = ();

    my @done;
    $c->setPower( 0, sub { @done = @_ } );
    report( $c, 1 );                 # read on -> toggle for off
    $c->setPower( 1, sub { @done = @_ } );        # pressed again: on after all
    report( $c, 0 );                 # our toggle took - but the wish is now ON
    is( toggles(), 2, 'it toggles once more, towards the latest wish' );
    is( scalar( grep { !$_->[1] } @POWER ), 0, 'and nothing on the way was mirrored as an outside change' );

    report( $c, 1 );
    is( $done[0], 1, 'and completes there' );
}

{
    my $c = link_();
    report( $c, 1 );

    $c->setPower( 0 );
    report( $c, 1 );                 # toggle 1
    $c->setPower(1);
    report( $c, 0 );                 # ours; wish moved -> toggle 2
    $c->setPower(0);
    report( $c, 1 );                 # ours again; wish moved again -> bound reached
    is( toggles(), 2, 'never more than two toggles for one request' );
}

# ---------------------------------------------------------------------------
print "-- reports from outside --\n";

{
    my $c = link_();
    report( $c, 0 );
    is( scalar @POWER, 1, 'the first report after connecting is passed on' );
    is( $POWER[0][2], 1, 'marked FIRST - the player adopts the Hub\'s state from it' );
    is( $POWER[0][1], 0, 'and it is not ours' );

    report( $c, 1 );                 # the remote's power button
    is( scalar @POWER, 2, 'a change made at the Hub is passed on' );
    is( "@{ $POWER[1] }", '1 0 0', 'as on, not ours, not first' );
}

{
    my $c = link_();
    $c->_onFrame( sourceReport($SOURCES_JSON) );
    is( scalar @SOURCE, 1, 'the first source report is passed on' );
    is( $SOURCE[0][0]{name}, 'Streaming', 'naming the source' );
    is( $c->onStreaming, 1, 'and the link knows it is on Streaming' );
    is( $c->streamingIndex, 9, 'and which index that is' );

    $c->_onFrame( sourceReport($SOURCES_JSON) );
    is( scalar @SOURCE, 1, 'the same source again is not news' );

    ( my $earc = $SOURCES_JSON ) =~ s/"sts":1/"sts":0/;
    $earc =~ s/("name":"eARC","sts":)0/${1}1/;
    $c->_onFrame( sourceReport($earc) );
    is( scalar @SOURCE, 2, 'a switch to eARC is passed on' );
    is( $SOURCE[1][0]{name} . ' <- ' . $SOURCE[1][1]{name}, 'eARC <- Streaming', 'with where it came from' );
    is( $c->onStreaming, 0, 'and the link knows it has left Streaming' );

    @SENT = ();
    $c->selectStreaming;
    is( $SENT[0], '00 04 0e 02 03 09', 'selecting Streaming sends source 9' );
}

{
    my $c = link_();
    is( $c->onStreaming, undef, 'before the Hub has said, the source is UNKNOWN - not "elsewhere"' );
}

# ---------------------------------------------------------------------------
print "-- a dropped link --\n";

{
    my $c = link_();
    report( $c, 1 );
    my @done;
    $c->setPower( 0, sub { @done = @_ } );
    $c->_drop('test');

    is( $done[0], 0, 'a command in flight fails when the link drops - nobody is left waiting' );
    is( $c->isUp, 0, 'the link reads down' );
    is( $c->power, 1, 'the last state is still known, for display' );
    ok( Slim::Utils::Timers::_pending() > 0, 'and a reconnect is scheduled' );
}

{
    my $c = link_();
    $c->close;
    is( $c->{closing}, 1, 'close marks the link closing' );
    Slim::Utils::Timers::_reset();
    $c->_drop('again');
    is( Slim::Utils::Timers::_pending(), 0, 'and a closing link never reconnects' );
}

# ---------------------------------------------------------------------------
printf "\n%s: %d passed, %d failed\n", ( $fail ? 'FAIL' : 'ok' ), $pass, $fail;
exit( $fail ? 1 : 0 );
