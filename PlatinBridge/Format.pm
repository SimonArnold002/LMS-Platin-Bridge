package Plugins::PlatinBridge::Format;

# Which LMS formats the player advertises, and what each one is called on the
# wire. That is ALL this module decides now.
#
# THE PLAYER NO LONGER OWNS AN AUDIO STAGE (0.2.0, Simon 2026-10-25: "reduce its
# scope so it doesnt need to do the transcoding or replay gain"). It used to ask
# LMS for raw pcm, apply ReplayGain itself and wrap the result in a WAV header or
# a FLAC encode. SqueezeDSP does all of that now, through LMS's own transcode
# table, so the player only has to tell LMS what the Hub can play and then pass
# whatever LMS produces to the Hub untouched.
#
# NO Slim:: DEPENDENCIES, so the whole table is unit-tested for real.

use strict;
use warnings;

# PREFERENCE ORDER, and it is not arbitrary. LMS walks a player's list in order
# and takes the first format a rule exists for (TranscodingHelper.pm:371), so the
# order decides what a track becomes when SqueezeDSP is OFF for this player.
# Measured against LMS 9.1's convert.conf (2026-10-25):
#
#   aac ogg ops ogf alc wma wav   only their OWN native rule produces them, so
#                                 they can never pull another format across
#   flc                           19 input types can become FLAC
#   aif                           FLAC, Ogg and Musepack can become AIFF - so it
#                                 must come AFTER flc or FLAC files decode to AIFF
#   mp3                           18 input types can become MP3 - LAST, or the
#                                 library is transcoded to MP3
#
# So each source plays in its own format where the Hub takes it, and only what
# it cannot take becomes FLAC. With SqueezeDSP ON for the player its format drop
# (Configuration::applyFormatOrder) trims this list to its own output format,
# which is why the list has to live in myFormats - see Player::formats.
my @ORDER = qw( aac ogg ops ogf alc wma wav flc aif mp3 );

# What goes in the Content-Type and the DIDL protocolInfo. The Hub is a
# GStreamer renderer and sniffs the stream rather than trusting either, so these
# need to be plausible rather than exact - but each is one the Hub's own Sink
# list names (read 2026-10-25), apart from audio/aac, which its decoders cover.
my %MIME = (
    aac => 'audio/aac',
    ogg => 'audio/ogg',
    ops => 'audio/ogg',
    ogf => 'audio/ogg',
    alc => 'audio/mp4',
    wma => 'audio/x-ms-wma',
    wav => 'audio/x-wav',
    flc => 'audio/flac',
    aif => 'audio/aiff',
    mp3 => 'audio/mpeg',
);

# The url suffix. Cosmetic to us - the endpoint routes on the player token and
# the sequence number - but a renderer that guesses from an extension guesses
# right, and it makes a packet capture readable.
my %EXT = (
    aac => 'aac',
    ogg => 'ogg',
    ops => 'opus',
    ogf => 'ogg',
    alc => 'm4a',
    wma => 'wma',
    wav => 'wav',
    flc => 'flac',
    aif => 'aif',
    mp3 => 'mp3',
);

# A format is offered only when the Hub's Sink list names a mime type that means
# it can decode it. The http-get:*:audio/*:* WILDCARD proves nothing - it is in
# none of these lists - because every format would pass it, including ones the
# Hub then fails to play.
my %PROVES = (
    aac => [qw( audio/aac audio/x-aac audio/mp4 audio/m4a audio/x-m4a )],
    ogg => [qw( audio/ogg audio/x-vorbis )],
    ops => [qw( audio/x-opus audio/opus )],
    ogf => [qw( audio/ogg )],
    alc => [qw( audio/alac audio/x-alac audio/mp4 audio/m4a )],
    wma => [qw( audio/x-ms-wma audio/x-wma )],
    wav => [qw( audio/x-wav audio/wav audio/wave )],
    flc => [qw( audio/flac audio/x-flac )],
    aif => [qw( audio/aiff audio/x-aiff )],
    mp3 => [qw( audio/mpeg audio/x-mpeg audio/mp3 )],
);

sub defaultFormats { return @ORDER }

# The list to advertise, from the Hub's own Sink entries (an array ref of
# protocolInfo strings, as UPnP::sink returns). UNDEF MEANS THE HUB NEVER TOLD
# US, and that is not the same as it taking nothing: the default list is what
# this Hub was measured to take, so it is the right answer to "unknown".
sub formatsFromSink {
    my $sink = shift;

    return @ORDER unless ref $sink eq 'ARRAY';

    my %have;
    for my $e (@$sink) {
        my @f = split /:/, ( defined $e ? $e : '' );
        $have{ lc $f[2] } = 1 if defined $f[2] && $f[2] ne '';
    }

    return grep {
        my $fmt = $_;
        scalar grep { $have{$_} } @{ $PROVES{$fmt} };
    } @ORDER;
}

sub mimeFor {
    my $fmt = lc( shift || '' );
    return $MIME{$fmt} || 'application/octet-stream';
}

sub ext {
    my $fmt = lc( shift || '' );
    return $EXT{$fmt} || 'bin';
}

# The 4-field protocolInfo that goes in DIDL-Lite's <res>. '*' in the 4th field
# says no DLNA profile is claimed, which is the honest answer: the Hub matches on
# the mime type, and asserting a profile we have not verified would say more
# than we know.
sub protocolInfo {
    return 'http-get:*:' . mimeFor(shift) . ':' . ( dlnaFeatures() || '*' );
}

# THE SEEK TEST (`A SEEK THE HUB DOES ITSELF`, 2026-10-25). The Hub lists
# X_DLNA_SeekTime and X_DLNA_SeekByte among its transport actions; whether it
# will time-seek OUR stream may depend on what we say we can serve. OFF unless
# `platinbridge seekop <00|01|10|11>` sets it, and only until LMS restarts: off,
# every string is what the builds before 0.2.5 sent.
my $seekOp;

sub seekOp {
    my $op = shift;
    $seekOp = ( defined $op && $op =~ /^[01]{2}$/ ) ? $op : undef;
    return $seekOp;
}

sub seekOpNow { $seekOp }

# The 4th protocolInfo field and the contentFeatures header, with the test's
# DLNA.ORG_OP; undef when the test is off.
sub dlnaFeatures {
    return undef unless defined $seekOp;
    return "DLNA.ORG_OP=$seekOp;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000";
}

# ---------------------------------------------------------------------------
# THE CONTAINER HEADER.
#
# A SEEKED OR RESUMED NATIVE STREAM HAS NONE. LMS starts a passthrough FLAC (or
# WAV) part way in by BYTE offset, so the stream begins at a frame, not at `fLaC`
# (SqueezeDSP's ledger, `A RESUMED FLAC STREAM HAS NO STREAMINFO`, measured
# 2026-10-24). A Squeezebox is told the format out of band; the Hub's GStreamer
# identifies a stream by its first bytes. On this Hub, 2026-10-25 (0.2.0), a
# track started part way in had it re-opening the url tens of times a second while
# LMS showed a frozen clock - the missing header is the inferred cause.
#
# So the player synthesises the header such a stream lacks, from the rate, depth
# and channel count its first frame states (else the track's).

# 42 bytes: `fLaC`, one last-block STREAMINFO. Total samples 0 = "length
# unknown", MD5 zero = "do not verify". THE BLOCK SIZE IS THE PART THAT BITES: it
# reads like a hint, but decoders size buffers from it, and against libFLAC only
# min == max == 4096 decoded frames taken from the middle of a real file (16/65535
# and 4096/16384 were refused) - measured for the HQPlayer bridge, 2026-08-28.
# $total: the samples the stream will carry, or 0 for "unknown". THE HUB TAKES A
# TRACK'S LENGTH FROM HERE, not from the DIDL - the UPnP Bridge, whose lengths
# showed on the Hub, writes it the same way (flac_thru.c FLAC_ADJUST_HEADER;
# its own encoder sets total_samples_estimate).
sub flacHeader {
    my ( $rate, $channels, $bits, $total ) = @_;

    return undef unless $rate && $rate < 2**20 && $channels && $channels <= 8 && $bits && $bits >= 4 && $bits <= 32;

    my $block = 4096;
    $total = 0 unless $total && $total > 0 && $total < 2**36;
    $total = int $total;

    # rate (20) | channels-1 (3) | bits-1 (5) | total samples (36: high 4 bits here)
    my $packed = ( $rate << 12 ) | ( ( $channels - 1 ) << 9 ) | ( ( $bits - 1 ) << 4 ) | ( ( $total >> 32 ) & 0x0F );

    return 'fLaC'
         . pack( 'C', 0x80 ) . pack( 'CCC', 0, 0, 34 )        # last block, STREAMINFO, length 34
         . pack( 'nn', $block, $block )                       # min / max block size
         . "\0\0\0" . "\0\0\0"                                # min / max frame size: unknown
         . pack( 'N', $packed )                               # rate, channels, bits, samples (hi)
         . pack( 'N', $total & 0xFFFFFFFF )                   # total samples (lo 32 bits)
         . ( "\0" x 16 );                                     # MD5: unknown
}

# The total samples a FLAC stream's STREAMINFO announces (0 = unknown), or undef
# if the bytes do not open with one.
sub flacTotalSamples {
    my $b = shift;
    return undef unless defined $b && length($b) >= 26 && substr( $b, 0, 4 ) eq 'fLaC'
        && ( ord( substr( $b, 4, 1 ) ) & 0x7F ) == 0;
    my ( $hi, $lo ) = ( ord( substr( $b, 21, 1 ) ) & 0x0F, unpack( 'N', substr( $b, 22, 4 ) ) );
    return $hi * 2**32 + $lo;
}

# The same stream with $total written into a STREAMINFO that says 0 ("unknown") -
# what an encoder writing to a pipe leaves (SqueezeDSP's flac). A length already
# there is never changed. Metadata blocks carry no CRC, and the MD5 is of the
# audio, so nothing else moves.
sub withFlacTotalSamples {
    my ( $b, $total ) = @_;
    my $have = flacTotalSamples($b);
    return $b unless defined $have && $have == 0 && $total && $total > 0 && $total < 2**36;
    $total = int $total;
    substr( $b, 21, 1 ) = chr( ( ord( substr( $b, 21, 1 ) ) & 0xF0 ) | ( ( $total >> 32 ) & 0x0F ) );
    substr( $b, 22, 4 ) = pack( 'N', $total & 0xFFFFFFFF );
    return $b;
}

# 44 bytes. PCM samples after a byte seek are whole frames, so the header is all
# that is missing. $frames given: the data size is stated (the Hub reads a WAV's
# length from it - 0xFFFFFFFF showed every track as 3:22:53, row 77); else both
# sizes are 0xFFFFFFFF, "read to the end".
sub wavHeader {
    my ( $rate, $channels, $bits, $frames ) = @_;

    return undef unless $rate && $channels && $bits && $bits % 8 == 0;

    my $align = $channels * $bits / 8;
    my $data  = ( $frames && $frames > 0 && $frames * $align < 0xFFFFFFFF - 36 ) ? int($frames) * $align : 0xFFFFFFFF;
    my $riff  = $data == 0xFFFFFFFF ? 0xFFFFFFFF : $data + 36;

    return 'RIFF' . pack( 'V', $riff ) . 'WAVE'
         . 'fmt ' . pack( 'VvvVVvv', 16, 1, $channels, $rate, $rate * $align, $align, $bits )
         . 'data' . pack( 'V', $data );
}

# WHERE THE FIRST WHOLE FLAC FRAME STARTS. LMS aligns a seeked FLAC to a frame
# itself (Slim::Formats::FLAC::frameAlign for a remote stream, Audio::Scan for a
# file), so this normally finds offset 0. It is a guard for a source that does
# not: a header put in front of a partial frame would still not decode. A frame
# is accepted only when its header is self-consistent and its CRC-8 matches - a
# bare 0xFFF8 turns up in audio data by chance.
my @CRC8;
for my $i ( 0 .. 255 ) {
    my $c = $i;
    for ( 1 .. 8 ) { $c = ( $c & 0x80 ) ? ( ( $c << 1 ) ^ 0x07 ) & 0xFF : ( $c << 1 ) & 0xFF }
    $CRC8[$i] = $c;
}

my %FLAC_RATE = ( 1 => 88200, 2 => 176400, 3 => 192000, 4 => 8000, 5 => 16000, 6 => 22050,
                  7 => 24000, 8 => 32000, 9 => 44100, 10 => 48000, 11 => 96000 );
my %FLAC_BITS = ( 1 => 8, 2 => 12, 4 => 16, 5 => 20, 6 => 24, 7 => 32 );

# The frame header at $at: { rate, bits, channels } (rate/bits undef where the
# frame defers them to STREAMINFO), or undef if this is not a frame header.
sub flacFrameAt {
    my ( $b, $at ) = @_;

    return undef if $at + 6 > length $b;

    my @h = unpack( 'C6', substr( $b, $at, 6 ) );

    return undef unless $h[0] == 0xFF && ( $h[1] & 0xFE ) == 0xF8;

    my $bsCode   = $h[2] >> 4;
    my $rateCode = $h[2] & 0x0F;
    my $chan     = $h[3] >> 4;
    my $bitsCode = ( $h[3] >> 1 ) & 0x07;

    return undef if $bsCode == 0 || $rateCode == 0x0F || $chan > 10 || $bitsCode == 3 || ( $h[3] & 1 );

    # The frame or sample number, UTF-8 style: the leading ones of its first byte
    # say how many bytes follow.
    my $n = 4;
    my $lead = $h[4];
    my $more = $lead < 0x80 ? 0 : $lead >= 0xFE ? 6 : $lead >= 0xFC ? 5 : $lead >= 0xF8 ? 4
             : $lead >= 0xF0 ? 3 : $lead >= 0xE0 ? 2 : $lead >= 0xC0 ? 1 : -1;
    return undef if $more < 0;
    $n += 1 + $more;

    $n += 1 if $bsCode == 6;
    $n += 2 if $bsCode == 7;

    my $rate = $FLAC_RATE{$rateCode};
    if    ( $rateCode == 12 ) { return undef if $at + $n + 1 > length $b; $rate = ord( substr( $b, $at + $n, 1 ) ) * 1000; $n += 1 }
    elsif ( $rateCode == 13 ) { return undef if $at + $n + 2 > length $b; $rate = unpack( 'n', substr( $b, $at + $n, 2 ) );      $n += 2 }
    elsif ( $rateCode == 14 ) { return undef if $at + $n + 2 > length $b; $rate = unpack( 'n', substr( $b, $at + $n, 2 ) ) * 10; $n += 2 }

    return undef if $at + $n + 1 > length $b;

    my $crc = 0;
    $crc = $CRC8[ $crc ^ $_ ] for unpack( 'C*', substr( $b, $at, $n ) );
    return undef unless $crc == ord( substr( $b, $at + $n, 1 ) );

    return {
        rate     => $rate,
        bits     => $FLAC_BITS{$bitsCode},
        channels => $chan <= 7 ? $chan + 1 : 2,
    };
}

# The offset of the first valid frame within the first $limit bytes, or undef.
sub flacFrameStart {
    my ( $b, $limit ) = @_;

    $limit ||= 256 * 1024;
    $limit = length $b if $limit > length $b;

    my $at = 0;
    while ( ( $at = index( $b, "\xFF", $at ) ) >= 0 && $at < $limit ) {
        return $at if flacFrameAt( $b, $at );
        $at++;
    }

    return undef;
}

# Does a stream of format $fmt that begins with $bytes lack its header? Only the
# two containers that cannot be decoded from the middle are asked about: MP3, AAC
# and Ogg frames are self-describing.
sub lacksHeader {
    my ( $fmt, $bytes ) = @_;

    $fmt = lc( $fmt || '' );
    return 0 unless defined $bytes && length $bytes >= 4;

    return ( substr( $bytes, 0, 4 ) ne 'fLaC' ) ? 1 : 0 if $fmt eq 'flc';
    return ( substr( $bytes, 0, 4 ) ne 'RIFF' ) ? 1 : 0 if $fmt eq 'wav';

    return 0;
}

# $total: the samples (FLAC) or frames (WAV) the stream will carry, 0 = unknown.
sub headerFor {
    my ( $fmt, $rate, $channels, $bits, $total ) = @_;
    $fmt = lc( $fmt || '' );
    return flacHeader( $rate, $channels, $bits, $total ) if $fmt eq 'flc';
    return wavHeader( $rate, $channels, $bits, $total )  if $fmt eq 'wav';
    return undef;
}

# What the opening bytes of a stream SAY they are - the readout behind
# `platinbridge info`, so the format reaching the Hub is read off the bytes
# rather than inferred from what LMS believes it is sending.
#   { container, rate, bits, channels }  (the last three where the header has them)
sub describeHeader {
    my $b = shift;

    return { container => 'nothing yet' } unless defined $b && length $b;

    if ( length($b) >= 42 && substr( $b, 0, 4 ) eq 'fLaC' && ( ord( substr( $b, 4, 1 ) ) & 0x7F ) == 0 ) {
        my $w = unpack( 'N', substr( $b, 18, 4 ) );
        return {
            container => 'FLAC',
            rate      => $w >> 12,
            channels  => ( ( $w >> 9 ) & 0x07 ) + 1,
            bits      => ( ( $w >> 4 ) & 0x1F ) + 1,
            samples   => flacTotalSamples($b),
        };
    }

    if ( length($b) >= 12 && substr( $b, 0, 4 ) eq 'RIFF' && substr( $b, 8, 4 ) eq 'WAVE' ) {
        # Walk the chunks to `fmt `: a WAV need not have it first.
        my $at = 12;
        while ( $at + 8 <= length $b ) {
            my ( $id, $len ) = ( substr( $b, $at, 4 ), unpack( 'V', substr( $b, $at + 4, 4 ) ) );
            if ( $id eq 'fmt ' && $at + 24 <= length $b ) {
                my ( $tag, $ch, $rate, undef, $align, $bits ) = unpack( 'vvVVvv', substr( $b, $at + 8, 16 ) );
                my $d = { container => 'WAV', rate => $rate, channels => $ch, bits => $bits };
                # The data chunk's size, if it follows: the length the Hub reads.
                my $dat = index( $b, 'data', $at + 8 + $len );
                if ( $dat > 0 && $dat + 8 <= length $b && $align ) {
                    my $size = unpack( 'V', substr( $b, $dat + 4, 4 ) );
                    $d->{samples} = $size == 0xFFFFFFFF ? 0 : int( $size / $align );
                }
                return $d;
            }
            last if $len > length $b;
            $at += 8 + $len + ( $len % 2 );
        }
        return { container => 'WAV' };
    }

    return { container => 'AIFF' } if length($b) >= 12 && substr( $b, 0, 4 ) eq 'FORM' && substr( $b, 8, 4 ) =~ /^AIF[FC]$/;
    return { container => 'Ogg' }  if substr( $b, 0, 4 ) eq 'OggS';
    return { container => 'MP4' }  if length($b) >= 8 && substr( $b, 4, 4 ) eq 'ftyp';

    # FLAC frames with no header begin with the frame sync 0xFFF8/0xFFF9. Tested
    # BEFORE the MP3 sync, whose mask also matches it (in MPEG terms 0xFFF8 is a
    # reserved layer, so it is never an MP3 frame).
    return { container => 'FLAC frames, NO header' } if length($b) >= 2 && ( unpack( 'n', substr( $b, 0, 2 ) ) & 0xFFFE ) == 0xFFF8;

    return { container => 'MP3' }  if substr( $b, 0, 3 ) eq 'ID3' || ( length($b) >= 2 && ( unpack( 'n', substr( $b, 0, 2 ) ) & 0xFFE0 ) == 0xFFE0 );

    return { container => 'unknown' };
}

sub describeText {
    my $d = shift or return '';
    my $s = $d->{container};
    $s .= sprintf ' %d Hz / %d bit / %d ch', $d->{rate}, $d->{bits}, $d->{channels}
        if $d->{rate} && $d->{bits} && $d->{channels};
    if ( defined $d->{samples} && $d->{rate} ) {
        my $t = int( $d->{samples} / $d->{rate} + 0.5 );
        $s .= $d->{samples}
            ? sprintf( ', length %d:%02d', int( $t / 60 ), $t % 60 )
            : ', length unknown';
    }
    $s .= ' (length written in here)' if $d->{lengthAdded};
    $s .= ' (header synthesised for a seeked stream)' if $d->{synthesised};
    return $s;
}

1;
