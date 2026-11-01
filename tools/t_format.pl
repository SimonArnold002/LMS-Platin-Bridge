#!/usr/bin/perl
#
# Unit tests for Plugins::PlatinBridge::Format - which LMS formats the player
# offers, and what each is called on the wire.
#
# Format.pm has NO Slim:: dependencies, so this is the real table, not a stub.
#
# `ok` TAKES THE ASSERTION NAME OFF THE END: a failed match in list context is
# the EMPTY list, so a name-last `ok` cannot read the label as the condition.

use strict;
use warnings;
use lib '.';

require Plugins::PlatinBridge::Format;

my $F = 'Plugins::PlatinBridge::Format';

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

# THE HUB'S OWN SINK LIST, mime by mime, as GetProtocolInfo returned it on
# 2026-10-25 (82 entries, every one `http-get:*:<mime>:*`).
my @HUB = map { "http-get:*:$_:*" } qw(
    audio/* audio/AMR audio/AMR-WB audio/G722 audio/G723 audio/G729 audio/ac3 audio/aiff
    audio/alac audio/flac audio/isac audio/m4a audio/mp4 audio/mpeg audio/ms-gsm audio/ogg
    audio/qcelp audio/webm audio/x-ac3 audio/x-adpcm audio/x-aiff audio/x-alac audio/x-alaw
    audio/x-amr-nb-sh audio/x-amr-wb-sh audio/x-au audio/x-bfstm audio/x-brstm audio/x-bv
    audio/x-celt audio/x-dpcm audio/x-dsd audio/x-dts audio/x-dv audio/x-eac3
    audio/x-ffmpeg-parsed-ape audio/x-ffmpeg-parsed-musepack audio/x-flac audio/x-gsm
    audio/x-gst-av-mp3adufloat audio/x-gst-av-mp3on4float audio/x-gst-av-vmdaudio
    audio/x-gst-av-ws_snd1 audio/x-iLBC audio/x-imc audio/x-ldac audio/x-m4a audio/x-mace
    audio/x-matroska audio/x-mpeg audio/x-ms-wma audio/x-mulaw audio/x-musepack
    audio/x-nellymoser audio/x-opus audio/x-pn-realaudio audio/x-private1-ac3
    audio/x-private1-dts audio/x-qdm2 audio/x-raw audio/x-rf64 audio/x-sbc audio/x-scpls
    audio/x-shorten audio/x-sipro audio/x-siren audio/x-smpte-302m audio/x-speex
    audio/x-truespeech audio/x-tta audio/x-ttafile audio/x-twin-vq audio/x-vnd.sony.atrac1
    audio/x-vnd.sony.atrac3 audio/x-voc audio/x-vorbis audio/x-voxware audio/x-wav
    audio/x-wavpack audio/x-wavpack-correction audio/x-wma audio/x-wms
);

# ---------------------------------------------------------------------------
print "-- the list offered to LMS --\n";

is( scalar @HUB, 82, 'the fixture is the whole of what the Hub said' );

is( join( ' ', $F->can('formatsFromSink')->( \@HUB ) ), 'aac ogg ops ogf alc wma wav flc aif mp3',
    'the real Hub is offered every format it decodes, in preference order' );

is( join( ' ', $F->can('defaultFormats')->() ), 'aac ogg ops ogf alc wma wav flc aif mp3',
    'and an UNKNOWN sink falls back to the same list - what this Hub was measured to take' );

is( join( ' ', $F->can('formatsFromSink')->(undef) ), 'aac ogg ops ogf alc wma wav flc aif mp3',
    'undef is UNKNOWN, not "takes nothing"' );

{
    # THE ORDER IS THE POINT. LMS takes the first listed format with a rule, so
    # flc ahead of a lossy format would transcode that lossy source to FLAC, aif
    # ahead of flc would decode every FLAC file to AIFF, and mp3 anywhere but last
    # would transcode the library to MP3.
    my @f = $F->can('defaultFormats')->();
    my %at = map { $f[$_] => $_ } 0 .. $#f;

    ok( $at{flc} > $at{$_}, "flc comes after $_ - nothing can be transcoded INTO $_" )
        for qw( aac ogg ops ogf alc wma wav );
    ok( $at{aif} > $at{flc}, 'aif comes after flc - flc->aif would otherwise decode every FLAC file' );
    is( $f[-1], 'mp3', 'mp3 is last - 18 input types can become mp3' );
    ok( !$at{pcm} && !grep( { $_ eq 'pcm' } @f ), 'raw pcm is NEVER offered - the Hub could not tell its rate or depth' );
}

{
    # THE WILDCARD DOES NOT COUNT. The Hub lists http-get:*:audio/*:* - read as a
    # proof, it would admit every format, including ones it then fails to play.
    my @only = $F->can('formatsFromSink')->( [ 'http-get:*:audio/*:*' ] );
    is( scalar @only, 0, 'a sink that is nothing but the wildcard proves nothing' );
}

{
    # A renderer that lists less gets less - and in the same order.
    my @f = $F->can('formatsFromSink')->( [ 'http-get:*:audio/x-flac:*', 'http-get:*:audio/mpeg:*', 'http-get:*:audio/*:*' ] );
    is( join( ' ', @f ), 'flc mp3', 'a sink of FLAC and MP3 offers exactly those, flc first' );
}

{
    # The match is case-blind (the Hub writes audio/AMR, audio/x-iLBC) and only the
    # mime field is read.
    my @f = $F->can('formatsFromSink')->( [ 'http-get:*:AUDIO/X-WAV:DLNA.ORG_PN=WAV' ] );
    is( join( ' ', @f ), 'wav', 'mime types match whatever their case, and the 4th field is ignored' );
}

{
    my @f = $F->can('formatsFromSink')->( [ 'garbage', undef, '', 'http-get:*:audio/x-flac:*' ] );
    is( join( ' ', @f ), 'flc', 'malformed entries are skipped, not fatal' );
}

{
    # Ogg FLAC needs an Ogg demuxer, not a FLAC decoder.
    my @f = $F->can('formatsFromSink')->( [ 'http-get:*:audio/flac:*' ] );
    ok( !grep( { $_ eq 'ogf' } @f ), 'a FLAC decoder alone does not offer Ogg FLAC' );
}

# ---------------------------------------------------------------------------
print "-- names on the wire --\n";

is( $F->can('mimeFor')->('flc'), 'audio/flac',     'FLAC goes out as audio/flac - in the Hub\'s list verbatim' );
is( $F->can('mimeFor')->('wav'), 'audio/x-wav',    'WAV as audio/x-wav' );
is( $F->can('mimeFor')->('mp3'), 'audio/mpeg',     'MP3 as audio/mpeg' );
is( $F->can('mimeFor')->('alc'), 'audio/mp4',      'ALAC in its MP4 container as audio/mp4' );
is( $F->can('mimeFor')->('FLC'), 'audio/flac',     'the stream format is read case-blind' );
is( $F->can('mimeFor')->('xyz'), 'application/octet-stream', 'an unknown format says nothing it cannot back up' );
is( $F->can('mimeFor')->(undef), 'application/octet-stream', 'and so does none at all' );

{
    # Every format offered has a name on the wire - otherwise a track LMS chose
    # for this player would go out as octet-stream.
    for my $f ( $F->can('defaultFormats')->() ) {
        ok( $F->can('mimeFor')->($f) ne 'application/octet-stream', "$f has a mime type" );
        ok( $F->can('ext')->($f) ne 'bin', "and an extension" );
    }
}

is( $F->can('ext')->('flc'), 'flac', 'the url suffix is the common one, not the LMS code' );
is( $F->can('protocolInfo')->('flc'), 'http-get:*:audio/flac:*', 'protocolInfo claims no DLNA profile' );

# THE SEEK TEST's switch (A SEEK THE HUB DOES ITSELF): off by default, and off
# again on anything but two binary digits.
is( $F->can('seekOpNow')->(), undef, 'the seek test is off by default' );
is( $F->can('seekOp')->('10'), '10', 'it can be set' );
is( $F->can('protocolInfo')->('flc'), 'http-get:*:audio/flac:DLNA.ORG_OP=10;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000',
    'and then the DIDL\'s protocolInfo says what it is set to' );
is( $F->can('seekOp')->('1x'), undef, 'anything but two binary digits switches it off' );
is( $F->can('protocolInfo')->('flc'), 'http-get:*:audio/flac:*', 'and protocolInfo is as before again' );

# ---------------------------------------------------------------------------
print "-- a seeked FLAC: finding its first whole frame --\n";

# THE FIXTURES are real encoder output: 40-64 KB cut from part way through a
# frame of four files LMS 9.1's bundled `flac` encoded from generated audio (a
# tone plus noise, nobody's music). Part way through a frame is the worst case -
# LMS aligns a seek to a frame itself - so they test the header AND the guard. The ORACLE is that
# same binary's `flac --analyze`, which printed each frame's offset - so the
# expected numbers below come from libFLAC, not from Format.pm's reading of the
# spec. Cut at, and the frames inside each cut:
#
#   flac_16_44100_cut.bin   from 25000; frames at 31035 42413 53810
#   flac_24_96000_cut.bin   from 30000; frames at 41203 57645 74087
#   flac_24_192000_cut.bin  from 50000; frames at 66958 86508 106080
#   flac_16_44100_frame150_cut.bin  from 1690000 of a 16 s file; frames 150-153
#       at 1695869 1707125 1718392 1729635. A seek minutes into a track lands at
#       frame numbers in the thousands, which take 2-3 bytes in the header; the
#       other cuts are all under 128, which take one.
#
# Benched the same day: each cut, repaired with flacFrameStart + flacHeader and
# decoded by that `flac`, gives samples identical to the original's from the
# first whole frame on.
sub fixture {
    my $f = shift;
    open my $fh, '<:raw', "fixtures/$f" or die "cannot read fixtures/$f: $!";
    local $/;
    return scalar <$fh>;
}

# Every offset in $b that reads as a frame header.
sub allFrames {
    my $b = shift;
    my @at;
    my $at = 0;
    while ( ( $at = index( $b, "\xFF", $at ) ) >= 0 ) {
        push @at, $at if $F->can('flacFrameAt')->( $b, $at );
        $at++;
    }
    return join ' ', @at;
}

my @CUTS = (
    [ 'flac_16_44100_cut.bin',  25000, [ 31035, 42413, 53810 ],  44100,  16, 2, 0x0AC442F0 ],
    [ 'flac_24_96000_cut.bin',  30000, [ 41203, 57645, 74087 ],  96000,  24, 2, 0x17700370 ],
    [ 'flac_24_192000_cut.bin', 50000, [ 66958, 86508, 106080 ], 192000, 24, 2, 0x2EE00370 ],
    [ 'flac_16_44100_frame150_cut.bin', 1690000, [ 1695869, 1707125, 1718392, 1729635 ], 44100, 16, 2, 0x0AC442F0 ],
);

for my $c (@CUTS) {
    my ( $file, $from, $frames, $rate, $bits, $ch, $word ) = @$c;
    my $b    = fixture($file);
    my $skip = $frames->[0] - $from;
    my $tag  = "$bits/$rate, frame at $frames->[0]";

    is( $F->can('flacFrameStart')->($b), $skip, "$tag: the first whole frame is where libFLAC says it is" );
    is( allFrames($b), join( ' ', map { $_ - $from } @$frames ),
        "$tag: and EVERY frame header found in the cut is a real one - none in the audio data" );

    my $fi = $F->can('flacFrameAt')->( $b, $skip );
    is( join( '/', map { defined $_ ? $_ : '?' } @{$fi}{qw( rate bits channels )} ), "$rate/$bits/$ch",
        "$tag: the frame says its own rate, depth and channels" );

    is( $F->can('describeHeader')->($b)->{container}, 'unknown', "$tag: the cut as it arrives is unrecognisable" );
    is( $F->can('describeHeader')->( substr( $b, $skip ) )->{container}, 'FLAC frames, NO header',
        "$tag: from its first frame it reads as headerless FLAC" );

    my $hdr = $F->can('flacHeader')->( $rate, $ch, $bits );
    is( length $hdr, 42, "$tag: the header made for it is 42 bytes" );

    # Against the encoder's own STREAMINFO for the same file: the word holding
    # rate, channels and depth, and the block sizes.
    is( sprintf( '%08X', unpack( 'N', substr( $hdr, 18, 4 ) ) ), sprintf( '%08X', $word ),
        "$tag: its rate/channels/depth word is bit for bit the encoder's" );
    is( unpack( 'H*', substr( $hdr, 8, 4 ) ), '10001000', "$tag: block size 4096/4096, as the encoder wrote" );

    my $fixed = $hdr . substr( $b, $skip );
    my $d     = $F->can('describeHeader')->($fixed);
    is( "$d->{container} $d->{rate}/$d->{bits}/$d->{channels}", "FLAC $rate/$bits/$ch", "$tag: the repaired stream reads back as what it is" );
    ok( !$F->can('lacksHeader')->( 'flc', $fixed ), "$tag: and no longer lacks a header" );
}

{
    # THE CRC IS WHAT MAKES A FRAME. 0xFFF8 turns up in audio data by chance; a
    # header whose CRC-8 does not match is not a frame.
    my $b    = fixture('flac_24_96000_cut.bin');
    my $skip = 41203 - 30000;

    ok( $F->can('flacFrameAt')->( $b, $skip ), 'CONTROL: the frame as encoded is accepted' );

    # Fixed 4096-sample blocks, a rate from the table, frame number 2 (one byte):
    # the header is 5 bytes and its CRC-8 the 6th.
    my $crc = $b;
    substr( $crc, $skip + 5, 1 ) = chr( ord( substr( $crc, $skip + 5, 1 ) ) ^ 0x01 );
    ok( !$F->can('flacFrameAt')->( $crc, $skip ), 'a frame header with one bit of its CRC flipped is refused' );

    my $bad = $b;
    substr( $bad, $skip + 2, 1 ) = chr( ord( substr( $bad, $skip + 2, 1 ) ) ^ 0x10 );
    ok( !$F->can('flacFrameAt')->( $bad, $skip ), 'and so is one with a bit of its header flipped' );

    is( $F->can('flacFrameStart')->( substr( $b, 0, $skip ) ), undef, 'the partial frame before it holds no frame at all' );
    is( $F->can('flacFrameStart')->( $b, $skip - 1 ), undef, 'the search stops at its limit' );

    # A header whose CRC MATCHES but which uses a reserved code is still not a
    # frame: the CRC-8 alone passes 1 random candidate in 256. Each case is the
    # real header above with one field changed and its CRC recomputed (by the
    # test's own CRC-8, checked against the encoder's first).
    my $crc8 = sub {
        my $c = 0;
        for my $byte ( unpack 'C*', shift ) {
            $c ^= $byte;
            $c = ( $c & 0x80 ) ? ( ( $c << 1 ) ^ 0x07 ) & 0xFF : ( $c << 1 ) & 0xFF for 1 .. 8;
        }
        return $c;
    };
    my @h = unpack( 'C5', substr( $b, $skip, 5 ) );
    is( $crc8->( pack 'C5', @h ), ord( substr( $b, $skip + 5, 1 ) ), "CONTROL: the test's CRC-8 agrees with the encoder's" );
    ok( $F->can('flacFrameAt')->( pack( 'C5', @h ) . chr( $crc8->( pack 'C5', @h ) ) . "\0" x 8, 0 ), 'CONTROL: so the real header re-made that way is accepted' );

    my %reserved = (
        'block size code 0'      => sub { $_[2] = $_[2] & 0x0F },
        'rate code 15'           => sub { $_[2] = ( $_[2] & 0xF0 ) | 0x0F },
        'channel code 11'        => sub { $_[3] = ( $_[3] & 0x0F ) | 0xB0 },
        'depth code 3'           => sub { $_[3] = ( $_[3] & 0xF1 ) | ( 3 << 1 ) },
        'the reserved bit set'   => sub { $_[3] = $_[3] | 0x01 },
    );
    for my $what ( sort keys %reserved ) {
        my @x = @h;
        $reserved{$what}->(@x);
        my $hdr = pack( 'C5', @x );
        ok( !$F->can('flacFrameAt')->( $hdr . chr( $crc8->($hdr) ) . "\0" x 8, 0 ), "a header with $what is refused even with a matching CRC" );
    }

    # Sync bytes with no valid header behind them.
    is( $F->can('flacFrameStart')->( "\xFF\xF8" x 2000 ), undef, 'a run of bare sync words is not a frame' );
    is( $F->can('flacFrameAt')->( "\xFF\xF8\x69", 0 ), undef, 'nor a header cut short' );
}

# ---------------------------------------------------------------------------
print "-- the length a stream announces --\n";

{
    # Against the encoder: LMS's flac wrote the 3 s, 16/44.1 fixture source with
    # these 8 bytes at offset 18 (rate/channels/depth, then the 36-bit sample
    # count, 132300 = 3 s x 44100).
    my $real = pack( 'H*', '0ac442f0000204cc' );
    is( unpack( 'H*', substr( $F->can('flacHeader')->( 44100, 2, 16, 132300 ), 18, 8 ) ), unpack( 'H*', $real ),
        'a STREAMINFO with a length is bit for bit what the encoder writes' );

    my $big = 5_000_000_000;    # past 32 bits: the top 4 go in the shared byte
    is( $F->can('flacTotalSamples')->( $F->can('flacHeader')->( 192000, 2, 24, $big ) ), $big, 'a 36-bit count reads back' );
    is( $F->can('flacTotalSamples')->( $F->can('flacHeader')->( 44100, 2, 16 ) ), 0, 'no count given: 0, "unknown"' );
    is( $F->can('flacTotalSamples')->('RIFF....WAVE'), undef, 'not a FLAC header: no answer' );

    my $piped = $F->can('flacHeader')->( 44100, 2, 16 ) . 'frames...';
    my $set   = $F->can('withFlacTotalSamples')->( $piped, 132300 );
    is( $F->can('flacTotalSamples')->($set), 132300, 'an "unknown" length is written in' );
    is( substr( $set, 0, 21 ) . substr( $set, 26 ), substr( $piped, 0, 21 ) . substr( $piped, 26 ), 'and only those bytes change' );
    is( unpack( 'N', substr( $set, 18, 4 ) ) & 0xFFFFFFF0, unpack( 'N', substr( $piped, 18, 4 ) ) & 0xFFFFFFF0,
        'the rate, channels and depth sharing that word are kept' );

    my $stated = $F->can('flacHeader')->( 44100, 2, 16, 99 ) . 'x';
    is( $F->can('withFlacTotalSamples')->( $stated, 132300 ), $stated, 'a length already stated is never changed' );
    is( $F->can('withFlacTotalSamples')->( 'OggS....', 132300 ), 'OggS....', 'and nothing that is not a FLAC header is touched' );

    my $d = $F->can('describeHeader')->($set);
    is( $F->can('describeText')->($d), 'FLAC 44100 Hz / 16 bit / 2 ch, length 0:03', 'the readout gives the length' );
    is( $F->can('describeText')->( $F->can('describeHeader')->($piped) ), 'FLAC 44100 Hz / 16 bit / 2 ch, length unknown', 'or says it is unknown' );
}

{
    my $w = $F->can('wavHeader')->( 48000, 2, 24, 48000 * 10 );
    is( unpack( 'V', substr( $w, 40, 4 ) ), 48000 * 10 * 6, 'a WAV with a length states its data size: frames x channels x bytes' );
    is( unpack( 'V', substr( $w, 4, 4 ) ), 48000 * 10 * 6 + 36, 'and its RIFF size' );
    is( $F->can('describeText')->( $F->can('describeHeader')->($w) ), 'WAV 48000 Hz / 24 bit / 2 ch, length 0:10', 'and reads back' );
    is( unpack( 'V', substr( $F->can('wavHeader')->( 48000, 2, 24 ), 40, 4 ) ), 0xFFFFFFFF, 'CONTROL: none given, "to the end"' );
}

# ---------------------------------------------------------------------------
print "-- which streams lack a header --\n";

is( $F->can('lacksHeader')->( 'flc', 'fLaC' . "\0" x 40 ), 0, 'a FLAC stream that starts with fLaC has one' );
is( $F->can('lacksHeader')->( 'flc', "\xFF\xF8\x69\x08" ), 1, 'one that starts at a frame does not' );
is( $F->can('lacksHeader')->( 'FLC', "junk" ), 1, 'the format name is not case-sensitive' );
is( $F->can('lacksHeader')->( 'wav', 'RIFF' . "\0" x 40 ), 0, 'a WAV that starts with RIFF has one' );
is( $F->can('lacksHeader')->( 'wav', "\x01\x02\x03\x04" ), 1, 'raw PCM under wav does not' );
is( $F->can('lacksHeader')->( 'mp3', "\x01\x02\x03\x04" ), 0, 'MP3 frames describe themselves: never asked about' );
is( $F->can('lacksHeader')->( 'aac', "\x01\x02\x03\x04" ), 0, 'nor AAC' );
is( $F->can('lacksHeader')->( 'ogg', "\x01\x02\x03\x04" ), 0, 'nor Ogg' );
is( $F->can('lacksHeader')->( 'flc', 'fLa' ), 0, 'three bytes cannot say: no verdict' );

# ---------------------------------------------------------------------------
print "-- the headers that can be made --\n";

{
    my $w = $F->can('wavHeader')->( 48000, 2, 24 );
    is( length $w, 44, 'a WAV header is 44 bytes' );
    my $d = $F->can('describeHeader')->($w);
    is( "$d->{container} $d->{rate}/$d->{bits}/$d->{channels}", 'WAV 48000/24/2', 'and reads back as what it says' );
    is( unpack( 'V', substr( $w, 28, 4 ) ), 48000 * 6, 'byte rate = rate x channels x bytes per sample' );
    is( unpack( 'V', substr( $w, 40, 4 ) ), 0xFFFFFFFF, 'data size "to the end": the length is not known' );

    is( $F->can('wavHeader')->( 44100, 2, 20 ), undef, 'no WAV header for a depth that is not whole bytes' );
    is( $F->can('flacHeader')->( undef, 2, 16 ), undef, 'no FLAC header without a rate' );
    is( $F->can('flacHeader')->( 44100, 2, undef ), undef, 'nor without a depth' );
    is( $F->can('headerFor')->( 'mp3', 44100, 2, 16 ), undef, 'and none for a format that needs none' );
    is( length( $F->can('headerFor')->( 'flc', 44100, 2, 16 ) ), 42, 'headerFor flc is the FLAC header' );
    is( length( $F->can('headerFor')->( 'wav', 44100, 2, 16 ) ), 44, 'headerFor wav is the WAV header' );
}

# ---------------------------------------------------------------------------
print "-- the readout --\n";

{
    my $D = sub { $F->can('describeHeader')->(shift)->{container} };

    is( $D->(''),                       'nothing yet', 'nothing read yet' );
    is( $D->( 'OggS' . "\0" x 20 ),     'Ogg',         'Ogg' );
    is( $D->( "\0\0\0\x20ftypM4A " ),   'MP4',         'MP4 / ALAC / AAC in MP4' );
    is( $D->( 'ID3' . "\x04" x 10 ),    'MP3',         'MP3 behind an ID3 tag' );
    is( $D->( "\xFF\xFB\x90\x64" ),     'MP3',         'a bare MP3 frame' );
    is( $D->( "\xFF\xF8\x69\x08" ),     'FLAC frames, NO header', 'a FLAC frame sync is NOT read as MP3' );
    is( $D->( 'FORM' . "\0" x 4 . 'AIFF' ), 'AIFF',    'AIFF' );

    my $t = $F->can('describeText');
    is( $t->( { container => 'FLAC', rate => 96000, bits => 24, channels => 2 } ), 'FLAC 96000 Hz / 24 bit / 2 ch', 'the text' );
    is( $t->( { container => 'FLAC', rate => 96000, bits => 24, channels => 2, synthesised => 1 } ),
        'FLAC 96000 Hz / 24 bit / 2 ch (header synthesised for a seeked stream)', 'says when the header was made here' );
    is( $t->(undef), '', 'and nothing for nothing' );
}

# ---------------------------------------------------------------------------
printf "\n%s: %d passed, %d failed\n", ( $fail ? 'FAIL' : 'ok' ), $pass, $fail;
exit( $fail ? 1 : 0 );
