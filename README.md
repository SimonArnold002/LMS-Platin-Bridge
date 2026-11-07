# Platin Hub Bridge — LMS Plugin

A plugin for **Lyrion Music Server** that presents the **Platin Stereo Hub HT** as a native LMS player. Play to it, pause, seek and set its volume from Material or any control point; switch the Hub on and off with the player's power button; and use the Hub's own remote, with LMS following along.

It talks to the Hub over UPnP for playback and over the Hub's own control port for power and input. **It carries no audio stage of its own**: it offers LMS the formats the Hub plays and passes the audio through untouched. For DSP, upsampling or ReplayGain, use [SqueezeDSP](https://github.com/Foxenfurter/SqueezeDSP) on the player.

**Bespoke to one renderer.** This is not a general UPnP bridge and will not be made into one. It is built around one rule: **nothing the Hub reports can ever start LMS playing**. Switching the Hub off, putting it in standby or changing its input never wakes the music up.

---

## Features

| Feature | What it gives you | Needs |
|---|---|---|
| **Appears as a real player** | Each Platin Hub on the network gets its own LMS player, named as the Hub names itself | Nothing |
| **Found automatically** | Discovered on the network, with nothing to configure | The Hub reachable from the server by multicast |
| **Stable player identity** | The Hub mints a new UPnP identity on every reboot; the player, its settings and its playlist stay the same | Nothing |
| **Untouched audio** | LMS sends each track in a format the Hub lists as playable, and the bytes reach the Hub as LMS produced them | Nothing |
| **Gapless** | The next track is handed to the Hub before the current one ends | Nothing |
| **Power button** | LMS's power button switches the Hub on and off | Nothing |
| **Off means off** | Powering off in LMS switches the Hub off only while it is on its Streaming input, so a Hub playing the TV is left alone | Nothing |
| **The Hub's remote** | Power, play/pause and volume from the remote or the app are followed in LMS; switching the Hub to another input pauses LMS | Nothing |
| **On is never play** | Switching the Hub on powers the LMS player on without starting playback | Nothing |
| **Mute** | Mute in LMS mutes the Hub | Nothing |
| **Track length on the Hub** | The Hub's display shows each track's length | Nothing |
| **Status page** | Settings → Plugins → Platin Hub Bridge shows each Hub's address, connection, power, input and the formats offered to LMS | Nothing |

---

## Requirements

- **Lyrion Music Server 8.0+**.
- A **Platin Stereo Hub HT** on the same network as the server, reachable by multicast (SSDP) and on TCP port 50006, its control port.
- **If you use the UPnP Bridge plugin**, disable the Hub in it. Otherwise LMS shows two players with the Hub's name, both driving the one Hub.

---

## Installation

**Via repository (recommended).** In LMS go to **Settings → Plugins → Additional Repositories** and add:

```
https://simonarnold002.github.io/LMS-Platin-Bridge/repo.xml
```

Install **Platin Hub Bridge** from the plugin list and restart LMS. The Hub appears in Material's player list under its own name. Select it and play something.

**Manual.** Download `PlatinBridge.zip` from the [repository](https://github.com/SimonArnold002/LMS-Platin-Bridge) and unzip it so it sits as `Plugins/PlatinBridge/`:

```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/PlatinBridge
sudo unzip PlatinBridge.zip -d /var/lib/squeezeboxserver/Plugins/
```

Then restart LMS.

---

## Using SqueezeDSP with it

The player carries no DSP, upsampling or ReplayGain of its own: LMS never applies ReplayGain for a non-Squeezebox player. Turn SqueezeDSP on for the Hub's player to get them. **FLAC** is the recommended SqueezeDSP output for the Hub.

---

## Known limits

- **The remote's skip and back buttons do nothing** while LMS is playing. The Hub does not report them for UPnP playback. Skip from LMS instead.
- **Up to 96 kHz.** LMS sends the Hub at most 96 kHz; a higher-rate source is converted down on the way.

---

## Testing

```
sh tools/run_checks.sh
```

Syntax-checks every module against a stub `Slim/` tree, runs the unit suites, and sweeps for calls to subs that do not exist, which `perl -c` will not catch.

---

## License

MIT. See [LICENSE](LICENSE).
