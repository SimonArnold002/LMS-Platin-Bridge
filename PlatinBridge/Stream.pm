package Plugins::PlatinBridge::Stream;

# The HTTP endpoint the Hub fetches audio from.
#
# IT PASSES LMS'S BYTES THROUGH UNTOUCHED (0.2.0). Whatever LMS's transcode table
# produced for this player - SqueezeDSP's FLAC or WAV, or a native file - goes to
# the Hub exactly as it came out. The bytes come through Player::nextChunk, which
# is also where a re-opened connection is served its replay; this module only
# decides what each request is owed and hands the socket to LMS's own streaming
# machinery, so the write queue, partial writes and connection lifecycle stay in
# proven LMS code.
#
# WHAT THIS MODULE IS ACTUALLY FOR is the handful of things LMS will not do for a
# player that is not a Squeezebox:
#   1. close the PREVIOUS streaming connection (LMS's guard is class-gated, so
#      two consumers otherwise draw from one chunk queue and each gets half the
#      bytes),
#   2. serve a SECOND request for a track from the START of it - see below,
#   3. set a status code, because a raw function is handed a response object with
#      none and nothing downstream fills it in.
# Every one of those fails SILENTLY - the Hub receives zero bytes or noise and
# nothing is logged as an error at either end.
#
# THE HUB OPENS A TRACK TWICE. Measured on the UPnP Bridge's log 2026-10-17, on
# every start: a probe GET, closed, then the real GET about 0.8 s later - the
# GStreamer pattern (typefind, then the pipeline). The bytes the probe read are
# gone from LMS's stream; it cannot send them twice. With a pcm wire that cost
# nothing (this module wrote a fresh WAV header per connection), but LMS's bytes
# now CARRY the header, so a second GET that continued from where the probe left
# off would get a stream with no header at all - static on WAV, nothing on FLAC
# (SqueezeDSP's ledger, `STATIC ON A LOST WAV HEADER`, is that failure on the
# bridge). So each track's opening bytes are kept (Player::_record) and a second
# request is served from them first. The UPnP Bridge does the same with an 8 MB
# ring, and that is what made its short-first-track fix work on this Hub.
#
# PATH-ONLY URLS, no query string. The sequence number makes each track's url
# unique, which matters for SetNextAVTransportURI (a renderer given the same uri
# twice may treat it as already loaded) and for the hand-over, which compares
# uris.

use strict;
use warnings;

use IO::Socket::INET;
use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Utils::IPDetect;
use Slim::Web::HTTP;
use Slim::Web::Pages;

use Plugins::PlatinBridge::Format;
use Plugins::PlatinBridge::Trace;

my $log   = logger('plugin.platinbridge');
my $prefs = preferences('server');

use constant PATH => '/platin/';

# A Hub that re-opens one track too often (Player::pbTakeoverOK) is told so a
# second late. An immediate refusal is only the next turn of its loop: measured
# 2026-10-25 (0.2.0, a track started part way in), 36-80 refusals a
# second, each one a warning in the server log.
use constant REFUSE_DELAY => 1;

my %loopWarned;

sub init {
    Slim::Web::Pages->addRawFunction( qr{^/platin/}, \&_handler );
    return;
}

# A player id is a MAC-shaped string; ':' is legal in a path but needlessly
# awkward, so it becomes '-'.
sub tokenFor {
    my $id = shift;
    $id =~ s/:/-/g;
    return $id;
}

# THE ADDRESS WE PUT IN THE URL IS THE ONE THE HUB HAS TO REACH US ON, and
# Slim::Utils::IPDetect::IP() answers 127.0.0.1 on this server - a url built from
# it is unreachable from anywhere but the box itself.
#
# So ask the routing table: a UDP socket "connected" to the Hub SENDS NOTHING
# (UDP connect is a purely local operation) but binds the local address of
# whichever interface routes to that peer.
sub serverBase {
    my ( $class, $client ) = @_;

    my $port = $prefs->get('httpport') || 9000;
    my $peer = $client->pbDevice && $client->pbDevice->{ip};

    my $ip;

    if ($peer) {
        my $s = IO::Socket::INET->new( Proto => 'udp', PeerAddr => $peer, PeerPort => 9 );
        $ip = $s->sockhost if $s;
        undef $s;
    }

    if ( !$ip || $ip eq '0.0.0.0' || $ip =~ /^127\./ ) {
        $ip = Slim::Utils::IPDetect::IP();
        $log->warn("could not determine a routable server address for the Hub; falling back to $ip")
            if !$ip || $ip =~ /^127\./;
    }

    return 'http://' . $ip . ':' . $port;
}

sub urlFor {
    my ( $class, $client, $fmt, $seq ) = @_;

    $seq = $client->pbSeq || 0 unless defined $seq;

    return $class->serverBase($client)
        . PATH
        . tokenFor( $client->id )
        . '/' . $seq
        . '.' . Plugins::PlatinBridge::Format::ext($fmt);
}

sub _clientFor {
    my $token = shift;

    # A linear scan over a handful of players, deliberately, rather than a
    # registry that can get out of sync with the real client list.
    for my $c ( Slim::Player::Client::clients() ) {
        next unless $c->isa('Plugins::PlatinBridge::Player');
        return $c if tokenFor( $c->id ) eq $token;
    }

    return undef;
}

# 'bytes=N-' or 'bytes=N-M' -> N. Anything else -> undef (no range asked).
sub rangeStart {
    my $h = shift;
    return undef unless defined $h && $h =~ /^\s*bytes\s*=\s*(\d+)\s*-/i;
    return $1 + 0;
}

# The request headers a seek can arrive in, as ' [Name: value; ...]', or '' when
# none was sent.
my @ASKED = qw( Range TimeSeekRange.dlna.org getcontentFeatures.dlna.org PlaySpeed.dlna.org
                realTimeInfo.dlna.org getAvailableSeekRange.dlna.org );

sub _asked {
    my $request = shift;
    my @h = map { my $v = $request->header($_); ( defined $v && length $v ) ? "$_: $v" : () } @ASKED;
    return @h ? ' [' . join( '; ', @h ) . ']' : '';
}

sub _handler {
    my ( $httpClient, $response ) = @_;

    return unless $httpClient && $httpClient->connected;

    my $request = $response->request;
    my $path    = $request->uri->path;

    my ( $token, $seq ) = $path =~ m{^/platin/([^/]+)/(\d+)\.};

    my $client = $token ? _clientFor($token) : undef;

    return _fail( $httpClient, $response, 404, 'no such player' ) if !$client;
    return _fail( $httpClient, $response, 404, 'no track in this url' ) if !defined $seq;

    my $method = uc( $request->method || 'GET' );

    if ( $method ne 'GET' && $method ne 'HEAD' ) {
        return _fail( $httpClient, $response, 405, 'method not allowed' );
    }

    my $live  = $client->pbLiveSeq;
    my $armed = $client->pbArmedFor($seq);

    # A sequence this player never handed out.
    if ( !$armed || !defined $live || $seq > $live ) {
        Plugins::PlatinBridge::Trace::note( 'refused', "$path - not a track we handed out" );
        return _fail( $httpClient, $response, 404, 'no such track' );
    }

    my $cache = $client->pbCacheFor($seq);

    # AN EARLIER TRACK can only be served from what was kept of it: LMS's stream
    # has moved on to the next one. A track kept whole is served whole; anything
    # less is gone, and saying so beats sending part of one track under another's
    # url. The same holds for a finished track that was too long to keep.
    my $whole = ( $cache && $cache->{eof} && !$cache->{capped} ) ? 1 : 0;

    if ( ( $seq < $live && !$whole ) || ( $cache && $cache->{eof} && $cache->{capped} ) ) {
        Plugins::PlatinBridge::Trace::note( 'refused', "$path - track no longer held" );
        return _fail( $httpClient, $response, 410, 'this track is no longer available' );
    }

    # NOTHING TO STREAM YET? REFUSE, and refuse WITHOUT touching the player. An
    # empty 200 reads to a renderer as a resource that exists and is empty, so it
    # retries at once - measured on the Hub in 0.1.x: tens of connections a
    # second, each displacing the last, and no audio ever moved.
    my $controller = $client->controller;

    if ( $seq == $live && !( $cache && $cache->{eof} ) && !( $controller && $controller->streamingSong ) ) {
        Plugins::PlatinBridge::Trace::note( 'refused', "$path - nothing is streaming" );
        return _fail( $httpClient, $response, 503, 'nothing is streaming yet' );
    }

    # A RAW FUNCTION IS HANDED A RESPONSE WITH NO STATUS CODE and nothing fills
    # one in. Omitting it sends a status line of "HTTP/1.1  ", which a renderer's
    # parser rejects with an error that names an empty integer.
    $response->code(200);
    $response->content_type( Plugins::PlatinBridge::Format::mimeFor( $armed->{fmt} ) );

    # No Content-Length: a live transcode has no known length, and this is a
    # stream rather than a file - close-delimited. Byte ranges ARE offered, over
    # what is held of the track: that is what the UPnP Bridge answers this Hub.
    $response->header( 'Accept-Ranges'         => 'bytes' );
    $response->header( 'Cache-Control'         => 'no-cache, no-store' );
    $response->header( 'Connection'            => 'close' );
    $response->header( 'transferMode.dlna.org' => 'Streaming' );

    if ( $request->header('getcontentFeatures.dlna.org') ) {
        $response->header( 'contentFeatures.dlna.org' => Plugins::PlatinBridge::Format::dlnaFeatures()
            || 'DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000' );
    }

    # WHAT THE HUB ASKED FOR beyond the url, carried on this connection's trace
    # entry - how a seek by the Hub shows itself (`A SEEK THE HUB DOES ITSELF`).
    my $asked = _asked($request);

    # WHERE THIS CONNECTION STARTS, judged on what is held.
    my $from  = rangeStart( $request->header('Range') );
    my $held  = $cache ? length( $cache->{buf} ) : 0;
    my $total = $cache ? $cache->{total} : 0;
    my $replay;

    if ( $total == 0 ) {
        # A first request: there is nothing to replay, so the stream starts at 0
        # whatever was asked - LMS's source cannot begin anywhere else.
        $replay = undef;
    }
    elsif ( !$from ) {
        # A request for the start of a track already being sent: from the top.
        $replay = 0;
    }
    elsif ( $from < $held ) {
        $replay = $from;
        $response->code(206);
        $response->header( 'Content-Range' => 'bytes ' . $from . '-' . ( $total - 1 ) . '/*' );
    }
    elsif ( $from == $total && $seq == $live && !$cache->{eof} ) {
        # Picking up exactly where the last connection stopped: the live stream
        # simply continues, as the UPnP Bridge answers the same request.
        $replay = undef;
    }
    else {
        $response->header( 'Content-Range' => 'bytes */' . $total ) if $cache->{eof};
        Plugins::PlatinBridge::Trace::note( 'refused', "$path - cannot serve from byte $from$asked" );
        return _fail( $httpClient, $response, 416, "cannot serve from byte $from" );
    }

    if ( $method eq 'HEAD' ) {
        Plugins::PlatinBridge::Trace::note( 'head', $path . $asked );
        return _head( $httpClient, $response );
    }

    if ( !$client->pbTakeoverOK($seq) ) {
        Plugins::PlatinBridge::Trace::note( 'refused', "$path - re-opened too often" );

        # One warning a minute, not one per refusal.
        my $now = Time::HiRes::time();
        if ( $now - ( $loopWarned{ $client->id } || 0 ) > 60 ) {
            $loopWarned{ $client->id } = $now;
            $log->warn( sprintf '%s: the Hub keeps re-opening %s - refusing it for now', $client->name, $path );
        }

        Slim::Utils::Timers::setTimer( $httpClient, $now + REFUSE_DELAY, sub {
            my $h = shift;
            return unless $h && $h->connected;
            _fail( $h, $response, 503, 'this track has been re-opened too often', 1 );
        } );

        return;
    }

    main::INFOLOG && $log->is_info && $log->info( sprintf '%s: serving %s as %s%s',
        $client->name, $path, $response->content_type,
        ( defined $replay ? " from byte $replay of what was already sent" : '' ) );

    Plugins::PlatinBridge::Trace::note( 'connect', $path
        . ( defined $replay ? " replay from $replay/$total" : '' ) . $asked );

    _takeOverSocket( $client, $httpClient, $response, $seq, $replay, $total );

    return;
}

# A HEAD MUST NOT CLAIM Content-Length: 0 - zero is an assertion that the
# resource is EMPTY. The honest answer is the GET's headers and no length at all,
# written straight to the socket because send_response is free to invent one.
sub _head {
    my ( $httpClient, $response ) = @_;

    my $headers = _stringifyHeaders($response) . "\r\n";

    my $off = 0;
    while ( $off < length $headers ) {
        my $n = syswrite $httpClient, $headers, length($headers) - $off, $off;
        last if !defined $n || $n <= 0;
        $off += $n;
    }

    Slim::Web::HTTP::closeHTTPSocket($httpClient);

    return;
}

# The housekeeping LMS does for a Squeezebox and not for us.
sub _takeOverSocket {
    my ( $client, $httpClient, $response, $seq, $replay, $total ) = @_;

    # 1. The PREVIOUS connection is never released by LMS for this class. Left
    #    open it stays in the write-select list still pulling nextChunk, so two
    #    consumers draw from one queue and each gets half the bytes.
    my $old = $client->streamingsocket;

    if ( $old && $old != $httpClient ) {
        main::INFOLOG && $log->is_info && $log->info( $client->name . ': closing the previous stream' );
        Slim::Web::HTTP::closeStreamingSocket($old);
    }

    # 2. A FIRST connection for a track flushes the chunk queue: nothing of this
    #    track has been read yet, so anything queued belongs to a stream being
    #    replaced (a stale end-of-stream marker would otherwise end it before it
    #    starts). A RE-OPENED track must NOT be flushed - the queue then holds the
    #    rest of a chunk LMS split, which has not been kept yet, and dropping it
    #    would leave a hole between the replay and the live stream.
    @{ $client->chunks } = () if !$total;

    $client->pbStreamOpened( $seq, $replay );

    my $headers = _stringifyHeaders($response) . "\r\n";

    $Slim::Web::HTTP::peerclient{$httpClient} = $client->id;

    delete $Slim::Web::HTTP::keepAlives{$httpClient};
    Slim::Utils::Timers::killTimers( $httpClient, \&Slim::Web::HTTP::closeHTTPSocket );

    # 3. NEGATIVE on purpose: sendStreamingResponse counts the headers toward the
    #    ICY metadata interval, so starting at minus their length keeps the first
    #    metadata boundary where the renderer expects it.
    $Slim::Web::HTTP::metaDataBytes{$httpClient} = -length($headers);

    Slim::Web::HTTP::addStreamingResponse( $httpClient, $headers );

    return;
}

sub _stringifyHeaders {
    my $response = shift;

    my $code = $response->code;
    my $msg  = $response->message || HTTP::Status::status_message($code) || '';

    my $out = 'HTTP/1.1 ' . $code . ' ' . $msg . "\r\n";

    $response->scan( sub {
        my ( $k, $v ) = @_;
        $out .= $k . ': ' . $v . "\r\n";
    } );

    return $out;
}

sub _fail {
    my ( $httpClient, $response, $code, $why, $quiet ) = @_;

    $log->warn("stream: $code $why") unless $quiet || $code == 404 || $code == 416;

    $response->code($code);
    $response->content_type('text/plain');
    $response->header( 'Connection' => 'close' );
    $response->content("$why\n");

    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \( $response->content ) );

    return;
}

1;
