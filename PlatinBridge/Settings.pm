package Plugins::PlatinBridge::Settings;

# The settings page. Since 0.2.0 there is nothing to set - the audio options went
# with the audio stage - but the page stays, for two reasons: a plugin with no
# page reads as a plugin that is not working (Simon, 0.1.x: "nothing works on
# this at all, no settings"), and it is the one place a person sees what the Hub
# said about itself, what the player offers LMS, and whether the Hub is on.

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.platinbridge');
my $log   = logger('plugin.platinbridge');

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_PLATIN_BRIDGE') }

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/PlatinBridge/settings/basic.html') }

sub prefs { return ($prefs) }

# Everything below is display only, built on every render.
sub handler {
    my ( $class, $client, $params, $callback, @args ) = @_;

    # A HALF-DEAD HANDLER STILL RENDERS - the page comes back looking fine with
    # the status quietly missing - so the gathering is wrapped and its failure is
    # reported rather than swallowed.
    eval { $class->_status($params); 1 }
        or $log->error("settings: could not read the renderer status: $@");

    return $class->SUPER::handler( $client, $params, $callback, @args );
}

sub _status {
    my ( $class, $params ) = @_;

    my $bridges = Plugins::PlatinBridge::Plugin::bridges();

    my @rows;

    for my $udn ( sort keys %$bridges ) {
        my $b      = $bridges->{$udn};
        my $upnp   = $b->{upnp};
        my $client = $b->{client};
        my $ctl    = $b->{control};

        my $r   = $upnp && $upnp->volRange;
        my $src = $ctl && $ctl->source;

        push @rows, {
            name     => ( $upnp && $upnp->name ) || ( $b->{device}{name} || 'Platin Hub' ),
            model    => $upnp ? join( ' ', grep { $_ } $upnp->maker, $upnp->model ) : '',
            udn      => $udn,
            address  => $b->{device}{ip} || '',
            ready    => ( $upnp && $upnp->isReady ) ? 1 : 0,
            gapless  => ( $upnp && $upnp->canGapless ) ? 1 : 0,
            volume   => $r ? "$r->{min} - $r->{max}" : '',
            control  => ( $ctl && $ctl->isUp ) ? 1 : 0,
            power    => ( $ctl && defined $ctl->power ) ? ( $ctl->power ? 'on' : 'off' ) : '',
            source   => $src ? $src->{name} : '',
            formats  => $client ? join( ', ', $client->formats ) : '',
            maxrate  => $client ? $client->maxSupportedSamplerate : '',
            playing  => $client ? ( $client->pbURL || '' ) : '',
        };
    }

    $params->{platin_devices} = \@rows;
    $params->{platin_none}    = @rows ? 0 : 1;

    return;
}

1;
