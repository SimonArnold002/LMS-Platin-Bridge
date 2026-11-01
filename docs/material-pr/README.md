# Add Platin Hub player icon

Adds a player icon for Platin Stereo Hub players, which the LMS Platin Hub
Bridge plugin reports with `model` `platinbridge`.

New `images/platin.svg` (24×24, single path, `fill="#000"`) and one entry in
`misc/player-icons.json`.

## The artwork

Platin's C-and-slash mark, redrawn as a plain Material icon. It is a single
path, monochrome and unstroked, so `_svgHandler` themes it with its single
`fill=` substitution. It inverts correctly on a dark background.

It is built for 24 px rather than copied at logo weight. In the original the
tail is a hairline and the slash is under a pixel wide at this size, so both
would grey out. The outline is thickened by 0.25 units and the slash is drawn
1.4 units wide on its own axis. The C is 31 smooth cubic curves, with no
polygon segments. The ink sits exactly inside the 2–22 box.

## Files

| file | goes to |
|---|---|
| `platin.svg` | `MaterialSkin/HTML/material/html/images/platin.svg` |
| `player-icons.json.diff` | `MaterialSkin/HTML/material/html/misc/player-icons.json` (adds `"platinbridge":{"svg":"platin"}` after `hqplayer`) |

## Copyright

Platin's mark, redrawn for this icon. No affiliation or endorsement implied.

Happy to drop the artwork and point the entry at an existing glyph instead
(`"platinbridge":{"icon":"speaker"}`) if you'd rather not carry it. The mapping
is the useful part.
