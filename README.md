# NotchLite

A deliberately small notch app: **Now Playing + a file shelf**, nothing else.

Derived from [Islet](https://github.com/ZNLong2203/Islet) (MIT). The notes scratchpad, focus timer,
battery indicator, calendar panel and language switcher were removed, leaving one process, zero
third-party dependencies and no permission prompts.

## What it does

| | |
|---|---|
| **Now Playing** | Album art, title/artist, drag-to-seek progress, play/pause/skip. Works with Music, Spotify, 网易云音乐, browsers — anything that reports to the system Now Playing panel. While a track plays, the notch grows wings: cover on the left, a visualizer tinted to the album colours on the right. Track changes drop a small banner. |
| **File shelf** | Park files, images, links and text on the notch, then drag them out later. Five ways in: drag onto the notch · shake a dragged file to summon a drop zone · `⌃⌥V` pastes the clipboard · Finder → Services → *Add to NotchLite* · `open -a NotchLite <file>`. Share, AirDrop, copy or zip from the shelf. |

### Shortcuts

| Shortcut | Action |
|---|---|
| `⌃⌥D` | open / close the shelf |
| `⌃⌥V` | put the clipboard on the shelf |

Hover the notch to expand it; move away to collapse. The gear button opens a small settings menu
(haptics, shake-to-drop, remove-after-drag, launch at login, quit).

## Build

Requires macOS 14+ and Xcode command line tools. No dependencies to fetch.

```bash
scripts/build-app.sh            # → build/NotchLite.app (signed, see below)
scripts/build-app.sh --run      # build and launch
scripts/install.sh              # build + install into /Applications + relaunch
VERSION=0.2.0 scripts/build-app.sh
```

`swift build` alone works too; run the binary directly for development (`swift run`). Xcode can open
the package with `open Package.swift` if you prefer an IDE.

The MediaRemote framework and its `perl` driver are vendored under `vendor/mediaremote-adapter`
(taken from [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), BSD-3-Clause),
so packaging needs neither network access nor cmake.

## Permissions

Reading Now Playing needs no permission: it goes through `/usr/bin/perl` + a small bridge dylib,
which macOS allows. Controlling other players does, because macOS only lets one app at a time own
the playback slot:

| Permission | Why | Covers |
|---|---|---|
| Automation | AppleScript talks to the player directly, bypassing the slot entirely | Apple Music, Spotify |
| Accessibility | The player's own global shortcut is pressed on its behalf | NetEase (⌃⌥⌘S / ⌃⌥⌘A / ⌃⌥⌘D) |

Transport falls back in this order: script → MediaRemote (only when the player holds the slot) →
global shortcut. Nothing else is asked for — the shelf only stores paths.

## Known limitations

**Artwork for players without a scripting interface.** MediaRemote hands out artwork only for the
session that holds the system playback slot; for every other session it exposes the cover's
metadata (`ArtworkIdentifier`, size, MIME) but never the image itself. Scriptable players (Music,
Spotify) are fetched through AppleScript and are unaffected, so 网易云音乐 and other non-scriptable
players only refresh their cover while they own the slot. When they do not, the previous cover stays
on screen rather than showing a wrong one.

## Notes

- `CFBundleIdentifier` is a placeholder (`com.example.notchlite`) — change it before distributing,
  and re-sign with your own identity.
- `tools/procstat` and `tools/postnotify` are development helpers: measure a process's RSS/CPU via
  libproc, and drive the app's DEBUG hook from a shell.

## License

MIT — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
