#!/bin/sh
# Syntax-check and unit-test the plugin without an LMS install.
#
# There is no LMS on the Mac, so `perl -c` cannot load Slim::*.  tools/Slim/**
# is a minimal stub tree that satisfies the `use` lines; it is NOT a simulator
# and proves nothing about runtime behaviour - only that the modules compile
# and that the logic is correct against stubs that follow LMS's contracts.
#
# Format.pm and Control.pm's framing have no Slim:: dependencies, so their
# suites test the real thing.
#
# Every suite's EXIT CODE is checked (set -e), not just its output: a suite
# that dies mid-run prints no FAIL line at all.
#
# Usage:  sh tools/run_checks.sh        (from anywhere)
set -e
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
rm -rf Plugins && mkdir -p Plugins && ln -sfn ../../PlatinBridge Plugins/PlatinBridge

echo "== syntax =="
for m in Trace Format Control UPnP Discovery Stream Player Settings Plugin; do
    perl -I. syncheck.pl "Plugins::PlatinBridge::$m"
done

echo
echo "== unit tests =="
perl -I. t_format.pl
perl -I. t_control.pl
perl -I. t_upnp.pl
perl -I. t_discovery.pl
perl -I. t_player.pl
perl -I. t_stream.pl
perl -I. t_plugin.pl
perl t_template.pl

echo
echo "== called-vs-defined sweep (perl -c will NOT catch these) =="
cd ../PlatinBridge
grep -ho 'Plugins::PlatinBridge::[A-Za-z]*::[a-zA-Z_]*' ./*.pm | sort -u | while read -r c; do
    mod=${c#Plugins::PlatinBridge::}; mod=${mod%%::*}; fn=${c##*::}
    grep -q "^sub $fn" "$mod.pm" 2>/dev/null \
        || grep -qE "^use constant +$fn\\b" "$mod.pm" 2>/dev/null \
        || echo "  MISSING $c"
done
echo "  (clean)"

echo
echo "== nothing of the 0.1.x audio stage is left =="
cd "$ROOT"
LEFT=$(grep -lE 'Plugins::PlatinBridge::(Gain|Wav|Encoder)|pbGain|pbEnc|pbFlow|pbPreamble|custom-convert' PlatinBridge/*.pm PlatinBridge/*.txt PlatinBridge/HTML -r 2>/dev/null || true)
if [ -n "$LEFT" ]; then
    echo "  STILL REFERENCED in: $LEFT"
    exit 1
fi
for f in Gain.pm Wav.pm Encoder.pm custom-convert.conf; do
    if [ -e "PlatinBridge/$f" ]; then echo "  PlatinBridge/$f still exists"; exit 1; fi
done
echo "  (clean)"

echo
echo "== version agreement =="
V_INSTALL=$(grep -o '<version>[^<]*' PlatinBridge/install.xml | cut -d'>' -f2)
V_REPO=$(grep -o 'version="[0-9.]*"' repo.xml | head -1 | cut -d'"' -f2)
V_CODE=$(grep -o "VERSION => '[0-9.]*'" PlatinBridge/Plugin.pm | cut -d"'" -f2)
echo "  install.xml=$V_INSTALL  repo.xml=$V_REPO  Plugin.pm=$V_CODE"
if [ "$V_INSTALL" != "$V_REPO" ] || [ "$V_INSTALL" != "$V_CODE" ]; then
    echo "  MISMATCH - the running build cannot be identified from install.xml alone"
    exit 1
fi
echo "  (agree)"
