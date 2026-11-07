# Platin Hub Bridge — LMS Plugin

A plugin for **Lyrion Music Server** that makes the **Platin Stereo Hub HT** a native LMS player.

---

## Features

| Feature | What it does |
|---|---|
| **Native player** | Each Platin Hub on your network appears in LMS as a player, found automatically |
| **Bit-perfect** | Plays in the formats the Hub supports, passed through untouched |
| **Gapless** | Albums play without gaps between tracks |
| **Power button** | Switch the Hub on and off from LMS |
| **Remote control** | Power, play/pause and volume from the Hub's remote or app show in LMS |
| **Mute** | Mute in LMS mutes the Hub |
| **Track length** | The Hub's display shows each track's length |
| **SqueezeDSP** | Add DSP and upsampling with SqueezeDSP |
| **Status page** | The Hub's connection, power, input and formats, under Settings → Plugins |

---

## Requirements

- Lyrion Music Server 8.0+
- A Platin Stereo Hub HT on the same network
- If you use the UPnP Bridge plugin, disable the Hub there

---

## Installation

In LMS go to **Settings → Plugins → Additional Repositories** and add:

```
https://simonarnold002.github.io/LMS-Platin-Bridge/repo.xml
```

Install **Platin Hub Bridge** and restart LMS. The Hub appears in the player list under its own name.

---

## License

MIT. See [LICENSE](LICENSE).
