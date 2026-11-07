# Changelog

All notable changes to **Platin Hub Bridge** are recorded here. This file records
what users receive: one entry per release published to `main`. Per-version
development notes live in `CLAUDE.md`.

## 0.2.10 — 2026-11-07

First release. The Platin Stereo Hub HT as a native Lyrion player: playback
over UPnP with the audio passed through untouched, and power and input over
the Hub's own control port.

### Features

- **The Hub as a Lyrion player.** Each Platin Hub on the network is found
  automatically and gets its own player, named as the Hub names itself. The
  player keeps its identity, settings and playlist across Hub reboots, though
  the Hub mints a new UPnP identity each time.
- **Untouched audio.** Lyrion is offered the formats the Hub lists as playable
  and sends each track in one of them; the bytes reach the Hub as Lyrion
  produced them. DSP, upsampling and ReplayGain are left to SqueezeDSP. Up to
  96 kHz.
- **Gapless.** The next track is handed to the Hub before the current one ends.
- **Power button.** Lyrion's power button switches the Hub on and off. Off
  switches the Hub off only while it is on its Streaming input, so a Hub
  playing the TV is left alone. On never starts playback.
- **The Hub's remote and app are followed.** Power, play/pause and volume
  changes made at the Hub show in Lyrion. Switching the Hub to another input
  pauses Lyrion. Playing to the player puts the Hub back on Streaming.
- **Nothing the Hub reports starts playback.** Switching it off, standby, an
  input change or a lost connection never wakes the music up. A Hub that stops
  answering is never read as stopped.
- **Mute** in Lyrion mutes the Hub.
- **Track length on the Hub's display.**
- **Seeking and resuming** part way through a FLAC track plays from the right
  place.
- **A status page** under Settings → Plugins → Platin Hub Bridge: each Hub's
  address, connection, power, input and the formats offered to Lyrion.

### Known limits

- The remote's skip and back buttons do nothing during Lyrion playback; the
  Hub does not report them.
