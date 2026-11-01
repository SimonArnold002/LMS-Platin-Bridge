package Plugins::PlatinBridge::Control;

# The Hub's own control port: TCP 50006, its "System Control" protocol. This is
# what switches the Hub on and off, and what tells us when its own remote or the
# Platin app did.
#
# WHY A SECOND CHANNEL AT ALL. UPnP has no power verb, and while the Hub is OFF
# it reports PAUSED_PLAYBACK - read live 2026-10-25 - so over UPnP alone "off"
# and "paused" are the same answer. That ambiguity is the root of the old wake
# bug. Port 50006 says which, and pushes every change.
#
# WHAT THE HUB IS. A Libre Wireless LS10 streaming module in front of the Hub's
# own microcontroller (firmware CR443GP_3863.062.2 on Simon's unit). Its media
# port, 7777 (LUCI), wants a client certificate on this model and is out of
# reach; 50006 has no handshake and no authentication. The protocol was mapped
# by drsound's aiolibresync (github.com/drsound/aiolibresync, docs/
# protocol-system-control.md), and the HT itself was characterised in that
# project's issue #2 - this module uses only frames that work recorded as tested.
#
# THE FRAME: [length: 2 bytes BE][checksum][class][opcode][data...]
#   length counts everything after itself; checksum = sum(class..data) & 0xFF.
#   The firmware does not check the checksum, and byte 2 is NOT a direction flag,
#   so a frame is identified by class + opcode + data length and nothing else.
#
# THE BUS IS SHARED. Every report reaches every connected client, and other
# clients' commands are visible too, so only the REPORT forms are decoded: a
# `02 0f` from the Platin app must never be read as a power state.
#
# POWER IS A TOGGLE. `02 0f` ignores its data byte - the vendor's own "power on"
# frame turns a Hub that is already on OFF. So every change here is
# read-then-act: ask, compare, toggle only on a difference, then wait for the
# Hub to confirm. Toggling first and correcting afterwards audibly cycles the
# speakers whenever the state was already right.
#
# AND "POWER" IS NOT MAINS POWER. While off, the Hub answers on both ports and
# keeps its state. Switching off is a stop; switching on restores nothing; and
# the Hub switches ITSELF on when a source starts sending - which is how LMS
# starting playback used to wake it.
#
# All socket I/O is non-blocking and driven from Slim::Networking::Select - the
# same pattern LMS-HQPlayer-Bridge's Control.pm has run in the field since
# 2026-08 - so nothing here may block LMS's event loop.

use strict;
use warnings;

use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_ERROR inet_aton pack_sockaddr_in);
use Errno  qw(EINPROGRESS EWOULDBLOCK EAGAIN EINTR);
use Time::HiRes ();

use Slim::Networking::Select;
use Slim::Utils::Log;
use Slim::Utils::Timers;

my $log = logger('plugin.platinbridge');

use constant PORT => 50006;

use constant CLASS_SYSTEM => 0x02;

use constant OP_SOURCE_GET    => 0x01;
use constant OP_SOURCE_REPORT => 0x02;
use constant OP_SOURCE_SET    => 0x03;
use constant OP_POWER_GET     => 0x0D;
use constant OP_POWER_REPORT  => 0x0E;
use constant OP_POWER_TOGGLE  => 0x0F;

# Frames that are understood but carry no state we model: our own and other
# clients' requests, and the connect-time configuration blocks the vendor's app
# reads. Anything outside this and the decoder is unknown and only logged.
my %KNOWN_UNDECODED = map { ( CLASS_SYSTEM << 8 | $_ ) => 1 }
    ( OP_SOURCE_GET, OP_SOURCE_SET, OP_POWER_GET, OP_POWER_TOGGLE, 0x20, 0x21, 0x4A, 0x4B, 0x4D, 0x4E, 0x8B );

use constant MIN_BODY => 3;          # checksum + class + opcode
use constant MAX_BODY => 0x1400;

use constant CONNECT_TIMEOUT => 5;

# A bound on how stale the power state can get, and the only way a connection to
# a peer that vanished without closing gets noticed: a query that nobody answers.
# The library this protocol came from polls at the same 30s.
use constant POLL_PERIOD => 30;
use constant REPLY_WAIT  => 5;

# How long a toggle may take to be confirmed. The Hub reports a power change
# within a second; five is generous and still short enough that a user pressing
# the button again is not left waiting on a command that went nowhere.
use constant CONFIRM_WAIT => 5;

# Never toggle more than this for one request. A conflict - the remote pressed
# while we were toggling - would otherwise make the two fight; the Hub wins.
use constant MAX_TOGGLES => 2;

use constant BACKOFF_MIN => 2;
use constant BACKOFF_MAX => 30;

# The source the Hub's JSON calls "Streaming" (its RF remote labels it "Wi-Fi").
# This is the one LMS plays through.
use constant STREAMING => 'streaming';

# ---------------------------------------------------------------------------
# Framing - plain functions, no state, so the suite drives them directly.

sub frame {
    my ( $cls, $op, @data ) = @_;

    my $body = pack( 'C*', $cls, $op, @data );
    my $sum  = 0;
    $sum += $_ for unpack( 'C*', $body );

    return pack( 'n', length($body) + 1 ) . chr( $sum & 0xFF ) . $body;
}

# Take every complete frame off the front of a byte buffer, leaving any partial
# one behind. A length that cannot be a frame costs ONE byte and the reader tries
# again: a firmware we have not seen must not wedge the connection.
sub takeFrames {
    my $bufref = shift;

    my @frames;

    while ( length($$bufref) >= 2 ) {
        my $len = unpack( 'n', substr( $$bufref, 0, 2 ) );

        if ( $len < MIN_BODY || $len > MAX_BODY ) {
            substr( $$bufref, 0, 1, '' );
            next;
        }

        last if length($$bufref) < $len + 2;

        push @frames, substr( $$bufref, 0, $len + 2, '' );
    }

    return @frames;
}

# One frame -> what it says.
#   { power => 0|1 }
#   { sources => [ { ix, name, on } ... ], source => { ix, name } | undef }
#   {}     understood, but carries no state (a request, a config block)
#   undef  not something this module has seen
sub decode {
    my $f = shift;

    return undef unless defined $f && length($f) >= 5;

    my ( $cls, $op ) = unpack( 'C2', substr( $f, 3, 2 ) );
    my $data = substr( $f, 5 );

    if ( $cls == CLASS_SYSTEM ) {

        if ( $op == OP_POWER_REPORT && length($data) == 1 ) {
            return { power => ( ord($data) ? 1 : 0 ) };
        }

        if ( $op == OP_SOURCE_REPORT && $data =~ /^\s*\{/ ) {
            my ( $list, $cur ) = parseSources($data);
            return undef unless $list;
            return { sources => $list, source => $cur };
        }
    }

    return {} if $KNOWN_UNDECODED{ $cls << 8 | $op };

    return undef;
}

# The `02 02` body: {"src":[{"ix":0,"name":"Line","sts":0}, ...]}
#
# Read with a pattern rather than a JSON module: the shape is fixed and tiny,
# and JSON::PP is core Perl but NOT shipped by LMS on every platform (the
# HQPlayer bridge's ledger, `use JSON::PP ()` at BEGIN time). Each object is read
# key by key, so the order of the keys does not matter.
sub parseSources {
    my $json = shift;

    my ($arr) = $json =~ /"src"\s*:\s*\[(.*)\]/s or return;

    my ( @list, $cur );

    while ( $arr =~ /\{([^{}]*)\}/g ) {
        my $o = $1;

        my ($ix)   = $o =~ /"ix"\s*:\s*(\d+)/;
        my ($name) = $o =~ /"name"\s*:\s*"((?:[^"\\]|\\.)*)"/;
        my ($sts)  = $o =~ /"sts"\s*:\s*(\d+)/;

        next unless defined $ix && defined $name;

        my $s = { ix => $ix + 0, name => $name, on => ( $sts ? 1 : 0 ) };
        push @list, $s;
        $cur = { ix => $s->{ix}, name => $s->{name} } if $sts;
    }

    return unless @list;

    return ( \@list, $cur );
}

sub isStreaming {
    my $src = shift;
    return ( $src && lc( $src->{name} || '' ) eq STREAMING ) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# The connection

# onPower  -> ( $on, $own, $first )  $own: the report confirms OUR request
#                                    $first: the first report this object has had
# onSource -> ( $now, $was )         only on a change of source
# onState  -> ( $up )
sub new {
    my ( $class, %args ) = @_;

    return bless {
        host     => $args{host},
        port     => $args{port} || PORT,
        name     => $args{name} || 'Platin Hub',
        onPower  => $args{onPower},
        onSource => $args{onSource},
        onState  => $args{onState},
        sock       => undef,
        connecting => 0,
        up         => 0,
        rbuf       => '',
        wbuf       => '',
        power      => undef,
        source     => undef,
        sources    => [],
        cmd        => undef,
        backoff    => BACKOFF_MIN,
        closing    => 0,
        quiet      => 0,
    }, $class;
}

sub host     { $_[0]->{host} }
sub isUp     { $_[0]->{up} ? 1 : 0 }
sub power    { $_[0]->{power} }            # undef = never told
sub source   { $_[0]->{source} }           # { ix, name } or undef
sub sources  { [ @{ $_[0]->{sources} } ] }
sub busy     { $_[0]->{cmd} ? 1 : 0 }

# 1 on Streaming, 0 on anything else, undef when the Hub has not said.
sub onStreaming {
    my $s = $_[0]->{source} or return undef;
    return isStreaming($s);
}

sub streamingIndex {
    my $self = shift;
    for my $s ( @{ $self->{sources} } ) {
        return $s->{ix} if isStreaming($s);
    }
    return undef;
}

sub start {
    my $self = shift;
    $self->{closing} = 0;
    $self->connect;
    return;
}

# The Hub moved (DHCP). Drop the link and come back on the new address.
sub setHost {
    my ( $self, $host ) = @_;

    return if defined $self->{host} && defined $host && $self->{host} eq $host;

    $self->{host} = $host;

    if ( $self->{sock} ) {
        $self->_drop('the Hub moved');
    }

    return;
}

sub close {
    my $self = shift;

    $self->{closing} = 1;
    Slim::Utils::Timers::killTimers( $self, \&_reconnect );
    $self->_drop('shutting down');

    return;
}

sub connect {
    my $self = shift;

    return if $self->{sock} || $self->{connecting} || $self->{closing};
    return unless $self->{host};

    my $sock = IO::Socket::INET->new( Proto => 'tcp', Blocking => 0 );

    if ( !$sock ) {
        $self->_outage("cannot create socket: $!");
        return $self->_scheduleReconnect;
    }

    my $packed = inet_aton( $self->{host} );

    if ( !$packed ) {
        CORE::close($sock);
        $self->_outage("no address for $self->{host}");
        return $self->_scheduleReconnect;
    }

    $self->{sock}       = $sock;
    $self->{connecting} = 1;

    # Non-blocking connect: EINPROGRESS is the expected outcome.
    if ( !CORE::connect( $sock, pack_sockaddr_in( $self->{port}, $packed ) ) ) {
        my $err = $!;
        if ( $err != EINPROGRESS && $err != EWOULDBLOCK ) {
            $self->_outage("connect failed: $err");
            return $self->_drop("connect: $err");
        }
    }

    Slim::Networking::Select::addWrite( $sock, sub { $self->_connectResolved } );
    Slim::Networking::Select::addError( $sock, sub { $self->_drop('select error during connect') } );

    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + CONNECT_TIMEOUT, \&_connectTimeout );

    return;
}

sub _connectResolved {
    my $self = shift;
    my $sock = $self->{sock} or return;

    Slim::Utils::Timers::killTimers( $self, \&_connectTimeout );
    Slim::Networking::Select::removeWrite($sock);

    my $packed = getsockopt( $sock, SOL_SOCKET, SO_ERROR );
    my $err    = $packed ? unpack( 'I', $packed ) : 0;

    if ($err) {
        $! = $err;
        $self->_outage("connect refused: $!");
        return $self->_drop("connect: $!");
    }

    $self->{connecting} = 0;
    $self->{up}         = 1;

    Slim::Networking::Select::addRead( $sock, sub { $self->_readable } );

    main::INFOLOG && $log->is_info && $log->info("$self->{name}: control link up ($self->{host}:$self->{port})");

    # Read the state rather than inferring it: the Hub answers queries.
    $self->_send( frame( CLASS_SYSTEM, OP_POWER_GET ) );
    $self->_send( frame( CLASS_SYSTEM, OP_SOURCE_GET ) );
    $self->_awaitReply;

    $self->{onState}->(1) if $self->{onState};

    return;
}

sub _connectTimeout {
    my $self = shift;
    $self->_outage( 'connect timed out after ' . CONNECT_TIMEOUT . 's' );
    $self->_drop('connect timeout');
}

# ---------------------------------------------------------------------------
# Writing. Every frame we build is ASCII-free binary we packed ourselves, so the
# buffer is octets by construction - there is no character string to encode.

sub _send {
    my ( $self, $bytes ) = @_;

    return 0 unless $self->{up} && $self->{sock};

    $self->{wbuf} .= $bytes;
    $self->_flush;

    return 1;
}

sub _flush {
    my $self = shift;

    my $sock = $self->{sock} or return;
    return unless length $self->{wbuf};

    my $wrote = syswrite( $sock, $self->{wbuf} );

    if ( !defined $wrote ) {
        return if $! == EWOULDBLOCK || $! == EAGAIN || $! == EINTR;
        return $self->_drop("write: $!");
    }

    substr( $self->{wbuf}, 0, $wrote, '' );

    if ( length $self->{wbuf} ) {
        Slim::Networking::Select::addWrite( $sock, sub { $self->_flush } );
    }
    else {
        Slim::Networking::Select::removeWrite($sock);
    }

    return;
}

# ---------------------------------------------------------------------------
# Reading

sub _readable {
    my $self = shift;

    my $sock = $self->{sock} or return;

    my $got = sysread( $sock, my $chunk, 4096 );

    if ( !defined $got ) {
        return if $! == EWOULDBLOCK || $! == EAGAIN || $! == EINTR;
        return $self->_drop("read: $!");
    }

    return $self->_drop('the Hub closed the link') if $got == 0;

    $self->{rbuf} .= $chunk;

    for my $f ( takeFrames( \$self->{rbuf} ) ) {
        $self->_onFrame($f);
    }

    return;
}

sub _onFrame {
    my ( $self, $f ) = @_;

    # ANY frame proves the link: the Hub is there and talking.
    Slim::Utils::Timers::killTimers( $self, \&_replyLate );
    $self->{backoff} = BACKOFF_MIN;
    $self->{quiet}   = 0;

    my $d = decode($f);

    if ( !defined $d ) {
        main::DEBUGLOG && $log->is_debug
            && $log->debug( "$self->{name}: unknown frame " . unpack( 'H*', $f ) );
        return;
    }

    $self->_onPower( $d->{power} ) if exists $d->{power};
    $self->_onSources( $d->{sources}, $d->{source} ) if $d->{sources};

    return;
}

sub _onPower {
    my ( $self, $on ) = @_;

    my $was = $self->{power};
    $self->{power} = $on;

    my $own = $self->_advance($on);

    # The Hub sends TWO identical reports for a change made over the network, and
    # answers every poll with the same one - only a CHANGE is news.
    return if defined $was && $was == $on;

    main::INFOLOG && $log->is_info && $log->info( sprintf '%s: the Hub is %s%s',
        $self->{name}, ( $on ? 'on' : 'off' ), ( $own ? ' (as asked)' : '' ) );

    $self->{onPower}->( $on, $own, ( defined $was ? 0 : 1 ) ) if $self->{onPower};

    return;
}

sub _onSources {
    my ( $self, $list, $cur ) = @_;

    $self->{sources} = $list;

    # An absent `sts` on every entry means "this frame does not say", not "no
    # source" - keep the one already known.
    return unless $cur;

    my $was = $self->{source};
    $self->{source} = $cur;

    return if $was && $was->{ix} == $cur->{ix};

    main::INFOLOG && $log->is_info && $log->info("$self->{name}: source is $cur->{name}");

    $self->{onSource}->( $cur, $was ) if $self->{onSource};

    return;
}

# ---------------------------------------------------------------------------
# Power: read, compare, toggle only on a difference, wait for the confirmation.

sub setPower {
    my ( $self, $want, $cb ) = @_;

    $want = $want ? 1 : 0;

    if ( !$self->{up} ) {
        $cb->( 0, 'no control link' ) if $cb;
        return;
    }

    # A request while one is running moves its target: the running command
    # converges on the LATEST wish rather than queueing a second toggle.
    if ( my $c = $self->{cmd} ) {
        $c->{want} = $want;
        $c->{cb}   = $cb if $cb;
        return;
    }

    $self->{cmd} = { want => $want, phase => 'read', toggles => 0, cb => $cb };

    $self->_send( frame( CLASS_SYSTEM, OP_POWER_GET ) );
    $self->_armCmd(REPLY_WAIT);

    return;
}

# Every power report passes through here while a command runs. Returns 1 when
# the report is the confirmation of OUR request - so the caller does not mirror
# its own echo back into LMS.
sub _advance {
    my ( $self, $on ) = @_;

    my $c = $self->{cmd} or return 0;

    if ( $on == $c->{want} ) {
        $self->_finish( 1, $c->{toggles} ? 'switched' : 'already there' );
        return 1;
    }

    # Whether this report is the answer to OUR toggle. It is when it shows the
    # state that toggle was sent for - even if the wish has moved on since.
    my $ours = ( $c->{phase} eq 'toggle' && $on == $c->{toggledFor} ) ? 1 : 0;

    # After our toggle the Hub reports the OTHER state: someone else changed it at
    # the same moment, or the toggle did not take. The Hub wins - stop here, and
    # let the report go through as an outside change.
    if ( $c->{phase} eq 'toggle' && !$ours ) {
        $self->_finish( 0, 'the Hub reported the other state after our toggle' );
        return 0;
    }

    # Here the state differs from the wish: either the first read, or our toggle
    # took while the user pressed the button again. Converge, within a bound.
    if ( $c->{toggles} >= MAX_TOGGLES ) {
        $self->_finish( 0, 'gave up after ' . MAX_TOGGLES . ' toggles' );
        return $ours;
    }

    $c->{toggles}++;
    $c->{phase}      = 'toggle';
    $c->{toggledFor} = $c->{want};

    main::INFOLOG && $log->is_info && $log->info( "$self->{name}: switching the Hub " . ( $c->{want} ? 'on' : 'off' ) );

    $self->_send( frame( CLASS_SYSTEM, OP_POWER_TOGGLE, 0x00 ) );
    $self->_armCmd(CONFIRM_WAIT);

    return 1;
}

sub _armCmd {
    my ( $self, $wait ) = @_;
    Slim::Utils::Timers::killTimers( $self, \&_cmdLate );
    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + $wait, \&_cmdLate );
    return;
}

sub _cmdLate {
    my $self = shift;

    my $c = $self->{cmd} or return;

    # A toggle that was never confirmed: READ AGAIN before doing anything else. A
    # second blind toggle could undo one that worked but whose report was lost.
    if ( $c->{phase} eq 'toggle' ) {
        $c->{phase} = 'read';
        $self->_send( frame( CLASS_SYSTEM, OP_POWER_GET ) );
        $self->_armCmd(REPLY_WAIT);
        return;
    }

    $self->_finish( 0, 'the Hub did not answer' );

    return;
}

sub _finish {
    my ( $self, $ok, $why ) = @_;

    my $c = delete $self->{cmd} or return;

    Slim::Utils::Timers::killTimers( $self, \&_cmdLate );

    $log->warn("$self->{name}: power command not completed - $why") unless $ok;

    $c->{cb}->( $ok, $why ) if $c->{cb};

    return;
}

# ---------------------------------------------------------------------------
# Source

sub selectSource {
    my ( $self, $ix ) = @_;

    return 0 unless defined $ix && $ix =~ /^\d+$/ && $ix <= 0xFF;

    main::INFOLOG && $log->is_info && $log->info("$self->{name}: selecting source $ix");

    return $self->_send( frame( CLASS_SYSTEM, OP_SOURCE_SET, $ix ) );
}

sub selectStreaming {
    my $self = shift;
    my $ix = $self->streamingIndex;
    return defined $ix ? $self->selectSource($ix) : 0;
}

# ---------------------------------------------------------------------------
# Liveness

sub _awaitReply {
    my $self = shift;

    Slim::Utils::Timers::killTimers( $self, \&_replyLate );
    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + REPLY_WAIT, \&_replyLate );

    Slim::Utils::Timers::killTimers( $self, \&_poll );
    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + POLL_PERIOD, \&_poll );

    return;
}

sub _poll {
    my $self = shift;

    return unless $self->{up};

    $self->_send( frame( CLASS_SYSTEM, OP_POWER_GET ) );
    $self->_awaitReply;

    return;
}

# A query nobody answered: a peer that vanished without closing the socket. That
# is the only way such a connection is ever noticed.
sub _replyLate {
    my $self = shift;
    $self->_drop( 'no answer for ' . REPLY_WAIT . 's' );
}

# ---------------------------------------------------------------------------
# Teardown

sub _drop {
    my ( $self, $why ) = @_;

    my $wasUp = $self->{up};

    Slim::Utils::Timers::killTimers( $self, \&_connectTimeout );
    Slim::Utils::Timers::killTimers( $self, \&_replyLate );
    Slim::Utils::Timers::killTimers( $self, \&_poll );

    if ( my $sock = delete $self->{sock} ) {
        Slim::Networking::Select::removeRead($sock);
        Slim::Networking::Select::removeWrite($sock);
        Slim::Networking::Select::removeError($sock);
        CORE::close($sock);
    }

    $self->{up}         = 0;
    $self->{connecting} = 0;
    $self->{rbuf}       = '';
    $self->{wbuf}       = '';

    # The last power and source stay KNOWN for display, but nothing acts on them
    # while the link is down: every caller asks isUp first. A Hub that stops
    # answering has no opinion.
    $self->_finish( 0, 'control link lost' ) if $self->{cmd};

    if ($wasUp) {
        if ( $self->{closing} ) {
            main::INFOLOG && $log->is_info && $log->info("$self->{name}: control link closed");
        }
        else {
            $log->warn("$self->{name}: control link down - $why");
            $self->{quiet} = 1;
        }
        $self->{onState}->(0) if $self->{onState};
    }

    $self->_scheduleReconnect unless $self->{closing};

    return;
}

# ONE warning per outage, not one per retry.
sub _outage {
    my ( $self, $msg ) = @_;

    if ( $self->{quiet} ) {
        main::DEBUGLOG && $log->is_debug && $log->debug("$self->{name}: $msg");
        return;
    }

    $self->{quiet} = 1;
    $log->warn("$self->{name}: control link: $msg - further attempts are logged at debug until it answers");

    return;
}

sub _scheduleReconnect {
    my $self = shift;

    return if $self->{closing};

    my $delay = $self->{backoff};
    $self->{backoff} = $delay * 2 > BACKOFF_MAX ? BACKOFF_MAX : $delay * 2;

    Slim::Utils::Timers::killTimers( $self, \&_reconnect );
    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + $delay, \&_reconnect );

    return;
}

sub _reconnect {
    my $self = shift;
    $self->connect;
}

1;
