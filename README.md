# App Audio Mixer

*** NOTE VERY IMPORTANT

Free and open source. macOS will warn that the app is from an unidentified developer — this is normal for free apps. Right-click the app and choose "Open" the first time. You'll also be asked to allow System Audio Recording, which the app needs to control per-app volume (nothing is ever recorded).

A macOS menu bar app that gives every app its own volume slider — set Spotify to 30% while a YouTube video in Chrome stays at 100%, mute Discord notifications without muting the system, and so on.

READ ABOVE

## Requirements

- macOS 14.4 (Sonoma) or later — the app uses Core Audio process taps, which are only available from 14.4 up
- Xcode (or Command Line Tools with a recent Swift toolchain) to build

## Build the DMG

```bash
chmod +x build_dmg.sh   # only needed if the executable bit didn't survive the zip
./build_dmg.sh
```

The finished disk image lands at `build/AppAudioMixer.dmg`. Open it, drag **App Audio Mixer** into Applications, and launch it.

Two first-launch notes:

1. The app is **ad-hoc signed** (no Developer ID, no notarization), so Gatekeeper will complain. Right-click the app → Open → Open. This is fine for personal use; distributing it to other people would require a paid Apple Developer account and notarization.
2. The first time you move a slider, macOS will ask for **System Audio Recording** permission (System Settings → Privacy & Security). This is required by the tap API even though the app never records anything — audio flows straight from the tap to your speakers.

## How it works

There's no kernel extension and no virtual audio driver. For each app you adjust, the mixer:

1. Creates a **Core Audio process tap** on that app's audio with `muteBehavior = .mutedWhenTapped`, which silences the app's direct path to the speakers.
2. Builds a private **aggregate device** combining the tap (input side) with your current default output device (output side).
3. Runs an IOProc that copies tap audio to the hardware every cycle, multiplied by the slider's gain (0–200%).

Quit the app (or hit Reset All) and every tap is destroyed, instantly returning all apps to normal untouched output. If the mixer ever crashes, coreaudiod cleans up the taps automatically — you can't end up with a permanently muted app.

## Usage details

- Apps appear in the list **when they're playing audio**. Once you've adjusted an app, it stays in the list even while paused.
- Chromium browsers play audio through helper processes, so an entry may show up as e.g. "Google Chrome Helper" — that's normal.
- Slider range is 0–200%. Above 100% is a straight digital boost and can clip loud material.
- Switching output devices (e.g. plugging in headphones) is handled: the mixer rebuilds its routing onto the new default device after a beat.

## Known limitations

- Audio routed through the mixer picks up a few milliseconds of extra latency (one IO cycle). Inaudible for music/video; if you're doing latency-critical audio work, hit Reset All first.
- Per-process control means multi-process apps are controlled per helper process, not grouped under the parent app.
- Volumes aren't persisted across launches (easy future addition: store `bundleID → volume` in UserDefaults and reapply when a matching process starts playing).
