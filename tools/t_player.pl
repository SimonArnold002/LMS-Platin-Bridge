#!/usr/bin/perl
#
# Unit tests for Plugins::PlatinBridge::Player.
#
# The things worth more than the rest put together:
#
#   1. THE ACCEPTANCE RULE. Nothing the Hub reports may ever start LMS playing.
#      Asserted as a PROPERTY over every transport state, power state and wish,
#      so a new branch cannot quietly reintroduce the wake bug.
#
#   2. THE STREAM IS LMS'S, BYTE FOR BYTE - including on the Hub's second GET of
#      a track, which must get the track from the top, header and all.
#
#   3. ONE "NEXT TRACK" REQUEST PER TRACK. A second playerReadyToStream while the
#      next track is still streaming makes LMS open a third and cut the second.
#
#   4. POWER IS MIRRORED, NEVER PLAYED. The Hub coming on switches LMS on
#      WITHOUT resuming.
#
# `ok` TAKES THE ASSERTION NAME OFF THE END: a failed match in list context is
# the EMPTY list, so a name-last `ok` cannot read the label as the condition.

use strict;
use warnings;
use lib '.';

# The stub globals below are driven directly by these tests and set nowhere else.
no warnings 'once';

BEGIN {
    package main;
    use constant DEBUGLOG => 0;
    use constant INFOLOG  => 0;
    use constant WEBUI    => 1;
}

require Plugins::PlatinBridge::Player;
require Plugins::PlatinBridge::Format;

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

# A clock reading to a millisecond.
sub near {
    my ( $got, $want, $n ) = @_;
    if ( defined $got && abs( $got - $want ) < 0.001 ) { $pass++ }
    else { $fail++; print "  FAIL $n\n    got:  " . ( defined $got ? $got : '(undef)' ) . "\n    want: $want\n" }
}

# The second LMS shows: the clock runs on between reports, so the whole second
# is what a display turns over.
sub clk { int( $_[0]->songElapsedSeconds ) }

my $serverPrefs = Slim::Utils::Prefs::preferences('server');

# --- fakes ------------------------------------------------------------------

# Records every call, so a test can assert on what the controller was TOLD
# rather than on the player's own internal state.
{
    package FakeController;
    sub new { bless { calls => [], paused => 0, streamingState => 0, dur => 200, elapsed => 0 }, shift }
    sub _log { my $s = shift; push @{ $s->{calls} }, shift; return }
    sub playerTrackStarted     { $_[0]->_log('playerTrackStarted') }
    sub playerEndOfStream      { $_[0]->_log('playerEndOfStream') }
    sub playerReadyToStream    { $_[0]->_log('playerReadyToStream') }
    sub playerStreamingFailed  { $_[0]->_log('playerStreamingFailed') }
    sub playerStatusHeartbeat  { $_[0]->_log('playerStatusHeartbeat') }
    sub playerStopped          { $_[0]->_log('playerStopped') }
    sub pause                  { $_[0]->_log('pause');  $_[0]->{paused} = 1 }
    sub resume                 { $_[0]->_log('resume'); $_[0]->{paused} = 0 }
    sub stop                   { $_[0]->_log('stop') }
    sub isPaused               { $_[0]->{paused} }
    sub isPlaying              { !$_[0]->{paused} }
    sub isStreaming            { $_[0]->{streamingState} == 1 }
    sub isStreamout            { $_[0]->{streamingState} == 2 }
    sub streamingSong          { $_[0]->{song} }
    sub playingSong            { $_[0]->{song} }
    sub playingSongDuration    { $_[0]->{dur} }
    sub playingSongElapsed     { $_[0]->{elapsed} }
    sub called { my ($s,$w)=@_; return scalar grep { $_ eq $w } @{ $s->{calls} } }
    sub calls  { join ',', @{ $_[0]->{calls} } }
    sub clear  { $_[0]->{calls} = []; return }
}

{
    package FakeUPnP;
    sub new { bless { calls => [], ready => 1, gapless => $_[1] }, shift }
    sub isReady    { $_[0]->{ready} }
    sub canGapless { $_[0]->{gapless} }
    sub volRange   { $_[0]->{range} }
    sub sink       { $_[0]->{sink} }
    sub name       { 'Platin Hub' }
    sub _log { push @{ $_[0]->{calls} }, $_[1]; return }
    sub stop  { my ($s,$cb)=@_; $s->_log('stop');  $cb->() if $cb }
    sub play  { my ($s,$cb)=@_; $s->_log('play');  $cb->( {}, undef ) if $cb }
    sub pause { my ($s,$cb)=@_; $s->_log('pause'); $cb->( {}, undef ) if $cb }
    sub setVolume {
        my ($s,$v,$cb)=@_;
        $s->_log("setVolume:$v");
        if ( $s->{deferVolume} ) { $s->{volCb} = $cb; return }    # the Hub has not answered yet
        $cb->( {}, undef ) if $cb;
    }
    sub setMute { my ($s,$on,$cb)=@_; $s->_log('setMute:' . ( $on ? 1 : 0 )); $cb->( {}, undef ) if $cb }
    sub setURI { my ($s,$u,$d,$cb)=@_; $s->{lastDidl} = $d; $s->_log("setURI:$u"); $cb->( {}, undef ) if $cb }
    sub setNextURI {
        my ($s,$u,$d,$cb)=@_;
        $s->{lastNextDidl} = $d;
        $s->_log("setNextURI:$u");
        my $err = $s->{refuseNext};
        $cb->( ( $err ? undef : {} ), $err ) if $cb;
    }
    # The poll's three reads. {down} answers each with an error, as a Hub that
    # no longer answers at its address does.
    sub transportInfo {
        my ($s,$cb)=@_;
        $s->_log('transportInfo');
        $s->{down} ? $cb->( undef, 'Timed out' ) : $cb->( { CurrentTransportState => $s->{state} || 'STOPPED' }, undef );
    }
    sub getVolume    { my ($s,$cb)=@_; $s->{down} ? $cb->( undef, 'Timed out' ) : $cb->( {}, undef ) }
    sub positionInfo { my ($s,$cb)=@_; $s->{down} ? $cb->( undef, 'Timed out' ) : $cb->( { RelTime => '0:00:00' }, undef ) }
    sub calls { join ',', @{ $_[0]->{calls} } }
    sub called { my ($s,$w)=@_; return scalar grep { $_ eq $w || index($_, "$w:") == 0 } @{ $s->{calls} } }
    sub clear { $_[0]->{calls} = []; return }
}

# The Hub's control port, as the player sees it.
{
    package FakeControl;
    sub new { my ($c,%o)=@_; bless { up => 1, power => 1, source => { ix => 9, name => 'Streaming' }, sets => [], selected => 0, %o }, $c }
    sub isUp        { $_[0]->{up} }
    sub power       { $_[0]->{power} }
    sub source      { $_[0]->{source} }
    sub onStreaming { my $s = $_[0]->{source} or return undef; return lc( $s->{name} ) eq 'streaming' ? 1 : 0 }
    sub setPower    { push @{ $_[0]->{sets} }, $_[1] ? 1 : 0; return }
    sub selectStreaming { $_[0]->{selected}++; return 1 }
}

{
    package FakeTrack;
    sub new { my ($c,%o)=@_; bless {%o}, $c }
    sub id           { $_[0]->{id} }
    sub url          { $_[0]->{url} || 'file:///music/a.flac' }
    sub remote       { $_[0]->{remote} }
    sub title        { 'A Title' }
    sub artistName   { 'An Artist' }
    sub albumname    { 'An Album' }
    sub secs         { exists $_[0]->{secs} ? $_[0]->{secs} : 200 }
    sub samplerate   { exists $_[0]->{samplerate} ? $_[0]->{samplerate} : 44100 }
    sub samplesize   { exists $_[0]->{samplesize} ? $_[0]->{samplesize} : 16 }
    sub channels     { exists $_[0]->{channels}   ? $_[0]->{channels}   : 2 }
    sub coverid      { $_[0]->{coverid} }
}
{
    package FakeSong;
    sub new { my ($c,%o)=@_; bless { fmt => 'flc', %o }, $c }
    sub currentTrack { $_[0]->{track} }
    sub streamformat { $_[0]->{fmt} }
    sub seekdata     { $_[0]->{seek} }
    sub canSeek      { exists $_[0]->{canSeek} ? $_[0]->{canSeek} : 1 }
}

sub song { my %o = @_; FakeSong->new( track => FakeTrack->new( id => ( $o{id} || 555 ), %o ), %o ) }

my $SEQ = 0;

sub mkplayer {
    my %o = @_;
    $SEQ++;
    my $p = Plugins::PlatinBridge::Player->new( "02:aa:bb:cc:dd:" . sprintf( '%02x', $SEQ ) );
    $p->chunks( [] );
    $p->name('Platin Hub');
    $p->controller( FakeController->new );
    $p->pbUPnP( FakeUPnP->new( exists $o{gapless} ? $o{gapless} : 1 ) );
    $p->pbDevice( { ip => '10.0.0.9', name => 'Platin Hub' } );
    $p->pbControl( FakeControl->new( %{ $o{control} || {} } ) ) unless $o{nocontrol};
    $serverPrefs->client($p)->set( 'power', exists $o{power} ? $o{power} : 1 );
    return $p;
}

sub exec_clear { @Slim::Player::Client::EXEC = () }
sub execs      { join ' | ', map { join ' ', map { defined $_ ? $_ : 'undef' } @$_ } @Slim::Player::Client::EXEC }

# A track playing on the Hub: loaded, acknowledged and reported playing.
sub playing {
    my ( $p, %o ) = @_;
    $p->_startTrack( song(%o), $o{fmt} || 'flc' );
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    $p->pbStartedAt( time() - 60 );     # well past the start grace
    $p->controller->clear;
    $p->pbUPnP->clear;
    exec_clear();
    return $p;
}

sub conn {
    # Stream.pm's take-over, as it hands a connection to the player.
    my ( $p, $seq, $replay ) = @_;
    $p->pbStreamOpened( $seq, $replay );
}

sub pull {
    # Read everything a connection gets, the way sendStreamingResponse does,
    # until the empty chunk that closes it.
    my ( $p, $max ) = @_;
    my $out = '';
    for ( 1 .. 1000 ) {
        my $r = $p->nextChunk( $max || 65536, undef );
        last unless defined $r;
        last unless length $$r;
        $out .= $$r;
    }
    return $out;
}

# ---------------------------------------------------------------------------
print "-- the acceptance rule: NOTHING the Hub says starts LMS --\n";

{
    my @states = qw( STOPPED NO_MEDIA_PRESENT TRANSITIONING PAUSED_PLAYBACK PLAYING RECORDING CUSTOM UNKNOWN );

    my $started = 0;

    for my $state (@states) {
        for my $wanted (qw( stop pause play )) {
            for my $power ( 0, 1, undef ) {
                for my $stream ( 0, 1, 2, 3 ) {
                  for my $hubPaused ( 0, 1 ) {
                    my $p = mkplayer( control => { power => $power } );
                    $p->pbWanted($wanted);
                    $p->pbHubPaused($hubPaused);
                    $p->pbStarted(1);
                    $p->pbStartedAt( time() - 60 );
                    $p->pbLastPlayPos(195);
                    $p->controller->{streamingState} = $stream;
                    $p->controller->clear;
                    exec_clear();

                    $p->_onTransport( { CurrentTransportState => $state } ) for 1 .. 3;

                    # A "resume" is only legitimate when the track is paused, the Hub
                    # HAD paused, and now reports PLAYING - the Hub's own play button
                    # on a paused track.
                    my $legit = ( $state eq 'PLAYING' && $wanted eq 'pause' && $hubPaused );

                    $started++ if $p->controller->called('resume') && !$legit;
                    $started++ if $p->controller->called('playerReadyToStream');
                    $started++ if $p->pbUPnP->called('play') || $p->pbUPnP->called('setURI');
                    $started++ if grep { $_->[0] =~ /^(?:play|playlist|time|power)$/ } @Slim::Player::Client::EXEC;
                  }
                }
            }
        }
    }

    is( $started, 0, 'no transport state from the Hub ever starts, advances or powers LMS' );
}

{
    # The shape of the old bug: the Hub switched off mid-track reports STOPPED and
    # then PAUSED_PLAYBACK. With it OFF, a STOPPED is no opinion.
    my $p = playing( mkplayer( control => { power => 0 } ) );
    $p->_onTransport( { CurrentTransportState => 'STOPPED' } ) for 1 .. 3;
    is( $p->controller->calls, '', 'a STOPPED from a switched-off Hub tells the controller NOTHING' );
    is( execs(), '', 'and asks LMS for nothing' );
}

{
    my $p = mkplayer();
    $p->pbWanted('play');
    $p->pbStarted(1);
    $p->controller->clear;
    $p->pbUPnP->{ready} = 0;
    $p->_poll;
    is( $p->controller->calls, '', 'an unreachable Hub produces no controller call at all' );
}

# The Hub-initiated transitions that ARE honoured, so the assertions above are not
# passing merely because nothing is ever honoured.
{
    my $p = playing( mkplayer() );
    $p->_onTransport( { CurrentTransportState => 'PAUSED_PLAYBACK' } );
    ok( $p->controller->called('pause'), 'pause pressed on the Hub DOES pause LMS' );
    is( $p->pbWanted, 'pause', 'and is recorded as what we now want' );
}

{
    # A Hub that is OFF reports PAUSED_PLAYBACK. A track LMS is still loading must
    # not be paused by it.
    my $p = mkplayer();
    $p->_startTrack( song(), 'flc' );
    $p->controller->clear;
    $p->pbPlayAck(0);
    $p->_onTransport( { CurrentTransportState => 'PAUSED_PLAYBACK' } );
    is( $p->controller->called('pause'), 0, 'a PAUSED report before the track has started pauses nothing' );
}

{
    my $p = playing( mkplayer() );
    $p->pbWanted('pause');
    $p->pbHubPaused(1);
    $p->controller->{paused} = 1;
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    ok( $p->controller->called('resume'), 'play pressed on the Hub resumes a player LMS had paused' );
}

{
    my $p = playing( mkplayer() );
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    ok( !$p->controller->called('resume'), 'a PLAYING report does not resume a player that was not paused' );
}

# ---------------------------------------------------------------------------
print "-- pause and play at the Hub's remote --\n";

# What LMS does after the poll reports the Hub paused: _Pause fades the volume
# and, when the fade is done, calls the player's pause(). The fake controller's
# pause() only records the call, so the test makes the player call itself.
sub lmsPauses { my $p = shift; $p->pause; }

{
    # PAUSE ON THE REMOTE, THEN PLAY. The old path sent LMS's pause back to the
    # Hub up to ~1.5 s after the press: a play pressed in that time was paused
    # again.
    my $p = playing( mkplayer() );
    $p->_onTransport( { CurrentTransportState => 'PAUSED_PLAYBACK' } );
    ok( $p->controller->called('pause'), 'pause on the remote pauses LMS' );

    lmsPauses($p);
    is( $p->pbUPnP->called('pause'), 0, 'and LMS\'s pause is NOT sent back to a Hub that is already paused' );

    $p->controller->{resumeTime} = 61;
    $p->controller->clear;
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    ok( $p->controller->called('resume'), 'play on the remote resumes LMS' );
    ok( !exists $p->controller->{resumeTime},
        'with no resume point, so LMS changes state instead of RELOADING the track under a Hub already playing' );

    # LMS's _Resume then calls the player's resume().
    $p->resume;
    is( $p->pbUPnP->called('play'), 0, 'and no Play is sent to a Hub already playing' );
    is( $p->pbUPnP->called('setURI') + $p->pbUPnP->called('stop'), 0, 'nor is anything re-loaded' );
}

{
    # Pause from LMS: sent once.
    my $p = playing( mkplayer() );
    $p->pause;
    is( $p->pbUPnP->called('pause'), 1, 'CONTROL: a pause from LMS is sent to the Hub' );
}

{
    # THE PAUSE FIGHT. The Hub answered 500 to every Pause while stuck
    # (2026-10-25) and kept reporting PLAYING; reading that as "play pressed on
    # the Hub" bounced LMS's pause button straight back to play.
    my $p = playing( mkplayer() );
    $p->pause;
    $p->controller->{paused} = 1;
    $p->controller->clear;

    $p->_onTransport( { CurrentTransportState => 'PLAYING' } ) for 1 .. 5;
    is( $p->controller->called('resume'), 0, 'a Hub that has not acted on our Pause does NOT resume LMS' );
    is( $p->pbUPnP->called('pause'), 1, 'and is not asked again at once' );

    $p->pbPauseSentAt( $p->pbPauseSentAt - 3 );
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    is( $p->pbUPnP->called('pause'), 2, 'after 2 s it is asked again' );

    for ( 1 .. 6 ) {
        $p->pbPauseSentAt( $p->pbPauseSentAt - 3 );
        $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    }
    is( $p->pbUPnP->called('pause'), Plugins::PlatinBridge::Player::PAUSE_TRIES(), 'but only so many times in all' );
    is( $p->controller->called('resume'), 0, 'and LMS stays paused throughout' );
}

{
    # Our Pause taken, then play on the remote.
    my $p = playing( mkplayer() );
    $p->pause;
    $p->controller->{paused} = 1;
    $p->_onTransport( { CurrentTransportState => 'PAUSED_PLAYBACK' } );
    $p->controller->clear;
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    ok( $p->controller->called('resume'), 'a Hub that DID pause for LMS, then plays, resumes LMS' );
}

{
    # A resume from LMS clears the record of the Hub's pause: the next pause starts
    # from scratch.
    my $p = playing( mkplayer() );
    $p->_onTransport( { CurrentTransportState => 'PAUSED_PLAYBACK' } );
    lmsPauses($p);
    $p->resume;
    ok( !$p->pbHubPaused, 'a resume forgets that the Hub had paused' );
    ok( $p->pbUPnP->called('play'), 'CONTROL: a resume from LMS while the Hub is paused is a Play' );
}

{
    # A Hub paused on the old track, a new track loaded, and pause pressed in LMS
    # before the next poll: the old PAUSED must not stand in for the new one.
    my $p = playing( mkplayer() );
    $p->_onTransport( { CurrentTransportState => 'PAUSED_PLAYBACK' } );
    lmsPauses($p);
    $p->_startTrack( song( id => 557 ), 'flc' );
    $p->pbUPnP->clear;
    $p->pause;
    is( $p->pbUPnP->called('pause'), 1, 'a pause right after a load is sent - the last PAUSED was the old track\'s' );

    $p->controller->clear;
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    is( $p->controller->called('resume'), 0, 'and the new track starting does not resume LMS' );
}

# ---------------------------------------------------------------------------
print "-- STOPPED: only ever a stop, and only where that is known to be right --\n";

{
    # The natural end of the queue: the Hub played the last track out, LMS has
    # nothing left to stream.
    my $p = playing( mkplayer() );
    $p->pbLastPlayPos(195);
    $p->controller->{streamingState} = 0;

    $p->_onTransport( { CurrentTransportState => 'STOPPED' } );
    is( $p->controller->called('playerStopped'), 0, 'ONE stray STOPPED is not believed' );

    $p->_onTransport( { CurrentTransportState => 'STOPPED' } );
    is( $p->controller->called('playerStopped'), 1, 'the second, at the end of the last track, is the end: LMS is told the player stopped' );
    is( $p->pbWanted, 'stop', 'and the player stops wanting to play' );
}

{
    # THE TRAP: in TRACKWAIT LMS answers playerStopped with _PlayIfReady - it would
    # START the next track. At the end of a track with LMS still finding the next
    # one, the player must wait instead.
    my $p = playing( mkplayer() );
    $p->pbLastPlayPos(195);
    $p->controller->{streamingState} = 3;

    $p->_onTransport( { CurrentTransportState => 'STOPPED' } ) for 1 .. 3;
    is( $p->controller->called('playerStopped'), 0, 'with LMS in TRACKWAIT the end is NOT reported as a stop' );
    ok( $p->pbHubEnded, 'the player remembers the Hub has run out' );

    $p->pbUPnP->clear;
    $p->play( { song => song( id => 556 ) } );
    ok( $p->pbUPnP->called('setURI'), 'so the track LMS then hands over is STARTED' );
    is( $p->pbUPnP->called('setNextURI'), 0, 'not armed as a next uri the stopped Hub would never use' );
}

{
    my $p = playing( mkplayer() );
    $p->pbLastPlayPos(60);
    $p->_onTransport( { CurrentTransportState => 'STOPPED' } ) for 1 .. 2;
    is( execs(), 'stop', 'stopped part way through with the Hub ON: someone pressed stop at the Hub - LMS stops' );
    is( $p->controller->called('playerStopped'), 0, 'via an ordinary stop, not the end-of-queue path' );
}

{
    my $p = playing( mkplayer( nocontrol => 1 ) );
    $p->pbLastPlayPos(60);
    $p->_onTransport( { CurrentTransportState => 'STOPPED' } ) for 1 .. 3;
    is( execs(), '', 'with no control link the power cannot be read: a mid-track stop is no opinion' );
}

{
    my $p = playing( mkplayer( control => { up => 0 } ) );
    $p->pbLastPlayPos(60);
    $p->_onTransport( { CurrentTransportState => 'STOPPED' } ) for 1 .. 3;
    is( execs(), '', 'nor with the control link down' );
}

{
    my $p = playing( mkplayer() );
    $p->pbStartedAt( time() );
    $p->pbLastPlayPos(1);
    $p->_onTransport( { CurrentTransportState => 'STOPPED' } ) for 1 .. 3;
    is( execs() . $p->controller->calls, '', 'a stop just after a load is the Hub changing tracks' );
}

{
    my $p = mkplayer();
    $p->pbWanted('stop');
    $p->pbStarted(1);
    $p->_onTransport( { CurrentTransportState => 'STOPPED' } ) for 1 .. 3;
    is( execs() . $p->controller->calls, '', 'a stop LMS asked for is not answered with another' );
}

{
    # The track position must come from the last report WHILE PLAYING: after the
    # first STOPPED poll the Hub's clock reads 0.
    my $p = playing( mkplayer() );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { RelTime => '0:03:16' } );
    $p->_onTransport( { CurrentTransportState => 'STOPPED' } );
    $p->_onPosition( { RelTime => '0:00:00' } );
    $p->_onTransport( { CurrentTransportState => 'STOPPED' } );
    is( $p->controller->called('playerStopped'), 1, 'the end is judged on the last position the Hub reported while playing' );
}

# ---------------------------------------------------------------------------
print "-- the stream is LMS's, byte for byte --\n";

{
    my $p = playing( mkplayer() );
    my $seq = $p->pbLiveSeq;
    my @chunks = ( "fLaC\x00\x00\x00\x22header", 'frame1-' x 10, 'frame2-' x 10 );

    conn( $p, $seq, undef );
    @Slim::Player::Client::QUEUE = map { my $c = $_; \$c } @chunks;
    $Slim::Player::Client::NEXT_CHUNK = undef;

    my $out = '';
    for (1 .. 3) { my $r = $p->nextChunk( 65536, undef ); $out .= $$r }

    is( $out, join( '', @chunks ), 'what LMS produced goes to the Hub exactly as it came' );
    is( $p->pbCacheFor($seq)->{buf}, $out, 'and the opening is kept' );
}

{
    # THE HUB'S SECOND GET. The probe read the opening and closed; the real
    # request must get the track from the top, or there is no header.
    my $p = playing( mkplayer(), fmt => 'wav' );
    my $seq = $p->pbLiveSeq;

    conn( $p, $seq, undef );
    @Slim::Player::Client::QUEUE = ( \"RIFF....WAVEfmt header", \"aaaaaaaa" );
    my $probe = '';
    $probe .= ${ $p->nextChunk( 65536, undef ) } for 1 .. 2;

    # Second connection, from byte 0. LMS's stream carries on with the rest.
    conn( $p, $seq, 0 );
    @Slim::Player::Client::QUEUE = ( \"bbbbbbbb", \"" );

    my $second = pull($p);

    is( $second, "RIFF....WAVEfmt header" . "aaaaaaaa" . "bbbbbbbb",
        'the re-opened track starts at the top, header and all, then continues - nothing lost, nothing doubled' );
}

{
    # A RANGE request is served from where it asked within what is held.
    my $p = playing( mkplayer(), fmt => 'mp3' );
    my $seq = $p->pbLiveSeq;
    conn( $p, $seq, undef );
    @Slim::Player::Client::QUEUE = ( \"0123456789" );
    $p->nextChunk( 65536, undef );

    conn( $p, $seq, 4 );
    @Slim::Player::Client::QUEUE = ( \"" );
    is( pull($p), '456789', 'a re-open from byte 4 gets byte 4 onwards' );
}

{
    # A SHORT TRACK, fully sent before the second GET (the 9 s opener the UPnP
    # Bridge answered with 410 Gone until 3.4.10.2).
    my $p = playing( mkplayer(), fmt => 'mp3' );
    my $seq = $p->pbLiveSeq;

    conn( $p, $seq, undef );
    @Slim::Player::Client::QUEUE = ( \"short-track", \"" );
    my $first = pull($p);
    is( $p->controller->called('playerEndOfStream'), 1, 'its end is reported once' );

    $p->controller->clear;
    conn( $p, $seq, 0 );

    # LMS's source has moved on - whatever it holds now is not this track's.
    @Slim::Player::Client::QUEUE = ( \"NOT-THIS-TRACK", \"" );

    is( pull($p), 'short-track', 'a second GET after the end still gets the whole track - and only that track' );
    is( scalar @Slim::Player::Client::QUEUE, 2, 'LMS\'s source is not read for a track that has ended' );
    is( $p->controller->calls, '', 'and its end is NOT reported again - LMS has moved on' );
    @Slim::Player::Client::QUEUE = ();
}

{
    # An EARLIER track's replay never draws on LMS's stream, which now belongs to
    # the next one.
    my $p = playing( mkplayer(), fmt => 'mp3' );
    my $first = $p->pbLiveSeq;
    conn( $p, $first, undef );
    @Slim::Player::Client::QUEUE = ( \"track-one", \"" );
    pull($p);

    $p->play( { song => song( id => 556 ) } );
    ok( $p->pbLiveSeq > $first, 'the next track becomes the live stream when LMS hands it over' );

    conn( $p, $first, 0 );
    @Slim::Player::Client::QUEUE = ( \"TRACK-TWO-BYTES" );
    is( pull($p), 'track-one', 'a replay of the earlier track is the earlier track only' );
    is( scalar @Slim::Player::Client::QUEUE, 1, 'and LMS\'s stream for the next track is not touched' );
    @Slim::Player::Client::QUEUE = ();
}

{
    # Past the kept opening, a re-open has a gap it cannot mend - and says so.
    my $p = playing( mkplayer(), fmt => 'mp3' );
    my $seq = $p->pbLiveSeq;
    conn( $p, $seq, undef );
    my $big = 'x' x ( Plugins::PlatinBridge::Player::HEAD_MAX() + 10 );
    @Slim::Player::Client::QUEUE = ( \"head", \$big );
    $p->nextChunk( 65536, undef ) for 1 .. 2;
    my $c = $p->pbCacheFor($seq);
    ok( $c->{capped}, 'a track larger than the kept opening is marked capped' );
    is( $c->{buf}, 'head', 'and the unbroken OPENING is what is kept' );

    conn( $p, $seq, 0 );
    @Slim::Player::Client::QUEUE = ( \"live" );
    my $out = '';
    $out .= ${ $p->nextChunk( 65536, undef ) } for 1 .. 2;
    is( $out, 'headlive', 'a re-open gets the opening, then the live stream' );
    ok( $p->pbGapNoted, 'and the gap between them is noted' );
}

{
    my $p = playing( mkplayer(), fmt => 'mp3' );
    my $seq = $p->pbLiveSeq;
    conn( $p, $seq, undef );
    @Slim::Player::Client::QUEUE = ( \"opening" );
    $p->nextChunk( 65536, undef );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { RelTime => '0:00:25' } );
    is( $p->pbCacheFor($seq)->{buf}, '', 'once the Hub is 20 s into a track its opening is let go' );
}

# ---------------------------------------------------------------------------
print "-- a seeked stream is given the header it lost --\n";

# A real 24/96 FLAC cut part way through a frame, as a byte seek cuts it - see
# t_format.pl for where the fixture comes from. Its first whole frame is 11203
# bytes in (libFLAC's own `flac --analyze`).
my $CUT  = do { open my $fh, '<:raw', 'fixtures/flac_24_96000_cut.bin' or die $!; local $/; <$fh> };
my $SKIP = 41203 - 30000;
# Started at 44 s of a 200 s track: the header states the 156 s that follow.
my $HDR  = Plugins::PlatinBridge::Format::flacHeader( 96000, 2, 24, 156 * 96000 );

sub chunksOf { my ( $b, $n ) = @_; my @c; push @c, substr( $b, $_ * $n, $n ) for 0 .. int( ( length($b) - 1 ) / $n ); return map { my $x = $_; \$x } @c }

{
    # The track's own metadata says 16/44.1 on purpose: the frame's word wins.
    my $p = playing( mkplayer(), seek => { timeOffset => 44 }, samplerate => 44100, samplesize => 16 );
    my $seq = $p->pbLiveSeq;
    conn( $p, $seq, undef );
    @Slim::Player::Client::QUEUE = ( chunksOf( $CUT, 4096 ), \"" );

    my $first = $p->nextChunk( 65536, undef );
    is( substr( $$first, 0, 42 ), $HDR, 'a seeked FLAC goes out behind a STREAMINFO made from its own first frame' );
    is( substr( $$first, 42, 6 ), substr( $CUT, $SKIP, 6 ), 'followed by that frame - the partial one before it is dropped' );

    my $all = $$first . pull($p);
    is( $all, $HDR . substr( $CUT, $SKIP ), 'and then the rest of the stream, byte for byte' );
    is( $p->pbCacheFor($seq)->{buf}, $all, 'the opening kept for a second GET is the REPAIRED one' );
    is( $p->pbWireFor($seq), 'FLAC 96000 Hz / 24 bit / 2 ch, length 2:36 (header synthesised for a seeked stream)',
        'and the readout says so - with the length the stream announces' );

    conn( $p, $seq, 0 );
    is( substr( pull($p), 0, 4 ), 'fLaC', 'the Hub\'s second GET gets the header too' );
}

{
    # The frame is not in what LMS has read so far: nothing goes out yet, and
    # nothing is lost.
    my $p = playing( mkplayer(), seek => { timeOffset => 44 } );
    my $seq = $p->pbLiveSeq;
    conn( $p, $seq, undef );
    my @c = chunksOf( $CUT, 4096 );
    @Slim::Player::Client::QUEUE = ( shift @c );
    $Slim::Player::Client::NEXT_CHUNK = undef;

    is( $p->nextChunk( 65536, undef ), undef, 'a frame not yet found: nothing to send yet' );
    is( $p->pbCacheFor($seq)->{total}, 0, 'and nothing counted as sent' );

    @Slim::Player::Client::QUEUE = ( @c, \"" );
    is( pull($p), $HDR . substr( $CUT, $SKIP ), 'when the rest arrives the stream is whole' );
}

{
    # A header that STATES its length (a file's own, LMS's native FLAC).
    my $p = playing( mkplayer() );
    my $seq = $p->pbLiveSeq;
    my $real = Plugins::PlatinBridge::Format::flacHeader( 44100, 2, 16, 9_000_000 ) . substr( $CUT, $SKIP );
    conn( $p, $seq, undef );
    @Slim::Player::Client::QUEUE = ( chunksOf( $real, 8192 ), \"" );
    is( pull($p), $real, 'CONTROL: a FLAC stream whose header states its length is sent untouched' );
    is( $p->pbWireFor($seq), 'FLAC 44100 Hz / 16 bit / 2 ch, length 3:24', 'and read for what it is' );
}

{
    # A header that says "length unknown" - SqueezeDSP's flac, writing to a pipe.
    # The Hub takes the length from the stream (with the UPnP Bridge, which writes
    # it, it showed; with 0 it does not).
    my $p = playing( mkplayer() );
    my $seq = $p->pbLiveSeq;
    my $body  = substr( $CUT, $SKIP );
    my $piped = Plugins::PlatinBridge::Format::flacHeader( 44100, 2, 16 ) . $body;
    conn( $p, $seq, undef );
    @Slim::Player::Client::QUEUE = ( chunksOf( $piped, 8192 ), \"" );
    my $out = pull($p);
    is( Plugins::PlatinBridge::Format::flacTotalSamples($out), 200 * 44100, 'a FLAC header that says "unknown" is given the track\'s length' );
    is( substr( $out, 26 ), substr( $piped, 26 ), 'and nothing else in the stream changes' );
    is( substr( $out, 0, 21 ), substr( $piped, 0, 21 ), 'not even the rest of the header' );
    is( $p->pbWireFor($seq), 'FLAC 44100 Hz / 16 bit / 2 ch, length 3:20 (length written in here)', 'and the readout says so' );
}

{
    # LMS does not know the length (a radio stream): nothing is made up.
    my $p = playing( mkplayer(), secs => 0 );
    my $seq = $p->pbLiveSeq;
    my $piped = Plugins::PlatinBridge::Format::flacHeader( 44100, 2, 16 ) . substr( $CUT, $SKIP );
    conn( $p, $seq, undef );
    @Slim::Player::Client::QUEUE = ( chunksOf( $piped, 8192 ), \"" );
    is( pull($p), $piped, 'with no length known, a header that says "unknown" is left saying so' );
}

{
    my $p = playing( mkplayer(), fmt => 'wav', seek => { timeOffset => 30 }, samplerate => 48000, samplesize => 24 );
    my $seq = $p->pbLiveSeq;
    my $pcm = "\x01\x02\x03" x 400;
    conn( $p, $seq, undef );
    @Slim::Player::Client::QUEUE = ( \$pcm, \"" );
    is( pull($p), Plugins::PlatinBridge::Format::wavHeader( 48000, 2, 24, 170 * 48000 ) . $pcm,
        'a seeked WAV goes out behind a RIFF header from the track\'s own format, sized for the 170 s that follow' );
}

{
    my $p = playing( mkplayer(), fmt => 'mp3' );
    my $seq = $p->pbLiveSeq;
    conn( $p, $seq, undef );
    @Slim::Player::Client::QUEUE = ( \"\x01\x02\x03\x04\x05", \"" );
    is( pull($p), "\x01\x02\x03\x04\x05", 'an MP3 stream is never given a header' );
}

{
    # The source ends before any frame turns up (a stream that short is not
    # FLAC worth the name, but it must still END).
    my $p = playing( mkplayer(), seek => { timeOffset => 10 } );
    my $seq = $p->pbLiveSeq;
    conn( $p, $seq, undef );
    @Slim::Player::Client::QUEUE = ( \( 'x' x 300 ), \"" );
    my $r = $p->nextChunk( 65536, undef );
    is( $$r, Plugins::PlatinBridge::Format::flacHeader( 44100, 2, 16, 190 * 44100 ) . ( 'x' x 300 ),
        'what there was goes out, behind a header from what LMS knows of the track' );
    is( $p->controller->called('playerEndOfStream'), 0, 'the end is not reported with it' );
    my $end = $p->nextChunk( 65536, undef );
    is( length $$end, 0, 'the next read is the end' );
    is( $p->controller->called('playerEndOfStream'), 1, 'reported once' );
}

# ---------------------------------------------------------------------------
print "-- one request for the next track per track --\n";

{
    my $p = playing( mkplayer(), fmt => 'mp3' );
    conn( $p, $p->pbLiveSeq, undef );
    @Slim::Player::Client::QUEUE = ( \"all", \"" );
    pull($p);

    is( $p->controller->called('playerEndOfStream'), 1, 'the end of the stream is reported' );
    is( $p->controller->called('playerReadyToStream'), 1, 'and LMS is asked for the next track - ONCE' );
}

{
    my $p = playing( mkplayer() );
    my $first = $p->pbURL;
    $p->play( { song => song( id => 556 ) } );
    my $armed = $p->pbArmedURL;

    ok( $armed && $armed ne $first, 'the next track is armed on the Hub, with a url of its own' );
    ok( $p->pbUPnP->called("setNextURI:$armed"), 'via SetNextAVTransportURI' );
    is( $p->pbURL, $first, 'and the playing track is left alone' );

    # THE HAND-OVER ASKS FOR NOTHING. In PLAYING/STREAMING a ReadyToStream is
    # _NextIfMore, which would open a THIRD track and cut this one short.
    $p->controller->clear;
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:00:02' } );
    is( $p->controller->calls, 'playerTrackStarted', 'the hand-over tells LMS the track started - and NOTHING else' );
    is( $p->pbURL, $armed, 'the armed url becomes the current one' );
    is( $p->pbArmedURL, undef, 'the arm is consumed' );
}

{
    # THE VETO. A spurious advance is the worst failure here.
    my $p = playing( mkplayer() );
    $p->play( { song => song( id => 556 ) } );
    my $armed = $p->pbArmedURL;
    $p->controller->clear;

    $p->_onPosition( { TrackURI => 'http://elsewhere/other.flac', RelTime => '0:00:03' } );
    is( $p->controller->calls, '', 'an unrelated uri is not a hand-over' );
    $p->_onPosition( { TrackURI => undef, RelTime => '0:00:04' } );
    is( $p->controller->calls, '', 'nor a missing one' );
    is( $p->pbArmedURL, $armed, 'and the arm still stands' );
}

# ---------------------------------------------------------------------------
print "-- a hand-over is a track the Hub is PLAYING --\n";

{
    # THE SEQUENCE OF 2026-10-25 10:44:34. The Hub leaves Streaming; LMS pauses;
    # the Hub moves its transport on to the armed uri and stays PAUSED. Taken for
    # a hand-over, LMS un-paused itself over a Hub that stayed paused.
    my $p = playing( mkplayer() );
    my $first = $p->pbURL;
    $p->play( { song => song( id => 556 ) } );
    my $armed = $p->pbArmedURL;
    exec_clear();
    $p->controller->clear;

    $p->_onHubSource( { ix => 0, name => 'Line' }, { ix => 9, name => 'Streaming' } );
    is( execs(), 'pause 1', 'the Hub leaving Streaming pauses LMS' );

    $p->_onTransport( { CurrentTransportState => 'PAUSED_PLAYBACK' } );
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:00:00' } );
    is( $p->controller->called('playerTrackStarted'), 0, 'the Hub moving on to the armed uri while it is paused is NOT a hand-over' );
    is( $p->pbURL, $first, 'the track LMS paused stays the current one' );
    is( $p->pbArmedURL, undef, 'and the arm is dropped - the Hub has lost its own playback' );

    # Back on Streaming, play on the remote: the Hub plays whatever it holds, and
    # LMS starts the paused track again where it was.
    $p->_onHubSource( { ix => 9, name => 'Streaming' }, { ix => 0, name => 'Line' } );
    $p->controller->{paused} = 1;
    $p->controller->{elapsed} = 120;
    $p->controller->{song} = song();
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:00:01' } );
    is( $p->controller->called('playerTrackStarted'), 0, 'and the Hub playing that uri afterwards is not one either' );
    ok( $p->controller->called('resume'), 'play on the Hub resumes LMS' );
    $p->resume;    # LMS's _Resume calls the player's resume()
    Slim::Utils::Timers::_fireAll();
    is( execs(), 'pause 1 | time 120', 'which starts the paused track again where it was' );
}

{
    my $p = playing( mkplayer() );
    $p->play( { song => song( id => 556 ) } );
    my $armed = $p->pbArmedURL;
    $p->controller->clear;

    $p->_onTransport( { CurrentTransportState => 'PAUSED_PLAYBACK' } );
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:00:00' } );
    is( $p->controller->called('playerTrackStarted'), 0, 'a PAUSED Hub reporting the armed uri is not a hand-over yet' );
    is( $p->pbArmedURL, $armed, 'the arm stands' );

    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:00:01' } );
    is( $p->controller->called('playerTrackStarted'), 1, 'CONTROL: once it plays, it is' );
}

{
    my $p = playing( mkplayer() );
    $p->play( { song => song( id => 556 ) } );
    $p->_onHubPower( 0, 0, 0 );
    is( $p->pbArmedURL, undef, 'switching the Hub off drops the arm too' );
}

{
    # LMS can arm a track AFTER the session was lost (its stream of the next one
    # ends while the player sits paused). The Hub reporting that uri is still not
    # a hand-over: LMS is paused, and its next play starts the paused track again.
    my $p = playing( mkplayer() );
    $p->_onHubSource( { ix => 0, name => 'Line' }, { ix => 9, name => 'Streaming' } );
    $p->play( { song => song( id => 557 ) } );
    my $armed = $p->pbArmedURL;
    ok( $armed, 'CONTROL: LMS armed the next track while the session was lost' );
    $p->controller->clear;
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:00:01' } );
    is( $p->controller->called('playerTrackStarted'), 0, 'and the Hub reporting it while the session is lost is not a hand-over' );
}

# ---------------------------------------------------------------------------
print "-- the hand-over when the Hub's TrackURI lags --\n";

{
    my $p = playing( mkplayer() );
    my $first = $p->pbURL;
    $p->play( { song => song( id => 556 ) } );
    my $seq = $p->pbArmedSeq;

    conn( $p, $seq, undef );          # the Hub FETCHES the armed track
    ok( $p->pbArmedFetched, 'the Hub fetching the armed url is recorded' );

    $p->pbHubState('PLAYING');
    $p->controller->clear;
    $p->_onPosition( { TrackURI => $first, RelTime => '0:03:18' } );
    is( $p->controller->calls, '', 'still the old uri near its end: nothing yet' );

    $p->_onPosition( { TrackURI => $first, RelTime => '0:00:01' } );
    is( $p->controller->calls, 'playerTrackStarted',
        'the clock back at the start, at the end of the old track, after the fetch: that is the change' );
}

{
    # CONTROLS - each condition alone is not enough.
    my $p = playing( mkplayer() );
    my $first = $p->pbURL;
    $p->play( { song => song( id => 556 ) } );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $first, RelTime => '0:03:18' } );
    $p->controller->clear;
    $p->_onPosition( { TrackURI => $first, RelTime => '0:00:01' } );
    is( $p->controller->calls, '', 'a clock back at the start WITHOUT the Hub having fetched the armed url is not a change' );
}

{
    my $p = playing( mkplayer() );
    my $first = $p->pbURL;
    $p->play( { song => song( id => 556 ) } );
    conn( $p, $p->pbArmedSeq, undef );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $first, RelTime => '0:01:00' } );
    $p->controller->clear;
    $p->_onPosition( { TrackURI => $first, RelTime => '0:00:01' } );
    is( $p->controller->calls, '', 'nor a clock back at the start in the MIDDLE of the old track' );
}

# ---------------------------------------------------------------------------
print "-- a next track the Hub will not take --\n";

{
    my $p = playing( mkplayer() );
    $p->pbUPnP->{refuseNext} = 'upnp701';
    $p->play( { song => song( id => 556 ) } );

    is( $p->controller->called('playerStreamingFailed'), 0, 'a refused pre-arm is not a streaming failure' );
    is( $p->pbArmedURL, undef, 'the arm is dropped' );
    ok( $p->pbHeld, 'and the track is held' );

    $p->pbUPnP->clear;
    $p->pbLastPlayPos(195);
    $p->controller->{streamingState} = 1;
    $p->_onTransport( { CurrentTransportState => 'STOPPED' } ) for 1 .. 2;
    ok( $p->pbUPnP->called('setURI'), 'and started when the Hub reaches the end of this one' );
}

{
    my $p = playing( mkplayer( gapless => 0 ) );
    $p->play( { song => song( id => 556 ) } );
    is( $p->pbUPnP->called('setNextURI'), 0, 'a Hub that lists no SetNextAVTransportURI is never sent one' );
    ok( $p->pbHeld, 'the next track waits for the end of this one instead' );
}

# ---------------------------------------------------------------------------
print "-- a playlist edit takes the armed track back --\n";

{
    my $p = playing( mkplayer() );
    my $playing = $p->pbPlayingSeq;
    $p->play( { song => song( id => 556 ) } );
    my $seq = $p->pbArmedSeq;
    conn( $p, $seq, undef );
    $p->streamingsocket( \do { my $x = 'SOCK' } );
    $p->pbUPnP->clear;

    $p->flush;

    ok( grep( { $_ eq 'setNextURI:' } @{ $p->pbUPnP->{calls} } ), 'the Hub\'s next uri is cleared' );
    is( $p->pbArmedURL, undef, 'the arm is forgotten' );
    is( $p->streamingsocket, undef, 'a connection drawing on the discarded track is closed' );
    is( $p->pbLiveSeq, $playing, 'and only the playing track is ours until the replacement arrives' );
    ok( $p->pbArmNext, 'the replacement is armed when it comes' );
}

# ---------------------------------------------------------------------------
print "-- formats: advertised in myFormats, so SqueezeDSP can trim them --\n";

{
    my $p = mkplayer();
    is( join( ' ', $p->formats ), 'aac ogg ops ogf alc wma wav flc aif mp3', 'the Hub\'s formats are advertised' );
    ok( ref $p->myFormats eq 'ARRAY', 'in myFormats - the list SqueezeDSP\'s format drop edits' );

    # SqueezeDSP trims it for a DSP-on player...
    $p->myFormats( ['flc'] );
    is( join( ' ', $p->formats ), 'flc', 'formats() is whatever myFormats holds' );

    # ...and the same answer from the Hub arriving again must not undo that.
    @Slim::Control::Request::NOTIFY = ();
    my $changed = $p->updateFormats(undef);
    is( $changed, 0, 'the Hub repeating what it said changes nothing' );
    is( join( ' ', $p->formats ), 'flc', 'so a trim SqueezeDSP made survives' );
    is( scalar @Slim::Control::Request::NOTIFY, 0, 'and nothing is announced' );
}

{
    my $p = mkplayer();
    @Slim::Control::Request::NOTIFY = ();
    $p->updateFormats( [ 'http-get:*:audio/x-flac:*', 'http-get:*:audio/x-wav:*' ] );
    is( join( ' ', $p->formats ), 'wav flc', 'a Hub that takes less is offered less' );
    is( join( ' ', @{ $Slim::Control::Request::NOTIFY[0] || [] }[ 1, 2 ] ), 'client reconnect',
        'and the change is announced as a HELO would be - when SqueezeDSP re-applies its order' );
}

# ---------------------------------------------------------------------------
print "-- power: LMS switches the Hub --\n";

{
    my $p = mkplayer();
    $p->audio_outputs_enable(0);
    is( "@{ $p->pbControl->{sets} }", '0', 'LMS power-off switches the Hub off' );
}

{
    # Simon 2026-10-25: only when the Hub is on Streaming.
    my $p = mkplayer( control => { source => { ix => 1, name => 'eARC' } } );
    $p->audio_outputs_enable(0);
    is( scalar @{ $p->pbControl->{sets} }, 0, 'a Hub on another input (the television) is left on' );
}

{
    my $p = mkplayer( control => { power => undef } );
    $p->audio_outputs_enable(0);
    $p->audio_outputs_enable(1);
    Slim::Utils::Timers::_fireAll();
    is( scalar @{ $p->pbControl->{sets} }, 0, 'with the Hub\'s state unknown nothing is toggled - an LMS restart cannot switch it' );
}

{
    my $p = mkplayer( control => { up => 0 } );
    $p->audio_outputs_enable(0);
    is( scalar @{ $p->pbControl->{sets} }, 0, 'nor with the control link down' );
}

{
    my $p = mkplayer( nocontrol => 1 );
    $p->audio_outputs_enable(0);
    ok( 1, 'and with no control link at all, nothing dies' );
}

{
    Slim::Utils::Timers::_reset();
    my $p = mkplayer( control => { power => 0 } );
    $p->audio_outputs_enable(1);
    is( scalar @{ $p->pbControl->{sets} }, 0, 'power-on waits a moment rather than toggling at once' );
    Slim::Utils::Timers::_fireAll();
    is( "@{ $p->pbControl->{sets} }", '1', 'and then switches the Hub on' );
}

{
    # Power-on followed by playback: the Hub switches ITSELF on when the stream
    # arrives, and a toggle sent into that would switch it back off.
    Slim::Utils::Timers::_reset();
    my $p = mkplayer( control => { power => 0 } );
    $p->audio_outputs_enable(1);
    $p->_startTrack( song(), 'flc' );
    Slim::Utils::Timers::_reset();
    $p->_powerOnLater;
    is( scalar @{ $p->pbControl->{sets} }, 0, 'a power-on that playback follows sends NO toggle' );
}

{
    my $p = mkplayer();
    $p->pbMirroring(1);
    $p->audio_outputs_enable(0);
    is( scalar @{ $p->pbControl->{sets} }, 0, 'a power change that FOLLOWS the Hub is not sent back to it' );
}

# ---------------------------------------------------------------------------
print "-- power: the Hub switches LMS - on, never play --\n";

{
    my $p = mkplayer( power => 1 );
    exec_clear();
    $p->_onHubPower( 0, 0, 0 );
    is( execs(), 'power 0', 'the Hub switched off at its remote: LMS powers off' );
}

{
    my $p = mkplayer( power => 0 );
    exec_clear();
    $p->_onHubPower( 1, 0, 0 );
    is( execs(), 'power 1 1', 'the Hub switched on: LMS powers on WITHOUT resuming (power 1 1)' );
}

{
    my $p = mkplayer( power => 1 );
    exec_clear();
    $p->_onHubPower( 0, 1, 0 );
    is( execs(), '', 'the confirmation of our own command is not mirrored' );
    $p->_onHubPower( 1, 0, 0 );
    is( execs(), '', 'nor a report that matches LMS already' );
}

{
    my $p = mkplayer( power => 1 );
    exec_clear();
    $p->_onHubPower( 0, 0, 1 );
    is( execs(), 'power 0', 'at connect, LMS adopts the Hub\'s state' );
}

{
    my $p = playing( mkplayer() );
    $p->_onHubPower( 0, 1, 0 );
    ok( $p->pbSessionLost, 'switching off with a track loaded loses the Hub\'s playback' );
}

# ---------------------------------------------------------------------------
print "-- a paused track after the Hub was off starts again where it was --\n";

{
    my $p = playing( mkplayer() );
    $p->pause;
    $p->pbSessionLost(1);
    $p->controller->{elapsed} = 61;
    $p->controller->{song} = song();
    $p->pbUPnP->clear;
    exec_clear();

    $p->resume;
    is( $p->pbUPnP->called('play'), 0, 'no UPnP Play - the Hub would fetch the track again from the top' );
    Slim::Utils::Timers::_fireAll();
    is( execs(), 'time 61', 'LMS is asked to start the track again where it was' );
}

{
    my $p = playing( mkplayer() );
    $p->pause;
    $p->pbSessionLost(1);
    $p->controller->{song} = song( canSeek => 0 );
    $Slim::Player::Source::INDEX = 4;
    exec_clear();
    $p->resume;
    Slim::Utils::Timers::_fireAll();
    is( execs(), 'playlist index 4', 'a stream that cannot seek is started again instead' );
}

{
    my $p = playing( mkplayer() );
    $p->pause;
    $p->pbUPnP->clear;
    $p->resume;
    ok( $p->pbUPnP->called('play'), 'CONTROL: an ordinary resume is a UPnP Play' );
}

{
    # LMS's _AutoStart resumes every player when a short track's stream ends
    # before it has started - for this player, while a track plays.
    my $p = playing( mkplayer() );
    $p->resume;
    is( $p->pbUPnP->called('play'), 0, 'a resume while already playing sends nothing' );
}

# ---------------------------------------------------------------------------
print "-- the Hub's input --\n";

{
    my $p = playing( mkplayer() );
    exec_clear();
    $p->_onHubSource( { ix => 1, name => 'eARC' }, { ix => 9, name => 'Streaming' } );
    is( execs(), 'pause 1', 'the Hub switched away from Streaming while playing: LMS pauses' );
    ok( $p->pbSessionLost, 'and the next play starts the track again where it was' );
}

{
    my $p = playing( mkplayer() );
    $p->pause;
    exec_clear();
    $p->_onHubSource( { ix => 1, name => 'eARC' }, { ix => 9, name => 'Streaming' } );
    is( execs(), '', 'already paused: nothing to do' );
}

{
    my $p = playing( mkplayer() );
    exec_clear();
    $p->_onHubSource( { ix => 9, name => 'Streaming' }, { ix => 1, name => 'eARC' } );
    $p->_onHubSource( { ix => 2, name => 'OPT1' }, undef );
    is( execs(), '', 'switching TO Streaming, or a first report, does nothing' );
}

{
    my $p = mkplayer( control => { source => { ix => 1, name => 'eARC' } } );
    $p->_startTrack( song(), 'flc' );
    is( $p->pbControl->{selected}, 1, 'playing on this player puts a Hub on another input onto Streaming' );

    my $q = mkplayer();
    $q->_startTrack( song(), 'flc' );
    is( $q->pbControl->{selected}, 0, 'CONTROL: a Hub already on Streaming is left alone' );
}

# ---------------------------------------------------------------------------
print "-- the streaming socket is this class's own responsibility --\n";

{
    my $p = playing( mkplayer() );
    my $sock = \do { my $x = 'SOCKET' };
    $p->streamingsocket($sock);
    $p->pbStreamSeq(7);
    @{ $p->chunks } = ( \'leftover' );
    Slim::Web::HTTP::_reset();

    $p->stop;

    is( $p->streamingsocket, undef, 'stop releases the streaming socket' );
    ok( scalar( grep { $_ eq $sock } @Slim::Web::HTTP::CLOSED ), 'by closing it' );
    is( scalar @{ $p->chunks }, 0, 'the queue is emptied with it' );
    is( $p->pbLiveSeq, undef, 'and nothing of the stopped stream can be served again' );
}

{
    my $keep  = mkplayer();
    my $other = mkplayer();
    my $ks = \do { my $x = 'KEEP' };
    my $os = \do { my $x = 'OTHER' };
    $keep->streamingsocket($ks);
    $other->streamingsocket($os);
    Slim::Web::HTTP::_reset();
    $other->stop;
    is( $keep->streamingsocket, $ks, 'CONTROL: another player keeps its own stream' );
}

{
    my $p = mkplayer();
    $p->songBytes(4096);
    is( $p->bytesReceived, 4096, 'bytesReceived reports what has actually been sent' );
}

# ---------------------------------------------------------------------------
print "-- volume: shared, not owned --\n";

{
    my $p = mkplayer();
    $p->pbUPnP->{range} = { min => 0, max => 100, step => 1 };
    $p->pbUPnP->clear;

    $p->volume(40);
    ok( $p->pbUPnP->called('setVolume:40'), 'setting the LMS volume sends it to the Hub' );

    $p->pbUPnP->clear;
    $p->volume(40);
    is( $p->pbUPnP->calls, '', 'setting the same level again sends nothing' );

    $p->volume( 20, 1 );
    is( $p->pbUPnP->calls, '', 'a temporary (fade) volume is never sent to the Hub' );
}

{
    my $p = mkplayer();
    $p->pbUPnP->{range} = { min => 0, max => 100, step => 1 };
    $p->volume(40);
    exec_clear();
    $p->_followVolume(75);
    is( execs(), 'mixer volume 75', 'a level changed on the Hub is followed into LMS' );

    # LMS holds 40. The Hub reporting 40 is LMS's own level coming back.
    exec_clear();
    $p->_followVolume(40);
    is( execs(), '', 'the echo of LMS\'s own level is not followed back - no feedback loop' );
}

{
    my $p = mkplayer();
    $p->pbUPnP->{range} = { min => 0, max => 32, step => 1 };
    $p->pbUPnP->clear;
    $p->volume(50);
    ok( $p->pbUPnP->called('setVolume:16'), 'LMS 50 maps onto the middle of a 0..32 device range' );
}

# ---------------------------------------------------------------------------
print "-- a position about another track is not the new track's clock --\n";

{
    # THE HAND-OVER'S OWN REPORT carries the new uri and can still carry the old
    # track's RelTime (81 s at 11:34:01, 38 s at 11:43:40). Since 0.2.5 the change
    # waits for the clock to go back, so it is only a Hub whose clock never does
    # that is handed over on such a report - after URI_LEAD.
    no warnings 'redefine';
    my $now = 5000;
    local *Time::HiRes::time = sub { $now };

    my $p = playing( mkplayer() );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:01:20' } );
    $p->play( { song => song( id => 556 ) } );
    my $armed = $p->pbArmedURL;
    $p->controller->clear;
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:01:21' } );
    $now += Plugins::PlatinBridge::Player::URI_LEAD();
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:01:26' } );
    ok( $p->controller->called('playerTrackStarted'), 'CONTROL: the hand-over happened' );
    is( $p->songElapsedSeconds, 0, 'the old RelTime in the hand-over\'s own report is not the new track\'s clock' );
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:00:01' } );
    is( clk($p), 1, 'the next report is' );
}

{
    # AFTER A LOAD (an LMS skip) the Hub answers for the old track for a moment:
    # 252 s, which LMS clamped to the new track's 217.3 s.
    my $p = playing( mkplayer() );
    $p->pbHubState('PLAYING');
    my $old = $p->pbURL;
    $p->_onPosition( { TrackURI => $old, RelTime => '0:04:12' } );
    $p->stop;
    $p->_startTrack( song( id => 557 ), 'flc' );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $old, RelTime => '0:04:12' } );
    is( $p->songElapsedSeconds, 0, 'after a load, the old track\'s position is not taken for the new one' );
    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:00:01' } );
    is( clk($p), 1, 'the new track\'s first report is' );
}

{
    my $p = playing( mkplayer() );
    my $old = $p->pbURL;
    $p->stop;
    $p->_startTrack( song( id => 557 ), 'flc' );
    $p->pbHubState('PLAYING');
    $p->pbAwaitURIAt( $p->pbAwaitURIAt - Plugins::PlatinBridge::Player::AWAIT_URI() - 1 );
    $p->_onPosition( { TrackURI => $old, RelTime => '0:00:05' } );
    is( clk($p), 5, 'a Hub that never reports the new uri is not left with a frozen clock' );
}

{
    my $p = playing( mkplayer() );
    $p->stop;
    $p->_startTrack( song( id => 557 ), 'flc' );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => '', RelTime => '0:00:04' } );
    is( clk($p), 4, 'a report with no uri at all is not held back' );
}

{
    # CONTROL - THE LAGGING URI. After a gapless change the Hub's TrackURI can
    # stay on the old track while its clock is the new one's; the hand-over by
    # the clock must keep that clock.
    my $p = playing( mkplayer() );
    my $first = $p->pbURL;
    $p->play( { song => song( id => 556 ) } );
    conn( $p, $p->pbArmedSeq, undef );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $first, RelTime => '0:03:15' } );
    $p->_onPosition( { TrackURI => $first, RelTime => '0:00:02' } );
    ok( $p->pbURL ne $first, 'CONTROL: handed over by the clock' );
    $p->_onPosition( { TrackURI => $first, RelTime => '0:00:03' } );
    is( clk($p), 3, 'and the lagging uri does not stop the new track\'s clock' );
}

# ---------------------------------------------------------------------------
print "-- LMS's clock runs on between polls (LMS'S CLOCK IS THE LAST POLL) --\n";

{
    no warnings 'redefine';
    my $now = 1000;
    local *Time::HiRes::time = sub { $now };

    my $p = playing( mkplayer() );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:00:10' } );
    near( $p->songElapsedSeconds, 10.5, 'the first report puts the clock in the middle of the second the Hub reports' );
    $now += 0.4;
    near( $p->songElapsedSeconds, 10.9, 'and it runs on between polls, as a Squeezebox\'s does between STATs' );

    $now += 0.3;    # 11.2
    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:00:11' } );
    near( $p->songElapsedSeconds, 11.2, 'a report that fits leaves it where it is' );

    $now += 0.4;    # 11.6, but the Hub is into 12 already
    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:00:12' } );
    near( $p->songElapsedSeconds, 12, 'behind the Hub: pulled up to the second it has reached' );

    $now += 1.1;    # 13.1, but the Hub is not into 13 yet
    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:00:12' } );
    near( $p->songElapsedSeconds, 12.99, 'ahead of the Hub: held back inside the second it reports' );

    $now += 10;     # the Hub stops answering
    near( $p->songElapsedSeconds, 12.99 + Plugins::PlatinBridge::Player::CLOCK_HOLD(),
        'with no report it runs on no further than CLOCK_HOLD' );

    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:01:30' } );
    near( $p->songElapsedSeconds, 90.5, 'a report that does not fit at all (a seek, a stall) starts it again mid-second' );
}

{
    no warnings 'redefine';
    my $now = 2000;
    local *Time::HiRes::time = sub { $now };

    my $p = playing( mkplayer() );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { RelTime => '0:00:40' } );
    $p->_onTransport( { CurrentTransportState => 'PAUSED_PLAYBACK' } );
    $p->_onPosition( { RelTime => '0:00:41' } );
    $now += 5;
    is( $p->songElapsedSeconds, 41, 'a Hub that is not PLAYING stops the clock at what it reports' );

    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    $p->_onPosition( { RelTime => '0:00:41' } );
    near( $p->songElapsedSeconds, 41.5, 'and PLAYING again starts it from there' );
}

{
    no warnings 'redefine';
    my $now = 3000;
    local *Time::HiRes::time = sub { $now };

    my $p = playing( mkplayer() );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:02:00' } );
    $p->stop;
    $p->_startTrack( song( id => 557 ), 'flc' );
    $now += 1;
    is( $p->songElapsedSeconds, 0, 'a new load does not carry the old track\'s running clock' );
}

# ---------------------------------------------------------------------------
print "-- a hand-over waits for the Hub's clock to go back (its TrackURI leads it) --\n";

{
    # 2026-10-25: 21.flac reported at 4:21 and 4:22, then 0:00:00.
    no warnings 'redefine';
    my $now = 4000;
    local *Time::HiRes::time = sub { $now };

    my $p = playing( mkplayer() );
    my $first = $p->pbURL;
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $first, RelTime => '0:04:20' } );
    $p->play( { song => song( id => 556 ) } );
    my $armed = $p->pbArmedURL;
    $p->controller->clear;

    $now += 1;
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:04:21' } );
    is( $p->controller->calls, '', 'the next uri with the OLD track\'s clock is not the change yet' );
    is( $p->pbURL, $first, 'the old track is still the one playing' );
    is( clk($p), 261, 'and its clock keeps counting' );

    $now += 1;
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:04:22' } );
    is( $p->controller->calls, '', 'nor is the next report' );

    $now += 1;
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:00:00' } );
    is( $p->controller->calls, 'playerTrackStarted', 'the clock going back is the change - and NOTHING else is asked' );
    is( $p->pbURL, $armed, 'CONTROL: the armed url is now the current one' );
    near( $p->songElapsedSeconds, 0.5, 'and the new track\'s clock starts from that report' );
}

{
    # BOUNDED: a Hub whose clock never goes back is still handed over.
    no warnings 'redefine';
    my $now = 6000;
    local *Time::HiRes::time = sub { $now };

    my $p = playing( mkplayer() );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:04:20' } );
    $p->play( { song => song( id => 556 ) } );
    my $armed = $p->pbArmedURL;
    $p->controller->clear;

    $p->_onPosition( { TrackURI => $armed, RelTime => '0:04:21' } );
    $now += 2;
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:04:23' } );
    $now += 2;
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:04:25' } );
    is( $p->controller->calls, '', 'inside URI_LEAD it still waits' );
    $now += 1;
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:04:26' } );
    is( $p->controller->calls, 'playerTrackStarted', 'after URI_LEAD the uri alone hands over, as before 0.2.5' );
    is( $p->songElapsedSeconds, 0, 'and the old RelTime it carried does not become the new track\'s clock' );
}

{
    # CONTROL: a uri that arrives WITH the new clock hands over at once.
    my $p = playing( mkplayer() );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:04:20' } );
    $p->play( { song => song( id => 556 ) } );
    my $armed = $p->pbArmedURL;
    $p->controller->clear;
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:00:01' } );
    is( $p->controller->calls, 'playerTrackStarted', 'CONTROL: the new uri with the new clock is the change at once' );
}

{
    # A clock that has gone back, but is already past the start when it is read
    # (a late poll), is the change too - it does not wait out URI_LEAD.
    my $p = playing( mkplayer() );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:04:20' } );
    $p->play( { song => song( id => 556 ) } );
    my $armed = $p->pbArmedURL;
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:04:21' } );
    $p->controller->clear;
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:00:05' } );
    is( $p->controller->calls, 'playerTrackStarted', 'a clock gone back, read late, is the change at once' );
}

{
    # A SHORT TRACK: its clock never got far enough to "go back" from.
    my $p = playing( mkplayer() );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:00:02' } );
    $p->play( { song => song( id => 556 ) } );
    my $armed = $p->pbArmedURL;
    $p->controller->clear;
    $p->_onPosition( { TrackURI => $armed, RelTime => '0:00:01' } );
    is( $p->controller->calls, 'playerTrackStarted', 'after a short track, a new uri at the start of its clock is the change' );
}

{
    # The wait is timed per armed track: the first sight of an EARLIER track's uri
    # does not start the next one's.
    no warnings 'redefine';
    my $now = 7000;
    local *Time::HiRes::time = sub { $now };

    my $p = playing( mkplayer() );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { TrackURI => $p->pbURL, RelTime => '0:04:20' } );
    $p->play( { song => song( id => 556 ) } );
    my $a = $p->pbArmedURL;
    $p->_onPosition( { TrackURI => $a, RelTime => '0:04:21' } );
    $now += 1;
    $p->_onPosition( { TrackURI => $a, RelTime => '0:00:00' } );
    is( $p->pbURL, $a, 'CONTROL: the first change happened' );

    $now += 200;
    $p->_onPosition( { TrackURI => $a, RelTime => '0:03:20' } );
    $p->play( { song => song( id => 557 ) } );
    my $b = $p->pbArmedURL;
    $p->controller->clear;
    $p->_onPosition( { TrackURI => $b, RelTime => '0:03:21' } );
    is( $p->controller->calls, '', 'the next track\'s uri with the old clock waits again' );
}

print "-- a stop voids the next track armed on the Hub --\n";

{
    my $p = playing( mkplayer() );
    $p->play( { song => song( id => 556 ) } );
    $p->pbUPnP->clear;
    $p->stop;
    is( scalar( grep { $_ eq 'setNextURI:' } @{ $p->pbUPnP->{calls} } ), 1,
        'stopping with a next track armed clears it on the Hub - Stop and a new uri leave it there' );
}

{
    my $p = playing( mkplayer() );
    $p->pbUPnP->clear;
    $p->stop;
    is( $p->pbUPnP->called('setNextURI'), 0, 'CONTROL: a stop with nothing armed sends no clear' );
}

{
    my $p = playing( mkplayer( gapless => 0 ) );
    $p->play( { song => song( id => 556 ) } );
    $p->pbUPnP->clear;
    $p->stop;
    is( $p->pbUPnP->called('setNextURI'), 0, 'and a Hub without SetNextAVTransportURI is never sent it' );
}

# ---------------------------------------------------------------------------
print "-- the Hub counts from its stream: a part-way start gets the time remaining --\n";

sub didlDuration { my $d = shift || ''; return $d =~ /duration="([^"]+)"/ ? $1 : '(none)' }

{
    my $p = mkplayer();
    $p->_startTrack( song(), 'flc' );
    is( didlDuration( $p->pbUPnP->{lastDidl} ), '0:03:20.000', 'CONTROL: a track from the top is given its whole length (200 s)' );
    ok( index( $p->pbUPnP->{lastDidl}, 'xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/"' ) > 0, 'the DIDL declares the dlna namespace, as the UPnP Bridge\'s does' );
}

{
    # A seek, a resume after the Hub was off, SqueezeDSP's restart: the stream
    # starts at 103 s and the Hub's elapsed starts at 0 whatever it carries.
    my $p = mkplayer();
    $p->_startTrack( song( seek => { timeOffset => 103 } ), 'flc' );
    is( didlDuration( $p->pbUPnP->{lastDidl} ), '0:01:37.000', 'a track started at 103 s is given the 97 s that remain' );

    # The NEXT track starts from its top: its length is whole.
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    $p->play( { song => song( id => 556 ) } );
    is( didlDuration( $p->pbUPnP->{lastNextDidl} ), '0:03:20.000', 'and the next track armed after it is given its whole length' );
}

{
    my $p = mkplayer();
    $p->_startTrack( song( seek => { timeOffset => 250 } ), 'flc' );
    is( didlDuration( $p->pbUPnP->{lastDidl} ), '0:03:20.000', 'an offset past the end does not produce a nonsense length' );
}

# ---------------------------------------------------------------------------
print "-- mute is the Hub's own mute --\n";

# How LMS 9.1 mutes (Commands.pm mixer muting -> fade -> Player::mute): the mute
# pref is set, then the player is handed the level to come back to, NEGATIVE.
# Unmuting clears the pref and hands it back the positive level.
sub lmsMute   { my $p = shift; my $v = $serverPrefs->client($p)->get('volume'); $serverPrefs->client($p)->set( 'mute', 1 ); $p->volume( -abs $v ) }
sub lmsUnmute { my $p = shift; my $v = $serverPrefs->client($p)->get('volume'); $serverPrefs->client($p)->set( 'mute', 0 ); $p->volume( abs $v ) }

{
    my $p = mkplayer();
    $p->pbUPnP->{range} = { min => 0, max => 100, step => 1 };
    $serverPrefs->client($p)->set( 'mute', 0 );
    $p->volume(29);
    $p->pbUPnP->clear;
    exec_clear();

    lmsMute($p);
    is( $p->pbUPnP->calls, 'setMute:1', 'muting in LMS sends the Hub SetMute - and NO volume' );
    is( $serverPrefs->client($p)->get('volume'), -29, 'CONTROL: LMS holds the level to come back to, negative' );

    $p->_followVolume(29);
    is( execs(), '', 'the Hub still at 29 under its mute is not read as a change' );
    is( $serverPrefs->client($p)->get('volume'), -29, 'and LMS keeps the level to come back to' );

    $p->pbUPnP->clear;
    lmsUnmute($p);
    is( $p->pbUPnP->calls, 'setMute:0', 'unmuting sends SetMute 0 - the Hub never lost its level' );
    $p->_followVolume(29);
    is( execs(), '', 'and the echo after it is not followed either' );
}

{
    # The Hub's own knob turned while LMS is muted: followed, and LMS (whose
    # mixer volume unmutes first) unmutes, as its own IR does.
    my $p = mkplayer();
    $p->pbUPnP->{range} = { min => 0, max => 100, step => 1 };
    $serverPrefs->client($p)->set( 'mute', 0 );
    $p->volume(29);
    lmsMute($p);
    exec_clear();
    $p->_followVolume(40);
    is( execs(), 'mixer volume 40', 'the knob turned while muted is followed into LMS' );
}

{
    # LMS re-applying a stored mute hands the player 0 with the mute pref set.
    my $p = mkplayer();
    $p->pbUPnP->{range} = { min => 0, max => 100, step => 1 };
    $p->volume(29);
    $p->pbUPnP->clear;
    $serverPrefs->client($p)->set( 'mute', 1 );
    $p->volume(0);
    is( $p->pbUPnP->calls, 'setMute:1', 'a 0 while the mute pref is set is the mute, not a level of 0' );
    $serverPrefs->client($p)->set( 'mute', 0 );
}

{
    my $p = mkplayer();
    $p->pbUPnP->{range} = { min => 0, max => 100, step => 1 };
    $serverPrefs->client($p)->set( 'mute', 0 );
    $p->volume(29);
    $p->pbUPnP->clear;
    $p->volume(0);
    is( $p->pbUPnP->calls, 'setVolume:0', 'CONTROL: an ordinary level of 0 is a level, not a mute' );
}

{
    my $p = mkplayer();
    $p->pbUPnP->{range} = { min => 0, max => 100, step => 1 };
    $p->pbUPnP->clear;
    $p->volume(29);
    is( $p->pbUPnP->calls, 'setMute:0,setVolume:29', 'the first level after start also clears a mute the Hub may have been left with' );
}

print "-- a level on its way is not followed back --\n";

{
    my $p = mkplayer();
    $p->pbUPnP->{range} = { min => 0, max => 100, step => 1 };
    $serverPrefs->client($p)->set( 'mute', 0 );
    $p->volume(29);
    $p->pbUPnP->{deferVolume} = 1;
    $p->volume(40);
    exec_clear();

    $p->_followVolume(29);
    is( execs(), '', 'a reading taken before the Hub applied the new level is not followed back' );
    is( $serverPrefs->client($p)->get('volume'), 40, 'LMS keeps the level it was set to' );

    $p->pbUPnP->{volCb}->( {}, undef );
    $p->_followVolume(40);
    is( execs(), '', 'CONTROL: once applied, its echo is not followed' );
    $p->_followVolume(55);
    is( execs(), 'mixer volume 55', 'and the Hub\'s own changes are followed again' );
}

{
    my $p = mkplayer();
    $p->pbUPnP->{range} = { min => 0, max => 100, step => 1 };
    $p->volume(29);
    $p->pbUPnP->{deferVolume} = 1;
    $p->volume(40);
    $p->pbVolSentAt( $p->pbVolSentAt - Plugins::PlatinBridge::Player::VOL_SETTLE() - 1 );
    exec_clear();
    $p->_followVolume(33);
    is( execs(), 'mixer volume 33', 'a level the Hub never confirmed stops blocking the readings after a while' );
}

{
    my $p = mkplayer();
    $p->pbUPnP->{range} = { min => 0, max => 100, step => 1 };
    is( $p->_toDevice(-29), 0, 'a level below the range is clamped to the Hub\'s minimum' );
    is( $p->_toDevice(150), 100, 'and above it to its maximum' );
}

# ---------------------------------------------------------------------------
print "-- a silent Hub is looked for (A SILENT HUB IS LOOKED FOR) --\n";

# Once the plugin has its Hub, discovery asks every 10 minutes. A Hub that comes
# back at a new address answered nothing at the old one, and nothing acted on that
# silence: up to 10 minutes unplayable. Now 30 s unanswered marks the Hub silent,
# which puts discovery back on its 15 s search until the Hub answers. Per player
# since 0.2.7: one Hub answering does not end another's search.
{
    no warnings 'redefine';
    my $probes = 0;
    local *Plugins::PlatinBridge::Discovery::probeNow = sub { $probes++ };
    my $D = 'Plugins::PlatinBridge::Discovery';

    my $p = mkplayer();
    $D->setSettled(1);
    is( $D->period, 600, 'with its Hub answering, discovery asks every 10 minutes' );

    $p->startPolling;
    ok( defined $p->pbLastSeen && abs( $p->pbLastSeen - time() ) <= 1,
        'polling starts with the Hub just heard from (it has just been described)' );

    $p->pbUPnP->{down} = 1;
    $p->_poll;
    is( $probes, 0, 'an unanswered poll right after polling starts is not an outage' );
    is( $D->period, 600, 'and discovery keeps its 10 minutes' );

    $p->pbLastSeen( time() - 25 );
    $p->_poll;
    is( $probes, 0, '25 s of silence is not an outage either' );
    is( $D->period, 600, 'discovery still at 10 minutes at 25 s' );

    $p->pbLastSeen( time() - 31 );
    $p->_poll;
    is( $probes, 1, 'past 30 s discovery searches at once' );
    is( $D->period, 15, 'and goes back to its 15 s pace' );
    is( $p->pbOutage, 1, 'the outage is recorded' );
    is( $D->settled, 1, 'without touching the plugin\'s own "has a Hub" flag' );

    $p->_poll for 1 .. 5;
    is( $probes, 1, 'once per outage: the 15 s pace does the searching after that' );

    is( $p->controller->calls, '', 'the silence tells the controller nothing - no opinion' );

    $p->pbUPnP->{down} = 0;
    $p->_poll;
    is( $D->period, 600, 'the Hub\'s first answer returns discovery to 10 minutes' );
    is( $p->pbOutage, 0, 'and ends the outage' );

    $p->_poll;
    is( $D->period, 600, 'and later answers leave it there' );

    $p->pbUPnP->{down} = 1;
    $p->pbLastSeen( time() - 31 );
    $p->_poll;
    is( $probes, 2, 'a later outage searches again' );
    is( $D->period, 15, 'at the 15 s pace again' );

    # FOUND AGAIN AT A NEW ADDRESS: Plugin::_moved rebinds the player to a new
    # link and restarts its poll while the outage is still on. The search ends
    # at that link's first ANSWER, not at the rebind.
    $p->pbUPnP( FakeUPnP->new(1) );
    $p->startPolling;
    is( $D->period, 15, 'a rebind to the Hub at a new address does not end the search by itself' );
    is( $p->pbOutage, 1, 'and the outage is still on' );
    $p->_poll;
    is( $D->period, 600, 'the new link\'s first answer ends it' );

    # TWO HUBS: the search runs while EITHER is silent.
    my $q = mkplayer();
    $q->startPolling;
    $p->pbUPnP->{down} = 1;
    $p->pbLastSeen( time() - 31 );
    $p->_poll;
    $q->_poll;
    is( $D->period, 15, 'one Hub silent: discovery searches' );
    $q->_poll for 1 .. 3;
    is( $D->period, 15, 'and the other Hub answering does not end that search' );
    $q->pbUPnP->{down} = 1;
    $q->pbLastSeen( time() - 31 );
    $q->_poll;
    $p->pbUPnP->{down} = 0;
    $p->_poll;
    is( $D->period, 15, 'the first answering again does not end the search for the second' );
    $q->pbUPnP->{down} = 0;
    $q->_poll;
    is( $D->period, 600, 'both answering: back to 10 minutes' );
    is( $D->silent, 0, 'with no Hub left marked silent' );

    $D->setSettled(0);
}

# ---------------------------------------------------------------------------
print "-- failures are bounded --\n";

{
    my $p = mkplayer();
    $p->controller->clear;
    $p->_loadFailed('one');
    $p->_loadFailed('two');
    is( $p->controller->called('playerStreamingFailed'), 2, 'the first failures are reported to LMS, which skips' );
    $p->_loadFailed('three');
    is( $p->controller->called('playerStreamingFailed'), 2, 'the third does NOT report another skippable failure' );
    is( $p->pbFailRun, 0, 'and the run is reset so the next play gets a fresh three' );
}

{
    my $p = mkplayer();
    $p->_loadFailed('one');
    $p->_loadFailed('two');
    $p->pbPlayAck(1);
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    is( $p->pbFailRun, 0, 'a track reaching PLAYING clears the failure run' );
}

# ---------------------------------------------------------------------------
print "-- position --\n";

{
    # After a seek LMS streams from the seek point and the Hub's clock starts at
    # 0. LMS adds the stream's start offset itself (playingSongElapsed), so the
    # player must NOT take it off as well - the 0.1.x code did, which would have
    # shown 0:00 for the first 30 s after a seek to 30 s.
    my $p = mkplayer();
    $p->_startTrack( song( seek => { timeOffset => 30 } ), 'flc' );
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    $p->pbHubState('PLAYING');
    $p->_onPosition( { RelTime => '0:00:02' } );
    is( clk($p), 2, 'a stream-relative clock after a seek is reported as it is' );
    $p->_onPosition( { RelTime => '0:00:10' } );
    is( clk($p), 10, 'and keeps counting from there' );
}

{
    # A native FLAC seeked by byte keeps its frames' own sample numbers, so the
    # Hub's clock can start AT the offset. The first report says which.
    my $p = mkplayer();
    $p->_startTrack( song( seek => { timeOffset => 30 } ), 'flc' );
    $p->_onTransport( { CurrentTransportState => 'PLAYING' } );
    $p->_onPosition( { RelTime => '0:00:31' } );
    is( clk($p), 1, 'a clock that starts at the offset has the offset taken off' );
}

{
    my $p = mkplayer();
    $p->pbPosition(42);
    $p->_onPosition( { RelTime => 'NOT_IMPLEMENTED' } );
    is( $p->pbPosition, 42, 'a renderer that will not report position leaves the last value alone' );
}

# ---------------------------------------------------------------------------
print "-- capability declarations --\n";

{
    my $p = mkplayer();
    ok( !grep( { $_ eq 'pcm' } $p->formats ), 'raw pcm is not offered - the Hub cannot tell its rate or depth' );
    is( $p->maxSupportedSamplerate, 96000, 'the Hub\'s ceiling is declared - WiSA carries 24/96' );
    is( $p->canDirectStream, 0, 'direct streaming is refused - SqueezeDSP stays in the path' );
    is( $p->canDoReplayGain, 0, 'and the player applies no gain of its own' );
    ok( $p->bufferFullness < $p->bufferSize * 0.98, 'the buffer is reported healthy but NEVER full' );
}

# ---------------------------------------------------------------------------
printf "\n%s: %d passed, %d failed\n", ( $fail ? 'FAIL' : 'ok' ), $pass, $fail;
exit( $fail ? 1 : 0 );
