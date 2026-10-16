# AeroGrid motion demo

An 80-second animated recreation of everyday AeroGrid use, created with Claude Opus. All app content is fictional. It is not a recording of real gesture input or the window engine, and does not serve as hardware-test evidence.

[Watch the MP4](../docs/media/AeroGrid-Demo-Opus.mp4) · [Storyboard](STORYBOARD.md)

## What it shows

- An editor and terminal sharing a workspace.
- A quick three-finger move to research, followed by held map exploration and release-to-open.
- Hover access to the organizer, stacking/splitting app cards, and moving a whole space with its arrangement.
- Four-finger navigation across two displays.

The animation stylizes transitions and may differ from the current app’s materials, timings, and minor interface details. It does not show physical monitor disconnection or live screenshot thumbnails.

## Source

- `src/demo.js`: deterministic Canvas 2D animation; `frame(t)` draws an instant.
- `src/template.html`: player and timeline.
- `assets/icons`: Apple app icons used in the demonstration; the editor icon is drawn in code.
- `AeroGrid-Demo-Opus.html`: generated, self-contained player. Open locally in Chrome; `?t=25` seeks and `?autoplay` plays.
- `build.py`: embeds JavaScript and icons into the standalone HTML.
- `render.mjs`: renders frames through headless Chrome/CDP and encodes with ffmpeg.

## Rebuild

Requires Python 3, Node 22+, Google Chrome, and ffmpeg. No npm dependencies are needed. `CHROME` and `FFMPEG` environment variables override the macOS executable defaults in the renderer.

```sh
cd demo
python3 build.py
mkdir -p build
node render.mjs video build/AeroGrid-Demo-Opus.mp4
node render.mjs stills build/frames 25 42 68.5
```

The published video is H.264/yuv420p, 1920×1080, 30 fps, without audio, with fast-start metadata. Application artwork remains the property of its respective owners; see [notices](../THIRD_PARTY_NOTICES.md).
