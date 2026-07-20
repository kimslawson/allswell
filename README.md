# AllsWell

A convert-everything Mac utility, grown from
[ImageWell](https://github.com/kimslawson/imagewell): a single media well.
Drop or paste a file into it and it is immediately converted and saved to the
folder of your choice.

| ![App icon](AllsWell/Assets.xcassets/AppIcon.appiconset/icon_256.png) | ![The AllsWell window](screenshot.png) |
|:---:|:---:|
| Drag a file to the app icon in the Dock | or to the well |

One well, type-aware: the format picker offers what makes sense for what you
dropped.

| In | Out (native) | Out (with ffmpeg installed) |
|---|---|---|
| Images | PNG, JPG | — |
| Audio | M4A/AAC, WAV, FLAC, ALAC | + MP3, OGG |
| Video | MP4 H.264, MP4 HEVC, MOV ProRes, M4A (audio extract) | + WebM, MP3 extract |

The conversion engine is a small `Converter` protocol with ImageIO,
AVFoundation, and (optionally) ffmpeg backends behind it.

## Behavior

- **Drop or paste.** Drag a file (or raw image data) into the well, or focus
  the well and ⌘V. Dropping a file on the Dock icon works too, even when the
  window is closed.
- **Batches are just fatter drops.** Drop several files — or a folder (top
  level only, no recursion) — and everything supported converts through a
  serial queue. The format pickers show only the media classes present, in
  fixed slots that never move; changing a picker re-converts just that
  class's files. Files already in the target format are skipped ("Saved 3 ·
  497 skipped"), failures don't stop the queue, and originals are never
  touched. The filename row becomes a summary ("14 images · 3 songs · 2
  movies"); files keep their own names.
- **In place.** A checkbox switches output from the chosen folder to
  next-to-the-original, handy for batch drops; the folder picker blanks out
  while it's on.
- **The log knows why.** Window ▸ Show Log (⌘L) opens a second window with
  every save, skip, and failure (with the reason) for the session —
  filterable, errors-only scope, selectable and copyable. Batches never
  interrupt with dialogs; this is where their errors land.
- **Auto-save.** The moment something lands, it is converted and written to
  the current destination using the current filename and format. A small toast
  confirms where it went. Conversions that take more than a beat show a thin
  progress bar with a cancel ✕ over the well.
- **Drag it back out.** Once converted, the proxy in the well *is* the
  converted file: drag it out into Finder, Mail, or any other app. A batch
  drags as the whole set of converted files.
- **Type-aware format picker.** The format popup offers what makes sense for
  what you dropped, and remembers your last choice per media class.
- **Fix-ups are renames.** Editing the filename, switching the format, or
  changing the destination after a save re-converts and moves the previous
  auto-saved file to the Trash — no littered copies.
- **Filename prefill.** Dragged files keep their original name; pasted data
  gets a timestamp (`Media 2026-06-11 at 14.32.05`). Name collisions get
  ` 2`, ` 3`, … appended.
- **HEIC gets converted.** Incoming HEIC/HEIF automatically flips the format
  picker to JPG. Anything ImageIO can read natively (TIFF, GIF, BMP, WebP,
  …) is ingested and converted; EXIF rotation is baked in so exports are
  upright. JPG exports use 0.9 quality and flatten transparency onto white.
- **Audio converts natively.** MP3, WAV, AIFF, CAF, FLAC, M4A in; M4A/AAC,
  WAV, FLAC, ALAC out — all via AVFoundation, no dependencies.
- **Video auto-starts.** Drop a movie and the transcode begins immediately;
  the well shows the poster frame, a thin progress bar with a cancel ✕
  appears, and a toast lands when it's done. Weird containers default the
  picker to MP4 H.264, the way HEIC defaults images to JPG.
- **ffmpeg appears by magic.** If a Homebrew or MacPorts ffmpeg is installed
  (`/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`), MP3, OGG, and
  WebM quietly join the pickers — including MP3-extract-from-video — and
  containers AVFoundation can't read (MKV, WebM, AVI, OGG, …) still
  convert. The app checks which encoders your particular build ships
  (`ffmpeg -encoders`) and offers only those, so a vorbis-less build
  simply has no OGG entry rather than a dead one. No ffmpeg, no trace
  of it.
- **Destination memory.** Defaults to the Desktop; remembers the last folder
  you picked (and the last format per media class) across launches.

The window is a utility panel — narrow titlebar, small traffic lights, small
title. The filename, per-class format pickers, and destination controls live
in a compact strip under the well.

No dependencies. AppKit + ImageIO + AVFoundation only (ffmpeg strictly
optional, never bundled).

## Building

Requires macOS 13+ and Xcode 15+.

Open `AllsWell.xcodeproj` in Xcode and run, or from the command line:

```sh
xcodebuild -project AllsWell.xcodeproj -target AllsWell -configuration Release build
open build/Release/AllsWell.app
```

The app is ad-hoc signed and unsandboxed; macOS will ask once for permission
to write to Desktop/Documents/Downloads.

## App icon

The icon (an old-school Aqua image well holding audio, image, and video
documents side by side — the outer two clipped by the well's edges — drawn
on the modern macOS icon grid) is generated by:

```sh
pip3 install pillow
python3 scripts/make_icon.py
```

which rewrites the PNGs in `AllsWell/Assets.xcassets/AppIcon.appiconset/`.
