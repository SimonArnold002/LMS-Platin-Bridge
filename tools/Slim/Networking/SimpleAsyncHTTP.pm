package Slim::Networking::SimpleAsyncHTTP;
# Records requests instead of making them; a test drives the callback itself.
#
# post() matches LMS's signature: ->post($url, %headers, $body) - the body is
# the LAST argument and the headers are a flat list before it, NOT a hashref.
# Getting that wrong sends the body as a header value and the renderer answers
# 400 with nothing in the log to explain it.
use strict; use warnings;

our @REQ;

sub new { my ($c,$cb,$ecb,$p)=@_; return bless { cb=>$cb, ecb=>$ecb, p=>$p||{} }, $c }

sub get {
    my ($s,$url)=@_;
    push @REQ, { method=>'GET', url=>$url, %{$s->{p}}, cb=>$s->{cb}, ecb=>$s->{ecb} };
    return $s;
}

sub post {
    my ($s,$url,@rest)=@_;
    my $body = pop @rest;
    my %hdr  = @rest;
    push @REQ, { method=>'POST', url=>$url, headers=>\%hdr, body=>$body,
                 %{$s->{p}}, cb=>$s->{cb}, ecb=>$s->{ecb} };
    return $s;
}

# --- test helpers ----------------------------------------------------------
#
# All of these are CLASS METHODS - the tests call them as $HTTP->_respond(...),
# so each must shift the invocant off. Forgetting that put the class name into
# the body argument and every response arrived empty.

sub _reset { shift if @_; @REQ = (); return }

sub _last  { shift if @_; return @REQ ? $REQ[-1] : undef }
sub _count { shift if @_; return scalar @REQ }

# Answer the most recent request with a body, as a real success would.
sub _respond {
    shift if @_ && !ref $_[0] && $_[0] eq __PACKAGE__;
    my ( $body, $idx ) = @_;
    my $r = $REQ[ defined $idx ? $idx : -1 ] or die "no recorded request to respond to\n";
    my $res = bless { c => $body }, 'Slim::Networking::SimpleAsyncHTTP::_Res';
    $r->{cb}->($res);
    return;
}

# Fail the most recent request. $body is the response body a UPnP fault would
# carry, which the real client may or may not expose - the point of the test.
sub _failed {
    shift if @_ && !ref $_[0] && $_[0] eq __PACKAGE__;
    my ( $err, $body, $idx ) = @_;
    my $r = $REQ[ defined $idx ? $idx : -1 ] or die "no recorded request to fail\n";
    my $http = bless { c => $body }, 'Slim::Networking::SimpleAsyncHTTP::_Res';
    $r->{ecb}->( $http, $err );
    return;
}

package Slim::Networking::SimpleAsyncHTTP::_Res;
sub content { $_[0]->{c} }
sub code    { $_[0]->{code} }

1;
