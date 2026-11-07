#!/usr/bin/perl
#
# The settings page template, checked without LMS. There is no Template Toolkit
# on the Mac, so this is structural - but each check is a way the page has
# actually failed.
#
#   * 0.1.x to 0.2.1 wrapped the page in `settings/section.html`, which LMS 9.1
#     does not ship: every render was "file error - settings/section.html: not
#     found" and an EMPTY page (HTTP 200, 0 bytes). With no LMS header there is
#     no section chooser and no settings form, so Material had nothing to
#     navigate with (Simon, 2026-10-25: "a material lock up moving out from the
#     platin hub settings page which doesnt show anything at all").
#   * A string missing from strings.txt shows as its raw token.
#
# usage: perl t_template.pl [template]   (default: the plugin's own)

use strict;
use warnings;

my $tpl = shift || '../PlatinBridge/HTML/EN/plugins/PlatinBridge/settings/basic.html';
my $str = '../PlatinBridge/strings.txt';

my ( $pass, $fail ) = ( 0, 0 );

sub ok {
    my $n = pop;
    my $c = @_ ? $_[0] : 0;
    if   ($c) { $pass++ }
    else      { $fail++; print "  FAIL $n\n" }
}

my $t = do { open my $fh, '<', $tpl or die "cannot read $tpl: $!"; local $/; <$fh> };
my $s = do { open my $fh, '<', $str or die "cannot read $str: $!"; local $/; <$fh> };

print "-- the page is wrapped the way LMS 9.1 draws a settings page --\n";

my @dirs = $t =~ /\[%-?\s*(.*?)\s*-?%\]/gs;

ok( @dirs && $dirs[0] eq 'PROCESS settings/header.html',
    'the first directive is PROCESS settings/header.html - it draws the section chooser and the settings form' );
ok( @dirs && $dirs[-1] eq 'PROCESS settings/footer.html', 'the last is PROCESS settings/footer.html' );

# The settings files LMS 9.1's own skins provide to a plugin page.
my %SHIPPED = map { $_ => 1 } qw( settings/header.html settings/footer.html );
my @used = $t =~ /\b(?:PROCESS|INCLUDE|WRAPPER|INSERT)\s+(settings\/[\w.\/]+)/g;
my @unknown = grep { !$SHIPPED{$_} } @used;
ok( !@unknown, 'no settings file LMS does not ship is included' . ( @unknown ? " (found: @unknown)" : '' ) );

# Blocks balance: every IF / UNLESS / FOREACH / WHILE / WRAPPER / BLOCK / SWITCH
# has its END. A missing one is a template error, and a template error renders
# nothing at all.
my $open = grep { /^(?:IF|UNLESS|FOREACH|WHILE|WRAPPER|BLOCK|SWITCH)\b/ } @dirs;
my $end  = grep { /^END\b/ } @dirs;
ok( $open == $end, "every block is closed ($open opened, $end END)" );

print "-- every string the page shows exists --\n";

my %have = map { $_ => 1 } $s =~ /^(PLUGIN_\w+)\s*$/mg;
my %want = map { $_ => 1 } ( $t =~ /\b(PLUGIN_PLATIN_\w+)/g );
my @missing = grep { !$have{$_} } sort keys %want;
ok( !@missing, 'every PLUGIN_PLATIN_ token in the template is in strings.txt' . ( @missing ? " (missing: @missing)" : '' ) );
ok( scalar( keys %want ) > 5, 'CONTROL: the template was read and has its strings' );

printf "\n%s: %d passed, %d failed\n", ( $fail ? 'FAIL' : 'ok' ), $pass, $fail;
exit( $fail ? 1 : 0 );
