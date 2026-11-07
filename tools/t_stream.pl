#!/usr/bin/perl
#
# Unit tests for Plugins::PlatinBridge::Stream - the endpoint the Hub fetches
# audio from - driven with real HTTP::Request / HTTP::Response objects.
#
# What it must get right, each a failure seen on this Hub or on the UPnP Bridge:
#   * a STATUS CODE on every answer (a raw function is handed none),
#   * a second GET for a track served from the TOP (the Hub's probe-then-play),
#   * an empty 200 NEVER (it drove the Hub into tens of reconnects a second),
#   * no Content-Length on a HEAD (zero asserts the resource is empty).
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

use File::Temp ();
use HTTP::Request;
use HTTP::Response;

require Plugins::PlatinBridge::Player;
require Plugins::PlatinBridge::Stream;

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

{
    package FakeController;
    sub new { bless { song => 1 }, shift }
    sub streamingSong { $_[0]->{song} }
    sub AUTOLOAD { return }
}

{
    package FakeUPnP;
    sub new { bless {}, shift }
    sub isReady { 1 } sub canGapless { 1 } sub name { 'Hub' }
    sub stop { my ($s,$cb)=@_; $cb->() if $cb } sub setURI { my ($s,$u,$d,$cb)=@_; $cb->({},undef) if $cb }
    sub play { my ($s,$cb)=@_; $cb->({},undef) if $cb } sub setNextURI { my ($s,$u,$d,$cb)=@_; $cb->({},undef) if $cb }
}

# A socket the handler can write a HEAD's headers to, and LMS can ask about.
{
    package FakeSock;
    use parent -norequire, 'IO::Handle';
    sub connected { 1 }
}

sub sock_ {
    my $fh = File::Temp->new;
    bless $fh, 'FakeSock';
    return $fh;
}

{
    package FakeSong;
    sub new { bless { track => FakeTrack->new }, shift }
    sub currentTrack { $_[0]->{track} } sub streamformat { 'flc' } sub seekdata { undef }
    package FakeTrack;
    sub new { bless {}, shift } sub AUTOLOAD { return }
}

my $handler;
{
    no warnings 'redefine';
    local *Slim::Web::Pages::addRawFunction = sub { $handler = $_[2] };
    Plugins::PlatinBridge::Stream->init;
}

Slim::Player::Client::_resetRegistry();
my $p = Plugins::PlatinBridge::Player->new('02:11:22:33:44:55');
$p->chunks( [] );
$p->name('Hub');
$p->controller( FakeController->new );
$p->pbUPnP( FakeUPnP->new );
$p->pbDevice( { ip => '10.0.0.35' } );

$p->_startTrack( FakeSong->new, 'flc' );
my $seq = $p->pbLiveSeq;

sub request {
    my ( $path, %h ) = @_;
    my $method = delete $h{method} || 'GET';
    my $req = HTTP::Request->new( $method => "http://10.0.0.1:9000$path" );
    $req->header( $_ => $h{$_} ) for keys %h;
    my $res = HTTP::Response->new;
    $res->request($req);
    my $sock = sock_();
    Slim::Web::HTTP::_reset();
    $handler->( $sock, $res );
    return ( $res, $sock );
}

my $tok = '02-11-22-33-44-55';

# ---------------------------------------------------------------------------
print "-- refusals carry a status code, and are never an empty 200 --\n";

{
    my ($r) = request("/platin/nobody/1.flac");
    is( $r->code, 404, 'an unknown player is 404' );
    is( scalar @Slim::Web::HTTP::STREAMS, 0, 'and touches no stream' );
}

{
    my ($r) = request("/platin/$tok/" . ( $seq + 5 ) . ".flac");
    is( $r->code, 404, 'a track this player never handed out is 404' );
}

{
    $p->controller->{song} = undef;
    my ($r) = request("/platin/$tok/$seq.flac");
    is( $r->code, 503, 'nothing streaming yet is 503 - an empty 200 made the Hub reconnect tens of times a second' );
    is( scalar @Slim::Web::HTTP::STREAMS, 0, 'and the player is not touched' );
    $p->controller->{song} = 1;
}

{
    my ($r) = request( "/platin/$tok/$seq.flac", method => 'POST' );
    is( $r->code, 405, 'only GET and HEAD are served' );
}

# ---------------------------------------------------------------------------
print "-- the first GET of a track --\n";

{
    @{ $p->chunks } = ( \'stale-end-marker-from-an-older-stream' );
    my ( $r, $s ) = request("/platin/$tok/$seq.flac");

    is( $r->code, 200, 'a first GET is 200' );
    is( $r->content_type, 'audio/flac', 'labelled with the format LMS chose for this track' );
    is( $r->header('Accept-Ranges'), 'bytes', 'ranges are offered, over what is held' );
    is( $r->header('Connection'), 'close', 'close-delimited' );
    is( scalar $r->header('Content-Length'), undef, 'with NO length - a live transcode has none' );
    is( scalar @Slim::Web::HTTP::STREAMS, 1, 'the socket is handed to LMS\'s streaming machinery' );
    like_( $Slim::Web::HTTP::STREAMS[0]{headers}, qr{^HTTP/1\.1 200 OK\r\n}, 'with a status line that has a code in it' );
    is( scalar @{ $p->chunks }, 0, 'a FIRST connection flushes anything queued from an older stream' );
    is( $p->pbStreamSeq, $seq, 'the connection is this track\'s' );
    is( $p->pbReplay, undef, 'and starts on the live stream' );
}

sub like_ { my ( $s, $re, $n ) = @_; ok( defined $s && $s =~ $re, $n ) }

# LMS's stream delivers the opening, which the player keeps. It starts with
# `fLaC` because it IS a FLAC stream: one that does not is held until its first
# frame is found (Player::_opening).
{
    @Slim::Player::Client::QUEUE = ( \"fLaC456789" );
    $p->nextChunk( 65536, undef );
    is( $p->pbCacheFor($seq)->{total}, 10, 'the opening is kept as it goes out' );
}

# ---------------------------------------------------------------------------
print "-- the Hub's second GET --\n";

{
    my $old = $p->streamingsocket;
    @{ $p->chunks } = ( \'the-rest-of-a-split-chunk' );

    my ( $r, $s ) = request("/platin/$tok/$seq.flac");
    is( $r->code, 200, 'a second GET for the same track is served' );
    is( $p->pbReplay, 0, 'from the TOP of what was sent' );
    is( scalar @{ $p->chunks }, 1, 'and the queue is NOT flushed - it holds the rest of this track' );
    ok( scalar( grep { defined $old && $_ == $old } @Slim::Web::HTTP::CLOSED ), 'the previous connection is closed' );
}

{
    my ($r) = request( "/platin/$tok/$seq.flac", Range => 'bytes=4-' );
    is( $r->code, 206, 'a range inside what is held is 206' );
    is( $r->header('Content-Range'), 'bytes 4-9/*', 'from where it asked to what has been sent' );
    is( $p->pbReplay, 4, 'and the connection starts there' );
}

{
    my ($r) = request( "/platin/$tok/$seq.flac", Range => 'bytes=0-' );
    is( $r->code, 200, 'a range from 0 is simply the whole track again' );
    is( $p->pbReplay, 0, 'from the top' );
}

{
    my ($r) = request( "/platin/$tok/$seq.flac", Range => 'bytes=10-' );
    is( $r->code, 200, 'a range exactly where the last connection stopped continues the live stream' );
    is( $p->pbReplay, undef, 'with nothing replayed' );
}

{
    my ($r) = request( "/platin/$tok/$seq.flac", Range => 'bytes=99-' );
    is( $r->code, 416, 'a range past what exists is 416' );
}

# ---------------------------------------------------------------------------
print "-- HEAD --\n";

{
    my ( $r, $s ) = request( "/platin/$tok/$seq.flac", method => 'HEAD' );
    seek $s, 0, 0;
    my $wire = do { local $/; <$s> };
    like_( $wire, qr{^HTTP/1\.1 200 OK\r\n}, 'a HEAD gets a status line with a code' );
    ok( $wire !~ /Content-Length/i, 'and NO Content-Length - zero would assert the track is empty' );
    is( scalar @Slim::Web::HTTP::STREAMS, 0, 'and is never handed the stream' );
}

# ---------------------------------------------------------------------------
print "-- an earlier track --\n";

{
    # The short track, fully sent, then the next one armed.
    @Slim::Player::Client::QUEUE = ( \"" );
    $p->nextChunk( 65536, undef );
    ok( $p->pbCacheFor($seq)->{eof}, 'the first track has ended' );

    $p->play( { song => FakeSong->new } );
    my $next = $p->pbLiveSeq;
    ok( $next > $seq, 'the next track is now the live stream' );

    my ($r) = request("/platin/$tok/$seq.flac");
    is( $r->code, 200, 'an earlier track kept whole is still served' );
    is( $p->pbReplay, 0, 'from what was kept' );

    my ($n) = request("/platin/$tok/$next.flac");
    is( $n->code, 200, 'the armed track is served' );
    ok( $p->pbArmedFetched, 'and the Hub fetching it is recorded - half the evidence of a hand-over' );
}

{
    # An earlier track NOT kept whole is gone.
    my $c = $p->pbCacheFor($seq);
    $c->{capped} = 1;
    my ($r) = request("/platin/$tok/$seq.flac");
    is( $r->code, 410, 'an earlier track too long to keep is 410 Gone, never part of it' );
    $c->{capped} = 0;
}

# ---------------------------------------------------------------------------
print "-- what the Hub asked for is traced (A SEEK THE HUB DOES ITSELF) --\n";

sub lastTrace {
    my $what = shift;
    my ($e) = grep { $_->{what} eq $what } reverse @{ Plugins::PlatinBridge::Trace::entries() };
    return $e || { detail => '' };
}

my $OFF = 'DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';

{
    $p->pbTakeovers( {} );
    my ($r) = request( "/platin/$tok/$seq.flac",
        'TimeSeekRange.dlna.org' => 'npt=60.000-', 'getcontentFeatures.dlna.org' => '1' );
    is( $r->code, 200, 'CONTROL: a GET with seek headers is served as before' );
    ok( index( lastTrace('connect')->{detail}, '[TimeSeekRange.dlna.org: npt=60.000-; getcontentFeatures.dlna.org: 1]' ) > 0,
        'its trace entry carries the seek headers the Hub sent' );
    is( $r->header('contentFeatures.dlna.org'), $OFF, 'with the test off, the features are what every build before 0.2.5 sent' );
}

{
    request("/platin/$tok/$seq.flac");
    ok( lastTrace('connect')->{detail} !~ /\[/, 'a plain GET adds nothing to its trace entry' );
}

{
    my ($r) = request( "/platin/$tok/$seq.flac", Range => 'bytes=99-' );
    is( $r->code, 416, 'CONTROL: a byte range past what is held is still 416' );
    ok( index( lastTrace('refused')->{detail}, 'cannot serve from byte 99 [Range: bytes=99-]' ) > 0,
        'and is traced now, with what was asked - a byte seek by the Hub would land here' );
}

{
    Plugins::PlatinBridge::Format::seekOp('10');
    my ($r) = request( "/platin/$tok/$seq.flac", 'getcontentFeatures.dlna.org' => '1' );
    is( $r->header('contentFeatures.dlna.org'), 'DLNA.ORG_OP=10;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000',
        'with the test on, the features say what it is set to' );
    Plugins::PlatinBridge::Format::seekOp(undef);
    ($r) = request( "/platin/$tok/$seq.flac", 'getcontentFeatures.dlna.org' => '1' );
    is( $r->header('contentFeatures.dlna.org'), $OFF, 'and off again, as before' );
}

# ---------------------------------------------------------------------------
print "-- a Hub that will not settle --\n";

{
    my $live = $p->pbLiveSeq;
    $p->pbTakeovers( {} );
    Slim::Utils::Timers::_reset();

    # Each request: was it handed the stream, or answered?
    my ( @streamed, @answered );
    for ( 1 .. 10 ) {
        request("/platin/$tok/$live.flac");
        push @streamed, scalar @Slim::Web::HTTP::STREAMS;
        push @answered, scalar @Slim::Web::HTTP::SENT;
    }

    is( join( '', @streamed ), '1111111100', 'the first 8 re-opens of one track in 4 s are served, the rest are not' );
    is( join( '', @answered ), '0000000000', 'and the rest are NOT answered at once - an immediate refusal is only the next turn of the loop' );

    my @t   = @{ Slim::Utils::Timers::_timers() };
    my $due = @t ? $t[0]{when} - Time::HiRes::time() : -1;
    ok( @t == 2 && $due > 0.8 && $due <= 1.0, 'they are answered a second later' );

    @Slim::Web::HTTP::SENT = ();
    {
        no warnings 'redefine';
        local *FakeSock::connected = sub { 0 };
        Slim::Utils::Timers::_fireNext();
    }
    is( scalar @Slim::Web::HTTP::SENT, 0, 'a connection the Hub has already dropped is not written to' );

    Slim::Utils::Timers::_fireAll();
    is( join( ',', map { $_->{code} } @Slim::Web::HTTP::SENT ), '503', 'one still open is refused with a 503' );
}

# ---------------------------------------------------------------------------
printf "\n%s: %d passed, %d failed\n", ( $fail ? 'FAIL' : 'ok' ), $pass, $fail;
exit( $fail ? 1 : 0 );
