# Platin Hub Bridge for Lyrion Music Server

Presents the **Platin Stereo Hub HT** to Lyrion as an ordinary player, over UPnP
AVTransport, and applies ReplayGain on the way out because the Hub cannot.

**Bespoke to one renderer.** This is not a general UPnP bridge and will not be
made into one.

## Why it exists

The generic UPnP bridge misreads renderer state: powering the Hub down makes
Lyrion start playing, which switches the unit back on. The rule this plugin is
built around is that **nothing the Hub reports may ever start Lyrion playing**,
and a Hub that stops answering has *no opinion* — it is never read as "stopped".

## What it does to the audio

Lyrion decodes, the plugin applies gain, the Hub plays. No external binary, no
subprocess, no new decoder — the player declares `pcm`, so Lyrion's existing
transcode table decodes every source with the binaries it already ships, and the
only stage added is one multiply per sample.

ReplayGain has to be the plugin's job because **Lyrion never applies it**:
`canDoReplayGain` returns 0 for any non-Squeezebox player, so the figure Lyrion
computes is stored and never read.

* The figure is **clamped to ≤ 0 dB** — attenuate only, never boost. That is not
  a limiter; it removes the need for one, since a multiplier of at most 1.0
  cannot increase a sample's magnitude and so cannot clip.
* **Depth rule:** gain applied → 24-bit; no gain and a lossless source → its
  native depth, untouched; no gain and a lossy source → 24-bit.

## Gapless

Decided from what the device itself advertises, not from a setting. If the Hub
lists `SetNextAVTransportURI`, tracks are pre-armed per-track. If it does not,
the plugin uses **Flow mode** — consecutive tracks are joined into one continuous
stream, so gapless does not depend on the renderer at all.

A stream's format is fixed once it starts, so the flow breaks on any change of
sample rate, bit depth or channel count. Within an album that costs nothing.

## Requirements

* Lyrion Music Server 8.0+
* A Platin Stereo Hub HT reachable by SSDP
* `lame` on the server, for the mp3 → pcm rule the plugin supplies (Lyrion ships
  no such rule of its own, because Squeezeboxes decode MP3 in hardware)

## Testing

```
sh tools/run_checks.sh
```

Syntax-checks every module against a stub `Slim/` tree, runs the unit suites, and
sweeps for calls to subs that do not exist — which `perl -c` will not catch.
`Gain.pm` has no `Slim::` dependencies, so its suite exercises the real audio
stage rather than a stub of it.
