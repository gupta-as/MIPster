# MIPster

A Lyrion Music Server plugin for MusicIP. It sends Lyrion's play history and ratings (and those of the
Alternative Play Count plugin, if installed) to MusicIP, and plays MusicIP's mixes in Lyrion as endless
chains or one-off batches, shaped by MusicIP filters, recipes, moods and Power Search.

Available features depend on the version and type of MusicIP server you run — see
[Which MusicIP](#which-musicip).

## Install

1. In Lyrion: **Settings > Plugins**, scroll to **Additional repositories**, and paste:

       https://raw.githubusercontent.com/gupta-as/MIPster/main/repo.xml

2. Click Apply. **MIPster** appears in a group of its own. Tick it, click Apply, and restart Lyrion.
3. Open MIPster's settings and set the MusicIP host and port (default `localhost:10002`), and, if Lyrion and
   MusicIP see your music under different paths, the two path settings (for example `/music` in Lyrion and
   `Z:\music` in MusicIP).

## Which MusicIP

MIPster works with MusicIP 1.8 and 1.9, headless or Mixer. It has been tested on 1.9 (1.96b); by MusicIP's
own documentation, everything it asks of MusicIP is also in 1.8.

| | MusicIP server (headless) | MusicIP Mixer (windowed) |
|---|---|---|
| Chains, batches, filters, recipes, moods | yes | yes |
| Statistics export | yes | yes |
| Power Search | no — hidden automatically | yes, with a registered Mixer (1.9; untested on 1.8) |
| Largest mix | 75 tracks (1.9) | no limit |

MIPster asks MusicIP whether it can take a Power Search before offering one, so where it can't, the option
simply doesn't appear.

On 1.8, FLAC files keep only the first value of a repeated tag (a second genre, say), so filters and Power
Search on those fields see less. 1.9 keeps every value.

Ready-made Docker images: [`saysaar/musicip-1.9-headless`](https://hub.docker.com/r/saysaar/musicip-1.9-headless) (headless) and [`saysaar/musicip-1.9-gui`](https://hub.docker.com/r/saysaar/musicip-1.9-gui) (Mixer).

## Lyrion and apps

The plugin has only been tested with recent Lyrion versions but is likely to work with older versions. All functionality is available in the Classic and Material interfaces and in Lyrplay. iPeng allows full control but lacks the ability to perform a new Power Search within the app.

## What it does

**Chains.** Switch the chain on for a player and MIPster keeps one track queued ahead. Each new track comes
from a MusicIP mix seeded from the track before, after MIPster trims the mix against Lyrion's statistics:
tracks already queued are always skipped, and tracks played recently, played often, rated low, or played
since the last export can be skipped too (each is a setting). A player with the chain on is left alone by Lyrion's "Don't Stop The Music".

**Batches.** A one-off list of MusicIP tracks added to the queue: from a song or an album (song and album
menus), or from a mood.

**MIP Controls** are in Extras, one page per player.  The same controls (except for Power Search) are also available in iPeng settings and player menu on hardware players. Chains and mood batches are played and controlled from here. Song or Album based batches are started from the song/album context menu.

**MIP Live View** — the playing track and the next one, with their Lyrion statistics.

**MIP Power Search** — build a filter from boxes (genre, artist, composer, album, file path and more,
include or exclude, match all or any) without writing a filter in MusicIP. Before saving, MIPster asks
MusicIP how many tracks the search leaves, so a typo or a too-narrow search is caught. It then appears as
**(Power Search)** in the player's Filter list. Needs the MusicIP Mixer.

**Statistics export** — play counts, last-played dates and ratings go to MusicIP after each Lyrion library
scan, at a set time each day, or on demand, and MusicIP's cache is saved at the end. Lyrion's 0–100 ratings
become MusicIP's 1–5 stars through five bands you set. The Exports page shows how the last export ended and
when.

**Auto Sleep** — between set hours, lowers the volume a step at each track change and sets Lyrion's sleep
timer for a set number of minutes; on or off per player.

**Alarms** — MIPster can be chosen as an alarm's source; it starts from what is queued, or from a random
track.

## Credits and licence

MIPster descends from **SugarCube** by Charles Parker (Spicefly), continued by **AF-1**.
Thanks to **HB64** for ideas and fixes. Released under the GNU General Public License v3 — see
[LICENSE](LICENSE).
