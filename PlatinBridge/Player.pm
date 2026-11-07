package Plugins::PlatinBridge::Player;

# The virtual player: a Slim::Player::Player that drives the Platin Hub over
# UPnP AVTransport / RenderingControl, and switches it on and off over the Hub's
# own control port (Control.pm).
#
# IT CARRIES NO AUDIO STAGE (0.2.0, Simon 2026-10-25: "Just needs to offer up as
# a player that advertises its formats to LMS. I will be using SqueezeDSP to do
# all the other stuff."). The player tells LMS what the Hub can play, LMS's
# transcode table - SqueezeDSP's rules, when it is on for this player - turns
# each track into one of those, and the bytes go to the Hub as they came out.
# ReplayGain, the WAV header and the FLAC encoder that used to live here are gone.
#
# SUBCLASSES Slim::Player::Player, NOT Squeezebox - everything in Squeezebox and
# below assumes a live SlimProto socket. Two things that costs us, both handled
# here because LMS gates them on the class: closeStream, and asserting
# bufferReady ourselves.
#
# THE CLIENT OBJECT IS A BLESSED ARRAY. `$client->{field}` is fatal ("Not a HASH
# reference"), so every piece of per-player state is declared through
# mk_accessor below.
#
# DESIGN RULE 1, unchanged: NOTHING THE HUB REPORTS MAY START LMS PLAYING. A
# report may pause LMS, stop it, power it off, or power it ON WITHOUT RESUMING -
# never play. The only Hub report that moves LMS forward is a resume of a track
# LMS itself had paused (the Hub's own play button).

use strict;
use warnings;

use base qw(Slim::Player::Player);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Web::HTTP;
use Slim::Control::Request;
use Slim::Player::Source ();
use Time::HiRes ();

use Plugins::PlatinBridge::Format;
use Plugins::PlatinBridge::Stream;
use Plugins::PlatinBridge::Trace;
use Plugins::PlatinBridge::UPnP;
use Plugins::PlatinBridge::Control;
use Plugins::PlatinBridge::Discovery;

my $log   = logger('plugin.platinbridge');
my $prefs = preferences('server');

{
    my $class = __PACKAGE__;

    # The client is a blessed ARRAY - see the header. Every one of these would be
    # a fatal hash deref if written as $client->{...}.
    $class->mk_accessor( rw =>
        qw( pbUPnP pbControl pbDevice
            pbSeq pbURL pbPrevURL pbArmed pbArmedURL pbArmedSeq pbArmedFetched
            pbArmNext pbPerTrack pbHeld pbHubEnded pbPlayingSeq
            pbLiveSeq pbStreamSeq pbReplay pbConnBytes pbCaches pbTakeovers pbGapNoted
            pbWanted pbStarted pbPlayAck pbGeneration pbFailRun
            pbPosition pbLastPlayPos pbStartOffset pbClockAbs pbStartedAt pbStopSeen pbHubState
            pbClockPos pbClockAt pbArmedSeen
            pbVolWant pbVolAt pbVolSentAt pbMuted pbAwaitURI pbAwaitURIAt pbPollTimer pbLastSeen pbOutage
            pbMirroring pbPowerOnAt pbLoadAt pbSessionLost
            pbHubPaused pbPauseSentAt pbPauseTries
            myFormats pbHubFormats ) );
}

# How long after a Play acknowledgement we allow the Hub to actually start
# before treating the load as failed. Without this a Play that is acked but never
# becomes playback tells LMS nothing, for ever.
use constant START_DEADLINE => 12;

# Three failed loads stop the player rather than letting LMS skip through a whole
# album against a sick device.
use constant FAIL_LIMIT => 3;

# How often we ask the Hub what it is doing over UPnP. A Hub that stops
# answering has NO OPINION - it is never read as "stopped".
use constant POLL_PERIOD => 1;

# A Hub that has not answered the poll for this long may be at a new address, so
# discovery goes back to looking for it (see _hubUnanswered).
use constant LOST_AFTER => 30;

# A transient stop right after a load is the Hub changing tracks, not an end.
use constant START_GRACE => 3;

# A STOPPED report is believed only after this many polls in a row: one stray
# report between two tracks must not end an album.
use constant STOP_POLLS => 2;

# "At the end of the track": within this many seconds of its duration. One poll
# a second, plus the Hub's own reporting lag.
use constant NEAR_END => 10;

# How much of each track's opening is kept for a renderer that opens it again
# (Stream.pm's header). The Hub's probe GET can pull megabytes before it closes,
# because LMS's writes land in kernel buffers at both ends; 16 MiB is ~29 s of
# 24/96 WAV and more of FLAC. The UPnP Bridge's equivalent ring is 8 MB.
use constant HEAD_MAX => 16 * 1024 * 1024;

# Once the Hub has played this long into a track, its opening is no longer needed.
use constant HEAD_KEEP_PLAYED => 20;

# How much of a seeked stream may be read looking for its first whole FLAC frame.
# A frame at 24/192 is at most ~65 KB, so this is several.
use constant OPENING_MAX => 256 * 1024;

# After a load, the Hub's position reports are taken only once it reports the new
# track's uri - or after this long, so a Hub that never does is not left frozen.
use constant AWAIT_URI => 10;

# LMS's clock runs on between polls (see _runClock), but no further than this
# past the Hub's last report: a Hub that stops answering does not leave it running.
use constant CLOCK_HOLD => 3;

# The Hub reports the next track's uri before its clock goes back (see
# _uriHandOver). The hand-over waits for the clock, but no longer than this.
use constant URI_LEAD => 5;

# A hand-over's own report sets the new track's clock only this close to the
# start. Anything later is still the old track's RelTime.
use constant FRESH_CLOCK => 3;

# A volume sent to the Hub is given this long to land before the Hub's readings
# count again (see _followVolume).
use constant VOL_SETTLE => 3;

# A Pause the Hub has not acted on is sent again after this long, at most
# PAUSE_TRIES times in all.
use constant PAUSE_RETRY => 2;
use constant PAUSE_TRIES => 3;

# A renderer that re-opens one track over and over is not going to settle. More
# than this many take-overs of the same track inside TAKEOVER_SPAN seconds and the
# next is refused. The Hub's own pattern is two.
use constant TAKEOVER_LIMIT => 8;
use constant TAKEOVER_SPAN  => 4;

# A power-on from LMS waits this long before switching the Hub on: if playback is
# starting, the Hub switches ITSELF on when the stream arrives, and a toggle sent
# into that would switch it straight back off.
use constant POWER_ON_WAIT => 1.5;

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);

    $self->pbSeq(0);
    $self->pbGeneration(0);
    $self->pbFailRun(0);
    $self->pbPosition(0);
    $self->pbStartOffset(0);
    $self->pbWanted('stop');
    $self->pbCaches( {} );

    # The format list LIVES IN myFormats, the same accessor SqueezePlay keeps its
    # HELO list in, because that is what SqueezeDSP's format drop edits
    # (Configuration::applyFormatOrder): a player with a fixed formats() list
    # "cannot be trimmed" and its covered formats would bypass the DSP
    # (SqueezeDSP ledger, `FIXED-LIST PLAYERS CANNOT BE TRIMMED`).
    my @f = Plugins::PlatinBridge::Format::defaultFormats();
    $self->myFormats( [@f] );
    $self->pbHubFormats( [@f] );

    return $self;
}

# ---------------------------------------------------------------------------
# Identity and capabilities

sub model         { 'platinbridge' }
sub modelName     { 'Platin Hub' }
sub vfd           { 0 }
sub isPlayer      { 1 }
sub hasVolumeControl { 1 }
sub hasDigitalOut { 1 }
sub connected     { $_[0]->tcpsock ? 1 : 0 }
sub opened        { undef }
sub signalStrength { undef }

sub formats {
    my $self = shift;
    my $f = ref $self ? $self->myFormats : undef;
    return ref $f eq 'ARRAY' ? @$f : Plugins::PlatinBridge::Format::defaultFormats();
}

# The Hub has said what it takes. Changed ONLY when the answer differs from the
# list we last derived - so a trim SqueezeDSP made to myFormats is never undone
# by the same answer arriving again - and a change is announced as a HELO would
# be (`client reconnect`), which is when SqueezeDSP re-applies its order.
sub updateFormats {
    my ( $self, $sink ) = @_;

    my @new = Plugins::PlatinBridge::Format::formatsFromSink($sink);
    return 0 unless @new;

    my $had = $self->pbHubFormats || [];
    return 0 if "@new" eq "@$had";

    $self->pbHubFormats( [@new] );
    $self->myFormats( [@new] );

    $log->info( $self->name . ': the Hub takes ' . join( ' ', @new ) );

    Slim::Control::Request::notifyFromArray( $self, [ 'client', 'reconnect' ] );

    return 1;
}

# WiSA carries 24/96 and no more, and the UPnP Bridge's player for this Hub runs
# at 96000. Saying so makes LMS - and SqueezeDSP's `D` rules - keep a hi-res
# track inside what the Hub plays (a 192k source comes down to 96k, 176.4k to
# 88.2k: LMS keeps the source's rate family).
sub maxSupportedSamplerate { 96000 }

# LMS applies no ReplayGain for a non-Squeezebox player, and this one no longer
# does either: SqueezeDSP's own gain stage is the place for it.
sub canDoReplayGain { 0 }

sub needsWeightedPlayPoint { 0 }

# A non-Squeezebox player inherits a DEFAULT 320kbps cap from the server's
# maxRate pref, which silently transcodes the entire library to mp3. Called from
# Plugin::_create, strictly AFTER $client->init (which is what runs initPrefs).
sub initBitrateLimit {
    my $self = shift;

    my $rate = $prefs->client($self)->get('maxBitrate');

    if ( !defined $rate ) {
        $prefs->client($self)->set( 'maxBitrate', 0 );
        main::INFOLOG && $log->is_info && $log->info( $self->name . ': bitrate limit set to unlimited' );
    }

    return;
}

# LMS opens every source itself and hands us the bytes, so the Hub never fetches
# a service's signed url directly - and SqueezeDSP stays in the path.
sub canDirectStream { 0 }

# LMS's two tidy-up points are gated on isa('Slim::Player::Squeezebox'), so for
# this class the old streaming connection is never released by LMS: it stays in
# the write-select list still pulling nextChunk. stop() calls this.
sub closeStream {
    my $self = shift;

    Slim::Web::HTTP::forgetClient($self);

    @{ $self->chunks } = ();

    $self->pbStreamSeq(undef);
    $self->pbReplay(undef);
    $self->pbConnBytes(0);

    return;
}

# Report a buffer that is healthy but NEVER full. _CheckPaused tears down the
# source stream when a paused remote track sits above 98% usage (LMS bug 10645),
# on the assumption that nothing is pulling.
sub bufferSize     { 128 * 1024 }
sub bufferFullness { 96 * 1024 }
sub bytesReceived  { $_[0]->songBytes }

# Hardware sync stubs - there is no play point to align. Sync groups are not
# supported by this player.
sub playPoint        { undef }
sub startAt          { 1 }
sub resumeAt         { 1 }
sub skipAhead        { 1 }
sub pauseForInterval { 1 }

# ---------------------------------------------------------------------------
# THE STREAM: LMS's bytes, passed through, with each track's opening kept.

sub pbCacheFor {
    my ( $self, $seq ) = @_;
    return undef unless defined $seq;
    my $c = $self->pbCaches or return undef;
    return $c->{$seq};
}

# Stream.pm has taken a connection over for $seq; $replay is where it starts in
# what is held (undef: a fresh connection on the live stream).
sub pbStreamOpened {
    my ( $self, $seq, $replay ) = @_;

    my $caches = $self->pbCaches || {};

    if ( !$caches->{$seq} && defined $self->pbLiveSeq && $seq == $self->pbLiveSeq ) {
        $caches->{$seq} = { buf => '', total => 0, eof => 0, capped => 0, seen => 0, pending => '' };

        # Keep this track and the one before it - the one the Hub may still be
        # playing out of its own buffer - and nothing older.
        for my $k ( keys %$caches ) {
            delete $caches->{$k} if $k < $seq - 1;
        }

        $self->pbCaches($caches);
    }

    $self->pbStreamSeq($seq);
    $self->pbReplay($replay);
    $self->pbConnBytes(0);
    $self->pbGapNoted(0);

    # The Hub fetching the track we armed is half of the evidence that it has
    # moved on to it - see _rolledOver.
    if ( defined $self->pbArmedSeq && $seq == $self->pbArmedSeq && !$self->pbArmedFetched ) {
        $self->pbArmedFetched( Time::HiRes::time() );
    }

    return;
}

sub pbTakeoverOK {
    my ( $self, $seq ) = @_;

    my $now = Time::HiRes::time();
    my $t   = $self->pbTakeovers || {};

    my @recent = grep { $now - $_ < TAKEOVER_SPAN } @{ $t->{$seq} || [] };
    return 0 if @recent >= TAKEOVER_LIMIT;

    push @recent, $now;
    $self->pbTakeovers( { $seq => \@recent } );

    return 1;
}

sub nextChunk {
    my ( $self, $maxChunkSize, $callback ) = @_;

    my $seq   = $self->pbStreamSeq;
    my $cache = $self->pbCacheFor($seq);
    my $empty = '';

    # 1. A CONNECTION THAT RE-OPENED A TRACK is served what was already sent,
    #    from where it asked, before anything new.
    if ( $cache && defined( my $at = $self->pbReplay ) ) {
        my $held = length $cache->{buf};

        if ( $at < $held ) {
            my $n = $held - $at;
            $n = $maxChunkSize if $maxChunkSize && $n > $maxChunkSize;

            my $out = substr( $cache->{buf}, $at, $n );
            $self->pbReplay( $at + $n );
            $self->_carried( length $out );

            return \$out;
        }

        $self->pbReplay(undef);

        # The kept opening ends before the point the live stream has reached, so
        # what lies between was sent once and is gone. FLAC resyncs on its next
        # frame; WAV may not. Logged, because it is the one thing the replay
        # cannot mend.
        if ( $held < $cache->{total} && !$self->pbGapNoted ) {
            $self->pbGapNoted(1);
            $log->warn( sprintf '%s: track re-opened past the %d bytes kept of it - %d bytes were already sent and cannot be sent again',
                $self->name, $held, $cache->{total} - $held );
            Plugins::PlatinBridge::Trace::note( 'replay-gap', "held $held of $cache->{total}" );
        }
    }

    # 2. Only the track LMS is streaming now has more to give. A replay of an
    #    earlier one, or of this one once it has ended, simply ends - and ends ONLY
    #    THIS connection: LMS has already been told about the end of the stream.
    return \$empty unless defined $seq && defined $self->pbLiveSeq && $seq == $self->pbLiveSeq;
    return \$empty if $cache && $cache->{eof};

    # The source ended while the stream's opening was still being assembled: that
    # opening went out on the last call, and THIS is the end.
    return $self->_atEndOfStream($cache) if $cache && $cache->{eofNext};

    my $ref = $self->SUPER::nextChunk( $maxChunkSize, $callback );

    return undef unless defined $ref;

    # THE FIRST BYTES OF THE TRACK: read what they are, and give a stream that
    # has lost its header to a seek the one it needs. Finding the first frame can
    # take more than one chunk, so read on while the source has more; when it has
    # none yet, undef - sendStreamingResponse asks again when it does.
    if ( $cache && !$cache->{seen} && ( length $$ref || length $cache->{pending} ) ) {
        my $out;

        while ( !defined( $out = $self->_opening( $seq, $cache, $$ref, !length $$ref ) ) ) {
            $ref = $self->SUPER::nextChunk( $maxChunkSize, $callback );
            return undef unless defined $ref;
        }

        # The source ended while the opening was being put together: the opening
        # goes now, and the end on the next call.
        $cache->{eofNext} = 1 if !length $$ref;

        $ref = \$out;
    }

    # THE END-OF-STREAM MARKER: a ref to an empty string, queued by
    # Source::_readNextChunk. sendStreamingResponse reads it as "close".
    return $self->_atEndOfStream($cache) if !length $$ref;

    $self->_record( $cache, $ref );
    $self->_carried( length $$ref );

    return $ref;
}

# A SEEKED OR RESUMED NATIVE STREAM HAS NO CONTAINER HEADER. LMS starts it at a
# frame - Audio::Scan's find_frame_fh for a file, Slim::Formats::FLAC::frameAlign
# for a remote stream such as Qobuz (read in 9.1) - but sends no STREAMINFO:
# FLAC has no getInitialAudioBlock (SqueezeDSP's ledger, `A RESUMED FLAC STREAM
# HAS NO STREAMINFO`). On 0.2.0 (2026-10-25) a track started at 44 s left LMS's
# clock frozen at 44 while the Hub re-opened the url tens of times a second; the Hub
# identifies a stream by its first bytes (GStreamer), so the missing header is
# the inferred cause - not proven on the Hub itself.
#
# So the opening is repaired: a FLAC stream that does not start with `fLaC` is
# given a STREAMINFO built from its first frame's own rate, depth and channels,
# and a WAV stream that does not start with `RIFF` a RIFF header. The stream is
# also cut to its first whole frame (header CRC checked) - normally a no-op, as
# LMS has aligned it already; a guard for a source that has not. Benched with
# LMS 9.1's own flac on cuts of four files (16/44.1 twice, 24/96, 24/192): the
# repaired stream decodes to exactly the original's samples from that frame on.
#
# Returns the bytes to send, or undef while more are needed to find a frame.
sub _opening {
    my ( $self, $seq, $cache, $bytes, $final ) = @_;

    my $buf = $cache->{pending} . $bytes;

    my $entry = $self->pbArmedFor($seq) || {};
    my $fmt   = lc( $entry->{fmt} || '' );

    # Too little to tell yet: four bytes say whether the header is there.
    if ( length($buf) < 4 && !$final ) {
        $cache->{pending} = $buf;
        return undef;
    }

    my $d;

    if ( Plugins::PlatinBridge::Format::lacksHeader( $fmt, $buf ) ) {

        my $skip = 0;

        if ( $fmt eq 'flc' ) {
            my $at = Plugins::PlatinBridge::Format::flacFrameStart( $buf, OPENING_MAX );

            if ( !defined $at && !$final && length($buf) < OPENING_MAX ) {
                $cache->{pending} = $buf;
                return undef;
            }

            $skip = $at || 0;
        }

        my ( $rate, $ch, $bits ) = $self->_streamFormat( $fmt, $buf, $skip, $entry->{song} );
        my $total = $self->_samplesToSend( $entry->{song}, $rate );
        my $hdr   = Plugins::PlatinBridge::Format::headerFor( $fmt, $rate, $ch, $bits, $total );

        if ($hdr) {
            $buf = $hdr . substr( $buf, $skip );
            $d = Plugins::PlatinBridge::Format::describeHeader($buf);
            $d->{synthesised} = 1;
            main::INFOLOG && $log->is_info && $log->info( sprintf '%s: track %d arrived with no %s header (a seek) - %s, %d bytes skipped to the first frame',
                $self->name, $seq, $fmt, Plugins::PlatinBridge::Format::describeText($d), $skip );
        }
        else {
            $d = Plugins::PlatinBridge::Format::describeHeader($buf);
            $log->warn( sprintf '%s: track %d has no %s header and its format is unknown - sent as it is', $self->name, $seq, $fmt );
        }
    }
    else {
        $d = Plugins::PlatinBridge::Format::describeHeader($buf);

        # A FLAC HEADER THAT DOES NOT SAY HOW LONG: an encoder writing to a pipe -
        # SqueezeDSP's flac - cannot go back to fill it in. The Hub takes a track's
        # length from the stream, not from the DIDL: with the UPnP Bridge, which
        # writes it, the length showed on the Hub; with 0 here it did not (Simon,
        # 2026-10-25). So the length LMS knows is written in.
        if ( $d->{container} eq 'FLAC' && defined $d->{samples} && $d->{samples} == 0 ) {
            if ( my $total = $self->_samplesToSend( $entry->{song}, $d->{rate} ) ) {
                $buf = Plugins::PlatinBridge::Format::withFlacTotalSamples( $buf, $total );
                $d   = Plugins::PlatinBridge::Format::describeHeader($buf);
                $d->{lengthAdded} = 1;
                main::INFOLOG && $log->is_info && $log->info( sprintf '%s: track %d - %s',
                    $self->name, $seq, Plugins::PlatinBridge::Format::describeText($d) );
            }
        }
    }

    $cache->{seen}    = 1;
    $cache->{pending} = '';
    $cache->{hdr}     = $d;

    Plugins::PlatinBridge::Trace::note( 'header', "track $seq: " . Plugins::PlatinBridge::Format::describeText($d) );

    return $buf;
}

# Rate, channels and depth for a header that has to be made: from the stream's
# own first frame where it says (the bytes describe themselves), else from what
# LMS knows of the track.
sub _streamFormat {
    my ( $self, $fmt, $buf, $at, $song ) = @_;

    my ( $rate, $ch, $bits );

    if ( $fmt eq 'flc' ) {
        if ( my $fi = Plugins::PlatinBridge::Format::flacFrameAt( $buf, $at ) ) {
            ( $rate, $ch, $bits ) = ( $fi->{rate}, $fi->{channels}, $fi->{bits} );
        }
    }

    my $t = $song ? eval { $song->currentTrack } : undef;

    $rate ||= $t ? scalar( eval { $t->samplerate } ) : undef;
    $bits ||= $t ? scalar( eval { $t->samplesize } ) : undef;
    $ch   ||= ( $t ? scalar( eval { $t->channels } ) : undef ) || 2;

    return ( $rate, $ch, $bits );
}

# The samples (frames, for PCM) the stream will carry: the track's length less
# where the stream starts (a seek, a resume, SqueezeDSP's restart), from what LMS
# knows of it. 0 when LMS does not know (a radio stream).
sub _samplesToSend {
    my ( $self, $song, $rate ) = @_;

    return 0 unless $song && $rate;

    my $secs = scalar( eval { $song->duration } ) || 0;
    if ( !$secs ) {
        my $t = scalar( eval { $song->currentTrack } );
        $secs = $t ? ( scalar( eval { $t->secs } ) || 0 ) : 0;
    }

    my $seek = scalar( eval { $song->seekdata } );
    my $from = ( $seek && $seek->{timeOffset} ) || 0;

    my $left = $secs - $from;
    return $left > 0 ? int( $left * $rate + 0.5 ) : 0;
}

# What the stream of track $seq said it was, for `platinbridge info`.
sub pbWireFor {
    my ( $self, $seq ) = @_;
    my $c = $self->pbCacheFor($seq) or return '';
    return Plugins::PlatinBridge::Format::describeText( $c->{hdr} );
}

sub _record {
    my ( $self, $cache, $ref ) = @_;

    return unless $cache;

    my $len = length $$ref;
    $cache->{total} += $len;

    return if $cache->{capped};

    if ( length( $cache->{buf} ) + $len <= HEAD_MAX ) {
        $cache->{buf} .= $$ref;
    }
    else {
        # Past the limit nothing more is kept, but what is kept is still the
        # unbroken OPENING - which is the part a re-opened connection needs.
        $cache->{capped} = 1;
    }

    return;
}

sub _carried {
    my ( $self, $n ) = @_;

    my $before = $self->pbConnBytes || 0;
    $self->pbConnBytes( $before + $n );

    # The single most useful fact when nothing is audible: did any audio actually
    # leave the server on this connection.
    Plugins::PlatinBridge::Trace::note( 'first-bytes', "$n bytes" ) if !$before;

    return;
}

# The track's stream has ended: every byte is with the Hub, which is still playing
# it out of its own buffer. LMS's own contract for a player fed over HTTP
# (Slim::Player::HTTP): the stream is over, and this player can take another. LMS
# then streams the next track and calls play() for it, which arms it on the Hub.
#
# NOTHING ELSE ASKS LMS FOR THE NEXT TRACK. The hand-over (_handedOver) used to
# call playerReadyToStream as well, and in the PLAYING/STREAMING cell that is
# _NextIfMore - it would open a THIRD track and cut off the one still streaming.
# LMS waits by itself while a streamed track has not started (_NextIfMore: "wait
# until the streaming one starts to play"), so the end of stream is enough.
sub _atEndOfStream {
    my ( $self, $cache ) = @_;

    my $empty = '';

    $cache->{eof} = 1 if $cache;

    Plugins::PlatinBridge::Trace::note( 'end-of-stream', ( $cache ? "$cache->{total} bytes" : '' ) );

    main::INFOLOG && $log->is_info && $log->info( $self->name . ': stream ended' );

    if ( my $c = $self->controller ) {
        $c->playerEndOfStream($self);
        $c->playerReadyToStream($self);
    }

    return \$empty;
}

# The opening of the track the Hub is playing is kept for HEAD_KEEP_PLAYED
# seconds of playback; after that a re-open is a reconnect, not the probe.
sub _dropPlayedHead {
    my $self = shift;

    my $cache = $self->pbCacheFor( $self->pbPlayingSeq ) or return;

    return unless length $cache->{buf};

    $cache->{buf}    = '';
    $cache->{capped} = 1;

    return;
}

# ---------------------------------------------------------------------------
# The armed-track registry: each url's track and stream format, under the
# sequence number the url carries.

sub pbArmedFor {
    my ( $self, $seq ) = @_;
    return undef unless defined $seq;
    my $armed = $self->pbArmed or return undef;
    return $armed->{$seq};
}

sub _arm {
    my ( $self, $seq, $entry ) = @_;

    my $armed = $self->pbArmed || {};
    $armed->{$seq} = $entry;

    # Keep only the last few. NOT named $a - a lexical $a shadows sort's package
    # variable and the comparison silently stops working.
    if ( scalar keys %$armed > 4 ) {
        my @old = sort { $a <=> $b } keys %$armed;
        delete $armed->{ shift @old } while scalar keys %$armed > 4;
    }

    $self->pbArmed($armed);

    return;
}

# ---------------------------------------------------------------------------
# Generations - every async callback of a load is stamped, so a superseded load
# cannot act on a player that has moved on.

sub _newGeneration {
    my $self = shift;

    my $g = ( $self->pbGeneration || 0 ) + 1;
    $self->pbGeneration($g);

    $self->pbArmNext(0);
    $self->pbArmedURL(undef);
    $self->pbArmedSeq(undef);
    $self->pbArmedFetched(undef);
    $self->pbHeld(undef);
    $self->pbHubEnded(0);

    Slim::Utils::Timers::killTimers( $self, \&_startDeadline );

    return $g;
}

sub _superseded {
    my ( $self, $g ) = @_;
    return ( ( $self->pbGeneration || 0 ) != $g ) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Transport

# play() is called for two things: "start this now", and "here is the next track".
# pbArmNext says which. It is set once a track is loaded and cleared by stop(),
# and LMS stops a player before every start it asks for - play, skip, jump, seek -
# so any play() between a load and a stop is the next track.
sub play {
    my ( $self, $params ) = @_;

    my $song = $params->{song} || ( $self->controller && $self->controller->streamingSong );

    if ( !$song ) {
        $log->warn( $self->name . ': play with no song' );
        return 0;
    }

    my $fmt = eval { $song->streamformat } || '';

    # The Hub has already reached the end of what it was given, so a "next" track
    # is now simply the track to start.
    if ( $self->pbArmNext && !$self->pbHubEnded ) {
        return $self->_armNextURI( $song, $fmt ) if $self->pbPerTrack;
        return $self->_hold( $song, $fmt );
    }

    return $self->_startTrack( $song, $fmt );
}

sub _startTrack {
    my ( $self, $song, $fmt ) = @_;

    my $g = $self->_newGeneration;

    my $upnp = $self->pbUPnP;

    if ( !$upnp || !$upnp->isReady ) {
        $self->_loadFailed('the renderer has not been described');
        return 0;
    }

    my $seq = ( $self->pbSeq || 0 ) + 1;
    $self->pbSeq($seq);

    $self->pbPrevURL( $self->pbURL );
    $self->pbStarted(0);
    $self->pbPlayAck(0);
    $self->pbPosition(0);
    $self->pbClockAt(undef);
    $self->pbLastPlayPos(undef);
    $self->pbStartedAt(0);
    $self->pbStopSeen(0);
    $self->pbClockAbs(undef);
    $self->pbLoadAt( Time::HiRes::time() );
    $self->pbSessionLost(0);
    $self->pbHubPaused(0);
    $self->pbPauseTries(0);

    # What the Hub last reported was about the track before. Left standing, a
    # PAUSED from it would make a pause pressed in LMS in the next second look
    # like one the Hub had already made (pause() sends nothing then), and the
    # new track's PLAYING then resume LMS.
    $self->pbHubState('');

    # Gapless is the Hub's own SetNextAVTransportURI. One that does not list it
    # gets each next track at the end of the one before (_hold).
    $self->pbPerTrack( $upnp->canGapless ? 1 : 0 );

    my $seek = $song->seekdata && $song->seekdata->{timeOffset};
    $self->pbStartOffset( $seek || 0 );

    my $url = Plugins::PlatinBridge::Stream->urlFor( $self, $fmt, $seq );

    $self->_arm( $seq, { song => $song, fmt => $fmt, url => $url } );

    $self->pbLiveSeq($seq);
    $self->pbPlayingSeq($seq);
    $self->pbURL($url);
    $self->pbAwaitURI($url);
    $self->pbAwaitURIAt( Time::HiRes::time() );
    $self->pbWanted('play');
    $self->pbArmNext(1);

    # bufferReady must be asserted BEFORE anything can ask. Nothing sets it for a
    # virtual player - on real hardware it comes from a STAT packet.
    $self->bufferReady(1);

    # A Hub on another input plays nothing it is sent. Playing on this player is
    # an explicit request for it, so put it on Streaming first.
    $self->_toStreaming;

    my $didl = $self->_didl( $song, $url, $fmt, $seek );

    my $at = $seek ? sprintf( ' at %d s', $seek ) : '';

    main::INFOLOG && $log->is_info && $log->info( sprintf '%s: load %s (%s)%s', $self->name, $url, ( $fmt || '?' ), $at );

    Plugins::PlatinBridge::Trace::note( 'load', "$url " . ( $fmt || '?' ) . $at );

    $upnp->stop( sub {
        return if $self->_superseded($g);

        $upnp->setURI( $url, $didl, sub {
            my ( $res, $err ) = @_;
            return if $self->_superseded($g);

            if ($err) {
                $self->_loadFailed("SetAVTransportURI failed: $err");
                return;
            }

            $self->_play($g);
        } );
    } );

    return 1;
}

# SetAVTransportURI returns on ACCEPTANCE, not readiness - a Play too soon after
# it fails UPnP 702 "no contents". Retry on a backoff, bounded.
use constant PLAY_RETRIES => 8;
use constant PLAY_BACKOFF => 0.4;

sub _play {
    my ( $self, $g, $try ) = @_;

    return if $self->_superseded($g);

    $try ||= 0;

    $self->pbUPnP->play( sub {
        my ( $res, $err ) = @_;
        return if $self->_superseded($g);

        if ( !$err ) {
            $self->pbPlayAck(1);
            $self->_armStartDeadline($g);
            return;
        }

        if ( $try < PLAY_RETRIES ) {
            Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + PLAY_BACKOFF,
                sub { $_[0]->_play( $g, $try + 1 ) } );
            return;
        }

        $self->_loadFailed( 'Play refused after ' . PLAY_RETRIES . " attempts: $err" );
    } );

    return;
}

sub _armStartDeadline {
    my ( $self, $g ) = @_;

    Slim::Utils::Timers::killTimers( $self, \&_startDeadline );
    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + START_DEADLINE, \&_startDeadline, $g );

    return;
}

# A Play that is acked but never becomes playback must not leave LMS believing it
# is playing for ever. Not a failure: a superseded load, a track paused inside
# the window, one that did start.
sub _startDeadline {
    my ( $self, $g ) = @_;

    return if $self->_superseded($g);
    return if $self->pbStarted;
    return if ( $self->pbWanted || '' ) ne 'play';

    $self->_loadFailed( 'the Hub acknowledged Play but never started within ' . START_DEADLINE . 's' );

    return;
}

sub pause {
    my $self = shift;

    $self->pbWanted('pause');
    $self->pbPauseTries(0);

    # PAUSED AT THE HUB (its remote, its app): it is paused already, and LMS is
    # only catching up. Sending Pause back is not merely redundant - it reaches the
    # Hub up to ~1.5 s after the press (the 1 s poll, then LMS's fade), and if play
    # was pressed in between it pauses the Hub AGAIN: the remote's resume "not
    # taking", intermittently.
    if ( ( $self->pbHubState || '' ) eq 'PAUSED_PLAYBACK' ) {
        $self->pbHubPaused(1);
        return 1;
    }

    $self->pbHubPaused(0);
    $self->_sendPause;

    return 1;
}

sub _sendPause {
    my $self = shift;

    $self->pbPauseSentAt( Time::HiRes::time() );
    $self->pbPauseTries( ( $self->pbPauseTries || 0 ) + 1 );
    $self->pbUPnP && $self->pbUPnP->pause;

    return;
}

sub resume {
    my $self = shift;

    $self->pbHubPaused(0);
    $self->pbPauseTries(0);

    # THE HUB WAS SWITCHED OFF (or left its Streaming input) while this track was
    # paused. Switching off is a stop on the Hub - its playback is terminated, not
    # suspended - so a UPnP Play would have it fetch the track again from the top
    # while LMS's clock says otherwise. Ask LMS to start the track again where it
    # was instead: a fresh stream, from the right place.
    if ( $self->pbSessionLost ) {
        $self->pbSessionLost(0);
        $self->pbWanted('play');
        $self->_restartWhereItWas;
        return 1;
    }

    # LMS's _AutoStart resumes every player when a short track's stream ends before
    # the track has started - for this player that is a track that is playing.
    return 1 if ( $self->pbWanted || '' ) eq 'play' && $self->pbStarted;

    $self->pbWanted('play');
    $self->_toStreaming;
    $self->pbUPnP && $self->pbUPnP->play;

    return 1;
}

# One turn later, never inside the controller call that brought us here.
sub _restartWhereItWas {
    my $self = shift;

    my $g = $self->pbGeneration;

    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + 0.01, sub {
        my $s = shift;
        return if $s->_superseded($g);

        my $c    = $s->controller or return;
        my $song = eval { $c->playingSong };
        my $pos  = eval { $c->playingSongElapsed } || 0;

        if ( $song && eval { $song->canSeek } ) {
            main::INFOLOG && $log->is_info && $log->info( sprintf '%s: the Hub was off - starting the track again at %d s', $s->name, $pos );
            $s->execute( [ 'time', $pos ] );
        }
        else {
            my $idx = eval { Slim::Player::Source::playingSongIndex($s) };
            main::INFOLOG && $log->is_info && $log->info( $s->name . ': the Hub was off - starting the track again' );
            $s->execute( [ 'playlist', 'index', $idx ] ) if defined $idx;
        }
    } );

    return;
}

sub stop {
    my $self = shift;

    # A NEXT TRACK ARMED ON THE HUB IS VOID ONCE LMS STOPS (a skip, a seek, a new
    # album). Stop and SetAVTransportURI leave gmrender's next uri in place:
    # measured 2026-10-25 11:43:06, the Hub playing 7.flac still held 5.flac,
    # armed before an LMS skip - at the end of a playlist it would have moved on
    # to that stale track.
    if ( defined $self->pbArmedURL && ( my $u = $self->pbUPnP ) ) {
        $u->setNextURI( '', '', undef ) if $u->canGapless;
    }

    $self->_newGeneration;
    $self->pbWanted('stop');
    $self->pbStarted(0);
    $self->pbPlayAck(0);
    $self->pbStopSeen(0);
    $self->bufferReady(0);

    # RELEASE THE STREAMING SOCKET. LMS will not, for this class.
    $self->closeStream;

    # Nothing of the stopped stream can be served again.
    $self->pbCaches( {} );
    $self->pbLiveSeq(undef);
    $self->pbPlayingSeq(undef);

    $self->pbUPnP && $self->pbUPnP->stop;

    Plugins::PlatinBridge::Trace::note( 'stop', 'streaming socket released' );

    return 1;
}

# LMS discarded the track it had streamed next (a playlist edit) and will hand
# over a replacement. The Hub may already hold the discarded one as its next uri,
# so take it back - and end any connection drawing on it, or the replacement's
# bytes would arrive under the discarded track's url.
sub flush {
    my $self = shift;

    if ( defined( my $seq = $self->pbArmedSeq ) ) {
        if ( my $u = $self->pbUPnP ) {
            $u->setNextURI( '', '', undef ) if $u->canGapless;
        }

        $self->closeStream if defined $self->pbStreamSeq && $self->pbStreamSeq == $seq;

        my $caches = $self->pbCaches || {};
        delete $caches->{$seq};

        $self->pbArmedURL(undef);
        $self->pbArmedSeq(undef);
        $self->pbArmedFetched(undef);
    }

    $self->pbHeld(undef);
    $self->pbLiveSeq( $self->pbPlayingSeq );
    $self->pbArmNext(1);

    return 1;
}

# Pre-arm the next track on the Hub. Gapless is then the RENDERER's job - it holds
# the next uri when the current track ends, so there is no round trip through LMS
# at the boundary, and that round trip is the gap.
sub _armNextURI {
    my ( $self, $song, $fmt ) = @_;

    my $upnp = $self->pbUPnP or return 0;

    my $seq = ( $self->pbSeq || 0 ) + 1;
    $self->pbSeq($seq);

    my $url = Plugins::PlatinBridge::Stream->urlFor( $self, $fmt, $seq );

    $self->_arm( $seq, { song => $song, fmt => $fmt, url => $url } );

    # LMS has opened this track's source to call us: from here its bytes are the
    # live stream.
    $self->pbLiveSeq($seq);
    $self->pbArmedURL($url);
    $self->pbArmedSeq($seq);
    $self->pbArmedFetched(undef);
    $self->pbHeld(undef);

    main::INFOLOG && $log->is_info && $log->info( $self->name . ": arming next uri $url" );

    my $g = $self->pbGeneration;

    $upnp->setNextURI( $url, $self->_didl( $song, $url, $fmt ), sub {
        my ( $res, $err ) = @_;

        return unless $err;
        return if $self->_superseded($g);

        # A refused pre-arm is NOT a streaming failure - reporting it would make
        # LMS tear down the track that is playing perfectly well. The track is
        # held instead and started when the Hub reaches the end of this one.
        $log->warn( $self->name . ": the Hub refused the next uri ($err) - it will start at the end of this track" );
        $self->pbArmedURL(undef);
        $self->pbArmedSeq(undef);
        $self->pbHeld( { song => $song, fmt => $fmt } );
    } );

    $self->bufferReady(1);

    return 1;
}

# A Hub that cannot pre-arm gets the next track at the end of this one.
sub _hold {
    my ( $self, $song, $fmt ) = @_;

    $self->pbHeld( { song => $song, fmt => $fmt } );
    $self->bufferReady(1);

    return 1;
}

# The Hub moved on to the uri we armed.
sub _handedOver {
    my ( $self, $why ) = @_;

    my $armed = $self->pbArmedURL or return 0;
    my $seq   = $self->pbArmedSeq;

    main::INFOLOG && $log->is_info && $log->info( $self->name . ": handed over to $armed ($why)" );

    Plugins::PlatinBridge::Trace::note( 'hand-over', "$armed - $why" );

    # The previous track's opening is no longer needed by anyone.
    my $caches = $self->pbCaches || {};
    delete $caches->{ $self->pbPlayingSeq } if defined $self->pbPlayingSeq;

    $self->pbPrevURL( $self->pbURL );
    $self->pbURL($armed);
    $self->pbPlayingSeq($seq);
    $self->pbArmedURL(undef);
    $self->pbArmedSeq(undef);
    $self->pbArmedFetched(undef);
    $self->pbPosition(0);
    $self->pbClockAt(undef);
    $self->pbLastPlayPos(undef);
    $self->pbStartOffset(0);
    $self->pbClockAbs(undef);
    $self->pbAwaitURI(undef);
    $self->pbStartedAt( time() );
    $self->pbStopSeen(0);
    $self->pbFailRun(0);

    my $c = $self->controller or return 1;

    # Only the start. LMS asks for the track after this one itself - see
    # _atEndOfStream for why a second ReadyToStream here would cut one short.
    $c->playerTrackStarted($self);

    return 1;
}

# THE HUB'S TrackURI LEADS ITS CLOCK at a gapless change it was armed for in
# time: it reports the next uri 1.25-1.5 s before the music and its RelTime move
# over, still carrying the OLD track's RelTime (21.flac at 4:21 and 4:22, then
# 0:00:00 - measured 2026-10-25, `LMS'S CLOCK IS THE LAST POLL`). Handed over at
# the uri, LMS showed the next title early, and its newsong push started
# Material's clock at 0 while the old track was still playing. So the change
# waits for the clock to go back - for URI_LEAD at most, so a Hub whose clock
# never does still hands over, as before.
sub _uriHandOver {
    my ( $self, $armed, $secs ) = @_;

    my $was = $self->pbLastPlayPos;

    # Nothing to tell by, or the clock is the new track's already.
    if ( !defined $secs || !defined $was || $secs <= FRESH_CLOCK || $secs + 2 < $was ) {
        return $self->_handedOver('the Hub reports the new uri');
    }

    my $now  = Time::HiRes::time();
    my $seen = $self->pbArmedSeen;

    if ( !$seen || $seen->[0] ne $armed ) {
        $self->pbArmedSeen( [ $armed, $now ] );
        return 0;
    }

    return 0 if $now - $seen->[1] < URI_LEAD;

    return $self->_handedOver('the Hub reports the new uri - its clock never went back');
}

# THE HUB'S TrackURI LAGS a gapless change it was armed for late (measured on the
# UPnP Bridge 2026-10-24, `THE TRACK LAG IS THE BRIDGE`): its clock goes back to 0
# at the boundary but TrackURI stays on the old track until the new one has fully
# downloaded, so a hand-over keyed on TrackURI alone leaves LMS a track behind -
# and, since the track after is asked for only at the next end of stream, keeps it
# there. This player has evidence the bridge does not: it SEES the Hub fetch the
# armed url. A clock that goes back to the start, at the end of the old track,
# after that fetch, is the change.
sub _rolledOver {
    my ( $self, $secs ) = @_;

    return 0 unless defined $secs && $self->pbArmedFetched;

    my $was = $self->pbLastPlayPos;
    return 0 unless defined $was;
    return 0 unless $secs <= 3 && $secs + 2 < $was;

    my $dur = eval { $self->controller->playingSongDuration };
    return 0 unless $dur;

    return ( $was + $self->_clockOffset >= $dur - NEAR_END ) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Failure bounding

sub _loadFailed {
    my ( $self, $why ) = @_;

    my $run = ( $self->pbFailRun || 0 ) + 1;
    $self->pbFailRun($run);

    $log->warn( $self->name . ": load failed ($run/" . FAIL_LIMIT . "): $why" );

    my $c = $self->controller or return;

    if ( $run < FAIL_LIMIT ) {
        $c->playerStreamingFailed( $self, 'PROBLEM_OPENING' );
        return;
    }

    # Reset on the trip so the user's next play gets a fresh three, and stop via
    # the CONTROLLER rather than reporting another skippable failure.
    $self->pbFailRun(0);
    $log->error( $self->name . ': stopping - ' . FAIL_LIMIT . ' consecutive failed loads' );

    my $g = $self->pbGeneration;
    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + 0.01, sub {
        my $s = shift;
        return if $s->_superseded($g);
        $s->execute( ['stop'] );
    } );

    return;
}

# ---------------------------------------------------------------------------
# Power: LMS's power button switches the Hub, and the Hub's switches LMS.
#
# LMS calls audio_outputs_enable(0|1) on every power change of a player - it is
# LMS's own hook for "this player's outputs", what a Squeezebox uses to switch
# its DAC. Simon 2026-10-25: LMS power-off switches the Hub off ONLY when it is
# on its Streaming input, so an LMS power-off (or an "all players off") never cuts
# the television.

sub audio_outputs_enable {
    my ( $self, $on ) = @_;

    # LMS is following the Hub - nothing to send back.
    return if $self->pbMirroring;

    # NEVER TOGGLE BLIND. LMS calls this at player creation with the SAVED power
    # state; at that moment there is no link and no state, and acting would let
    # an LMS restart switch the Hub. The Hub's own state is adopted instead when
    # the link comes up (_onHubPower, first report).
    my $ctl = $self->pbControl or return;
    return unless $ctl->isUp && defined $ctl->power;

    Slim::Utils::Timers::killTimers( $self, \&_powerOnLater );

    if ( !$on ) {
        my $streaming = $ctl->onStreaming;

        if ( !$streaming ) {
            main::INFOLOG && $log->is_info && $log->info( sprintf '%s: powered off in LMS - the Hub is left on, it is on %s',
                $self->name, ( $ctl->source ? $ctl->source->{name} : 'another input' ) );
            return;
        }

        $ctl->setPower(0);
        return;
    }

    $self->pbPowerOnAt( Time::HiRes::time() );
    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + POWER_ON_WAIT, \&_powerOnLater );

    return;
}

sub _powerOnLater {
    my $self = shift;

    # Playback started since the button was pressed: the Hub switches itself on
    # when the stream arrives (that is how LMS used to wake it), and a toggle sent
    # now could cross that and switch it straight back off.
    return if $self->pbLoadAt && $self->pbPowerOnAt && $self->pbLoadAt >= $self->pbPowerOnAt;

    return unless $prefs->client($self)->get('power');

    my $ctl = $self->pbControl or return;
    return unless $ctl->isUp;

    $ctl->setPower(1);

    return;
}

# The Hub's power changed - its remote, the Platin app, its own standby, or our
# own command ($own: then LMS is already where the Hub is).
sub _onHubPower {
    my ( $self, $on, $own, $first ) = @_;

    # Switching off terminates the Hub's playback. A paused track cannot simply be
    # resumed after it.
    $self->_sessionLost if !$on && $self->pbURL;

    return if $own;

    my $lms = $prefs->client($self)->get('power') ? 1 : 0;

    return if $lms == ( $on ? 1 : 0 );

    main::INFOLOG && $log->is_info && $log->info( $self->name . ': the Hub was switched ' . ( $on ? 'on' : 'off' )
        . ( $first ? ' (found that way)' : '' ) . ' - following it in LMS' );

    # ON IS NEVER PLAY - Design rule 1. The Hub also switches itself on (a source
    # starting, the television), and that must not start LMS. `power 1 1` is LMS's
    # own "on, without resuming".
    $self->pbMirroring(1);
    eval { $self->execute( $on ? [ 'power', 1, 1 ] : [ 'power', 0 ] ); 1 }
        or $log->error( $self->name . ": could not follow the Hub's power: $@" );
    $self->pbMirroring(0);

    return;
}

# Simon 2026-10-25: the Hub switched away from Streaming while LMS plays to it
# -> LMS pauses and keeps its place.
# THE HUB'S OWN PLAYBACK HAS ENDED (it was switched off, or left Streaming). The
# next play starts the track again where it was (resume), and the next track
# LMS had armed is forgotten: the Hub may move its transport on to that uri by
# itself (it does, leaving Streaming), and that is not a gapless change. The
# restart arms it again in the ordinary way.
sub _sessionLost {
    my $self = shift;

    $self->pbSessionLost(1);
    $self->pbArmedURL(undef);
    $self->pbArmedSeq(undef);
    $self->pbArmedFetched(undef);

    return;
}

sub _onHubSource {
    my ( $self, $now, $was ) = @_;

    return if Plugins::PlatinBridge::Control::isStreaming($now);
    return unless $was && Plugins::PlatinBridge::Control::isStreaming($was);

    # Whatever the Hub was playing for us has stopped with the switch.
    $self->_sessionLost if $self->pbURL;

    return unless ( $self->pbWanted || '' ) eq 'play';

    main::INFOLOG && $log->is_info && $log->info( $self->name . ": the Hub switched to $now->{name} - pausing" );

    eval { $self->execute( [ 'pause', 1 ] ); 1 } or $log->error( $self->name . ": could not pause: $@" );

    return;
}

sub _toStreaming {
    my $self = shift;

    my $ctl = $self->pbControl or return;
    return unless $ctl->isUp;

    my $on = $ctl->onStreaming;
    return if !defined $on || $on;

    $ctl->selectStreaming;

    return;
}

# ---------------------------------------------------------------------------
# Volume
#
# SHARED, NOT OWNED. The Hub's own remote moves it too, so each side declines to
# correct what the other set - otherwise a level set on the handset is dragged
# back by LMS re-asserting its stored volume at the next track start (bug 10310).

sub _volRange {
    my $self = shift;
    my $u    = $self->pbUPnP;
    my $r    = $u && $u->volRange;
    return $r || { min => 0, max => 100, step => 1 };
}

# Clamped to the Hub's range. LMS hands a MUTED player its volume as a negative
# number (Player::mute keeps the level to come back to that way); unclamped, a
# mute at 29 went to the Hub as -28.
sub _toDevice {
    my ( $self, $lms ) = @_;
    my $r = $self->_volRange;
    my $v = int( $r->{min} + ( $r->{max} - $r->{min} ) * ( $lms / 100 ) + 0.5 );
    $v = $r->{min} if $v < $r->{min};
    $v = $r->{max} if $v > $r->{max};
    return $v;
}

sub _fromDevice {
    my ( $self, $dev ) = @_;
    my $r    = $self->_volRange;
    my $span = ( $r->{max} - $r->{min} ) || 1;
    return int( ( $dev - $r->{min} ) * 100 / $span + 0.5 );
}

# Half a device step, expressed in LMS units - the tolerance both directions use.
sub _volTol {
    my $self = shift;
    my $r    = $self->_volRange;
    my $span = ( $r->{max} - $r->{min} ) || 1;
    return ( ( $r->{step} || 1 ) * 100 / $span ) / 2;
}

sub volume {
    my ( $self, $vol, $temp ) = @_;

    my $set = $self->SUPER::volume( $vol, $temp );

    # A temporary volume is the pause/resume fade ramp; sending those to the Hub
    # would be a burst of SOAP calls the user never asked for.
    return $set if $temp;
    return $set unless defined $vol;

    my $u = $self->pbUPnP or return $set;

    # MUTE IS THE HUB'S OWN MUTE. LMS mutes by keeping the level to come back to
    # as a NEGATIVE volume (Player::mute; 0 when it re-applies a stored mute). The
    # Hub is sent SetMute and keeps its level - what the UPnP Bridge does
    # (squeeze2upnp.c SQ_VOLUME: "some controllers send a volume < 0 to mute"),
    # which Simon had working. 0.2.2 sent the negative level as a VOLUME: the Hub
    # went to 0, the poll read that 0 back into LMS as a new level, and the unmute
    # had nothing to restore ("muting via material sends volume to 0 and it
    # doesnt return", 2026-10-25).
    if ( $vol < 0 || ( $vol == 0 && $prefs->client($self)->get('mute') ) ) {
        if ( !$self->pbMuted ) {
            $self->pbMuted(1);
            $self->_sendMute(1);
        }
        return $set;
    }

    # Unmuting - or the first level set since start, when the Hub may have been
    # left muted.
    if ( $self->pbMuted || !defined $self->pbMuted ) {
        $self->pbMuted(0);
        $self->_sendMute(0);
    }

    my $want = $self->_toDevice($vol);
    my $at   = $self->pbVolAt;

    if ( defined $at && abs( $self->_fromDevice($at) - $vol ) <= $self->_volTol ) {
        return $set;
    }

    $self->pbVolWant($want);
    $self->pbVolSentAt( Time::HiRes::time() );
    $u->setVolume( $want, sub {
        my ( $res, $err ) = @_;
        $self->pbVolWant(undef);
        $self->pbVolAt($want) unless $err;
    } );

    return $set;
}

sub _sendMute {
    my ( $self, $on ) = @_;

    my $u = $self->pbUPnP or return;

    $u->setMute( $on, sub {
        my ( $res, $err ) = @_;
        $log->warn( sprintf '%s: could not %s the Hub: %s', $self->name, ( $on ? 'mute' : 'unmute' ), $err ) if $err;
    } );

    return;
}

sub _followVolume {
    my ( $self, $dev ) = @_;

    return unless defined $dev;

    # A LEVEL WE SENT IS STILL ON ITS WAY: a reading taken before the Hub applied
    # it is the OLD level, and following it would put LMS back where it was (and,
    # mid-mute, unmute it). Readings wait for the Hub's answer - or VOL_SETTLE
    # seconds, if none comes.
    if ( defined $self->pbVolWant ) {
        return if Time::HiRes::time() - ( $self->pbVolSentAt || 0 ) < VOL_SETTLE;
        $self->pbVolWant(undef);
    }

    $self->pbVolAt($dev);

    my $lms  = $self->_fromDevice($dev);
    my $have = $prefs->client($self)->get('volume');

    # MUTED IN LMS the level is held NEGATIVE, and the Hub keeps that level under
    # its mute - so the two agree in size, not in sign. Compared signed, every poll
    # read as a change and set LMS's volume, which LMS takes as "unmute at this
    # level". The knob turned WHILE muted is still followed, and LMS then unmutes,
    # as its own IR does.
    $have = abs($have) if defined $have;

    # Compare against the PERSISTED volume - _Resume parks a temporary 0 there.
    return if defined $have && abs( $have - $lms ) <= $self->_volTol;

    main::INFOLOG && $log->is_info && $log->info( $self->name . ": following the Hub's volume to $lms" );

    $self->execute( [ 'mixer', 'volume', $lms ] );

    return;
}

# ---------------------------------------------------------------------------
# Status polling
#
# THE ONLY TRANSPORT SIGNAL. A Hub that does not answer has NO OPINION.

sub startPolling {
    my $self = shift;

    $self->stopPolling;

    # Polling starts on a Hub that has just been described, so it has just
    # answered. pbOutage is NOT cleared here: a Hub found again at a new address
    # (Plugin::_moved) is still in its outage until it answers the poll, and that
    # answer is what ends its silence in discovery (_hubAnswered).
    $self->pbLastSeen( time() );

    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + POLL_PERIOD, \&_poll );

    return;
}

sub stopPolling {
    my $self = shift;
    Slim::Utils::Timers::killTimers( $self, \&_poll );
    return;
}

sub _poll {
    my $self = shift;

    my $u = $self->pbUPnP;

    if ( !$u || !$u->isReady ) {
        Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + POLL_PERIOD, \&_poll );
        return;
    }

    $u->transportInfo( sub {
        my ( $res, $err ) = @_;

        if ( !$err && $res ) {
            $self->pbLastSeen( time() );
            $self->_hubAnswered;
            $self->_onTransport($res);
        }
        else {
            $self->_hubUnanswered;
        }

        $u->getVolume( sub {
            my ( $v, $verr ) = @_;
            $self->_followVolume( $v->{CurrentVolume} ) if !$verr && $v && defined $v->{CurrentVolume};

            $u->positionInfo( sub {
                my ( $p, $perr ) = @_;
                $self->_onPosition($p) if !$perr && $p;

                Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + POLL_PERIOD, \&_poll );
            } );
        } );
    } );

    return;
}

# THE POLL IS DISCOVERY'S LIVENESS SIGNAL. Once the plugin has its Hubs, discovery
# asks only every 10 minutes (Discovery::period), and a Hub that comes back at a
# NEW address - a DHCP lease after a power cut or a router restart - would sit
# unplayable for that long while this poll asked the old address. Nothing acted on
# the silence until 0.2.6 (found 2026-11-01, `A SILENT HUB IS LOOKED FOR`). Simon
# chose: unanswered for LOST_AFTER, discovery goes back to the 15 s search it runs
# before any Hub is found, until the Hub answers. Per player since 0.2.7
# (Discovery::setSilent), so another Hub answering does not end this one's search.
# Standby is not silence - the Hub answers on both ports while off. Unreachable is
# still no opinion (Design rule 2): nothing here touches the transport.
sub _hubUnanswered {
    my $self = shift;

    return if $self->pbOutage;
    return if time() - ( $self->pbLastSeen || 0 ) < LOST_AFTER;

    $self->pbOutage(1);

    $log->warn( $self->name . ': the Hub has not answered for ' . LOST_AFTER . ' s - looking for it on the network again' );
    Plugins::PlatinBridge::Trace::note( 'outage', 'discovery searching every 15 s' );

    Plugins::PlatinBridge::Discovery->setSilent( $self->id, 1 );
    Plugins::PlatinBridge::Discovery->probeNow;

    return;
}

sub _hubAnswered {
    my $self = shift;

    return unless $self->pbOutage;

    $self->pbOutage(0);

    main::INFOLOG && $log->is_info && $log->info( $self->name . ': the Hub answers again' );
    Plugins::PlatinBridge::Trace::note( 'outage', 'over' );

    Plugins::PlatinBridge::Discovery->setSilent( $self->id, 0 );

    return;
}

sub _onTransport {
    my ( $self, $res ) = @_;

    my $state = $res->{CurrentTransportState} || '';
    my $c     = $self->controller or return;

    $self->pbHubState($state);
    $self->pbStopSeen(0) if $state ne 'STOPPED';

    if ( $state eq 'PLAYING' ) {

        if ( !$self->pbStarted && $self->pbPlayAck ) {
            $self->pbStarted(1);
            $self->pbStartedAt( time() );
            $self->pbFailRun(0);          # a track that really played proves the link is healthy
            Slim::Utils::Timers::killTimers( $self, \&_startDeadline );
            $c->playerTrackStarted($self);
        }

        if ( ( $self->pbWanted || '' ) eq 'pause' ) {

            # PLAY PRESSED AT THE HUB on a track LMS had paused - but only if the Hub
            # had actually PAUSED. A Hub still PLAYING because our Pause has not
            # reached it, or failed (it answered 500 to every Pause while stuck,
            # 2026-10-25), is not a resume: following it made LMS's pause button
            # bounce straight back to play.
            if ( $self->pbHubPaused ) {
                main::INFOLOG && $log->is_info && $log->info( $self->name . ': resumed from the Hub' );
                $self->pbWanted('play');

                # The Hub is playing out of its own buffer. LMS, resuming a paused
                # track whose stream has finished, would otherwise RELOAD it at
                # the paused position (_JumpOrResume, because _Pause always records
                # resumeTime): a stop, a new url and a re-buffer under a Hub that
                # had already resumed - the laggy resume. Without resumeTime LMS
                # only changes state.
                eval { delete $c->{resumeTime} };

                $c->resume if $c->isPaused;
            }
            elsif ( Time::HiRes::time() - ( $self->pbPauseSentAt || 0 ) >= PAUSE_RETRY
                && ( $self->pbPauseTries || 0 ) < PAUSE_TRIES )
            {
                main::INFOLOG && $log->is_info && $log->info( $self->name . ': the Hub has not paused yet - asking again' );
                $self->_sendPause;
            }
        }

        $c->playerStatusHeartbeat($self);
        return;
    }

    if ( $state eq 'PAUSED_PLAYBACK' ) {

        # Only act if WE did not ask for it - compare against the last state we
        # commanded, never against the controller's own, which _Pause sets ~300ms
        # before calling pause().
        if ( ( $self->pbWanted || '' ) eq 'play' && $self->pbStarted ) {
            main::INFOLOG && $log->is_info && $log->info( $self->name . ': paused from the Hub' );
            $self->pbWanted('pause');
            $self->pbHubPaused(1);
            $c->pause unless $c->isPaused;
        }

        # The Hub acting on a Pause we sent.
        $self->pbHubPaused(1) if ( $self->pbWanted || '' ) eq 'pause';

        $c->playerStatusHeartbeat($self);
        return;
    }

    $self->_onHubStopped($c) if $state eq 'STOPPED';

    # TRANSITIONING / NO_MEDIA_PRESENT: nothing.
    return;
}

# THE HUB REPORTED STOPPED. This is where the old bridge's bug lived: a stop read
# as "move on" made LMS play, which woke the Hub. Here a stop only ever STOPS LMS,
# and only in the two cases where that is known to be right:
#
#   * the natural end: the Hub played what it was given to the end and nothing
#     was armed. LMS is told the player stopped (or the track it holds is
#     started), exactly as a Squeezebox's STAT would say;
#   * a stop part way through while the Hub is still switched ON - someone
#     pressed stop at the Hub. LMS stops too.
#
# A stop with the Hub OFF is the power-off, which the power path answers (LMS
# powers off and pauses). A stop when the power cannot be read is no opinion.
#
# playerStopped is used ONLY when LMS is not streaming anything. In the TRACKWAIT
# cell LMS answers it with _PlayIfReady, which STARTS the next track - the wake
# bug by another door.
sub _onHubStopped {
    my ( $self, $c ) = @_;

    return unless $self->pbStarted;

    my $w = $self->pbWanted || '';
    return unless $w eq 'play' || $w eq 'pause';

    return if $self->pbStartedAt && ( time() - $self->pbStartedAt ) < START_GRACE;

    my $n = ( $self->pbStopSeen || 0 ) + 1;
    $self->pbStopSeen($n);
    return if $n < STOP_POLLS;

    if ( !$self->pbArmedURL && $self->_atTrackEnd($c) ) {

        if ( my $h = $self->pbHeld ) {
            main::INFOLOG && $log->is_info && $log->info( $self->name . ': the track ended - starting the next' );
            $self->pbHeld(undef);
            $self->_startTrack( $h->{song}, $h->{fmt} );
            return;
        }

        if ( $self->_lmsIdle($c) ) {
            main::INFOLOG && $log->is_info && $log->info( $self->name . ': the last track has finished' );
            $self->pbWanted('stop');
            $self->pbStarted(0);
            $self->pbPlayAck(0);
            $c->playerStopped($self);
            return;
        }

        # LMS is still finding the next track. When it arrives it has to be
        # STARTED - the Hub is past the point where a next uri would be used.
        $self->pbHubEnded(1);
        return;
    }

    my $ctl = $self->pbControl;

    if ( $ctl && $ctl->isUp && $ctl->power ) {
        main::INFOLOG && $log->is_info && $log->info( $self->name . ': stopped at the Hub - stopping LMS' );
        $self->pbWanted('stop');
        eval { $self->execute( ['stop'] ); 1 } or $log->error( $self->name . ": could not stop: $@" );
    }

    return;
}

sub _atTrackEnd {
    my ( $self, $c ) = @_;

    my $was = $self->pbLastPlayPos;
    return 0 unless defined $was;

    my $dur = eval { $c->playingSongDuration };
    return 0 unless $dur;

    return ( $was + $self->_clockOffset >= $dur - NEAR_END ) ? 1 : 0;
}

sub _lmsIdle {
    my ( $self, $c ) = @_;

    return 0 if eval { $c->isStreaming } || eval { $c->isStreamout };

    my $s = eval { $c->{streamingState} };

    return ( !defined $s || $s == 0 ) ? 1 : 0;
}

sub _onPosition {
    my ( $self, $p ) = @_;

    my $secs = Plugins::PlatinBridge::UPnP::timeToSecs( $p->{RelTime} );

    # GetPositionInfo carries the uri the renderer is playing. Checked before the
    # clock, because the position that follows belongs to the NEW track.
    #
    # A HAND-OVER IS A TRACK THE HUB IS PLAYING. Switched off its Streaming input,
    # the Hub moves its transport on to the armed uri and stays PAUSED (measured
    # 2026-10-25 10:44:35). Read as a hand-over, LMS was told the track had
    # started, and LMS answers Started in PAUSED with _Playing: it un-paused itself
    # over a Hub that stayed paused, and only a skip in LMS moved it again.
    my $armed = $self->pbArmedURL;
    $armed = undef unless ( $self->pbHubState || '' ) eq 'PLAYING' && !$self->pbSessionLost;

    my $handed = 0;

    if ($armed) {
        if ( defined $p->{TrackURI} && $p->{TrackURI} eq $armed ) {
            $handed = $self->_uriHandOver( $armed, $secs );
        }
        elsif ( $self->_rolledOver($secs) ) {
            $handed = $self->_handedOver('its clock went back to the start after it fetched the next track');
        }
    }

    return unless defined $secs;

    # A POSITION THAT BELONGS TO ANOTHER TRACK. Right after a load the Hub still
    # answers for the track it was playing; and the report that brings a hand-over
    # can still carry the old track's RelTime. Applied to the new track, LMS showed
    # the old clock for a second - 81 s and 38 s after hand-overs, and after an
    # LMS skip 252 s, which LMS clamps to the new track's length (217.3 s, measured
    # 2026-10-25). So a hand-over's own report sets the clock only when it reads
    # the start of the new track (FRESH_CLOCK), and after a load none counts until
    # the Hub reports the new uri (or AWAIT_URI passes). The clock roll-over
    # hand-over is NOT gated on the uri: there the Hub's TrackURI lags, and its
    # clock is the new track's.
    return if $handed && $secs > FRESH_CLOCK;

    if ( my $await = $self->pbAwaitURI ) {
        my $uri = $p->{TrackURI};
        if ( defined $uri && length $uri && $uri ne $await
            && Time::HiRes::time() - ( $self->pbAwaitURIAt || 0 ) < AWAIT_URI )
        {
            return;
        }
        $self->pbAwaitURI(undef);
    }

    # After a seek LMS streams from the seek point, so the Hub's clock normally
    # starts at 0 - LMS adds the offset itself. A native FLAC seeked by byte keeps
    # its frames' own sample numbers, though, and the Hub's clock can then start
    # AT the offset. The first report after the start says which.
    if ( !defined $self->pbClockAbs && $self->pbStarted && ( $self->pbStartOffset || 0 ) > 5 ) {
        $self->pbClockAbs( $secs >= $self->pbStartOffset - 3 ? 1 : 0 );
    }

    $self->pbPosition($secs);
    $self->pbLastPlayPos($secs) if ( $self->pbHubState || '' ) eq 'PLAYING';
    $self->_runClock($secs);

    $self->_dropPlayedHead if $self->pbStarted && $secs >= HEAD_KEEP_PLAYED;

    return;
}

# THE CLOCK RUNS ON BETWEEN POLLS. The Hub reports whole seconds once a poll
# (~1 s). Handed to LMS as they were, LMS read 0.75-1.5 s behind the Hub, and
# Material, which re-syncs its own ticking clock to LMS's on every status it
# gets, was pulled back a second or two each time (measured 2026-10-25, `LMS'S
# CLOCK IS THE LAST POLL`). A Squeezebox's clock runs on between STATs
# (Squeezebox2::songElapsedSeconds); this one runs on between reports.
#
# The estimate is kept INSIDE the second the Hub reports - it has reached that
# second and not the next - so LMS turns each second when the Hub does. A report
# that does not fit at all (the first one, a seek, a stall) starts it again in
# the middle of the reported second. Only while the Hub is PLAYING.
sub _runClock {
    my ( $self, $secs ) = @_;

    if ( ( $self->pbHubState || '' ) ne 'PLAYING' ) {
        $self->pbClockAt(undef);
        return;
    }

    my $now = Time::HiRes::time();
    my $at  = $self->pbClockAt;
    my $est = defined $at ? $self->pbClockPos + ( $now - $at ) : undef;

    if    ( !defined $est || $est < $secs - 1 || $est >= $secs + 2 ) { $est = $secs + 0.5 }
    elsif ( $est < $secs )      { $est = $secs }
    elsif ( $est >= $secs + 1 ) { $est = $secs + 0.99 }

    $self->pbClockPos($est);
    $self->pbClockAt($now);

    return;
}

# What has to be added to the Hub's clock to get a position in the TRACK.
sub _clockOffset {
    my $self = shift;
    return $self->pbClockAbs ? 0 : ( $self->pbStartOffset || 0 );
}

# Elapsed WITHIN THE STREAM. LMS's playingSongElapsed adds the stream's
# startOffset on top, so a position that already includes it would be counted
# twice and the clock would run ahead.
sub songElapsedSeconds {
    my $self = shift;

    return $self->SUPER::songElapsedSeconds(@_) if @_;

    my $p = $self->pbPosition || 0;

    if ( defined( my $at = $self->pbClockAt ) ) {
        my $run = Time::HiRes::time() - $at;
        $run = 0          if $run < 0;
        $run = CLOCK_HOLD if $run > CLOCK_HOLD;
        $p = $self->pbClockPos + $run;
    }

    $p -= ( $self->pbStartOffset || 0 ) if $self->pbClockAbs;

    return $p > 0 ? $p : 0;
}

# ---------------------------------------------------------------------------
# DIDL-Lite - what the Hub shows while it plays.

# H:MM:SS.mmm - the form the UPnP Bridge sends (avt_util.c CreateDIDL), whose
# lengths showed on the Hub.
sub _hmsms {
    my $secs = shift;
    my $ms   = int( $secs * 1000 + 0.5 );
    my $s    = int( $ms / 1000 );
    return sprintf( '%d:%02d:%02d.%03d', int( $s / 3600 ), int( $s / 60 ) % 60, $s % 60, $ms % 1000 );
}

# $from: where in the track the stream starts (a seek, a resume, SqueezeDSP's
# restart). THE HUB COUNTS FROM ITS STREAM - its elapsed starts at 0 whatever
# the stream carries (measured 2026-10-25: a native FLAC restarted at 12 s, its
# frames numbered from 12 s, still read 0) - so it is given the time REMAINING:
# its bar then ends with the track. Its elapsed counts from the restart; LMS's
# own clock, which adds the offset, is the right one.
sub _didl {
    my ( $self, $song, $url, $fmt, $from ) = @_;

    my $m = $self->_meta($song) or return '';
    my $e = \&Plugins::PlatinBridge::UPnP::escape;

    my $didl =
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"'
      . ' xmlns:dc="http://purl.org/dc/elements/1.1/"'
      . ' xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"'
      . ' xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
      . '<item id="1" parentID="0" restricted="1">'
      . '<dc:title>' . $e->( $m->{title} ) . '</dc:title>';

    $didl .= '<upnp:artist>' . $e->( $m->{artist} ) . '</upnp:artist>'
           . '<dc:creator>' . $e->( $m->{artist} ) . '</dc:creator>' if $m->{artist} ne '';
    $didl .= '<upnp:album>' . $e->( $m->{album} ) . '</upnp:album>' if $m->{album} ne '';
    $didl .= '<upnp:albumArtURI>' . $e->( $m->{cover} ) . '</upnp:albumArtURI>' if $m->{cover};

    my $secs = $m->{secs};
    $secs -= $from if $secs && $from && $from > 0 && $from < $secs;

    $didl .= '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
           . '<res protocolInfo="' . $e->( Plugins::PlatinBridge::Format::protocolInfo($fmt) ) . '"'
           . ( $secs ? ' duration="' . _hmsms($secs) . '"' : '' )
           . '>' . $e->($url) . '</res>'
           . '</item></DIDL-Lite>';

    return $didl;
}

# Title, artist, album, artwork and duration for the Hub's own display. A
# STREAMED track keeps its metadata with its protocol handler, not on the track
# row - the HQPlayer bridge learnt that from a Tidal track that reached it with a
# title and nothing else - so the handler is asked first for a remote track.
sub _meta {
    my ( $self, $song ) = @_;

    my $track = eval { $song->currentTrack } or return undef;

    # scalar() on every call: an eval in a list returns the EMPTY LIST when the
    # method returns nothing, and one empty value shifts every key after it.
    my %m = (
        title  => scalar( eval { $track->title } )      || '',
        artist => scalar( eval { $track->artistName } ) || '',
        album  => scalar( eval { $track->albumname } )  || '',
        secs   => scalar( eval { $track->secs } ),
        cover  => '',
    );

    my $url = scalar( eval { $track->url } ) || '';

    if ( eval { $track->remote } ) {
        my $h = eval {
            my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
            $handler && $handler->can('getMetadataFor') ? $handler->getMetadataFor( $self, $url ) : undef;
        };

        if ( ref $h eq 'HASH' ) {
            for my $k (qw( title artist album )) {
                my $v = $h->{$k};
                $v = $v->{name} if ref $v eq 'HASH';
                $m{$k} = $v if defined $v && !ref $v && $v ne '';
            }
            $m{secs} ||= $h->{duration};
            $m{cover} = $self->_absolute( $h->{cover} || $h->{icon} || '' );
        }
    }
    else {
        # A remote track carries a NEGATIVE coverid, and /music/ 404s on one; a
        # broken image is worse than none.
        my $id = eval { $track->coverid };
        $m{cover} = $self->_serverBase . '/music/' . $id . '/cover_600x600_o.jpg'
            if defined $id && $id ne '' && $id !~ /^-/;
    }

    return \%m;
}

sub _absolute {
    my ( $self, $u ) = @_;
    return '' unless defined $u && $u ne '';
    return $u if $u =~ m{^https?://}i;
    return $u =~ m{^/} ? $self->_serverBase . $u : '';
}

sub _serverBase {
    my $self = shift;
    return Plugins::PlatinBridge::Stream->serverBase($self);
}

1;
